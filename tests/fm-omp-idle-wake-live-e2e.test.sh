#!/usr/bin/env bash
# Token-free live guard: a watcher wake must start a turn in an IDLE omp
# session even when the transcript tail is not an assistant message.
#
# omp only auto-resumes an explicitly queued follow-up from an assistant or
# tool-result tail, so an idle session whose last entry is a custom message
# (omp's advisor card, an extension note) strands a follow-up wake until the
# next typed prompt. The watch extension therefore sends an idle-session wake
# with no deliverAs, which omp starts as a turn. This guard proves that against
# the installed omp: a real rpc session in an isolated lab checkout and HOME,
# driven by a local deterministic OpenAI-compatible model (no credentials, no
# provider call), arms the watcher, leaves a custom-message tail, fires one
# actionable close, and requires the wake to run as a new turn that consumes
# it (no replacement handoff left behind at shutdown).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_OMP_IDLE_WAKE_LIVE omp node jq git

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OMP_VERSION=$(omp --version 2>/dev/null | head -1)
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-omp-idle-wake.XXXXXX")
PROJECT="$LAB/project"
RPC_LOG="$LAB/rpc.log"
OMP_PID=''

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

fail() { printf 'not ok - %s: %s\n' "$OMP_VERSION" "$1" >&2; tail -5 "$LAB/rpc.err" >&2 2>/dev/null; exit 1; }
send() { printf '%s\n' "$1" >&3; }
wait_for_log() {  # <fixed-string> <half-seconds>
  local i=0
  while [ "$i" -lt "$2" ]; do
    grep -Fq -- "$1" "$RPC_LOG" 2>/dev/null && return 0
    sleep 0.5; i=$((i + 1))
  done
  return 1
}
agent_ends() { jq -r 'select(.type == "agent_end") | .type' "$RPC_LOG" 2>/dev/null | grep -c . || true; }
wait_for_ends() {  # <count> <half-seconds>
  local i=0
  while [ "$i" -lt "$2" ]; do
    [ "$(agent_ends)" -ge "$1" ] && return 0
    sleep 0.5; i=$((i + 1))
  done
  return 1
}

git clone -q "$ROOT" "$PROJECT" || fail "could not clone the lab checkout"
cp "$ROOT/.omp/extensions/fm-primary-omp-watch.ts" "$PROJECT/.omp/extensions/"
mkdir -p "$PROJECT/state" "$PROJECT/config" "$PROJECT/data" "$LAB/home"

# A deterministic chat-completions stream: every request answers "ok".
cat > "$LAB/model.mjs" <<'JS'
import { createServer } from "node:http";
import { writeFileSync } from "node:fs";
const chunk = (choices, usage) => `data: ${JSON.stringify({ id: "x", object: "chat.completion.chunk", created: 0, model: "deterministic", choices, ...(usage ? { usage } : {}) })}\n\n`;
const server = createServer((req, res) => {
  req.resume();
  req.on("end", () => {
    res.writeHead(200, { "content-type": "text/event-stream" });
    res.write(chunk([{ index: 0, delta: { role: "assistant", content: "ok" }, finish_reason: null }]));
    res.write(chunk([{ index: 0, delta: {}, finish_reason: "stop" }]));
    res.write(chunk([], { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 }));
    res.end("data: [DONE]\n\n");
  });
});
server.listen(0, "127.0.0.1", () => writeFileSync(process.argv[2], String(server.address().port)));
JS
# Registers that model and, after every run, appends a custom message while
# idle, the same non-assistant tail omp's advisor card leaves.
cat > "$PROJECT/.omp/extensions/zz-idle-wake-lab.ts" <<'TS'
type Pi = {
  registerProvider(name: string, config: Record<string, unknown>): void;
  on(event: string, handler: () => void): void;
  sendMessage(message: { customType: string; content: string; display: boolean }): void;
};
export default function (pi: Pi) {
  pi.registerProvider("idle-wake-lab", {
    baseUrl: `http://127.0.0.1:${process.env.FM_IDLE_WAKE_LAB_PORT}/v1`,
    apiKey: "offline-test-only",
    api: "openai-completions",
    models: [{ id: "deterministic", name: "deterministic", reasoning: false, input: ["text"],
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 128000, maxTokens: 128 }],
  });
  pi.on("agent_end", () => {
    setTimeout(() => pi.sendMessage({ customType: "idle-wake-lab-note", content: "lab note", display: true }), 200);
  });
}
TS

node "$LAB/model.mjs" "$LAB/port" &
for _ in $(seq 50); do [ -s "$LAB/port" ] && break; sleep 0.1; done
[ -s "$LAB/port" ] || fail "the local model server did not start"
mkfifo "$LAB/rpc.in"
(cd "$PROJECT" && exec env -i PATH="$PATH" HOME="$LAB/home" TERM=dumb FM_IDLE_WAKE_LAB_PORT="$(cat "$LAB/port")" \
  FM_OMP_HARNESS=omp OMP_SKIP_SETUP=1 FM_POLL=1 FM_SIGNAL_GRACE=0 FM_HEARTBEAT=600 \
  omp --mode rpc --no-session --cwd "$PROJECT" --auto-approve <"$LAB/rpc.in" >"$RPC_LOG" 2>"$LAB/rpc.err") &
OMP_PID=$!
exec 3>"$LAB/rpc.in"

wait_for_log '"type":"ready"' 240 || fail "did not print its rpc ready frame"
send '{"id":"m","type":"set_model","provider":"idle-wake-lab","modelId":"deterministic"}'
wait_for_log '"command":"set_model","success":true' 60 || fail "did not accept the lab model"
# The first turn runs session start, which takes the home lock the arm needs.
send '{"id":"p1","type":"prompt","message":"hello"}'
wait_for_ends 1 120 || fail "did not finish the first turn"
send '{"id":"arm","type":"prompt","message":"/fm-watch-arm-omp"}'
wait_for_log 'watcher: started' 120 || fail "/fm-watch-arm-omp did not start a watcher"
sleep 2
send '{"id":"g","type":"get_messages"}'
wait_for_log '"command":"get_messages"' 40 || fail "get_messages did not answer"
tail_role=$(jq -r 'select(.command == "get_messages") | .data.messages[-1].role' "$RPC_LOG")
[ "$tail_role" != assistant ] && [ "$tail_role" != toolResult ] \
  || fail "the lab did not leave a non-assistant idle tail (got '$tail_role'), so the case is vacuous"
[ "$(agent_ends)" -eq 1 ] || fail "a turn ran before the wake"

: > "$PROJECT/state/idle-wake.meta"
printf 'done: idle wake probe\n' >> "$PROJECT/state/idle-wake.status"
wait_for_ends 2 120 || fail "an actionable close did not start a turn in the idle session (tail role '$tail_role')"
jq -r 'select(.type == "message_start" and .message.role == "user") | .message.content[0].text' "$RPC_LOG" \
  | grep -q 'FIRSTMATE WATCHER WAKE: signal:' || fail "the new turn did not carry the watcher wake"

exec 3>&-
for _ in $(seq 60); do kill -0 "$OMP_PID" 2>/dev/null || break; sleep 0.5; done
[ ! -e "$PROJECT/state/extensions/omp-primary-watch/session-replacement-actionable.json" ] \
  || fail "the delivered wake was left unconsumed in the replacement handoff"
printf 'ok - %s starts a turn for a watcher wake in an idle session whose tail is a custom message\n' "$OMP_VERSION"
