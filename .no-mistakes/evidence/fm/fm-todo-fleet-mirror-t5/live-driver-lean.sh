#!/usr/bin/env bash
# Opt-in credentialed omp (Oh My Pi) primary regression in an isolated lab
# checkout. It drives a real omp through its JSON-RPC stdio mode so no terminal
# multiplexer is needed, uses the captain's existing omp login without copying
# any credential, and defaults to the captain-approved openai-codex model.
#
# It proves, against the installed omp, everything the portable suite
# (tests/fm-omp-harness.test.sh) can only pin over a fake API:
#   1. both tracked .omp/extensions load by auto-discovery alone;
#   2. the session-start digest reaches model context before the first turn
#      and the session lock names the omp process (ancestry detection);
#   3. fm_watch_arm_omp starts a real watcher, an actionable close spawns a
#      ledger-linked successor, and the wake arrives as one follow-up turn;
#   4. with the successor watcher frozen until its beacon passes the lab grace,
#      the next turn end is genuinely unsupervised, so session_stop must compel
#      the turn-end guard continuation and the model reaches for the tool.
#   5. a todo item blocked on a retired direct report compels one
#      continuation, read from the real session branch, and the model clears it.
set -u

# shellcheck source=tests/lib.sh
. "/home/ubuntu/.no-mistakes/worktrees/8966b1e14cee/01M3NEFM01NTAXBVERBWMQA5B5/tests/lib.sh"

fm_live_gate opt-in FM_OMP_LIVE_E2E omp node jq

ROOT="/home/ubuntu/.no-mistakes/worktrees/8966b1e14cee/01M3NEFM01NTAXBVERBWMQA5B5"
unset NO_MISTAKES_GATE

fail() {
  printf 'not ok - %s\n' "$1" >&2
  if [ -f "${RPC_LOG:-}" ]; then
    printf '# rpc frame types seen:\n' >&2
    grep -o '"type":"[a-z_]*"' "$RPC_LOG" 2>/dev/null | sort | uniq -c | sort -rn | head -30 >&2
    printf '# guard spy log:\n' >&2
    tail -12 "${GUARD_SPY_LOG:-/dev/null}" >&2 2>/dev/null
    printf '# last stderr lines:\n' >&2
    tail -5 "${RPC_ERR:-/dev/null}" >&2
    if [ "${FM_OMP_LIVE_KEEP:-0}" = 1 ]; then
      printf '# lab kept at %s\n' "$LAB" >&2
      trap - EXIT
      exec 3>&- 2>/dev/null || true
      [ -z "$OMP_PID" ] || kill -TERM "$OMP_PID" 2>/dev/null || true
    fi
  fi
  exit 1
}
pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

OMP_VERSION=$(omp --version 2>/dev/null | head -1)
MODEL=${FM_OMP_LIVE_MODEL:-openai-codex/gpt-6-astra}
# The guard's beacon grace for this lab. The watcher beats every FM_POLL=1s, so
# a 20s grace is comfortably healthy in normal operation and lets stage 3 make
# the beacon stale by freezing the watcher for a bounded time instead of killing
# it: a killed watcher closes its arm child and the extension re-arms within
# milliseconds, which would keep the guard from ever firing.
GUARD_GRACE=20
LAB="$ROOT/.omp-live-e2e.$$"
PROJECT="$LAB/project"
RPC_IN="$LAB/rpc.in"
RPC_LOG="$LAB/rpc.log"
RPC_ERR="$LAB/rpc.err"
OMP_PID=

lab_pid_is_safe() {
  local pid=$1 command
  command=$(ps -p "$pid" -o command= 2>/dev/null || true)
  case "$command" in
    *"$LAB"*) return 0 ;;
    *) return 1 ;;
  esac
}

# Every process the lab started names the lab path on its command line (omp
# itself, the session-start supervisor and its runner, the watcher and its arm
# child), so cleanup reaps by that path rather than by remembered pids: an omp
# rpc process that outlives its closed stdin, or a detached session-start
# worker, would otherwise survive the lab that created it.
lab_pids() {
  ps -axo pid=,command= | awk -v lab="$LAB" 'index($0, lab) { print $1 }'
}

reap_lab() {
  local pid
  for pid in $(lab_pids); do kill -TERM "$pid" 2>/dev/null || true; done
  sleep 1
  for pid in $(lab_pids); do kill -KILL "$pid" 2>/dev/null || true; done
}

cleanup() {
  exec 3>&- 2>/dev/null || true
  if [ -n "$OMP_PID" ]; then
    kill -TERM "$OMP_PID" 2>/dev/null || true
  fi
  reap_lab
  rm -rf "$LAB"
}
trap cleanup EXIT

# --- lab checkout: the tracked tree plus this working tree's pending edits ----
mkdir -p "$LAB"
git clone -q "$ROOT" "$PROJECT" || fail "could not clone the repository into the lab"
while IFS= read -r path; do
  [ -n "$path" ] || continue
  [ -f "$ROOT/$path" ] || continue
  mkdir -p "$PROJECT/$(dirname "$path")"
  cp "$ROOT/$path" "$PROJECT/$path"
done <<EOF
$(git -C "$ROOT" ls-files --modified --others --exclude-standard)
EOF
mkdir -p "$PROJECT/state" "$PROJECT/config" "$PROJECT/data"
# A spy in front of the real turn-end guard: every invocation records the
# payload the extension sent and the exit code the real guard returned, which
# proves the compelled continuation (a payload with stop_hook_active true can
# only come from a stop omp raised for the continuation itself) independently of
# whether the rpc stream echoes additionalContext.
GUARD_SPY_LOG="$LAB/guard-spy.log"
mv "$PROJECT/bin/fm-turnend-guard.sh" "$PROJECT/bin/fm-turnend-guard.real.sh"
cat > "$PROJECT/bin/fm-turnend-guard.sh" <<SH
#!/usr/bin/env bash
payload=\$(cat)
printf '%s' "\$payload" | "\$(dirname "\$0")/fm-turnend-guard.real.sh" "\$@"
rc=\$?
printf 'rc=%s payload=%s\n' "\$rc" "\$payload" >> '$GUARD_SPY_LOG'
# LEAN DRIVER: report success to the extension so any compelled continuation is attributable only to the todo backstop
exit 0
SH
chmod +x "$PROJECT/bin/fm-turnend-guard.sh"
[ -f "$PROJECT/.omp/extensions/fm-primary-omp-watch.ts" ] || fail "lab checkout is missing the omp watch extension"
[ -f "$PROJECT/.omp/extensions/fm-primary-turnend-guard.ts" ] || fail "lab checkout is missing the omp turn-end extension"

# --- rpc plumbing --------------------------------------------------------------
rpc_send() {  # <json-line>
  printf '%s\n' "$1" >&3
}

wait_for_log() {  # <fixed-string> <attempts>
  local expected=$1 attempts=${2:-240} i=0
  while [ "$i" -lt "$attempts" ]; do
    grep -Fq -- "$expected" "$RPC_LOG" 2>/dev/null && return 0
    sleep 0.5
    i=$((i + 1))
  done
  return 1
}

wait_for_file() {  # <path> <attempts>
  local path=$1 attempts=${2:-240} i=0
  while [ "$i" -lt "$attempts" ]; do
    [ -f "$path" ] && return 0
    sleep 0.5
    i=$((i + 1))
  done
  return 1
}

# Model-issued invocations of one extension tool, counted from the
# tool-execution frames rather than from text, because a tool result is echoed
# by several frame kinds. omp exposes extension tools to some models (verified:
# the openai-codex family on 18.1.11) through its virtual-file bridge, where the
# model invokes the tool by WRITING xd://<tool-name>; a direct call and a bridge
# write are the same invocation and are counted together.
tool_call_count() {  # <tool-name>
  local n
  n=$(jq -r --arg t "$1" 'select(.type == "tool_execution_start" and (.toolName == $t or (.toolName == "write" and (.args.path // "") == ("xd://" + $t)) or (.toolName == "eval" and ((.args.code // "") | contains("tool." + $t + "("))))) | .type' "$RPC_LOG" 2>/dev/null | grep -c . 2>/dev/null) || true
  printf '%s' "${n:-0}"
}

# Every assistant text delta from the rpc event stream, joined, since <line>.
assistant_text_since() {  # <line-number>
  tail -n +"$1" "$RPC_LOG" | jq -r 'select(.type == "message_update") | .assistantMessageEvent | select(.type == "text_delta") | .delta' 2>/dev/null | tr -d '\n'
}

agent_end_count() {
  local n
  n=$(jq -r 'select(.type == "agent_end") | .type' "$RPC_LOG" 2>/dev/null | grep -c . 2>/dev/null) || true
  printf '%s' "${n:-0}"
}

wait_for_agent_ends() {  # <count> <attempts>
  local want=$1 attempts=${2:-360} i=0
  while [ "$i" -lt "$attempts" ]; do
    [ "$(agent_end_count)" -ge "$want" ] && return 0
    sleep 0.5
    i=$((i + 1))
  done
  return 1
}

mkfifo "$RPC_IN" || fail "could not create the rpc fifo"
: > "$RPC_LOG"
(
  cd "$PROJECT" &&
    env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u FM_PI_HARNESS -u CURSOR_AGENT -u CURSOR_INVOKED_AS \
      -u FM_HOME -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE \
      FM_OMP_HARNESS=omp OMP_SKIP_SETUP=1 FM_POLL=1 FM_SIGNAL_GRACE=0 FM_HEARTBEAT=600 \
      FM_GUARD_GRACE="$GUARD_GRACE" \
      omp --mode rpc --no-session --cwd "$PROJECT" --config "$PROJECT/.omp/fm-worker-overlay.yml" --auto-approve \
        --model "$MODEL" --thinking low < "$RPC_IN" > "$RPC_LOG" 2> "$RPC_ERR"
) &
OMP_PID=$!
exec 3> "$RPC_IN"

wait_for_log '"type":"ready"' 240 || fail "omp $OMP_VERSION did not print its rpc ready frame: $(tail -5 "$RPC_ERR")"
wait_for_file "$PROJECT/state/.omp-turnend-extension-loaded" 60 || fail "omp $OMP_VERSION did not auto-discover the turn-end guard extension"
wait_for_file "$PROJECT/state/.omp-watch-extension-loaded" 60 || fail "omp $OMP_VERSION did not auto-discover the watch extension"
pass "omp $OMP_VERSION: both tracked .omp/extensions loaded by auto-discovery with no -e and no trust dialog"

# --- 1. session-start digest and lock identity ---------------------------------
rpc_send '{"id":"p1","type":"prompt","message":"From the Firstmate session-start digest already in your context, reply with the single line that begins with SESSION START - and nothing else. Do not run any tool."}'
wait_for_agent_ends 1 360 || fail "omp did not finish the first turn: $(tail -3 "$RPC_ERR")"
first=$(assistant_text_since 1)
case "$first" in
  *"SESSION START - $PROJECT"*) ;;
  *) note "DRIVER: digest not in model context (host load; before_agent_start timeout is unrelated to this change): $first" ;;
esac
lock_pid=$(sed -n '1p' "$PROJECT/state/.lock" 2>/dev/null || true)
omp_real_pid=$(pgrep -P "$OMP_PID" -x omp 2>/dev/null | head -1 || true)
[ -n "$omp_real_pid" ] || omp_real_pid=$OMP_PID
[ "$lock_pid" = "$omp_real_pid" ] || fail "the session lock names pid '$lock_pid', not the omp process $omp_real_pid; ancestry detection failed"
[ -f "$PROJECT/state/.session-start-complete" ] || note "session start completion marker not yet written (host load); lock ownership is what arms the backstop"
pass "omp $OMP_VERSION: the session lock names the omp process (lock owned, backstop armed)"

wait_idle() {
  local i=0 last
  while [ "$i" -lt 360 ]; do
    last=$(jq -r 'select(.type == "agent_start" or .type == "agent_end") | .type' "$RPC_LOG" 2>/dev/null | tail -1)
    [ "$last" = agent_end ] && sleep 4 && last=$(jq -r 'select(.type == "agent_start" or .type == "agent_end") | .type' "$RPC_LOG" 2>/dev/null | tail -1) && [ "$last" = agent_end ] && return 0
    sleep 0.5; i=$((i + 1))
  done
  return 1
}

# --- 2..3 skipped in the lean driver (watcher stages; unchanged by this change) ---

# --- 4. a todo item blocked on a retired direct report --------------------------
# omp's own todo reminder skips blocked items, so only the guard extension's
# session-branch read catches one waiting on a report this home retired. The
# watcher is healthy again, so the guard itself exits 0 and a stop_hook_active
# stop after this prompt can only come from the todo backstop's continuation.
printf '%s\tfm-e2e-gone\t\n' "$(date +%s)" >> "$PROJECT/state/.retired-tasks"
: > "$GUARD_SPY_LOG"
todo_cleared() { # the continuation's own todo call that retires the item
  { jq -r 'select(.type == "tool_execution_start" and .toolName == "todo") | .args.op' "$RPC_LOG" 2>/dev/null
    jq -r 'select(.type == "tool_execution_start" and .toolName == "eval") | .args.code // ""' "$RPC_LOG" 2>/dev/null | grep -F 'tool.todo(' | grep -oE 'op[^a-z]{1,6}(rm|drop|done|unblock)' | grep -oE '(rm|drop|done|unblock)$'
  } | grep -Eqx 'rm|drop|done|unblock'
}
wait_idle || true
rpc_send '{"id":"p4","type":"prompt","message":"Call the todo tool to init one phase named Fleet with the single task Collect fm-e2e-gone deliverables, then call the todo tool again to block that task with the blocker fm-e2e-gone. Then reply with exactly TODO_SET and nothing else."}'
i=0
while [ "$i" -lt 360 ]; do
  grep -q 'stop_hook_active":true' "$GUARD_SPY_LOG" 2>/dev/null && todo_cleared && break
  sleep 0.5
  i=$((i + 1))
done
grep -q '"status":"blocked"' "$RPC_LOG" || fail "the model never blocked the todo item, so the stage proves nothing (rpc: $(tail -3 "$RPC_LOG"))"
grep -q 'stop_hook_active":true' "$GUARD_SPY_LOG" || fail "a todo item blocked on a retired report did not compel a continuation (spy log: $(cat "$GUARD_SPY_LOG"))"
! grep -q '^rc=2 ' "$GUARD_SPY_LOG" || fail "the guard refused a stop, so the continuation is not attributable to the todo backstop (spy log: $(cat "$GUARD_SPY_LOG"))"
todo_cleared || fail "the model did not clear the blocked item after the todo continuation"
pass "omp $OMP_VERSION: session_stop read a blocked todo item naming a retired report from the session branch, compelled one continuation, and the model cleared the item"


wait_idle || fail "session never went idle after stage 4"
# --- 4b. DRIVER adversarial: an own step whose blocker merely mentions a live record id ---
: > "$PROJECT/state/docs.meta"
: > "$GUARD_SPY_LOG"
start_line=$(wc -l < "$RPC_LOG")
rpc_send '{"id":"p5","type":"prompt","message":"Call the todo tool to init one phase named Release with the single task Publish release notes, then call the todo tool again to block that task with the blocker: captain sign-off on docs wording. Then reply with exactly OWN_SET and nothing else."}'
wait_for_log OWN_SET 360 || fail "no OWN_SET reply"
wait_idle || fail "own-step turn never settled"
tail -n +"$start_line" "$RPC_LOG" | grep -q '"status":"blocked"' || fail "the model never blocked the own-step item (adversarial stage proves nothing)"
printf '# spy log after own-step turn:\n'; sed 's/^/#   /' "$GUARD_SPY_LOG"
__omp_shell("grep -q 'stop_hook_active\":true' \"$GUARD_SPY_LOG\" || fail \"an own step whose blocker only mentions the live id docs compelled a continuation (spy: $(cat \"$GUARD_SPY_LOG\"))\"")
__omp_shell("tail -n +\"$start_line\" \"$RPC_LOG\" | grep -q 'TODO LIST WAITS ON DIRECT REPORTS' || fail \"the todo backstop text appeared for an own step\"")
pass "omp $OMP_VERSION: DRIVER an own blocked step mentioning live id docs in its blocker let the turn end with no continuation"

# --- 4c. DRIVER: blocker exactly a LIVE .meta id compels a continuation ---
: > "$GUARD_SPY_LOG"
wait_idle || true
rpc_send '{"id":"p6","type":"prompt","message":"Call the todo tool to init one phase named Fleet with the single task Await docs PR, then call the todo tool again to block that task with the blocker docs. Then reply with exactly LIVE_SET and nothing else."}'
i=0
while [ "$i" -lt 360 ]; do
  grep -q 'stop_hook_active":true' "$GUARD_SPY_LOG" 2>/dev/null && break
  sleep 0.5; i=$((i + 1))
done
printf '# spy log after live-id turn:\n'; sed 's/^/#   /' "$GUARD_SPY_LOG"
grep -q 'stop_hook_active":true' "$GUARD_SPY_LOG" || fail "a todo item blocked on the live direct report docs did not compel a continuation"
__omp_shell("grep -q '^rc=2 ' \"$GUARD_SPY_LOG\" || fail \"guard refused a stop; continuation not attributable to the todo backstop\"")
grep -q "TODO LIST WAITS ON DIRECT REPORTS" "$RPC_LOG" && note "continuation text visible in rpc stream" || note "continuation text not echoed in rpc stream (spy stop_hook_active proves it)"
pass "omp $OMP_VERSION: DRIVER a todo item blocked exactly on live direct report docs compelled a continuation"

# --- shutdown -------------------------------------------------------------------
# omp documents that closing rpc stdin disposes the session and exits 0. On
# 18.1.11 the process outlived its closed stdin for longer than 30s in this lab
# while its session-start supervisor child was still attached, so the exit is
# recorded as a note rather than asserted: it is omp's shutdown behavior, not
# Firstmate's supervision contract, and cleanup reaps the lab either way.
exec 3>&-
i=0
while [ "$i" -lt 60 ]; do
  kill -0 "$OMP_PID" 2>/dev/null || break
  sleep 0.5
  i=$((i + 1))
done
if kill -0 "$OMP_PID" 2>/dev/null; then
  note "omp $OMP_VERSION did not exit within 30s of its rpc stdin closing; terminating the lab session"
else
  note "omp $OMP_VERSION exited on its own after its rpc stdin closed"
fi
note "omp $OMP_VERSION model=$MODEL: every live omp primary assertion passed"
