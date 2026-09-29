#!/usr/bin/env bash
# Token-free live guard: omp reads a home's .omp/extensions once, when the agent
# starts, so a changed extension file reaches a running agent only by replacing
# it. bin/fm-ff-lib.sh's launch_surface_paths lists that path as omp's launch
# surface, and the session-start sweep restarts a live second mate whose home
# changed it; this guard proves the premise against the installed omp.
#
# A real rpc session in an isolated lab directory and HOME, driven by a local
# deterministic OpenAI-compatible model (no credentials, no provider call), loads
# a lab extension that records its version after every turn. The file is then
# rewritten to a new version: the running agent must keep recording the old one,
# and a replacement agent in the same directory must record the new one.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_OMP_EXTENSION_LOAD_LIVE omp node jq

OMP_VERSION=$(omp --version 2>/dev/null | head -1)
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-omp-ext-load.XXXXXX")
PROJECT="$LAB/project"
OUT="$LAB/versions"
RPC_LOG=''
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

fail() {
  printf 'not ok - %s: %s\n' "$OMP_VERSION" "$1" >&2
  exit 1
}
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
write_extension() { # <version>
  cat >"$PROJECT/.omp/extensions/zz-launch-load-lab.ts" <<TS
import { appendFileSync } from "node:fs";
type Pi = { registerProvider(name: string, config: Record<string, unknown>): void; on(event: string, handler: () => void): void };
export default function (pi: Pi) {
  pi.registerProvider("launch-load-lab", {
    baseUrl: \`http://127.0.0.1:\${process.env.FM_LAUNCH_LOAD_LAB_PORT}/v1\`,
    apiKey: "offline-test-only",
    api: "openai-completions",
    models: [{ id: "deterministic", name: "deterministic", reasoning: false, input: ["text"],
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 128000, maxTokens: 128 }],
  });
  pi.on("agent_end", () => appendFileSync(process.env.FM_LAUNCH_LOAD_LAB_OUT as string, "$1\n"));
}
TS
}
start_agent() { # <incarnation>
  RPC_LOG="$LAB/rpc.$1.log"
  rm -f "$LAB/rpc.in"
  mkfifo "$LAB/rpc.in"
  (cd "$PROJECT" && exec env -i PATH="$PATH" HOME="$LAB/home" TERM=dumb OMP_SKIP_SETUP=1 \
    FM_LAUNCH_LOAD_LAB_PORT="$(cat "$LAB/port")" FM_LAUNCH_LOAD_LAB_OUT="$OUT" \
    omp --mode rpc --no-session --cwd "$PROJECT" --auto-approve <"$LAB/rpc.in" >"$RPC_LOG" 2>"$LAB/rpc.$1.err") &
  OMP_PID=$!
  exec 3>"$LAB/rpc.in"
  wait_for_log '"type":"ready"' 240 || fail "incarnation $1 did not print its rpc ready frame"
  printf '%s\n' '{"id":"m","type":"set_model","provider":"launch-load-lab","modelId":"deterministic"}' >&3
  wait_for_log '"command":"set_model","success":true' 60 || fail "incarnation $1 did not accept the lab model"
}
prompt() { # <turn-count-after>
  printf '{"id":"p%s","type":"prompt","message":"hello"}\n' "$1" >&3
  wait_for_ends "$1" 120 || fail "turn $1 did not finish"
}

mkdir -p "$PROJECT/.omp/extensions" "$LAB/home"
cat >"$LAB/model.mjs" <<'JS'
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
node "$LAB/model.mjs" "$LAB/port" &
for _ in $(seq 50); do
  [ -s "$LAB/port" ] && break
  sleep 0.1
done
[ -s "$LAB/port" ] || fail "the local model server did not start"

write_extension v1
start_agent 1
prompt 1
[ "$(tail -1 "$OUT" 2>/dev/null)" = v1 ] || fail "the launched agent did not load the v1 extension"

write_extension v2
grep -qF '"v2\n"' "$PROJECT/.omp/extensions/zz-launch-load-lab.ts" || fail "the extension file was not rewritten, so the case is vacuous"
sleep 2
prompt 2
[ "$(tail -1 "$OUT")" = v1 ] ||
  fail "a running agent picked up the rewritten extension (recorded '$(tail -1 "$OUT")'), so omp no longer reads .omp/extensions only at launch and launch_surface_paths overstates it"

# Replace the agent: close its input, then stop it, since omp can take well
# over 30s to close on its own.
exec 3>&-
kill -TERM "$OMP_PID" 2>/dev/null || true
for _ in $(seq 60); do
  kill -0 "$OMP_PID" 2>/dev/null || break
  sleep 0.5
done
start_agent 2
prompt 1
[ "$(tail -1 "$OUT")" = v2 ] || fail "a replacement agent did not load the rewritten extension (recorded '$(tail -1 "$OUT")')"
printf 'ok - %s reads .omp/extensions only at launch: a running agent kept v1, its replacement loaded v2\n' "$OMP_VERSION"
