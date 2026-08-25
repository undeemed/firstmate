#!/usr/bin/env bash
# E2E evidence driver (test phase, not shipped): drives the real bin/fm-watch.sh
# and bin/fm-wake-drain.sh CLIs through the declared-pause lifecycle a captain
# would experience, printing a readable transcript.
set -u

. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
TMP_ROOT=$(fm_test_tmproot fm-e2e-pause)

say() { printf '\n== %s\n' "$*"; }
show() { sed 's/^/   | /' "$1"; }

reap() {
	local pid=$1
	kill "$pid" 2>/dev/null || true
	wait "$pid" 2>/dev/null || true
}

seen_sig() {
	local f=$1
	if [ "$(uname)" = Darwin ]; then stat -f '%z:%Fm' "$f"; else stat -c '%s:%Y' "$f"; fi
}

file_mtime_local() { stat -c '%Y' "$1" 2>/dev/null || true; }

wait_cycle() { # <state> <pid>
	local state=$1 pid=$2 beat first now i=0
	beat="$state/.last-watcher-beat"
	rm -f "$beat"
	first=""
	while [ "$i" -lt 300 ]; do
		kill -0 "$pid" 2>/dev/null || return 1
		first=$(file_mtime_local "$beat")
		[ -n "$first" ] && break
		sleep 0.1
		i=$((i + 1))
	done
	while [ "$i" -lt 300 ]; do
		kill -0 "$pid" 2>/dev/null || return 1
		now=$(file_mtime_local "$beat")
		if [ -n "$now" ] && [ "$now" != "$first" ]; then return 0; fi
		sleep 0.1
		i=$((i + 1))
	done
	return 1
}

ack_cycle() { # <state>
	local state=$1 err sequence generation
	err="$state/.e2e-drain.err"
	FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2>"$err" || return 1
	sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
	generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
	rm -f "$err"
	[ -n "$sequence" ] && [ -n "$generation" ] || return 1
	FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" --recovery-generation "$generation" >/dev/null 2>&1
}

dir=$(make_case e2e-pause)
state="$dir/state"
fakebin="$dir/fakebin"
out="$dir/watch.out"
drain_out="$dir/drain.out"
capture_file="$dir/pane.txt"
window="test:fm-e2e-held"
key=$(printf '%s' "$window" | tr ':/.' '___')

printf 'idle, holding for upstream' >"$capture_file"
printf 'window=%s\nkind=ship\n' "$window" >"$state/held.meta"
statusf="$state/held.status"
printf 'paused: holding for the upstream tool release\n' >"$statusf"
printf '%s' "$(seen_sig "$statusf")" >"$state/.seen-held_status"
pane_hash=$(hash_text "idle, holding for upstream")
printf '%s' "$pane_hash" >"$state/.hash-$key"
printf '1\n' >"$state/.count-$key"
export FM_FAKE_CREW_STATE='state: paused · source: status-log · holding for the upstream tool release'

say "SCENARIO 1: crew declared 'paused: holding for the upstream tool release'; pane is idle."
say "Watcher runs one poll cycle (resurface threshold 999s, pause is fresh)."
PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
	FM_FAKE_TMUX_CURRENT_COMMAND=zsh \
	FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
	FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
	FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" >"$out" &
pid=$!
if wait_cycle "$state" "$pid"; then
	echo "   watcher is still running after a full poll cycle (it did NOT wake the captain)"
else
	echo "   FAIL: watcher exited during a fresh declared pause"
	cat "$out"
	exit 1
fi
[ ! -s "$out" ] && echo "   watcher stdout: (empty - no wake reason printed)" || {
	echo "   FAIL: unexpected output:"
	show "$out"
	exit 1
}
[ ! -s "$state/.wake-queue" ] && echo "   durable wake queue: (empty)" || {
	echo "   FAIL: wake queued"
	exit 1
}
[ -e "$state/.paused-$key" ] && echo "   .paused-$key marker recorded: pause honored" || {
	echo "   FAIL: no paused marker"
	exit 1
}
[ ! -e "$state/.stale-since-$key" ] && echo "   no wedge timer started (a pause is not a wedge)" || {
	echo "   FAIL: wedge timer started"
	exit 1
}
reap "$pid"
ack_cycle "$state" || {
	echo "   FAIL: could not acknowledge the intentional phase stop"
	exit 1
}
echo "   RESULT: PASS - a fresh declared pause is honored (absorbed, no wake, no wedge timer)"

say "SCENARIO 2: same pause, now 500s old with resurface threshold 240s. The pause is bounded:"
say "the watcher must re-surface it as an 'awaiting external' recheck, never a possible wedge."
back=$(($(date +%s) - 500))
touch -m -d "@$back" "$statusf"
printf '%s' "$(seen_sig "$statusf")" >"$state/.seen-held_status"
: >"$out"
printf 'idle, holding for upstream (token 2)' >"$capture_file"
PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
	FM_FAKE_TMUX_CURRENT_COMMAND=zsh \
	FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
	FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
	FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" >"$out" &
pid=$!
wait_for_exit "$pid" 100 || {
	echo "   FAIL: watcher did not re-surface the aged pause"
	exit 1
}
echo "   watcher exited with:"
show "$out"
grep -F "stale: $window" "$out" >/dev/null || {
	echo "   FAIL: no stale wake"
	exit 1
}
grep -F "awaiting external" "$out" >/dev/null || {
	echo "   FAIL: not labeled awaiting-external"
	exit 1
}
grep -F "possible wedge" "$out" >/dev/null && {
	echo "   FAIL: mislabeled a possible wedge"
	exit 1
}
FM_STATE_OVERRIDE="$state" "$DRAIN" >"$drain_out" 2>/dev/null || {
	echo "   FAIL: drain failed"
	exit 1
}
echo "   fm-wake-drain.sh (what the captain's agent reads):"
show "$drain_out"
grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null || {
	echo "   FAIL: not queued"
	exit 1
}
echo "   RESULT: PASS - an aged pause re-surfaces on the bounded cadence as an awaiting-external recheck"

say "SCENARIO 3: a crew ends its turn with NO pause and NO running pipeline (it stopped)."
say "The watcher must surface that finish instead of absorbing it (the swallowed-finish fix)."
dir2=$(make_case e2e-stopped)
state2="$dir2/state"
fakebin2="$dir2/fakebin"
out2="$dir2/watch.out"
drain_out2="$dir2/drain.out"
: >"$state2/task.turn-ended"
export FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available'
PATH="$fakebin2:$PATH" FM_STATE_OVERRIDE="$state2" FM_CREW_STATE_BIN="$fakebin2/fm-crew-state.sh" \
	FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" >"$out2" &
pid=$!
wait_for_exit "$pid" 100 || {
	echo "   FAIL: watcher did not surface the stopped crew's turn-end"
	exit 1
}
echo "   watcher exited with:"
show "$out2"
grep -F "signal: $state2/task.turn-ended" "$out2" >/dev/null || {
	echo "   FAIL: turn-end not printed"
	exit 1
}
FM_STATE_OVERRIDE="$state2" "$DRAIN" >"$drain_out2" 2>/dev/null || {
	echo "   FAIL: drain failed"
	exit 1
}
echo "   fm-wake-drain.sh:"
show "$drain_out2"
grep "$(printf '\tsignal\t')" "$drain_out2" | grep -F "$state2/task.turn-ended" >/dev/null || {
	echo "   FAIL: not queued"
	exit 1
}
echo "   RESULT: PASS - a stopped crew's finish is surfaced and durably queued"

say "ALL THREE SCENARIOS PASSED"
