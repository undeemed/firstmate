#!/usr/bin/env bash
# Opt-in live guard for the Lavish answer channel, run against the REAL
# lavish-axi build installed on this machine.
#
# Two facts this guard exists to hold, because both come from the vendor and no
# fixture can prove either:
#
#   1. Concurrency. Opening another board must not silently kill an armed
#      board's listener. Every observed interruption cluster followed a new
#      artifact being opened, so this measures that claim directly.
#   2. The interruption payload. `bin/fm-procevent-lavish.sh` absorbs one exact
#      response shape. A build that changes that shape disables the whole retry
#      silently, which is exactly what happened between 0.1.45 and 0.1.52 when a
#      `help[...]` diagnostics line appeared under the two pinned lines.
#
# The interruption is produced the way the vendor really produces it: the single
# shared server is shut down under a live poll, which is what any `lavish-axi`
# invocation whose version differs from the running server's does on its way to
# starting its own server.
#
# It is opt-in because it starts a real Lavish server and real poll processes.
# Everything runs on a scratch port with a scratch state directory, so it never
# touches an operator's live boards; the port guard below refuses the default
# port outright.
#
# Run it after every lavish-axi upgrade, and before trusting a refreshed
# docs/verification/process-event-sources.md "Lavish answer channel" entry.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
	printf 'not ok - %s\n' "$1" >&2
	exit 1
}
pass() { printf 'ok - %s\n' "$1"; }

if [ "${FM_LAVISH_POLL_CHANNEL_LIVE_E2E:-0}" != 1 ]; then
	echo "skip: set FM_LAVISH_POLL_CHANNEL_LIVE_E2E=1 to run the real lavish-axi answer-channel guard"
	exit 0
fi
command -v lavish-axi >/dev/null 2>&1 || {
	echo "skip: lavish-axi not found"
	exit 0
}
command -v perl >/dev/null 2>&1 || {
	echo "skip: perl not found"
	exit 0
}

LAVISH_VERSION=$(lavish-axi --version 2>/dev/null | tr -d '[:space:]')
[ -n "$LAVISH_VERSION" ] || fail "lavish-axi did not report a version"

TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-lavish-channel.XXXXXX")
SCRATCH_PORT=$((41000 + ($$ % 2000)))
[ "$SCRATCH_PORT" -ne 4387 ] || fail "refusing to run on the default Lavish port"

export LAVISH_AXI_STATE_DIR="$TMP_ROOT/lavish-state"
export LAVISH_AXI_PORT="$SCRATCH_PORT"
export LAVISH_AXI_NO_OPEN=1
export FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims"
export FM_LAVISH_POLL_RETRY_DELAY=2
export FM_HOME="$TMP_ROOT/home"
mkdir -p "$FM_HOME/state" "$LAVISH_AXI_STATE_DIR"

BOARD_A="$TMP_ROOT/board-a.html"
BOARD_B="$TMP_ROOT/board-b.html"
printf '<!doctype html><html><body style="background:#111;color:#eee"><h1>A</h1></body></html>\n' >"$BOARD_A"
printf '<!doctype html><html><body style="background:#111;color:#eee"><h1>B</h1></body></html>\n' >"$BOARD_B"

cleanup() {
	local status=$?
	"$ROOT/bin/fm-procevent-lavish.sh" retire "$BOARD_A" >/dev/null 2>&1 || true
	lavish-axi end "$BOARD_A" >/dev/null 2>&1 || true
	lavish-axi end "$BOARD_B" >/dev/null 2>&1 || true
	lavish-axi stop >/dev/null 2>&1 || true
	rm -rf "$TMP_ROOT"
	exit "$status"
}
trap cleanup EXIT

listening_state() { # prints "<exit> <output>" for board A
	local out status=0
	out=$("$ROOT/bin/fm-procevent-lavish.sh" listening "$BOARD_A" 2>&1) || status=$?
	printf '%s\n%s\n' "$status" "$out"
}

poll_pid_now() {
	listening_state | sed -n 's/.*poll-process=\([0-9][0-9]*\).*/\1/p' | head -1
}

wait_listening() { # <seconds>
	local deadline=$((SECONDS + $1))
	while [ "$SECONDS" -lt "$deadline" ]; do
		"$ROOT/bin/fm-procevent-lavish.sh" listening "$BOARD_A" >/dev/null 2>&1 && return 0
		sleep 0.5
	done
	return 1
}

captured_results() {
	local n=0 g
	for g in "$FM_HOME/state/procevent-inbox/"*.result; do
		[ -e "$g" ] && n=$((n + 1))
	done
	printf '%s\n' "$n"
}

lavish-axi --no-open "$BOARD_A" >/dev/null 2>&1 ||
	fail "lavish-axi $LAVISH_VERSION could not open the scratch board on port $SCRATCH_PORT"
"$ROOT/bin/fm-procevent-lavish.sh" arm "$BOARD_A" >/dev/null || fail "arming the scratch board failed"
"$ROOT/bin/fm-procevent.sh" reconcile >/dev/null || fail "reconcile did not start a listener"
wait_listening 30 || fail "the armed scratch board never reached a live poll: $(listening_state)"
FIRST_POLL_PID=$(poll_pid_now)
[ -n "$FIRST_POLL_PID" ] || fail "the liveness check passed without naming a poll process"

# 1. Concurrency: another board must not displace this one.
lavish-axi --no-open "$BOARD_B" >/dev/null 2>&1 || fail "opening a second scratch board failed"
sleep 3
"$ROOT/bin/fm-procevent-lavish.sh" listening "$BOARD_A" >/dev/null 2>&1 ||
	fail "opening a second board killed the first board's listener: $(listening_state)"
[ "$(poll_pid_now)" = "$FIRST_POLL_PID" ] ||
	fail "opening a second board replaced the first board's poll process"
[ "$(captured_results)" = 0 ] ||
	fail "opening a second board produced a captured result for the first board"
[ ! -s "$FM_HOME/state/.wake-queue" ] ||
	fail "opening a second board woke the fleet: $(cat "$FM_HOME/state/.wake-queue")"
pass "lavish-axi $LAVISH_VERSION polls concurrent boards without displacing one another"

# 2. The real interruption: losing the shared server under a live poll, exactly
#    as a version-mismatched invocation does, must be absorbed and recovered
#    from - never delivered as a result.
lavish-axi stop >/dev/null 2>&1 || true
INTERRUPTED=0
DEADLINE=$((SECONDS + 30))
while [ "$SECONDS" -lt "$DEADLINE" ]; do
	kill -0 "$FIRST_POLL_PID" 2>/dev/null || {
		INTERRUPTED=1
		break
	}
	sleep 0.5
done
[ "$INTERRUPTED" -eq 1 ] ||
	fail "stopping the shared server left the original poll process alive; the guard proved nothing"
wait_listening 60 ||
	fail "the listener never recovered after the shared server was stopped: $(listening_state)"
[ "$(poll_pid_now)" != "$FIRST_POLL_PID" ] ||
	fail "the recovered listener reports the poll process that was already killed"
[ "$(captured_results)" = 0 ] ||
	fail "an absorbed interruption was captured as a result: $(cat "$FM_HOME/state/procevent-inbox/"*.result)"
[ ! -s "$FM_HOME/state/.wake-queue" ] ||
	fail "an absorbed interruption woke the fleet: $(cat "$FM_HOME/state/.wake-queue")"
pass "lavish-axi $LAVISH_VERSION's real poll interruption is absorbed and the board keeps listening"
