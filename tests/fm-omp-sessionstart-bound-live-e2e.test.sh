#!/usr/bin/env bash
# Token-free live guard: a session-start digest slower than omp's 30s extension
# handler cap must neither trip that cap nor be lost.
#
# omp times out every extension handler after 30s, so the turn-end guard
# extension waits a bounded time in before_agent_start and sends a slower
# digest the moment it completes. This guard proves that against the installed
# omp: a real rpc session in an isolated lab checkout and HOME, driven by a
# local deterministic OpenAI-compatible model (no credentials, no provider
# call), runs its first turn while a stub digest is still sleeping past the
# cap, then requires the next model request to carry that digest exactly once
# and omp to have logged no handler timeout.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_OMP_SESSIONSTART_BOUND_LIVE omp node jq git

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OMP_VERSION=$(omp --version 2>/dev/null | head -1)
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-omp-sessionstart-bound.XXXXXX")
PROJECT="$LAB/project"
RPC_LOG="$LAB/rpc.log"
REQUESTS="$LAB/requests.jsonl"
NONCE="SLOW-DIGEST-$$-$RANDOM"

# TERM first so omp retires its own worker processes, whose command lines the
# path scan cannot see; KILL only what is left.
reap() {
  exec 3>&- 2>/dev/null
  local pid
  for pid in $(ps -axo pid=,command= | awk -v lab="$LAB" 'index($0, lab) { print $1 }'); do kill -TERM "$pid" 2>/dev/null || true; done
  sleep 1
  for pid in $(ps -axo pid=,command= | awk -v lab="$LAB" 'index($0, lab) { print $1 }'); do kill -KILL "$pid" 2>/dev/null || true; done
  rm -rf "$LAB"
}
trap reap EXIT

fail() {
  printf 'not ok - %s: %s\n' "$OMP_VERSION" "$1" >&2
  tail -5 "$LAB/rpc.err" >&2 2>/dev/null
  exit 1
}
send() { printf '%s\n' "$1" >&3; }
wait_for_log() { # <fixed-string> <half-seconds>
  local i=0
  while [ "$i" -lt "$2" ]; do
    grep -Fq -- "$1" "$RPC_LOG" 2>/dev/null && return 0
    sleep 0.5
    i=$((i + 1))
  done
  return 1
}
agent_ends() { jq -r 'select(.type == "agent_end") | .type' "$RPC_LOG" 2>/dev/null | grep -c . || true; }
wait_for_ends() { # <count> <half-seconds>
  local i=0
  while [ "$i" -lt "$2" ]; do
    [ "$(agent_ends)" -ge "$1" ] && return 0
    sleep 0.5
    i=$((i + 1))
  done
  return 1
}
# How many times request <n> (1-based) carries the digest nonce.
nonce_count() { sed -n "${1}p" "$REQUESTS" | grep -o "$NONCE" | grep -c . || true; }

git clone -q "$ROOT" "$PROJECT" || fail "could not clone the lab checkout"
cp "$ROOT/.omp/extensions/fm-primary-turnend-guard.ts" "$PROJECT/.omp/extensions/"
mkdir -p "$PROJECT/state" "$PROJECT/config" "$PROJECT/data" "$LAB/home"
# A digest that outlives omp's 30s handler cap.
cat >"$PROJECT/bin/fm-sessionstart-run.sh" <<SH
#!/usr/bin/env bash
sleep 35
touch "$LAB/digest-done"
printf '%s\n' "$NONCE"
SH
chmod +x "$PROJECT/bin/fm-sessionstart-run.sh"

# A deterministic chat-completions stream that records every request body.
cat >"$LAB/model.mjs" <<'JS'
import { createServer } from "node:http";
import { appendFileSync, writeFileSync } from "node:fs";
const chunk = (choices, usage) => `data: ${JSON.stringify({ id: "x", object: "chat.completion.chunk", created: 0, model: "deterministic", choices, ...(usage ? { usage } : {}) })}\n\n`;
const server = createServer((req, res) => {
  let body = "";
  req.on("data", (part) => { body += part; });
  req.on("end", () => {
    appendFileSync(process.argv[3], `${JSON.stringify(body)}\n`);
    res.writeHead(200, { "content-type": "text/event-stream" });
    res.write(chunk([{ index: 0, delta: { role: "assistant", content: "ok" }, finish_reason: null }]));
    res.write(chunk([{ index: 0, delta: {}, finish_reason: "stop" }]));
    res.write(chunk([], { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 }));
    res.end("data: [DONE]\n\n");
  });
});
server.listen(0, "127.0.0.1", () => writeFileSync(process.argv[2], String(server.address().port)));
JS
cat >"$PROJECT/.omp/extensions/zz-sessionstart-bound-lab.ts" <<'TS'
type Pi = { registerProvider(name: string, config: Record<string, unknown>): void };
export default function (pi: Pi) {
  pi.registerProvider("sessionstart-bound-lab", {
    baseUrl: `http://127.0.0.1:${process.env.FM_SESSIONSTART_BOUND_LAB_PORT}/v1`,
    apiKey: "offline-test-only",
    api: "openai-completions",
    models: [{ id: "deterministic", name: "deterministic", reasoning: false, input: ["text"],
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 128000, maxTokens: 128 }],
  });
}
TS

node "$LAB/model.mjs" "$LAB/port" "$REQUESTS" &
for _ in $(seq 50); do
  [ -s "$LAB/port" ] && break
  sleep 0.1
done
[ -s "$LAB/port" ] || fail "the local model server did not start"
mkfifo "$LAB/rpc.in"
(cd "$PROJECT" && exec env -i PATH="$PATH" HOME="$LAB/home" TERM=dumb FM_SESSIONSTART_BOUND_LAB_PORT="$(cat "$LAB/port")" \
  FM_OMP_HARNESS=omp OMP_SKIP_SETUP=1 \
  omp --mode rpc --no-session --cwd "$PROJECT" --auto-approve <"$LAB/rpc.in" >"$RPC_LOG" 2>"$LAB/rpc.err") &
exec 3>"$LAB/rpc.in"

wait_for_log '"type":"ready"' 240 || fail "did not print its rpc ready frame"
send '{"id":"m","type":"set_model","provider":"sessionstart-bound-lab","modelId":"deterministic"}'
wait_for_log '"command":"set_model","success":true' 60 || fail "did not accept the lab model"
send '{"id":"p1","type":"prompt","message":"hello"}'
wait_for_ends 1 70 || fail "the first turn did not finish while the digest was still running"
[ ! -e "$LAB/digest-done" ] || fail "the digest finished before the first turn, so the case is vacuous"
[ "$(nonce_count 1)" -eq 0 ] || fail "the first request carried a digest that had not completed"

for _ in $(seq 80); do
  [ -e "$LAB/digest-done" ] && break
  sleep 0.5
done
[ -e "$LAB/digest-done" ] || fail "the stub digest never completed"
sleep 3
send '{"id":"p2","type":"prompt","message":"again"}'
wait_for_ends 2 60 || fail "did not finish the second turn"
[ "$(nonce_count 2)" -eq 1 ] || fail "the next request carried the slow digest $(nonce_count 2) times, not once"

if grep -rqs 'handler timed out' "$LAB/home" "$RPC_LOG" "$LAB/rpc.err"; then
  fail "omp logged an extension handler timeout: $(grep -rhs 'handler timed out' "$LAB/home" "$RPC_LOG" "$LAB/rpc.err" | head -1)"
fi
printf 'ok - %s delivers a session-start digest slower than the handler cap exactly once with no handler timeout\n' "$OMP_VERSION"
