#!/usr/bin/env bash
# Throwaway live driver for the omp todo backstop (fm-primary-turnend-guard.ts
# session_stop). Drives a real omp rpc session with a real model in a lab clone
# of the worktree HEAD. The only stub is bin/fm-turnend-guard.sh (the
# watcher-health guard, untouched by this change) which logs its payload and
# exits 0, so any stop_hook_active:true stop can only come from the todo
# backstop continuation.
set -u
ROOT=${ROOT:?}
EVID=${EVID:?}
LAB="$ROOT/.todo-live.$$"
PROJECT="$LAB/project"
RPC_IN="$LAB/rpc.in"; RPC_LOG="$EVID/todo-backstop-rpc.jsonl"; RPC_ERR="$LAB/rpc.err"
SPY="$EVID/todo-backstop-guard-spy.log"
MODEL=${MODEL:-openai-codex/gpt-6-astra}
OMP_PID=
cleanup() {
  exec 3>&- 2>/dev/null || true
  for p in $(ps -axo pid=,command= | awk -v lab="$LAB" 'index($0, lab) {print $1}'); do kill -TERM "$p" 2>/dev/null; done
  sleep 1
  for p in $(ps -axo pid=,command= | awk -v lab="$LAB" 'index($0, lab) {print $1}'); do kill -KILL "$p" 2>/dev/null; done
  rm -rf "$LAB"
}
trap cleanup EXIT
say() { printf '%s\n' "$*"; }
mkdir -p "$LAB"
git clone -q "$ROOT" "$PROJECT"
git -C "$PROJECT" checkout -q "$(git -C "$ROOT" rev-parse HEAD)"
mkdir -p "$PROJECT/state" "$PROJECT/config" "$PROJECT/data"
cat > "$PROJECT/bin/fm-turnend-guard.sh" <<SH
#!/usr/bin/env bash
payload=\$(cat)
printf 'rc=0 payload=%s\n' "\$payload" >> '$SPY'
exit 0
SH
chmod +x "$PROJECT/bin/fm-turnend-guard.sh"
: > "$SPY"; : > "$RPC_LOG"
# Fleet state: one live direct report, one live record named with an ordinary word, one retired report.
printf 'window=fm:1\n' > "$PROJECT/state/fm-e2e-live.meta"
printf 'window=fm:3\n' > "$PROJECT/state/docs.meta"
printf '%s\tfm-e2e-gone\tfm:2\n' "$(date +%s)" > "$PROJECT/state/.retired-tasks"
mkfifo "$RPC_IN"
(
  cd "$PROJECT" &&
    env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u FM_PI_HARNESS -u CURSOR_AGENT -u CURSOR_INVOKED_AS \
      -u FM_HOME -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE \
      FM_OMP_HARNESS=omp OMP_SKIP_SETUP=1 FM_POLL=1 FM_HEARTBEAT=600 \
      omp --mode rpc --no-session --cwd "$PROJECT" --config "$PROJECT/.omp/fm-worker-overlay.yml" --auto-approve \
        --model "$MODEL" --thinking low < "$RPC_IN" > "$RPC_LOG" 2> "$RPC_ERR"
) &
OMP_PID=$!
exec 3> "$RPC_IN"
# This lab session owns the home lock (an ancestor pid of the omp process).
printf '%s\n' "$OMP_PID" > "$PROJECT/state/.lock"
for i in $(seq 240); do grep -q '"type":"ready"' "$RPC_LOG" 2>/dev/null && break; sleep 0.5; done
ends() { jq -r 'select(.type=="agent_end")|.type' "$RPC_LOG" 2>/dev/null | grep -c .; }
wait_ends() { for i in $(seq 720); do [ "$(ends)" -ge "$1" ] && return 0; sleep 0.5; done; return 1; }
todo_ops_since() { tail -n +"$1" "$RPC_LOG" | jq -r 'select(.type=="tool_execution_start" and .toolName=="todo") | .args.op' 2>/dev/null | tr '\n' ' '; }

say "== omp $(omp --version | head -1), model $MODEL"
say "== lab state: fm-e2e-live.meta and docs.meta live; fm-e2e-gone retired; lab session owns state/.lock"

# --- turn 1 (adversarial): own step whose blocker merely mentions the live id 'docs'
printf '%s\n' '{"id":"p1","type":"prompt","message":"Call the todo tool to init one phase named Own with the single task Publish release notes, then call the todo tool again to block that task with the blocker: captain sign-off on docs wording. Then reply with exactly OWN_SET and nothing else."}' >&3
wait_ends 1 || { say "FAIL turn 1 never ended"; exit 1; }
sleep 20
say "-- turn 1 todo ops: $(todo_ops_since 1)"
T1_BLOCKED=$(grep -c '"status":"blocked"' "$RPC_LOG")
T1_CONT=$(grep -c 'stop_hook_active":true' "$SPY")
T1_ENDS=$(ends)
say "-- turn 1 guard stops: $(grep -c . "$SPY"); stop_hook_active:true stops: $T1_CONT; agent_end count after 20s settle: $T1_ENDS"
say "-- turn 1 TODO LIST WAITS text occurrences: $(grep -c 'TODO LIST WAITS' "$RPC_LOG")"
[ "$T1_BLOCKED" -gt 0 ] && say "turn 1: the model blocked the own step (blocked status in rpc)" || say "turn 1: WARNING model never blocked the item"
if [ "$T1_BLOCKED" -gt 0 ] && [ "$T1_CONT" -eq 0 ] && [ "$T1_ENDS" -eq 1 ]; then say "PASS adversarial: own blocked step whose blocker mentions 'docs' did NOT compel a continuation"; else say "FAIL/INCONCLUSIVE adversarial (blocked=$T1_BLOCKED cont=$T1_CONT ends=$T1_ENDS)"; fi

# --- turn 2: mirror items blocked on a retired and a live direct report
L2=$(( $(wc -l < "$RPC_LOG") + 1 ))
: > "$SPY"
printf '%s\n' '{"id":"p2","type":"prompt","message":"Call the todo tool to init one phase named Fleet with two tasks: Collect fm-e2e-gone deliverables, and Await fm-e2e-live PR. Then call the todo tool to block the first task with the blocker fm-e2e-gone, and block the second task with the blocker fm-e2e-live. Then reply with exactly TODO_SET and nothing else."}' >&3
for i in $(seq 720); do
  grep -q 'stop_hook_active":true' "$SPY" 2>/dev/null && [ "$(ends)" -ge 3 ] && break
  sleep 0.5
done
sleep 5
say "-- turn 2 todo ops: $(todo_ops_since "$L2")"
say "-- turn 2 guard stops:"; sed 's/^/   /' "$SPY"
say "-- continuation text seen in rpc stream:"
tail -n +"$L2" "$RPC_LOG" | grep -o 'TODO LIST WAITS ON DIRECT REPORTS[^"]*\(\\n[^"]*\)\{0,3\}' | head -1 | sed 's/^/   /'
say "-- assistant text since turn 2:"
tail -n +"$L2" "$RPC_LOG" | jq -r 'select(.type=="message_update")|.assistantMessageEvent|select(.type=="text_delta")|.delta' 2>/dev/null | tr -d '\n' | cut -c1-600; echo
say "-- last todo tool result phases:"
tail -n +"$L2" "$RPC_LOG" | jq -c 'select(.type=="tool_execution_end" and .toolName=="todo") | .result.details.phases // empty' 2>/dev/null | tail -1 | cut -c1-800
C=$(grep -c 'stop_hook_active":true' "$SPY")
if [ "$C" -ge 1 ]; then say "PASS: todo items blocked on a retired and a live direct report compelled a continuation (stop_hook_active:true stops=$C)"; else say "FAIL: no continuation compelled"; fi
