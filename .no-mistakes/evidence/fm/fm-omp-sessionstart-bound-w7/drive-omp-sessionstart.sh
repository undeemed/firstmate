#!/usr/bin/env bash
# Live driver for the omp session-start bound. Runs a real omp rpc session in an
# isolated lab checkout + HOME against a local deterministic model.
# Usage: drive-omp-sessionstart.sh <label> <extension.ts> <digest-sleep-s> <mode>
#   mode: single    - one prompt, then wait for the digest and any digest turn
#         twoprompt - prompt 1, then prompt 2 right after turn 1 ends while the
#                     digest is still pending; measures prompt-2 latency
set -u
LABEL=$1 EXT=$2 SLEEP=$3 MODE=$4
ROOT=/home/ubuntu/.no-mistakes/worktrees/8966b1e14cee/01M3NDXY9P2KKTH5GWJ4YKGW9V
OUT=/home/ubuntu/.no-mistakes/evidence/01M3NDXY9P2KKTH5GWJ4YKGW9V/$LABEL
mkdir -p "$OUT"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-omp-drive.XXXXXX")
PROJECT="$LAB/project"
RPC_LOG="$LAB/rpc.log"
REQUESTS="$LAB/requests.jsonl"
NONCE="SLOW-DIGEST-$$-$RANDOM"
T0=$(date +%s.%N)
ts() { awk -v a="$(date +%s.%N)" -v b="$T0" 'BEGIN{printf "%.1f", a-b}'; }
say() { printf '[t+%ss] %s\n' "$(ts)" "$*" | tee -a "$OUT/transcript.txt"; }
reap() {
  exec 3>&- 2>/dev/null
  cp "$RPC_LOG" "$OUT/rpc.log" 2>/dev/null
  cp "$LAB/rpc.err" "$OUT/rpc.err" 2>/dev/null
  cp "$REQUESTS" "$OUT/requests.jsonl" 2>/dev/null
  grep -rhsI 'handler timed out' "$LAB/home" >"$OUT/omp-home-timeout-lines.txt" 2>/dev/null
  local pid
  for pid in $(ps -axo pid=,command= | awk -v lab="$LAB" 'index($0, lab) { print $1 }'); do kill -TERM "$pid" 2>/dev/null || true; done
  sleep 1
  for pid in $(ps -axo pid=,command= | awk -v lab="$LAB" 'index($0, lab) { print $1 }'); do kill -KILL "$pid" 2>/dev/null || true; done
  rm -rf "$LAB"
}
trap reap EXIT
: >"$OUT/transcript.txt"
send() { say "SEND $1"; printf '%s\n' "$1" >&3; }
wait_for_log() { local i=0; while [ "$i" -lt "$2" ]; do grep -Fq -- "$1" "$RPC_LOG" 2>/dev/null && return 0; sleep 0.5; i=$((i+1)); done; return 1; }
agent_ends() { jq -r 'select(.type == "agent_end") | .type' "$RPC_LOG" 2>/dev/null | grep -c . || true; }
nreq() { if [ -f "$REQUESTS" ]; then wc -l <"$REQUESTS"; else echo 0; fi; }
wait_for_ends() { local i=0; while [ "$i" -lt "$2" ]; do [ "$(agent_ends)" -ge "$1" ] && return 0; sleep 0.5; i=$((i+1)); done; return 1; }
wait_for_reqs() { local i=0; while [ "$i" -lt "$2" ]; do [ "$(nreq)" -ge "$1" ] && return 0; sleep 0.1; i=$((i+1)); done; return 1; }
digest_state() { if [ -e "$LAB/digest-done" ]; then echo done; else echo pending; fi; }
since() { awk -v a="$(date +%s.%N)" -v b="$1" 'BEGIN{printf "%.1f", a-b}'; }

git clone -q "$ROOT" "$PROJECT"
cp "$EXT" "$PROJECT/.omp/extensions/fm-primary-turnend-guard.ts"
say "extension under test: $EXT (sha256 $(sha256sum "$EXT" | cut -c1-12)); digest sleep ${SLEEP}s; mode $MODE; FM_OMP_SESSIONSTART_WAIT_MS=${FM_OMP_SESSIONSTART_WAIT_MS:-unset}; $(omp --version | head -1)"
mkdir -p "$PROJECT/state" "$PROJECT/config" "$PROJECT/data" "$LAB/home"
cat >"$PROJECT/bin/fm-sessionstart-run.sh" <<SH
#!/usr/bin/env bash
sleep $SLEEP
touch "$LAB/digest-done"
printf '%s\n' "$NONCE"
SH
chmod +x "$PROJECT/bin/fm-sessionstart-run.sh"
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
cat >"$PROJECT/.omp/extensions/zz-drive-lab.ts" <<'TS'
type Pi = { registerProvider(name: string, config: Record<string, unknown>): void };
export default function (pi: Pi) {
  pi.registerProvider("drive-lab", {
    baseUrl: `http://127.0.0.1:${process.env.FM_DRIVE_LAB_PORT}/v1`,
    apiKey: "offline-test-only",
    api: "openai-completions",
    models: [{ id: "deterministic", name: "deterministic", reasoning: false, input: ["text"],
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 128000, maxTokens: 128 }],
  });
}
TS
node "$LAB/model.mjs" "$LAB/port" "$REQUESTS" &
for _ in $(seq 50); do [ -s "$LAB/port" ] && break; sleep 0.1; done
mkfifo "$LAB/rpc.in"
(cd "$PROJECT" && exec env -i PATH="$PATH" HOME="$LAB/home" TERM=dumb FM_DRIVE_LAB_PORT="$(cat "$LAB/port")" \
  FM_OMP_HARNESS=omp OMP_SKIP_SETUP=1 ${FM_OMP_SESSIONSTART_WAIT_MS:+FM_OMP_SESSIONSTART_WAIT_MS=$FM_OMP_SESSIONSTART_WAIT_MS} \
  omp --mode rpc --no-session --cwd "$PROJECT" --auto-approve <"$LAB/rpc.in" >"$RPC_LOG" 2>"$LAB/rpc.err") &
exec 3>"$LAB/rpc.in"
say "omp launched (session_start starts the stub digest now)"
if wait_for_log '"type":"ready"' 240; then say "omp rpc ready"; else say "FAIL no ready"; exit 1; fi
send '{"id":"m","type":"set_model","provider":"drive-lab","modelId":"deterministic"}'
wait_for_log '"command":"set_model","success":true' 60 || { say "FAIL set_model"; exit 1; }
send '{"id":"p1","type":"prompt","message":"hello"}'
P1=$(date +%s.%N)
if wait_for_reqs 1 900; then say "model request #1 received $(since "$P1")s after prompt 1 sent (digest $(digest_state))"
else say "no model request #1 within 90s of prompt 1 (digest $(digest_state))"; fi
if wait_for_ends 1 140; then say "agent_end #1"; else say "no agent_end #1"; fi
if [ "$MODE" = twoprompt ]; then
  [ -e "$LAB/digest-done" ] && say "NOTE digest already done before prompt 2 (vacuous)"
  send '{"id":"p2","type":"prompt","message":"second"}'
  P2=$(date +%s.%N)
  if wait_for_reqs 2 400; then say "model request #2 received $(since "$P2")s after prompt 2 sent (digest $(digest_state))"
  else say "model request #2 not received within 40s of prompt 2"; fi
  if wait_for_ends 2 60; then say "agent_end #2"; fi
fi
for _ in $(seq $((SLEEP * 2 + 20))); do [ -e "$LAB/digest-done" ] && break; sleep 0.5; done
say "stub digest $(digest_state)"
sleep 15
say "settled: agent_end count=$(agent_ends), model requests=$(nreq)"
i=0
while IFS= read -r line; do i=$((i+1)); say "request #$i nonce occurrences: $(printf '%s' "$line" | grep -o "$NONCE" | grep -c .)"; done <"$REQUESTS"
say "total nonce occurrences across requests: $(grep -o "$NONCE" "$REQUESTS" | grep -c .)"
say "handler-timeout lines in omp logs/rpc output: $(grep -rhsI 'handler timed out' "$LAB/home" "$RPC_LOG" "$LAB/rpc.err" | grep -c .)"
grep -rhsI 'handler timed out' "$LAB/home" "$RPC_LOG" "$LAB/rpc.err" | cut -c1-400 | while IFS= read -r l; do say "  $l"; done
