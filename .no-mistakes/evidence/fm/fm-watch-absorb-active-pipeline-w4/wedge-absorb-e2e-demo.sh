#!/usr/bin/env bash
# Manual E2E evidence for the step-progress wedge absorb.
# Chains the two real product binaries:
#   1. bin/fm-crew-state.sh reads the exact incident `axi status` shape
#      (ci step running, last_activity "6m51s ago: log: CI checks running,
#      waiting for results...") and publishes the activity field.
#   2. bin/fm-watch.sh, at the wedge-escalation threshold, absorbs the lane on
#      that evidence, logs the reason, and still escalates once the step goes
#      silent past FM_STEP_ACTIVITY_MAX_SECS or reports no active step.
set -u
WT=$1
SCRATCH=$(mktemp -d /tmp/fm-wedge-demo.XXXXXX)
WATCH="$WT/bin/fm-watch.sh"
CREW="$WT/bin/fm-crew-state.sh"
export FM_WEDGE_ALARM_EXEC=/bin/true
export FM_ROOT_OVERRIDE="$SCRATCH/tangle-root"; mkdir -p "$FM_ROOT_OVERRIDE"

say() { printf '\n=== %s ===\n' "$*"; }

# ---- Stage 1: the real crew-state reader on the incident axi-status shape ----
say "STAGE 1: bin/fm-crew-state.sh reads the incident run shape"
d="$SCRATCH/crew"; mkdir -p "$d/state" "$d/fakebin" "$d/wt"
git -C "$d/wt" init -q && git -C "$d/wt" commit -q --allow-empty -m init
git -C "$d/wt" checkout -q -b fm/fm-forge-write-audit-log-a3
HEAD=$(git -C "$d/wt" rev-parse HEAD)
cat > "$d/fakebin/no-mistakes" <<SH
#!/usr/bin/env bash
set -u
case "\${1:-}" in
  axi) case "\${2:-}" in status) cat "$d/axi-status.toon" ;; esac ;;
esac
exit 0
SH
cat > "$d/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  display-message) printf '%%1\n' ;;
  capture-pane) printf 'all quiet\n> \n' ;;
esac
exit 0
SH
chmod +x "$d/fakebin/no-mistakes" "$d/fakebin/tmux"
printf 'window=fm:fm-forge-write-audit-log-a3\nworktree=%s\nkind=ship\n' "$d/wt" > "$d/state/audit.meta"
cat > "$d/axi-status.toon" <<EOF
run:
  id: "01RUN"
  branch: fm/fm-forge-write-audit-log-a3
  status: running
  head: "$HEAD"
  pr: "https://github.com/example/repo/pull/44"
  findings: none
  steps[8]{step,status,findings,duration_ms}:
    intent,completed,0,0
    review,completed,0,0
    fix,completed,0,0
    test,completed,0,0
    lint,completed,0,0
    docs,completed,0,0
    push,completed,0,0
    pr,completed,0,0
  active_steps[1]{step,status,active_for,last_activity,agent_pid,round}:
    ci,running,44m31s,"6m51s ago: log: CI checks running, waiting for results...","",starting
EOF
echo "-- axi status served to the reader (the 2026-08-27 incident shape):"
sed -n '1,7p;16,18p' "$d/axi-status.toon"
LINE=$(PATH="$d/fakebin:$PATH" FM_STATE_OVERRIDE="$d/state" "$CREW" audit)
echo "-- fm-crew-state.sh current-state line:"
printf '%s\n' "$LINE"

# ---- watcher fixture builder (mirrors the lane the watcher supervises) ----
seen_sig() { stat -c '%s:%Y' "$1" 2>/dev/null; }
mk_lane() {  # <name> <crew-state-line> -> echoes dir
  local dir="$SCRATCH/$1" key pane_hash
  mkdir -p "$dir/state" "$dir/fakebin" "$dir/config"
  cat > "$dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = list-windows ]; then printf 'fm-quiet\n'; exit 0; fi
if [ "${1:-}" = capture-pane ]; then printf 'idle building output'; exit 0; fi
exit 1
SH
  cat > "$dir/fakebin/fm-crew-state.sh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\${FM_FAKE_CREW_STATE:-state: unknown · source: none · fake default}"
exit 0
SH
  chmod +x "$dir/fakebin/tmux" "$dir/fakebin/fm-crew-state.sh"
  printf 'window=test:fm-quiet\nkind=ship\n' > "$dir/state/quiet.meta"
  printf 'working: still compiling\n' > "$dir/state/quiet.status"
  printf '%s' "$(seen_sig "$dir/state/quiet.status")" > "$dir/state/.seen-quiet_status"
  key=test_fm-quiet
  pane_hash=$(printf '%s' 'idle building output' | md5sum | cut -d' ' -f1)
  printf '%s' "$pane_hash" > "$dir/state/.hash-$key"
  printf '2\n' > "$dir/state/.count-$key"
  printf '%s' "$pane_hash" > "$dir/state/.stale-$key"
  echo $(($(date +%s) - 500)) > "$dir/state/.stale-since-$key"
  printf '%s\n' "$dir"
}
run_watch() {  # <dir> <crew-state-line>; rc 0=absorbed(alive), 10=escalated
  local dir=$1 line=$2 pid i
  : > "$dir/watch.out"
  env -u FM_STALE_ESCALATE_SECS -u FM_STEP_ACTIVITY_MAX_SECS \
    "PATH=$dir/fakebin:$PATH" FM_FAKE_TMUX_WINDOW=test:fm-quiet \
    "FM_FAKE_CREW_STATE=$line" \
    "FM_STATE_OVERRIDE=$dir/state" "FM_CONFIG_OVERRIDE=$dir/config" \
    "FM_CREW_STATE_BIN=$dir/fakebin/fm-crew-state.sh" \
    FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$WATCH" > "$dir/watch.out" 2>"$dir/watch.err" &
  pid=$!
  i=0
  while [ "$i" -lt 80 ]; do
    kill -0 "$pid" 2>/dev/null || { wait "$pid" 2>/dev/null; return 10; }
    sleep 0.1; i=$((i+1))
  done
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  return 0
}

# ---- Stage 2: the incident lane at the wedge threshold is absorbed ----
say "STAGE 2: the incident lane (ci waiting on GitHub, activity 411s ago) at the 240s wedge threshold"
d2=$(mk_lane absorb "x")
if run_watch "$d2" "$LINE"; then
  echo "-- watcher kept supervising (no exit): possible-wedge ABSORBED"
else
  echo "-- WATCHER ESCALATED (unexpected):"; cat "$d2/watch.out"
fi
echo "-- wake output (empty means no possible-wedge raised):"
cat "$d2/watch.out"
echo "-- wake queue file: $(ls "$d2/state/.wake-queue" 2>/dev/null || echo 'absent - no wake ever enqueued')"
echo "-- escalation counter file: $(ls "$d2/state/".wedge-escalations-* 2>/dev/null || echo 'none - counter never advanced')"
echo "-- watcher debug log (state/.watch-triage.log):"
cat "$d2/state/.watch-triage.log" 2>/dev/null

# ---- Stage 3: same lane once the step has been silent past the bound ----
say "STAGE 3: same lane shape, step silent for 2463s (> FM_STEP_ACTIVITY_MAX_SECS=900)"
d3=$(mk_lane silent "x")
if run_watch "$d3" 'state: working · source: run-step · ci running · activity: ci 2463'; then
  echo "-- WATCHER ABSORBED (unexpected)"
else
  echo "-- watcher ESCALATED, wake reason:"
  cat "$d3/watch.out"
fi

# ---- Stage 4: stale record - run-step verdict but the run reports no active step ----
say "STAGE 4: stale record - state says run-step but the run reports no active step (no activity field)"
d4=$(mk_lane stale-record "x")
if run_watch "$d4" 'state: working · source: run-step · ci running'; then
  echo "-- WATCHER ABSORBED (unexpected)"
else
  echo "-- watcher ESCALATED, wake reason:"
  cat "$d4/watch.out"
fi

# ---- Stage 5: spoof attempt - a status-log verdict quoting the progress record ----
say "STAGE 5: spoof - a worker's own status line quoting 'source: run-step · activity: pr 30' inside a status-log verdict"
d5=$(mk_lane spoof "x")
if run_watch "$d5" 'state: working · source: status-log · working: source: run-step · activity: pr 30'; then
  echo "-- WATCHER ABSORBED (unexpected - spoof succeeded)"
else
  echo "-- watcher ESCALATED (spoof did not silence the alarm), wake reason:"
  cat "$d5/watch.out"
fi

say "scratch: $SCRATCH"
