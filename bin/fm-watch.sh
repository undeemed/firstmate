#!/usr/bin/env bash
# Firstmate watcher.
# Classifies supervision wakes in bash. In normal mode it absorbs benign wakes
# and keeps blocking; it queues and exits only for actionable wakes.
# The no-verb signal and stale path is absorb-only-when-provably-working: a wake
# is absorbed only when the crew shows POSITIVE evidence it is still working (an
# actively-running no-mistakes step, or a backend busy signal), and surfaced
# otherwise, so a crew that finishes (or stops and waits) without a current
# working signal is never silently swallowed. A declared wait, either a paused:
# external wait or a verified captain-held transfer, is the separate idle absorb
# case and re-surfaces only on its long bounded cadence, which decays as the
# unchanged wait ages, although its initial no-verb status signal still surfaces in
# normal mode.
# While state/.afk exists, the daemon owns triage and this watcher queues and exits
# on every wake. Printed reason lines:
#   signal: <file>...      status/turn-end signals, surfaced when a listed status
#                          has a captain-relevant verb OR a no-verb signal's crew
#                          is not provably working, unless afk is active
#   stale: <window>        a provably-working stale is ALWAYS absorbed (with a wedge
#                          timer) regardless of what the status log says - an active
#                          run-step or busy pane outranks even a captain-relevant log
#                          line, since the crew's own log gets no new entry once
#                          firstmate hands it to a no-mistakes validation. A declared
#                          external-wait pause or verified captain-held transfer is
#                          absorbed instead with its own long re-surface cadence,
#                          never as a wedge, and that recheck reason names which
#                          human the wait is on and when the next recheck of an
#                          unchanged wait is due. The declaration outranks every
#                          liveness read except an actively-running pipeline
#                          attributed to that crew's current code, so a parked
#                          lane whose per-harness busy source keeps reporting busy
#                          cannot route a declared wait into the wedge timer.
#                          Rechecking an UNCHANGED declaration carries no new
#                          information, so that cadence doubles as the declaration
#                          ages (FM_PAUSE_RESURFACE_SECS, bounded by
#                          FM_PAUSE_BACKOFF_MAX_SECS): hourly for a fresh wait,
#                          daily for one that has held for days, never silent.
#                          Only when neither absorb class
#                          applies does the log's last line decide:
#                          terminal (captain-relevant) or non-terminal (no verb),
#                          both surfaced at once. A provably-working stale past the
#                          wedge threshold also surfaces, with an "escalation N"
#                          count in the reason; at FM_WEDGE_DEMAND_INSPECT_COUNT
#                          consecutive escalations on the SAME pane, the reason
#                          also carries a "demand-deep-inspection" marker so the
#                          wake payload itself, not just repetition, forces a
#                          closer look instead of another routine supervision
#                          resume, and from that escalation onward the SAME
#                          unchanged pane re-surfaces on a doubling interval
#                          (FM_WEDGE_BACKOFF_SECS, bounded by
#                          FM_WEDGE_BACKOFF_MAX_SECS) instead of the fixed short
#                          one, so an already-reported wedge keeps reporting
#                          without burying every other event. Any genuine change
#                          resets both the count and the cadence. Unless afk is
#                          active. Three evidence classes defer that escalation
#                          instead (wedge_defer): a task worktree written during
#                          the quiet window, an actively-progressing pipeline
#                          step, and a model turn completed during that same
#                          window (crew_step_progress_evidence and
#                          crew_turn_progress_evidence in bin/fm-classify-lib.sh
#                          own why). All three re-surface once per
#                          PAUSE_RESURFACE_SECS, and anything the probes
#                          cannot evaluate keeps the unchanged schedule.
#                          A genuinely busy pane
#                          (window_is_busy true) is exempt from the above, but
#                          only up to BUSY_TURN_MAX_SECS with no completed turn
#                          (state/<id>.turn-ended, or the spawn record before any
#                          turn completes). Past that bound, a declared external
#                          wait or verified captain-held transfer uses the long
#                          pause recheck cadence; every other pane goes through
#                          the same wedge timer and surfaces with the identical
#                          "stale: ..." reason, escalation count, and
#                          demand-deep-inspection marker, for human inspection
#                          only - never an automatic interrupt, signal, or restart
#                          of the worker or its tool process.
#   check: <script>: <out> authenticated check output, always actionable
#   check: process-event result captured: <keys>
#                          a durably captured process-to-event result is queued
#                          and has not been surfaced yet; reported once per
#                          captured generation, never again while that record
#                          stays queued and never once it is acknowledged
#   check: rejected unauthenticated state checks: <paths>
#                          unsafe state checks were refused without execution
#   check: unverifiable PR merge polls: <paths>
#                          a poll whose bytes ARE the canonical merge poll no
#                          longer verifies against its private sidecar,
#                          registration, or task metadata; nothing ran and that
#                          pull request is no longer being watched, so rearm it
#                          with bin/fm-pr-check.sh after repairing the record
#   check: rejected unauthenticated PR poll retirement receipts: <paths>
#                          invalid pending retirements were preserved without
#                          running a check or removing poll artifacts
#   heartbeat              fleet-scan backstop found an unsurfaced captain-relevant
#                          status, unless afk is active
#   check: inactive-outcome bounded poll-loop reconciliation found a suspicious
#                          inactive terminal outcome that still lacks its durable
#                          upstream receipt
#   check: secondmate wake-loop stalled: mate=<id> row=<seq> age=<seconds>s
#     depth=<rows> (unchanged backlog not reported again before <seconds>s)
#                          the oldest valid row in an endpoint-recorded local
#                          secondmate home's durable wake queue exceeded
#                          FM_SECONDMATE_WAKE_STALL_SECS while the mate was not
#                          merely mid-turn: a mate whose endpoint is provably busy
#                          is given until FM_SECONDMATE_WAKE_STALL_DEPTH rows or
#                          FM_SECONDMATE_WAKE_STALL_BEHIND_SECS to reach the row,
#                          because a row arriving during a long turn ages past the
#                          threshold every time. Observation is read-only, and a
#                          backlog that stays behind repeats on a doubling
#                          interval (FM_SECONDMATE_WAKE_STALL_REPEAT_SECS, bounded
#                          by FM_SECONDMATE_WAKE_STALL_REPEAT_MAX_SECS) rather
#                          than being silenced forever by the first report of that
#                          row
# For normal supervision, resume the session-start primary-harness protocol
# after each printed reason. Direct duplicate invocations of this script still
# no-op through the watcher singleton lock.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
mkdir -p "$STATE"

# The native event fast-path and only its true dependencies have one narrow
# production owner. The Herdr event-wait smoke test consumes this same owner
# without sourcing the entire watcher graph.
# The shared transition owner is a canonical lint root itself. Stop duplicate
# source-graph expansion here: following its backend graph from this large
# runtime can exceed the bounded CI lint worker while adding no uncovered file.
# shellcheck source=/dev/null
. "$SCRIPT_DIR/fm-push-transition-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-x-lib.sh
. "$SCRIPT_DIR/fm-x-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"
# Parent-owned secondmate missed-report guards: durable pending-reply
# expectations created by fm-send on marked secondmate requests. The tick is
# cheap when no records exist and never scrapes secondmate conversation.
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$SCRIPT_DIR/fm-pending-reply-lib.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$SCRIPT_DIR/fm-busy-lib.sh"

WATCH_LOCK="$STATE/.watch.lock"
WATCH_PATH="$SCRIPT_DIR/fm-watch.sh"
WATCHER_DOWNTIME_MARKER="$STATE/.watcher-down"
WATCHER_STALE_GRACE=${FM_WATCHER_STALE_GRACE:-${FM_GUARD_GRACE:-300}}
# The singleton-lock acquisition, EXIT trap, and the blocking supervision loop
# all live below the source guard at the very bottom of this file (see "Main
# entry"). Sourcing this file for unit tests therefore loads the functions -
# including the event-wait splice below - and returns before acquiring the lock
# or starting the loop. Running it as a script executes the runtime exactly as
# before, byte-for-byte.

# Portable stat. macOS (BSD) stat uses `-f <fmt>`; Linux (GNU) stat uses `-c <fmt>`.
# Do NOT use the `stat -f <fmt> ... || stat -c <fmt> ...` fallback form: on Linux
# `stat -f` is *filesystem* stat and writes a partial filesystem dump ("File: ...",
# "Blocks: ...") to stdout before failing, so the fallback's correct output gets
# appended to that garbage. Arithmetic under `set -u` then aborts on the stray
# token (e.g. the word "File" read as an unset variable), which silently kills the
# watcher mid-cycle. Detect the platform once and pick the right form.
if [ "$(uname)" = Darwin ]; then
  stat_mtime() { stat -f %m "$1" 2>/dev/null; }        # epoch seconds of mtime
else
  stat_mtime() { stat -c %Y "$1" 2>/dev/null; }
fi
# The size:mtime signal signature and .seen-* marker format are owned by
# bin/fm-wake-lib.sh (fm_wake_signal_sig, fm_wake_signal_seen_path), shared
# with the drain's annotation staleness check and this home's own bookkeeping
# writers' guarded self-announced append.

POLL=${FM_POLL:-15}                   # seconds between cycles
HEARTBEAT=${FM_HEARTBEAT:-600}        # base seconds between heartbeat scans
HEARTBEAT_MAX=${FM_HEARTBEAT_MAX:-7200}  # heartbeat backoff cap
CHECK_INTERVAL=${FM_CHECK_INTERVAL:-300}  # seconds between *.check.sh sweeps
CHECK_TIMEOUT=${FM_CHECK_TIMEOUT:-30}     # seconds allowed per *.check.sh
SIGNAL_GRACE=${FM_SIGNAL_GRACE:-30}   # seconds to linger after a signal so trailing
                                      # signals (a status write, then the same turn's
                                      # turn-end hook) coalesce into one wake
# Busy state is decided by the semantic contract in bin/fm-busy-lib.sh, which
# is the single owner of per-harness sources, source attribution, and the one
# remaining rendered-text fallback (Grok only).
# Always-on wake triage: most wakes during a long crew validation are benign (a
# working: note or turn-end while a pipeline runs, a no-change heartbeat). Rather
# than wake firstmate's LLM for each, this watcher classifies every wake in bash
# and ABSORBS the benign majority - it advances the suppression marker, logs to a
# debug log, and keeps blocking WITHOUT enqueuing or exiting. The no-verb signal
# / stale path is absorb-only-when-provably-working: such a wake is absorbed ONLY
# while the crew shows positive evidence it is still working (an actively-running
# no-mistakes step, or a busy pane, via crew_is_provably_working over
# fm-crew-state.sh); a crew that stopped its turn with no running pipeline and no
# busy pane is SURFACED, so a finish reported only through interactive pane menus
# (no done: status) is never swallowed. An ACTIONABLE wake (a captain-relevant
# signal, a no-verb signal whose crew is not provably working, any check, a stale
# pane whose crew is not provably working, a provably-working stale past the
# threshold, or anything unknown) is written to the durable queue and exits, which
# is what wakes the LLM through the background-task completion. The same classifier
# (fm-classify-lib.sh) backs the away-mode daemon; while state/.afk exists the
# daemon owns triage, so this watcher reverts to one-shot (enqueue + exit on every
# wake) and never double-triages - and never runs the costly provably-working read.
# Idle secs before a provably-working stale escalates as a possible wedge.
# Per home, because the longest LEGITIMATE silence is a property of the work that
# home runs: a home whose gate run takes 17 minutes crosses a 240s threshold four
# or more times per run, and an alarm that is structurally guaranteed to be wrong
# trains its reader to skim it. Precedence: FM_STALE_ESCALATE_SECS in the
# environment, then config/stale-escalate-secs, then the unchanged 240s default.
# The environment wins because the harness extension that launches this watcher
# sets no such variable, so a deliberate per-process override stays authoritative
# over the home's standing file. A malformed file is reported and ignored rather
# than wedging the watcher or silently changing the cadence.
# docs/configuration.md "Stale escalation threshold" owns the operator contract,
# including the rule that the value is SIZED just above the home's real gate-run
# time and never used to mute this alarm class.
STALE_ESCALATE_SECS_DEFAULT=240
STALE_ESCALATE_SECS_FILE="$CONFIG/stale-escalate-secs"

# Print the configured threshold held by <file>: 0 with the value on stdout, 1
# when the file is absent or holds no value line, 2 when its first value line is
# not one positive whole number in plain decimal digits.
stale_escalate_configured() { # <file>
	local file=$1 line value
	[ -f "$file" ] || return 1
	while IFS= read -r line || [ -n "$line" ]; do
		case "$line" in '#'*) continue ;; esac
		value=${line#"${line%%[![:space:]]*}"}
		value=${value%"${value##*[![:space:]]}"}
		[ -n "$value" ] || continue
		case "$value" in '' | *[!0-9]* | 0[0-9]*) return 2 ;; esac
		[ "$value" -gt 0 ] || return 2
		printf '%s' "$value"
		return 0
	done <"$file"
	return 1
}

if [ -n "${FM_STALE_ESCALATE_SECS:-}" ]; then
	STALE_ESCALATE_SECS=$FM_STALE_ESCALATE_SECS
else
	_stale_escalate_configured=$(stale_escalate_configured "$STALE_ESCALATE_SECS_FILE")
	_stale_escalate_rc=$?
	case "$_stale_escalate_rc" in
	0) STALE_ESCALATE_SECS=$_stale_escalate_configured ;;
	2)
		echo "warning: ignoring malformed config/stale-escalate-secs (want one positive whole number of seconds); using ${STALE_ESCALATE_SECS_DEFAULT}s" >&2
		STALE_ESCALATE_SECS=$STALE_ESCALATE_SECS_DEFAULT
		;;
	*) STALE_ESCALATE_SECS=$STALE_ESCALATE_SECS_DEFAULT ;;
	esac
	unset _stale_escalate_configured _stale_escalate_rc
fi
# A busy pane is unconditional proof of liveness with no built-in duration bound,
# so a hung foreground call can remain hidden even while its rendered busy
# footer changes every poll. BUSY_TURN_MAX_SECS bounds how long any busy pane
# may go with no completed turn: once its task's
# state/<id>.turn-ended marker (or, before any turn has completed, the task's
# spawn record) is this old, busy_turn_over_age routes the pane through
# busy_turn_bound_check, which hands a crossed bound to the same
# STALE_ESCALATE_SECS-paced wedge_timer_check used for a provably-working
# non-busy stale - so it escalates via the existing stale reason, escalation
# counter, and demand-deep-inspection marker for human inspection only, never an
# automatic interrupt, signal, or restart - unless the crew declared the wait
# itself, which takes the long pause cadence instead. A completed turn touches
# turn-ended and resets the age. Set generously above any legitimate interval
# between completed turns, including long tool calls, builds, or test runs.
BUSY_TURN_MAX_SECS=${FM_BUSY_TURN_MAX_SECS:-3600}
# A local secondmate's foreign queue is checked on every poll, but only after this
# bounded age can it produce a parent notification.
SECONDMATE_WAKE_STALL_SECS=${FM_SECONDMATE_WAKE_STALL_SECS:-60}
# An aged row alone does not mean the mate's wake loop stalled: a mate that is
# mid-turn cannot reach its queue until that turn ends, so a row arriving during a
# long turn ages past the threshold every time (measured 2026-08-24: two mates
# reported repeatedly while holding ZERO undrained rows). These two bounds say when
# "mid-turn" stops being an explanation - a queue this deep, or an oldest row this
# old, is a mate that is genuinely behind however busy it looks.
SECONDMATE_WAKE_STALL_DEPTH=${FM_SECONDMATE_WAKE_STALL_DEPTH:-10}
SECONDMATE_WAKE_STALL_BEHIND_SECS=${FM_SECONDMATE_WAKE_STALL_BEHIND_SECS:-900}
# A mate that IS behind must keep reporting, because the per-row records alone made
# the loudest case silent: the same measurement found a mate holding 90 undrained
# rows whose oldest was 331 minutes old raising nothing at all, since its oldest row
# had already been reported once. An unchanged backlog therefore repeats on a
# growing interval that starts here and is bounded by the ceiling below, so it
# escalates without storming.
SECONDMATE_WAKE_STALL_REPEAT_SECS=${FM_SECONDMATE_WAKE_STALL_REPEAT_SECS:-300}
SECONDMATE_WAKE_STALL_REPEAT_MAX_SECS=${FM_SECONDMATE_WAKE_STALL_REPEAT_MAX_SECS:-3600}
# A crew that declared a pause is idling on a known external wait, so its stale
# pane is absorbed rather than wedge-escalated.
# When authoritative crew state cannot name that wait at all, a crew whose agent
# has confidently exited still earns the same bounded cadence, while a live or
# ambiguously read agent surfaces once; a secondmate earns the cadence on its
# declaration alone, because its endpoint liveness is deliberately never read
# (pause_state_class owns that split).
# These cases re-surface once for a recheck, first after PAUSE_RESURFACE_SECS - far
# longer than the wedge threshold, but finite so a forgotten hold cannot rot invisibly.
PAUSE_RESURFACE_SECS=${FM_PAUSE_RESURFACE_SECS:-$FM_PAUSE_RESURFACE_SECS_DEFAULT}
# A recheck of an UNCHANGED declaration carries no new information, so repeating it
# on a fixed hourly cadence is pure cost: measured 2026-08-24, two correctly declared
# waits in one home produced essentially every routine wake that home received over
# 26.4 hours, while both waits were externally covered and neither had moved. The
# condition must still never rot invisibly, so the recheck decays instead of
# stopping - the same "known, already-reported, must not rot invisibly" treatment
# WEDGE_BACKOFF_SECS gives an escalated wedge. decayed_interval doubles the
# interval as the declaration itself ages, bounded by PAUSE_BACKOFF_MAX_SECS, so a
# wait that has held for days is rechecked daily rather than hourly and a fresh one
# is still rechecked at the base cadence.
PAUSE_BACKOFF_MAX_SECS=${FM_PAUSE_BACKOFF_MAX_SECS:-86400}
# Consecutive event-path failures (fm_backend_wait_transition returning 2 -
# connect/subscribe failure) before the push fast-path is disabled for the rest
# of this watcher process and the loop reverts to pure polling (report section
# 5c trigger 3: proven-unreliable-at-runtime). A watcher restart re-probes
# capability, so a transient herdr hiccup self-heals on the next cycle chain.
EVENT_CAP_FAIL_MAX=${FM_EVENT_CAP_FAIL_MAX:-3}
# Per-process memo for the push-capability probe (fm_backend_events_capable runs
# a ~220KB `herdr api schema` read, too heavy to repeat every poll). Keyed by
# "<backend>:<session>"; re-probed only when that key changes.
_event_cap_key=""
_event_cap_ok=0
_event_cap_fails=0

# afk_present: 0 while the away-mode flag exists. When set, the daemon wraps this
# watcher and owns triage, so the watcher must behave one-shot (enqueue + exit on
# every wake) and let the daemon classify - never absorb here, or the daemon's
# digest/injection layer would never see the wake.
afk_present() { [ -e "$STATE/.afk" ]; }

hash_pane() {
  if command -v md5 >/dev/null 2>&1; then md5 -q; else md5sum | cut -d' ' -f1; fi
}

# window_is_busy: 0 (busy) iff the task's harness is PROVABLY working, through
# the semantic busy-state contract (bin/fm-busy-lib.sh). Only an exact busy
# verdict returns 0: idle, unknown, and dead all return 1, so a converted
# adapter whose semantic state is missing, malformed, stale, or unverified is
# treated as not-provably-working and surfaces rather than being absorbed.
# <tail40> is the same bounded capture already read for hashing and is
# consumed only by the Grok-scoped fallback inside the contract.
window_is_busy() {  # <window> <tail40>
  local w=$1 tail40=$2 task meta verdict
  task=$(window_to_task "$w" "$STATE")
  meta="$STATE/$task.meta"
  if [ -n "$task" ] && [ -f "$meta" ]; then
    verdict=$(fm_busy_classify_meta "$meta" "$task" "$STATE" "$tail40")
  else
    verdict=$(fm_busy_classify "$(window_backend "$w")" "$w" "$(window_harness "$w")" \
      "${task:-unknown}" "$STATE" "$tail40")
  fi
  [ "${verdict%% *}" = busy ]
}

window_kind() {
  local w=$1 meta kind
  meta=$(fm_backend_meta_for_window "$w" "$STATE" 2>/dev/null || true)
  if [ -n "$meta" ]; then
    kind=$(grep '^kind=' "$meta" | cut -d= -f2- || true)
    [ -n "$kind" ] || kind=ship
    echo "$kind"
    return 0
  fi
  echo unknown
}

# window_backend: the backend recorded in the meta whose window= matches <w>,
# defaulting to tmux (absent backend= means tmux; the P1 compatibility
# contract) when no matching meta carries the field, or none matches at all.
window_backend() {
  local w=$1 meta backend
  meta=$(fm_backend_meta_for_window "$w" "$STATE" 2>/dev/null || true)
  if [ -n "$meta" ]; then
    backend=$(grep '^backend=' "$meta" | cut -d= -f2- || true)
    [ -n "$backend" ] || backend=tmux
    echo "$backend"
    return 0
  fi
  echo tmux
}

window_harness() {
  local w=$1 meta
  meta=$(fm_backend_meta_for_window "$w" "$STATE" 2>/dev/null || true)
  [ -n "$meta" ] || return 0
  grep '^harness=' "$meta" | cut -d= -f2- || true
}

window_label() {
  local w=$1 task
  task=$(window_to_task "$w" "$STATE")
  [ -n "$task" ] && printf 'fm-%s' "$task"
}

# The ONE derivation of a window's per-window marker key: `:`, `/` and `.` become
# `_` so a window name is usable as a filename suffix. Every per-window file the
# watcher keeps is named by it (.hash-, .count-, .stale-, .stale-since-,
# .wedge-escalations-, .paused-*, .defer-*), and live homes hold those markers on
# disk under the current format, so the format lives here alone: a second copy is
# how a future change to it silently orphans a window's markers instead of clearing
# them. The helpers below take the derived key rather than re-deriving it, so one
# poll of one window derives it once.
window_key() {  # <window>
  local key=${1//:/_}
  key=${key//\//_}
  printf '%s' "${key//./_}"
}

recorded_windows() {
  local meta w seen=
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    w=$(fm_backend_target_of_meta "$meta")
    [ -n "$w" ] || continue
    case "$seen" in
      *"|$w|"*) continue ;;
    esac
    seen="$seen|$w|"
    printf '%s\n' "$w"
  done
}

# Print the oldest structurally valid row in a local secondmate's foreign queue.
# This is a read-only observation: the receiving home owns acknowledgement and
# this parent never changes the row or the foreign queue.
secondmate_oldest_queue_row() {  # <queue-path>
  local queue=$1
  [ -f "$queue" ] && [ ! -L "$queue" ] || return 0
  awk -F '\t' '
    NF >= 5 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ {
      if (!found || $2 < seq) {
        found = 1
        seq = $2
        row = $0
      }
    }
    END { if (found) print row }
  ' "$queue" 2>/dev/null || true
}

# Count the structurally valid rows in a local secondmate's foreign queue. Depth is
# the half of the picture the oldest row alone cannot give: one aged row is a mate
# mid-turn, a deep queue behind that same row is a mate whose wake loop is not
# keeping up. Read-only, exactly like secondmate_oldest_queue_row above.
secondmate_queue_depth() {  # <queue-path>
  local queue=$1
  if [ ! -f "$queue" ] || [ -L "$queue" ]; then
    printf '0'
    return 0
  fi
  awk -F '\t' '
    NF >= 5 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ { n++ }
    END { printf "%d", n + 0 }
  ' "$queue" 2>/dev/null || printf '0'
}

# 0 while <task>'s recorded endpoint is PROVABLY mid-turn, through the same
# semantic busy contract every other liveness read here uses (bin/fm-busy-lib.sh).
# Classifies through fm_busy_classify_meta, which never produces the dead verdict
# (only fm_busy_classify_live applies the endpoint-gone override): only an exact
# busy verdict counts as mid-turn, and every other verdict, including idle and an
# unreadable or missing one, returns 1 so the aged row still reports. A mate whose
# endpoint is gone while a leftover busy record still reads open classifies busy
# and is absorbed as mid-turn, which stays bounded by
# FM_SECONDMATE_WAKE_STALL_DEPTH and FM_SECONDMATE_WAKE_STALL_BEHIND_SECS, after
# which it reports regardless; registered mates with a missing or dead endpoint
# are owned by the separate startup secondmate-liveness check. Called only on a
# row that already crossed the age threshold and is still inside the mid-turn
# bounds, never on every poll.
secondmate_mid_turn() {  # <meta> <task>
  local meta=$1 task=$2 backend target tail40 verdict
  target=$(fm_backend_target_of_meta "$meta" 2>/dev/null) || return 1
  [ -n "$target" ] || return 1
  backend=$(fm_backend_of_meta "$meta" 2>/dev/null) || return 1
  tail40=$(fm_backend_capture "$backend" "$target" 40 "fm-$task" 2>/dev/null) || tail40=''
  verdict=$(fm_busy_classify_meta "$meta" "$task" "$STATE" "$tail40")
  [ "${verdict%% *}" = busy ]
}

# Surface one durable parent check for a local secondmate whose wake loop is behind,
# and keep reporting it on a decaying cadence while it stays behind. Two shapes have
# to stay apart, because the first version of this check got both backwards
# (measured 2026-08-24): a mate merely mid-turn, whose newly arrived row ages past
# the threshold before it can reach it, must stay silent however often that repeats,
# while a mate holding a deep queue whose oldest row is hours old must keep
# reporting even though that exact row was already reported once. The mid-turn
# excuse is therefore bounded by queue DEPTH and by the oldest row's age, and the
# per-row marker and receipt no longer veto a report forever - they date the last
# report so an unchanged backlog repeats on decayed_interval instead of never.
# The queued-key check still makes repeated watcher cycles converge without a storm,
# and an empty queue still removes only this home's records so a later row can be
# observed.
secondmate_wake_stall_tick() {
  local now=$(( $(date +%s) )) threshold=$SECONDMATE_WAKE_STALL_SECS
  local depth_limit=$SECONDMATE_WAKE_STALL_DEPTH behind=$SECONDMATE_WAKE_STALL_BEHIND_SECS
  local repeat_base=$SECONDMATE_WAKE_STALL_REPEAT_SECS repeat_max=$SECONDMATE_WAKE_STALL_REPEAT_MAX_SECS
  local meta task kind remote_host home queue row epoch seq row_key marker receipt receipt_dir notify_key queued age reason
  local depth reported reported_age repeat
  case "$threshold" in ''|*[!0-9]*|0) threshold=60 ;; esac
  case "$depth_limit" in ''|*[!0-9]*|0) depth_limit=10 ;; esac
  case "$behind" in ''|*[!0-9]*|0) behind=900 ;; esac
  case "$repeat_base" in ''|*[!0-9]*|0) repeat_base=300 ;; esac
  case "$repeat_max" in ''|*[!0-9]*|0) repeat_max=3600 ;; esac
  # Endpoint metadata admits this queue-loop check; secondmate-liveness owns registered mates whose endpoint is missing or dead.
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    kind=$(fm_meta_get "$meta" kind)
    [ "$kind" = secondmate ] || continue
    remote_host=$(fm_meta_get "$meta" remote_host)
    [ -z "$remote_host" ] || continue
    task=${meta##*/}
    task=${task%.meta}
    case "$task" in ''|*[!A-Za-z0-9._-]*) continue ;; esac
    home=$(fm_meta_get "$meta" home)
    [ -n "$home" ] || continue
    [ -f "$home/.fm-secondmate-home" ] && [ ! -L "$home/.fm-secondmate-home" ] || continue
    [ "$(cat "$home/.fm-secondmate-home" 2>/dev/null || true)" = "$task" ] || continue
    queue="$home/state/.wake-queue"
    row=$(secondmate_oldest_queue_row "$queue")
    marker="$STATE/.secondmate-wake-stall-$task"
    receipt_dir="$STATE/.secondmate-wake-stall-receipts/$task"
    if [ -z "$row" ]; then
      rm -f "$marker"
      if [ -e "$receipt_dir" ] || [ -L "$receipt_dir" ]; then
        [ -d "$receipt_dir" ] && [ ! -L "$receipt_dir" ] || return 1
        rm -rf -- "$receipt_dir" || return 1
      fi
      continue
    fi
    IFS=$(printf '\t') read -r epoch seq _row_kind _row_key _row_payload <<EOF
$row
EOF
    case "$epoch" in ''|*[!0-9]*) continue ;; esac
    case "$seq" in ''|*[!0-9]*) continue ;; esac
    age=$((now - epoch))
    [ "$age" -ge "$threshold" ] || continue
    row_key="$epoch-$seq"
    receipt="$receipt_dir/$row_key"
    if [ -e "$marker" ] || [ -L "$marker" ]; then
      [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
    fi
    depth=$(secondmate_queue_depth "$queue")
    repeat=$(decayed_interval "$age" "$repeat_base" "$repeat_max")
    # When this exact row was last reported, from whichever record is newer: the
    # marker this watcher writes at publication, or the receipt the drain writes at
    # acknowledgement - which alone survives a crash between the two. 999999 (the
    # age_of miss value) means never, so a first sighting is never throttled.
    reported_age=999999
    if [ "$(cat "$marker" 2>/dev/null || true)" = "$row_key" ]; then
      reported_age=$(age_of "$marker")
    fi
    if [ "$(cat "$receipt" 2>/dev/null || true)" = "$row_key" ]; then
      reported=$(age_of "$receipt")
      [ "$reported" -lt "$reported_age" ] && reported_age=$reported
    fi
    [ "$reported_age" -ge "$repeat" ] || continue
    # A mate that is mid-turn cannot drain its queue yet, so an aged row alone is no
    # evidence its wake loop stalled. That excuse ends where the mate is measurably
    # behind: a queue at least depth_limit deep, or an oldest row at least `behind`
    # old, reports whatever the endpoint says.
    if [ "$depth" -lt "$depth_limit" ] && [ "$age" -lt "$behind" ] \
      && secondmate_mid_turn "$meta" "$task"; then
      triage_log "absorbed secondmate wake-loop row (mate mid-turn, depth $depth, oldest ${age}s): $task"
      continue
    fi
    notify_key="secondmate-wake-loop-$task-$row_key"
    reason="check: secondmate wake-loop stalled: mate=$task row=$seq age=${age}s depth=$depth (unchanged backlog not reported again before ${repeat}s)"
    queued=$(fm_wake_queued_keys check)
    if ! printf '%s\n' "$queued" | grep -Fx "$notify_key" >/dev/null 2>&1; then
      fm_wake_append check "$notify_key" "$reason" || return 1
    fi
    fm_wake_secondmate_stall_receipt_write "$task" "$row_key" || return 1
    fm_wake_secondmate_stall_marker_write "$task" "$row_key" || return 1
    wake "$reason"
  done
  return 0
}

# Consecutive wedge-escalation count for a window past FM_WEDGE_DEMAND_INSPECT_COUNT
# (default 3): a pane that keeps re-wedging on the SAME stale hash - each
# escalation gets absorbed again as "still validating" one poll later, since the
# hash never changes - can otherwise repeat forever with no signal that this is
# no longer a one-off. At the threshold, wedge_timer_check appends a
# "demand-deep-inspection" marker to the wake payload so the wake reason itself
# (not just repetition the supervisor has to notice on its own) forces a closer
# look instead of another routine supervision resume. Reset wherever a window's
# pane/hash state resets to genuinely active (see the two rm-on-reset call sites
# below).
FM_WEDGE_DEMAND_INSPECT_COUNT=${FM_WEDGE_DEMAND_INSPECT_COUNT:-3}
# Past that threshold the marker alone changed nothing about the watcher's own
# cadence, so an already-reported wedge kept waking firstmate every
# STALE_ESCALATE_SECS indefinitely (2026-08-23: eight panes at "escalation 28"
# and still climbing, burying real events). The condition is real and must never
# be silenced, so it re-surfaces on a growing interval instead of a fixed one -
# the same "known, already-reported, must not rot invisibly" treatment a declared
# pause gets from PAUSE_RESURFACE_SECS. WEDGE_BACKOFF_SECS is the unit that
# doubles per escalation past the threshold, and WEDGE_BACKOFF_MAX_SECS bounds it
# at the pause cadence, so a genuine wedge still reports at least hourly. The
# backoff is derived purely from the escalation counter, so every existing reset
# of .wedge-escalations-<key> - a changed stale hash, a busy pane, a terminal or
# paused task - returns the cadence to STALE_ESCALATE_SECS with no extra state.
WEDGE_BACKOFF_SECS=${FM_WEDGE_BACKOFF_SECS:-$STALE_ESCALATE_SECS}
WEDGE_BACKOFF_MAX_SECS=${FM_WEDGE_BACKOFF_MAX_SECS:-$PAUSE_RESURFACE_SECS}

# Seconds this pane must stay idle before its NEXT wedge escalation, given the
# escalations already recorded for it. Below the demand-inspect threshold this is
# the unchanged STALE_ESCALATE_SECS cadence; from the threshold escalation onward
# it doubles per escalation, bounded by WEDGE_BACKOFF_MAX_SECS.
wedge_escalate_interval() {  # <escalations-already-recorded>
  local n=$1 steps interval
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  if [ "$n" -lt "$FM_WEDGE_DEMAND_INSPECT_COUNT" ]; then
    printf '%s' "$STALE_ESCALATE_SECS"
    return 0
  fi
  steps=$(( n - FM_WEDGE_DEMAND_INSPECT_COUNT + 1 ))
  [ "$steps" -gt 20 ] && steps=20   # shift guard; the ceiling below binds long before this
  interval=$(( WEDGE_BACKOFF_SECS * (1 << steps) ))
  [ "$interval" -gt "$WEDGE_BACKOFF_MAX_SECS" ] && interval=$WEDGE_BACKOFF_MAX_SECS
  # A backoff only ever slows this pane down. A smaller configured unit or
  # ceiling clamps to the pre-threshold cadence rather than escalating a
  # known, already-reported wedge FASTER than an unreported one.
  [ "$interval" -lt "$STALE_ESCALATE_SECS" ] && interval=$STALE_ESCALATE_SECS
  printf '%s' "$interval"
}

# How long a KNOWN, already-reported condition of <age> must go before it is worth
# reporting again. The first report still lands at <base>; from there the interval
# doubles once per doubling of the condition's own age, so an unchanged condition is
# reported at about 1x, 3x, 7x and 15x the base before settling on <ceiling>.
# Deriving the interval from the condition's own age rather than from a counter
# keeps it stateless: the condition restarting resets the cadence by resetting the
# age, nothing has to be cleaned up, and a condition that has already held for days
# reports at the ceiling immediately instead of climbing the whole ramp again after
# a watcher restart. A ceiling below the base clamps to the base, so a
# misconfiguration can only ever slow reporting down, never turn a decayed cadence
# into a faster nag than the flat one it replaced. Shared by the declared-wait
# recheck and the secondmate wake-loop stall report; the wedge escalation keeps its
# own counter-driven WEDGE_BACKOFF_SECS shape, which is anchored on consecutive
# escalations rather than on one condition's age.
decayed_interval() {  # <age-seconds> <base-seconds> <ceiling-seconds>
  local age=$1 base=$2 ceiling=$3 interval
  case "$age" in ''|*[!0-9]*) age=0 ;; esac
  case "$base" in ''|*[!0-9]*|0) base=1 ;; esac
  case "$ceiling" in ''|*[!0-9]*) ceiling=$base ;; esac
  [ "$ceiling" -lt "$base" ] && ceiling=$base
  interval=$base
  while [ "$interval" -lt "$ceiling" ] && [ "$age" -ge $(( interval * 2 )) ]; do
    interval=$(( interval * 2 ))
  done
  [ "$interval" -gt "$ceiling" ] && interval=$ceiling
  printf '%s' "$interval"
}

# One bounded re-surface for a pane the watcher is deliberately absorbing, so no
# absorb can rot invisibly. <age> is how long the current absorb has held and
# <throttle> is the per-window marker whose mtime records the last re-surface, so
# once past <interval> the pane wakes once per window rather than every poll.
# <interval> defaults to the flat PAUSE_RESURFACE_SECS and the declared-wait caller
# passes its decayed interval instead. Shared by the declared-pause absorb and the
# worktree-write deferral so the two cadences cannot drift apart; each caller owns
# its own marker and reason.
# Returns without waking while either the absorb or the throttle is inside the
# window; wake() itself exits the cycle, exactly as it does inline.
resurface_absorbed() {  # <window> <throttle-marker> <age> <reason> [interval]
  local win=$1 throttle=$2 age=$3 reason=$4 interval=${5:-$PAUSE_RESURFACE_SECS}
  [ "$age" -ge "$interval" ] || return 0
  [ "$(age_of "$throttle")" -ge "$interval" ] || return 0   # 999999 when no prior re-surface
  fm_wake_append stale "$win" "$reason" || exit 1
  date +%s > "$throttle"
  wake "$reason"
}

# Defer ONE wedge escalation for a pane the watcher has positive evidence for that
# its own rendered pane cannot show (see this file's header for the evidence
# classes and the call sites for their probes). Deliberately a DEFERRAL, not a
# cancellation: the idle timer restarts, so the next window probes again, and
# the window's deferral chain keeps ageing across both evidence classes, so it
# still re-surfaces once every PAUSE_RESURFACE_SECS through the shared
# resurface_absorbed and evidence that churns without real progress cannot stay
# invisible. The escalation counter is left alone: it is neither
# advanced (this is not an escalation) nor reset (a later genuine escalation must
# still carry the demand-deep-inspection history it had earned).
wedge_defer() {  # <window> <since-file> <triage-label> <idle-age> <evidence>
  local win=$1 since_file=$2 label=$3 age=$4 evidence=$5 key csf cage
  key=$(window_key "$win")
  csf="$STATE/.defer-since-$key"
  [ -e "$csf" ] || date +%s > "$csf"
  cage=$(age_of "$csf")
  date +%s > "$since_file"
  resurface_absorbed "$win" "$STATE/.defer-resurfaced-$key" "$cage" \
    "stale: $win (idle ${age}s, $evidence, deferred for ${cage}s, rechecked on a long cadence not a wedge; confirm it is real progress)"
  triage_log "absorbed $label ($evidence, idle ${age}s): $win"
}

# Drop a window's deferral chains wherever its stale bookkeeping resets, so the
# bounded re-surface cadence is measured from the CURRENT quiet stretch and a
# long-finished one cannot make the next deferral resurface immediately.
clear_defer_tracking() {  # <window-key>
  local key=$1
  rm -f "$STATE/.defer-since-$key" "$STATE/.defer-resurfaced-$key"
}

# Repeat-poll wedge-timer bookkeeping for an already-classified stale hash
# absorbed as provably-working - repairs a missing/corrupt timer (self-heals a
# watcher restart between recording the hash and recording the timer), or
# escalates once this pane's current wedge_escalate_interval has elapsed. Shared
# by both places a hash can be absorbed this way: the plain non-terminal path, and
# the stale_is_terminal-overridden path (a captain-relevant status-log line that an
# active run/busy pane outranked).
# Every evidence probe runs ONLY in the at-threshold branch below, on current
# reads rather than classification-time ones, because the question at escalation
# is whether this crew is progressing NOW. Probes keep the order they were added
# in; reaching any of them means this poll was about to escalate, so ordering
# only relabels the deferral.
wedge_timer_check() {  # <window> <since-file> <triage-label> <escalation-count-file> <task>
  local win=$1 since_file=$2 label=$3 escalation_file=$4 task=$5 since age n interval next reason evidence
  since=$(cat "$since_file" 2>/dev/null || true)
  case "$since" in
    ''|*[!0-9]*)
      date +%s > "$since_file"
      clear_defer_tracking "$(window_key "$win")"
      triage_log "absorbed $label timer reset: $win"
      ;;
    *)
      age=$(( $(date +%s) - since ))
      n=$(cat "$escalation_file" 2>/dev/null || echo 0)
      case "$n" in ''|*[!0-9]*) n=0 ;; esac
      interval=$(wedge_escalate_interval "$n")
      if [ "$age" -ge "$interval" ]; then
        if crew_worktree_written_since "$task" "$STATE" "$since_file"; then
          wedge_defer "$win" "$since_file" "$label" "$age" "writing its worktree"
          return 0
        fi
        if evidence=$(crew_step_progress_evidence "$task"); then
          wedge_defer "$win" "$since_file" "$label" "$age" "$evidence"
          return 0
        fi
        if evidence=$(crew_turn_progress_evidence "$task" "$STATE" "$since_file"); then
          wedge_defer "$win" "$since_file" "$label" "$age" "$evidence"
          return 0
        fi
        n=$(( n + 1 ))
        echo "$n" > "$escalation_file"
        reason="stale: $win (idle ${age}s, possible wedge, escalation $n)"
        if [ "$n" -ge "$FM_WEDGE_DEMAND_INSPECT_COUNT" ]; then
          next=$(wedge_escalate_interval "$n")
          reason="stale: $win (idle ${age}s, possible wedge, escalation $n, demand-deep-inspection: same pane has wedge-escalated $n times in a row - do not re-absorb on the run-step/pane state alone; backing off, next recheck of this unchanged pane in ${next}s)"
        fi
        fm_wake_append stale "$win" "$reason" || exit 1
        rm -f "$since_file"
        clear_defer_tracking "$(window_key "$win")"
        wake "$reason"
      fi
      ;;
  esac
}

# busy_turn_over_age: 0 iff <task>'s latest completed-turn marker is at least
# BUSY_TURN_MAX_SECS old. Ages the per-task turn-ended marker, the harness-neutral
# signal every verified harness's turn-end hook touches; before any turn has
# completed, ages the task's spawn record instead so a fresh task still gets a
# bound. The caller checks that the pane is busy and routes a crossed bound
# through busy_turn_bound_check, never anything that touches the worker itself.
busy_turn_over_age() {  # <task>
  local task=$1 f
  f="$STATE/$task.turn-ended"
  [ -e "$f" ] || f="$STATE/$task.meta"
  [ "$(age_of "$f")" -ge "$BUSY_TURN_MAX_SECS" ]
}

# Absorb a stale pane under a declared external-wait pause (paused:) or a
# captain-held transfer, and re-surface it once per recheck interval so it cannot
# rot invisibly - decayed_interval owns that interval, which starts at
# PAUSE_RESURFACE_SECS and decays as the unchanged declaration ages. Called on any
# stale poll once pause_state_class permits the bounded cadence, so it must be
# cheap: it NEVER re-reads crew state. The re-surface age is anchored on the
# status file mtime, not a per-hash marker, so a churny idle pane (a ticking
# clock, a token counter) cannot keep resetting the cadence the way a hash-tied
# timer would. The bounded re-surface itself is the shared resurface_absorbed
# above, throttled by this window's own .paused-resurfaced-<key> marker. Advances
# the stale suppressor to <hash> and flags the key paused.
#
# The recheck names WHICH human the declared wait is on, because that is the whole
# point of a recheck the captain reads: an external dependency for paused:, and the
# captain themself for a verified hold. Only the captain-held verb takes the second
# wording; a caller that reached the bounded cadence off pause tracking alone, with
# no declaring verb left on the log, keeps the external-wait wording it always had.
handle_paused_stale() {  # <window> <task> <hash>
  local win=$1 task=$2 h=$3 key statusf mtime age interval detail reason
  key=$(window_key "$win")
  printf '%s' "$h" > "$STATE/.stale-$key"
  : > "$STATE/.paused-$key"
  rm -f "$STATE/.stale-since-$key" "$STATE/.wedge-escalations-$key"
  clear_defer_tracking "$key"
  statusf="$STATE/$task.status"
  mtime=$(stat_mtime "$statusf")
  case "$mtime" in ''|*[!0-9]*) mtime=$(date +%s) ;; esac
  age=$(( $(date +%s) - mtime ))
  interval=$(decayed_interval "$age" "$PAUSE_RESURFACE_SECS" "$PAUSE_BACKOFF_MAX_SECS")
  if status_is_captain_held "$(last_status_line "$statusf")"; then
    detail="captain-held, awaiting the captain"
    reason="captain-held ${age}s, awaiting the captain - verified hold transfer, rechecked on a long cadence not a wedge; answer the held decision or release the hold; next recheck of this unchanged hold not before ${interval}s"
  else
    detail="paused, awaiting external"
    reason="paused ${age}s, awaiting external - declared pause, rechecked on a long cadence not a wedge; confirm the wait still holds; next recheck of this unchanged wait not before ${interval}s"
  fi
  resurface_absorbed "$win" "$STATE/.paused-resurfaced-$key" "$age" "stale: $win ($reason)" "$interval"
  triage_log "absorbed stale ($detail, age ${age}s): $win"
}

# Apply the busy-pane completed-turn bound to a window whose bound has already
# crossed, honoring the worker's OWN declared external wait. Prints/queues
# nothing itself; it only chooses which absorber owns the crossed bound.
# 0 when the declared-pause cadence took the pane, 1 when the wedge timer did.
#
# A busy pane past BUSY_TURN_MAX_SECS is normally a wedge suspect because a hung
# foreground call can hide behind a busy signature. A `paused:` declaration or
# verified captain-held transfer instead identifies that live foreground call as
# the expected external wait. The caller has already confirmed liveness through
# the busy verdict, so this exception does not suppress undeclared wedges or
# alter the separate non-busy classification. handle_paused_stale keeps the
# exception bounded by its decaying re-surface cadence. Away mode
# remains daemon-owned and receives the undecorated wake identity for its own
# classification.
busy_turn_bound_check() {  # <window> <task> <hash> <since-file> <escalation-file>
  local win=$1 task=$2 h=$3 since_file=$4 escalation_file=$5
  if ! afk_present && status_is_paused_or_captain_held "$(last_status_line "$STATE/$task.status")"; then
    handle_paused_stale "$win" "$task" "$h"
    return 0
  fi
  wedge_timer_check "$win" "$since_file" "busy (no completed turn)" "$escalation_file" "$task"
  return 1
}

clear_pause_state() {  # <window-key>
  local key=$1
  rm -f "$STATE/.paused-$key" "$STATE/.paused-rechecked-$key" "$STATE/.paused-resurfaced-$key"
}

clear_pause_tracking() {  # <window-key>
  local key=$1
  clear_pause_state "$key"
  clear_defer_tracking "$key"
  rm -f "$STATE/.stale-$key" "$STATE/.stale-since-$key" "$STATE/.wedge-escalations-$key"
}

# Reconcile a declared pause or captain-held status with authoritative crew state.
# A declared wait is the worker's OWN account of why its pane is quiet, so it holds
# while the agent is alive. Only an actively-running pipeline attributed to this
# crew's current code (crew_absorb_state's `working run-step`) outranks it, because
# that is positive evidence the crew resumed, rather than another reading of the
# same quiet pane the declaration already explains. A pane-sourced busy verdict
# deliberately does NOT outrank it: a parked lane whose per-harness busy source
# still reports busy is exactly the shape that used to route a declared wait into
# wedge_timer_check and escalate it on the stale cadence forever.
# After fm-crew-state has fallen back to stopped or unknown, paused classification
# is recovered only for a confidently dead ordinary crew, or for a secondmate, whose
# endpoint liveness this function deliberately never reads.
pause_state_class() {  # <window> <task>
  local win=$1 task=$2 key last recheck_file verdict class src agent_alive kind
  key=$(window_key "$win")
  last=$(last_status_line "$STATE/$task.status")
  recheck_file="$STATE/.paused-rechecked-$key"
  if ! status_is_paused_or_captain_held "$last"; then
    rm -f "$recheck_file"
    crew_absorb_class "$task"
    return
  fi
  if [ -e "$STATE/.paused-$key" ] && [ "$(age_of "$recheck_file")" -lt "$STALE_ESCALATE_SECS" ]; then
    printf 'paused'
    return
  fi
  verdict=$(crew_absorb_state "$task")
  class=${verdict%% *}
  src=${verdict##* }
  if [ "$class" = working ] && [ "$src" = run-step ]; then
    rm -f "$recheck_file"
    printf 'working'
    return
  fi
  if [ "$class" = none ]; then
    # Recover paused classification for a declared wait that authoritative crew
    # state could not name at all. A pane-sourced `working` is not that case: it is
    # another reading of the same quiet pane, so it never reaches here. Only two
    # cases are admissible: an ordinary crew whose agent is confirmed dead, so no
    # live decision gate is being silenced, or a secondmate, whose endpoint liveness
    # is deliberately never read and so cannot supply that confirmation. Without the mate case a mate's captain hold - which
    # has no current-state mapping and so arrives as `none` - would be silenced by
    # every caller rather than taking the bounded re-surface cadence, and a
    # forgotten hold would rot invisibly.
    kind=$(window_kind "$win")
    if [ "$kind" != secondmate ]; then
      agent_alive=$(fm_backend_agent_alive "$(window_backend "$win")" "$win" 2>/dev/null) || agent_alive=unknown
      if [ "$agent_alive" != dead ]; then
        rm -f "$recheck_file"
        printf 'none'
        return
      fi
    fi
  fi
  date +%s > "$recheck_file"
  printf 'paused'
}

surface_nonterminal_stale() {  # <window> <hash>
  local win=$1 h=$2 key task last
  key=$(window_key "$win")
  fm_wake_append stale "$win" "stale: $win" || exit 1
  printf '%s' "$h" > "$STATE/.stale-$key"
  rm -f "$STATE/.stale-since-$key"
  clear_defer_tracking "$key"
  task=$(window_to_task "$win" "$STATE")
  last=$(last_status_line "$STATE/$task.status")
  if status_is_paused_or_captain_held "$last"; then
    : > "$STATE/.paused-$key"
    date +%s > "$STATE/.paused-rechecked-$key"
    date +%s > "$STATE/.paused-resurfaced-$key"
  else
    rm -f "$STATE/.paused-$key" "$STATE/.paused-rechecked-$key" "$STATE/.paused-resurfaced-$key"
  fi
  wake "stale: $win"
}

# Check and heartbeat cadence must survive actionable exits and restarts: the
# watcher may be relaunched before in-memory counters reach their threshold on a
# busy fleet. Persist the schedule as file mtimes instead.
age_of() {  # seconds since file mtime; "due immediately" if missing
  local f=$1 m
  m=$(stat_mtime "$f") || { echo 999999; return; }
  echo $(( $(date +%s) - m ))
}

# Layer 2 + 3 signal scan: status files and turn-end markers. Each file is
# compared against a persisted size:mtime signature (.seen-*) rather than
# mtime-vs-a-startup-touch, so signals that land while no watcher is running
# are caught by the next one, and same-second writes cannot slip through a
# strict -nt comparison. Pure read: prints one "<seen-file>\t<sig>\t<file>"
# line per changed file. .seen-* is updated only after the wake is either
# surfaced or intentionally absorbed, so a watcher killed mid-cycle never
# swallows a signal.
scan_signals() {
  local f sig sf
  for f in "$STATE"/*.status "$STATE"/*.turn-ended; do
    [ -e "$f" ] || continue
    sig=$(fm_wake_signal_sig "$f") || continue
    [ -n "$sig" ] || continue
    sf=$(fm_wake_signal_seen_path "$STATE" "$f")
    if [ "$sig" != "$(cat "$sf" 2>/dev/null)" ]; then
      printf '%s\t%s\t%s\n' "$sf" "$sig" "$f"
    fi
  done
  return 0
}

# Deliver a durably queued process-event result to firstmate. Publication is
# owned by bin/fm-procevent.sh - by the runner at capture time and by reconcile's
# re-announcement - so this decides only whether a queued check record has been
# surfaced yet, then reports it through the same actionable exit every other wake
# uses. Without it a captured result sits on the queue until something else
# happens to wake firstmate, which is exactly the missed delivery this repairs.
# Dedup uses the same .seen-* discipline as scan_signals: the durable record is
# always written before its marker, so nothing is suppressed before it is queued,
# and re-announcement, drain-time deduplication, and the handled acknowledgement
# keep their existing owners untouched.
procevent_surfaced_marker() {  # <queue-key>
  printf '%s/.seen-procevent-%s' "$STATE" "$(printf '%s' "$1" | LC_ALL=C od -An -tx1 | tr -d ' \n')"
}

procevent_surface_after_output() {
  local output_status=$1 key marker tmp status=0
  if [ "$output_status" -eq 0 ]; then
    for key in $PROCEVENT_SURFACED; do
      marker=$(procevent_surfaced_marker "$key")
      tmp=$(umask 077; mktemp "$STATE/.seen-procevent.XXXXXX") || { status=1; continue; }
      if ! mv -f -- "$tmp" "$marker"; then
        rm -f -- "$tmp"
        status=1
      fi
    done
  fi
  fm_lock_release "$FM_WAKE_QUEUE_LOCK"
  return "$status"
}

procevent_surface_queued() {
  local key reason
  PROCEVENT_SURFACED=
  [ -s "$FM_WAKE_QUEUE" ] || return 0
  fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK"
  while IFS= read -r key; do
    case "$key" in procevent:*) ;; *) continue ;; esac
    [ -e "$(procevent_surfaced_marker "$key")" ] && continue
    PROCEVENT_SURFACED="$PROCEVENT_SURFACED $key"
  done < <(fm_wake_queued_keys_locked check)
  if [ -z "$PROCEVENT_SURFACED" ]; then
    fm_lock_release "$FM_WAKE_QUEUE_LOCK"
    return 0
  fi
  reason="check: process-event result captured:$PROCEVENT_SURFACED"
  # shellcheck disable=SC2034 # Consumed by wake() in the separately linted transition owner.
  FM_WAKE_POST_OUTPUT_ACTION=procevent_surface_after_output
  wake "$reason"
}

run_check_process() {
  local c=$1
  shift
  if [ "${FM_CHECK_FORCE_FALLBACK:-0}" != 1 ] && command -v timeout >/dev/null 2>&1; then
    exec timeout "$CHECK_TIMEOUT" bash "$c" "$@"
  elif [ "${FM_CHECK_FORCE_FALLBACK:-0}" != 1 ] && command -v gtimeout >/dev/null 2>&1; then
    exec gtimeout "$CHECK_TIMEOUT" bash "$c" "$@"
  else
    # shellcheck disable=SC2016  # single quotes are deliberate: Perl expands its own variables.
    exec perl -e 'my $t = shift; my $owned = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0) unless $owned; exec @ARGV } my $group = $owned ? getpgrp(0) : $pid; my $stop = sub { $SIG{HUP} = $SIG{INT} = $SIG{TERM} = "IGNORE"; kill "TERM", -$group; select undef, undef, undef, 0.2; kill "KILL", -$group; waitpid $pid, 0; exit 124 }; local $SIG{ALRM} = $stop; local $SIG{HUP} = $stop; local $SIG{INT} = $stop; local $SIG{TERM} = $stop; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$CHECK_TIMEOUT" "${FM_CHECK_OWNED_GROUP:-0}" bash "$c" "$@"
  fi
}

run_check() {
  ( run_check_process "$@" ) 2>/dev/null || true
}

FM_ACTIVE_CHECK_PID=
FM_ACTIVE_CHECK_PGID=
FM_CHECK_OUTPUT=
FM_CHECK_RESULT=
FM_CHECK_SIGNAL_PENDING=

fm_check_output_cleanup() {
  [ -z "$FM_CHECK_OUTPUT" ] || rm -f -- "$FM_CHECK_OUTPUT"
  FM_CHECK_OUTPUT=
}

fm_active_check_stop() {
  local pid=${FM_ACTIVE_CHECK_PID:-} pgid=${FM_ACTIVE_CHECK_PGID:-} i
  [ -n "$pid" ] || [ -n "$pgid" ] || return 0
  [ -z "$pgid" ] || kill -TERM -- "-$pgid" 2>/dev/null || true
  [ -z "$pid" ] || kill -TERM "$pid" 2>/dev/null || true
  i=0
  while [ -n "$pgid" ] && kill -0 -- "-$pgid" 2>/dev/null && [ "$i" -lt 20 ]; do
    sleep 0.01
    i=$((i + 1))
  done
  [ -z "$pgid" ] || kill -KILL -- "-$pgid" 2>/dev/null || true
  [ -z "$pid" ] || kill -KILL "$pid" 2>/dev/null || true
  [ -z "$pid" ] || wait "$pid" 2>/dev/null || true
  i=0
  while [ -n "$pgid" ] && kill -0 -- "-$pgid" 2>/dev/null && [ "$i" -lt 100 ]; do
    sleep 0.01
    i=$((i + 1))
  done
  if [ -n "$pgid" ] && kill -0 -- "-$pgid" 2>/dev/null; then
    return 1
  fi
  FM_ACTIVE_CHECK_PID=
  FM_ACTIVE_CHECK_PGID=
}

run_check_capture() {
  local pgid
  fm_check_output_cleanup
  FM_CHECK_RESULT=
  FM_CHECK_OUTPUT=$(mktemp "$STATE/.fm-check-output.XXXXXX") || return 1
  chmod 0600 "$FM_CHECK_OUTPUT" || { fm_check_output_cleanup; return 1; }
  FM_CHECK_SIGNAL_PENDING=
  trap 'FM_CHECK_SIGNAL_PENDING=1' HUP INT TERM
  set -m
  ( FM_CHECK_OWNED_GROUP=1 run_check_process "$@" ) > "$FM_CHECK_OUTPUT" 2>/dev/null &
  FM_ACTIVE_CHECK_PID=$!
  FM_ACTIVE_CHECK_PGID=$FM_ACTIVE_CHECK_PID
  set +m
  pgid=$(ps -o pgid= -p "$FM_ACTIVE_CHECK_PID" 2>/dev/null | tr -d '[:space:]')
  trap 'exit 1' HUP INT TERM
  if [ -n "$pgid" ] && [ "$pgid" != "$FM_ACTIVE_CHECK_PGID" ]; then
    fm_active_check_stop || true
    fm_check_output_cleanup
    return 1
  fi
  [ -z "$FM_CHECK_SIGNAL_PENDING" ] || exit 1
  wait "$FM_ACTIVE_CHECK_PID" 2>/dev/null || true
  FM_ACTIVE_CHECK_PID=
  fm_active_check_stop || return 1
  FM_CHECK_RESULT=$(cat "$FM_CHECK_OUTPUT" 2>/dev/null || true)
  fm_check_output_cleanup
}

# Surfaced-marker bookkeeping for the heartbeat backstop is owned by
# fm-push-transition-lib.sh because push and poll paths must write one format.
# Mark every current captain-relevant status as surfaced. Called after the
# heartbeat backstop enqueues its wake, so the same statuses are not re-surfaced
# by the next heartbeat.
mark_all_captain_relevant_surfaced() {
  local f task last
  while IFS=$(printf '\t') read -r f task last; do
    [ -n "$f" ] || continue
    printf '%s' "$last" > "$(_hb_surfaced_path "$task")"
  done < <(scan_captain_relevant_statuses "$STATE")
}

# Cheap heartbeat fleet-scan (the always-on twin of the daemon's catch-all). 0 if
# any captain-relevant status has NOT already been surfaced to firstmate (its
# content differs from the .hb-surfaced-<task> marker). Pure detect, no side
# effects: the caller enqueues first, then marks surfaced. Because every
# captain-relevant signal/stale already marks itself surfaced when it wakes
# firstmate, this normally finds nothing and the heartbeat is absorbed; it
# surfaces only a captain-relevant status the per-wake path absorbed by mistake -
# the fail-safe backstop.
heartbeat_scan_finds_actionable() {
  local f task last surfaced
  while IFS=$(printf '\t') read -r f task last; do
    [ -n "$f" ] || continue
    surfaced=$(cat "$(_hb_surfaced_path "$task")" 2>/dev/null || true)
    [ "$surfaced" = "$last" ] && continue
    return 0
  done < <(scan_captain_relevant_statuses "$STATE")
  return 1
}

# event_wait_or_sleep: the terminal wait of each supervision cycle. For a home
# with push-capable windows (herdr), it replaces the blind `sleep POLL` with a
# bounded wait on the backend's native transition stream, so a crew going
# `blocked` wakes the supervisor sub-second instead of after the stale-pane
# wedge timer. For every other home - no push-capable window, backend not
# capable, or the event path proven unreliable this process - it sleeps POLL,
# byte-for-byte today's behavior. The poll loop above still runs every cycle, so
# this only ever SHORTENS latency; it can never drop an escalation (the poll
# loop is the permanent fail-closed backstop). This preserves the single live
# supervision cycle: the reader is a short-lived subprocess of THIS watcher, not
# a second watcher, so every guard/beacon/arm/turn-end mechanism is unchanged.
event_wait_or_sleep() {
  local w b session first_backend="" first_session="" rec rc
  local windows=()
  while IFS= read -r w; do
    b=$(window_backend "$w")
    fm_backend_has_push "$b" || continue
    # Secondmate endpoints are supervised via status writes, not pane/agent
    # state (an idle or blocked secondmate agent pane is healthy by design), so
    # they are excluded from the fast escalation exactly as the stale loop skips
    # them.
    [ "$(window_kind "$w")" = secondmate ] && continue
    session=${w%%:*}
    if [ -z "$first_backend" ]; then first_backend=$b; first_session=$session; fi
    # One socket connection covers one backend+session; a home normally has a
    # single herdr session. A window in a different backend/session stays on the
    # poll path this cycle.
    if [ "$b" != "$first_backend" ] || [ "$session" != "$first_session" ]; then
      continue
    fi
    windows+=("$w")
  done < <(recorded_windows)

  if [ "${#windows[@]}" -eq 0 ]; then
    sleep "$POLL"
    return
  fi

  # Memoized capability probe (fm_backend_events_capable runs a heavy schema
  # read); re-probed only when the backend/session key changes.
  if [ "$_event_cap_key" != "$first_backend:$first_session" ]; then
    _event_cap_key="$first_backend:$first_session"
    if fm_backend_events_capable "$first_backend" "$first_session"; then
      _event_cap_ok=1
    else
      _event_cap_ok=0
    fi
    _event_cap_fails=0
  fi
  if [ "$_event_cap_ok" != 1 ]; then
    sleep "$POLL"
    return
  fi

  rec=$(FM_BACKEND_EVENTS_CAPABILITY_CONFIRMED=1 fm_backend_wait_transition "$first_backend" "$first_session" "$POLL" "$STATE" "${windows[@]}")
  rc=$?
  case "$rc" in
    0)
      _event_cap_fails=0
      handle_push_transition "$first_backend" "$first_session" "$rec"
      ;;
    2)
      # Event path unusable this cycle (connect/subscribe failure). Sleep the
      # budget and count toward the runtime-disable threshold; past it, drop to
      # pure polling for the rest of this watcher process.
      _event_cap_fails=$((_event_cap_fails + 1))
      [ "$_event_cap_fails" -ge "$EVENT_CAP_FAIL_MAX" ] && _event_cap_ok=0
      sleep "$POLL"
      ;;
    *)
      # 1: a clean full-budget wait with no actionable edge - the reader already
      # blocked ~POLL, so just continue; the next cycle re-scans.
      _event_cap_fails=0
      ;;
  esac
}

# --- Main entry: the runtime below runs only when this file is executed as a
# script. When sourced (unit tests loading the functions above), return here
# before acquiring the singleton lock or entering the blocking loop.
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  return 0
fi

# Before acquiring the watcher lock or enumerating any runnable check, replace
# or quarantine checks created by older versions. The migration compares bytes
# and reads data only; it never invokes legacy check files through Bash.
"$SCRIPT_DIR/fm-pr-check-migrate.sh" --checks-safe || {
  echo "watcher: PR check migration blocked; refusing to execute state checks" >&2
  exit 1
}

if ! fm_lock_try_acquire "$WATCH_LOCK"; then
  BEAT="$STATE/.last-watcher-beat"
  if [ -n "${FM_LOCK_HELD_PID:-}" ]; then
    if [ -e "$BEAT" ]; then
      beat_age=$(fm_path_age "$BEAT")
      if [ "$beat_age" -ge "$WATCHER_STALE_GRACE" ]; then
        echo "watcher: lock held by live pid $FM_LOCK_HELD_PID but heartbeat is stale for ${beat_age}s (>${WATCHER_STALE_GRACE}s); inspect or stop that watcher before re-arming." >&2
        exit 1
      fi
    elif [ "$(fm_path_age "$WATCH_LOCK")" -ge "$WATCHER_STALE_GRACE" ]; then
      echo "watcher: lock held by live pid $FM_LOCK_HELD_PID but no heartbeat exists; inspect or stop that watcher before re-arming." >&2
      exit 1
    fi
    echo "watcher: already running pid $FM_LOCK_HELD_PID"
  else
    echo "watcher: already running"
  fi
  exit 0
fi
WATCHER_RECOVERY_PENDING=0
if [ -n "${FM_LOCK_RECOVERED_PID:-}" ]; then
  WATCHER_RECOVERY_PENDING=1
fi
if [ "${FM_WATCH_HANDLING_SUCCESSOR:-0}" != 1 ]; then
  if ! fm_recovery_marker_reopen_announced "$WATCHER_DOWNTIME_MARKER"; then
    echo "watcher: recovery state could not be reopened safely; retaining stale lock evidence" >&2
    exit 1
  fi
fi
if ! fm_recovery_marker_arm_check "$WATCHER_DOWNTIME_MARKER"; then
  echo "watcher: recovery state could not be consumed safely; retaining stale lock evidence" >&2
  exit 1
fi
if [ "${FM_WATCH_HANDLING_SUCCESSOR:-0}" = 1 ]; then
  WATCHER_RECOVERY_PENDING=0
elif [ "$FM_RECOVERY_MARKER_ACTION" = recover ]; then
  WATCHER_RECOVERY_PENDING=1
fi
watcher_cleanup() {
  local cleanup_status=0 owns_lock=0 transition=release-lock
  if [ "$(cat "$WATCH_LOCK/pid" 2>/dev/null || true)" = "${WATCHER_PID:-}" ]; then
    owns_lock=1
    if [ "${WATCHER_RECOVERY_PENDING:-0}" -eq 1 ] \
      && [ "${FM_WATCH_DELIVERED_REASON:-}" = "check: rearm-resurface" ]; then
      transition=release-lock-existing
    fi
  fi
  fm_active_check_stop || cleanup_status=1
  fm_check_output_cleanup
  fm_custom_check_snapshot_cleanup
  if [ "$owns_lock" -eq 1 ] \
    && ! fm_recovery_transition "$WATCHER_DOWNTIME_MARKER" "$transition" "$WATCH_LOCK" downtime; then
    echo "watcher: recovery state could not be persisted; retaining stale lock evidence" >&2
    cleanup_status=1
  fi
  return "$cleanup_status"
}
trap watcher_cleanup EXIT
trap 'exit 1' HUP INT TERM
# This watcher's own pid, as recorded in the lock by fm_lock_claim (which writes
# ${BASHPID:-$$} from this same main shell). Read directly, never via a command
# substitution, so it matches the stored holder pid for the self-eviction check.
WATCHER_PID=${BASHPID:-$$}
printf '%s\n' "$FM_HOME" > "$WATCH_LOCK/fm-home" || true
printf '%s\n' "$WATCH_PATH" > "$WATCH_LOCK/watcher-path" || true
# shellcheck disable=SC2034 # Consumed by wake() in the separately linted transition owner.
FM_WATCH_DELIVERY_PID=$WATCHER_PID
FM_WATCH_DELIVERY_IDENTITY=$(fm_pid_identity "$WATCHER_PID" 2>/dev/null || true)
printf '%s\n' "$FM_WATCH_DELIVERY_IDENTITY" > "$WATCH_LOCK/pid-identity" 2>/dev/null || true

[ -e "$STATE/.last-heartbeat" ] || touch "$STATE/.last-heartbeat"

# A merged poll may have queued its terminal wake and then lost the process
# between receipt publication and fixed-path removal.
# Finish only identity-bound retirement receipts before any check can run.
if ! fm_pr_poll_retirement_recover_all "$STATE" "$SCRIPT_DIR/fm-pr-poll.sh"; then
  reason="check: rejected unauthenticated PR poll retirement receipts:$FM_PR_POLL_RETIREMENT_REJECTED"
  fm_wake_append check pr-poll-retirement "$reason" || exit 1
  touch "$STATE/.last-check"
  wake "$reason"
fi

resurface_after_downtime() {
  # Handling successors already have a predecessor-delivered wake on the way.
  # Re-announcing from this cycle is what turned a lost handshake into an
  # unbounded recovery loop; stay in the poll loop and supervise instead.
  if [ "${FM_WATCH_HANDLING_SUCCESSOR:-0}" = 1 ]; then
    return 0
  fi
  if [ "$WATCHER_RECOVERY_PENDING" -ne 1 ]; then
    if ! fm_recovery_marker_arm_check "$WATCHER_DOWNTIME_MARKER"; then
      echo "watcher: recovery state could not be consumed safely" >&2
      exit 1
    fi
    [ "$FM_RECOVERY_MARKER_ACTION" = recover ] || return 0
  fi
  wake "check: rearm-resurface"
}

while :; do
  # Self-eviction: if the singleton lock no longer names this process, a second
  # watcher has taken over (e.g. a transient duplicate from a racy arm). Stand
  # down so the rightful singleton continues alone. The EXIT trap's release
  # no-ops because the lock pid is not ours, so the survivor's lock is untouched.
  # This makes any duplicate self-resolve within one poll instead of persisting
  # and doubling every wake.
  if [ "$(cat "$WATCH_LOCK/pid" 2>/dev/null || true)" != "$WATCHER_PID" ]; then
    exit 0
  fi

  # Liveness beacon for fm-guard.sh: a fresh mtime here means a watcher is
  # alive. Supervision scripts warn when this goes stale with tasks in flight.
  touch "$STATE/.last-watcher-beat"

  # Parent-owned secondmate pending-reply reconciliation: resolve correlated
  # parent reports, observe backend busy/idle turn completion, send one recovery
  # repost after grace, and escalate once if the recovery turn is also missed.
  # No conversation scraping; unresolved records are never silently expired.
  fm_pending_reply_tick "$STATE" || true

  # A live secondmate endpoint does not prove that its own wake loop is alive.
  # Observe the foreign queue before the rest of this cycle so an aged row wakes
  # the parent without consuming or rewriting the receiving home's record.
  secondmate_wake_stall_tick || {
    echo "watcher: secondmate wake-loop observation failed" >&2
    exit 1
  }

  # Process-to-event liveness repair. This never discovers a result by polling:
  # each registered source has its own child blocking on that source, and this
  # only republishes results already captured durably and restarts a source
  # whose owner is gone. It is a no-op with nothing registered.
  if [ -d "$STATE/procevent" ]; then
    FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-procevent.sh" reconcile >/dev/null 2>&1 || true
  fi
  # Then deliver any queued-but-unsurfaced result, including one a runner
  # published while this watcher was between cycles.
  procevent_surface_queued

  # A process-event result carries richer adapter-owned wake context than the
  # generic recovery reason, so give that owner first refusal.
  resurface_after_downtime

  # The existing poll loop also owns the bounded inactive-outcome cadence.
  # This is mechanical and silent unless a durable terminal-outcome obligation
  # was created, so quiet cycles never wake firstmate or consume model tokens.
  inactive_out=
  if inactive_out=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
    "$SCRIPT_DIR/fm-inactive-reconcile.sh" scan 2>/dev/null); then
    if [ -n "$inactive_out" ]; then
      wake "check: inactive-outcome"
    fi
  else
    triage_log "inactive-outcome reconciliation unavailable"
  fi

  # Slow per-task checks (firstmate writes these, e.g. a merged-PR poll).
  # Time-based via .last-check mtime so the cadence survives watcher restarts.
  # Evaluated BEFORE the signal scan: wake() exits the cycle, so a check placed
  # after the signal scan would be starved whenever a chatty sibling crewmate
  # keeps producing signals - the slow poll (e.g. merge detection) would then
  # never run until the fleet went quiet. Checks are due only every
  # CHECK_INTERVAL, so most cycles skip this block and fall straight through.
  if [ "$(age_of "$STATE/.last-check")" -ge "$CHECK_INTERVAL" ]; then
    rejected_checks=
    unverifiable_polls=
    for c in "$STATE"/*.check.sh; do
      [ -e "$c" ] || continue
      is_pr_poll=0
      if [ "$(basename "$c")" = x-watch.check.sh ]; then
        if fmx_poll_shim_valid "$c" "$FM_HOME" "$FM_ROOT" \
          && [ -f "$FM_ROOT/bin/fm-x-poll.sh" ] && [ ! -L "$FM_ROOT/bin/fm-x-poll.sh" ]; then
          FM_HOME="$FM_HOME" run_check_capture "$FM_ROOT/bin/fm-x-poll.sh" || exit 1
          out=$FM_CHECK_RESULT
        else
          rejected_checks="$rejected_checks $c"
          continue
        fi
      else
        id=$(basename "$c" .check.sh)
        if fm_pr_poll_snapshot_capture "$STATE" "$id" "$SCRIPT_DIR/fm-pr-poll.sh"; then
          is_pr_poll=1
          provider=$FM_PR_POLL_SNAPSHOT_PROVIDER
          url=$FM_PR_POLL_SNAPSHOT_URL
          host=$FM_PR_POLL_SNAPSHOT_HOST
          path=$FM_PR_POLL_SNAPSHOT_PATH
          number=$FM_PR_POLL_SNAPSHOT_NUMBER
          run_check_capture "$SCRIPT_DIR/fm-pr-poll.sh" --validated \
            "$provider" "$url" "$host" "$path" "$number" || exit 1
          out=$FM_CHECK_RESULT
        elif fm_custom_check_snapshot_prepare "$STATE" "$id"; then
          custom_snapshot=$FM_CUSTOM_CHECK_SNAPSHOT
          run_check_capture "$custom_snapshot" || exit 1
          out=$FM_CHECK_RESULT
          fm_custom_check_snapshot_cleanup
        else
          fm_custom_check_snapshot_cleanup
          # A file whose bytes are the canonical merge poll is not an
          # unauthenticated check someone dropped in state/: it is a poll this
          # home armed whose binding no longer verifies. Report that separately
          # so the operator repairs the binding instead of the check file's
          # mode, which the owner path deliberately publishes as 0600 because
          # the watcher never executes this file.
          if cmp -s "$SCRIPT_DIR/fm-pr-poll.sh" "$c"; then
            unverifiable_polls="$unverifiable_polls $c"
          else
            rejected_checks="$rejected_checks $c"
          fi
          continue
        fi
      fi
      if [ -n "$out" ]; then
        reason="check: $c: $out"
        fm_wake_append check "$c" "$reason" || exit 1
        if [ "$is_pr_poll" -eq 1 ] && [ "$out" = merged ]; then
          if fm_pr_poll_retirement_publish "$STATE" "$id" "$SCRIPT_DIR/fm-pr-poll.sh" "$out"; then
            fm_pr_poll_retirement_recover_one "$STATE" "$id" "$SCRIPT_DIR/fm-pr-poll.sh" \
              || triage_log "merged PR poll retirement remains recoverable for $id"
          else
            triage_log "merged PR poll retirement deferred because its canonical snapshot changed for $id"
          fi
        fi
        touch "$STATE/.last-check"
        wake "$reason"
      fi
    done
    # Both buckets reach the durable queue before either wakes, because wake()
    # exits the cycle and a wake that never queued would be lost.
    unverifiable_reason=
    if [ -n "$unverifiable_polls" ]; then
      unverifiable_reason="check: unverifiable PR merge polls:$unverifiable_polls"
      fm_wake_append check unverifiable-pr-polls "$unverifiable_reason" || exit 1
    fi
    if [ -n "$rejected_checks" ]; then
      reason="check: rejected unauthenticated state checks:$rejected_checks"
      fm_wake_append check unauthenticated-state-checks "$reason" || exit 1
      touch "$STATE/.last-check"
      wake "$reason"
    fi
    if [ -n "$unverifiable_reason" ]; then
      touch "$STATE/.last-check"
      wake "$unverifiable_reason"
    fi
    touch "$STATE/.last-check"
  fi

  # On the first changed signal, linger one grace period and re-scan before
  # classifying: a crewmate's final status write and the same turn's turn-end
  # hook land seconds apart, and reporting them as separate actionable wakes
  # costs a full firstmate turn each. The re-scan also picks up a newer
  # signature for an already-pending file (last write wins below).
  pending=$(scan_signals)
  if [ -n "$pending" ]; then
    sleep "$SIGNAL_GRACE"
    pending=$(printf '%s\n%s' "$pending" "$(scan_signals)")
    files=""
    while IFS=$(printf '\t') read -r sf sig f; do
      [ -n "$sf" ] || continue
      case " $files " in *" $f "*) ;; *) files="$files $f" ;; esac
    done <<EOF
$pending
EOF
    reason="signal:$files"
    # Triage: a signal is ACTIONABLE when any of these holds (cheapest first):
    #   - the away-mode daemon owns triage (afk) and wants every wake;
    #   - any status file carries a captain-relevant verb;
    #   - or it is a no-verb wake (a bare turn-end, a working: note) whose crew is
    #     NOT provably working - the crew stopped its turn with no actively-running
    #     pipeline and no busy pane, so it may be done (even via an interactive menu
    #     that wrote no done: status), waiting on a decision, or wedged. Absorbing
    #     such a turn-end is exactly the swallowed-finish this change guards against.
    # Actionable -> enqueue, advance .seen-* markers, exit. Benign (a no-verb wake
    # whose crew IS provably working) in always-on mode -> advance the markers so it
    # will not re-fire, log, and keep blocking without enqueuing. The provably-working
    # check is the only costly one (it may run a bounded no-mistakes call), so the ||
    # ordering evaluates it ONLY for a non-afk, no-captain-verb signal.
    # shellcheck disable=SC2086  # $files is a space-separated status-path list (ids carry no spaces)
    if afk_present || signal_reason_is_actionable $files || ! signal_crew_provably_working $files; then
      while IFS=$(printf '\t') read -r sf sig f; do
        [ -n "$sf" ] || continue
        fm_wake_append signal "$(basename "$f")" "$reason" || exit 1
      done <<EOF
$pending
EOF
      while IFS=$(printf '\t') read -r sf sig f; do
        [ -n "$sf" ] || continue
        printf '%s' "$sig" > "$sf"
        mark_surfaced "$f"
      done <<EOF
$pending
EOF
      wake "$reason"
    else
      while IFS=$(printf '\t') read -r sf sig f; do
        [ -n "$sf" ] || continue
        printf '%s' "$sig" > "$sf"
      done <<EOF
$pending
EOF
      triage_log "absorbed benign $reason"
    fi
  fi

  # Layer 1 backbone: pane staleness. Two consecutive identical hashes with no busy
  # signature means the crewmate finished, is waiting, or is wedged. Each distinct
  # stale hash is surfaced, absorbed, or timed toward escalation once (.stale-*
  # remembers the hash already classified).
  while IFS= read -r w; do
    kind=$(window_kind "$w")
    task=$(window_to_task "$w" "$STATE")
    key=$(window_key "$w")
    last=$(last_status_line "$STATE/$task.status")
    if ! status_is_paused_or_captain_held "$last" && [ -e "$STATE/.paused-$key" ]; then
      clear_pause_tracking "$key"
    fi
    # An idle secondmate endpoint is healthy by design, so a mate is admitted to
    # the pane-stale path ONLY to serve a declared wait's bounded re-surface -
    # the same declarations pause_state_class reconciles below, which is why this
    # gate reads the shared predicate rather than the pause verb alone. Narrowing
    # it to `paused` would leave a mate's captain hold rotting invisibly: the
    # clear above already spares its pause tracking, but nothing would ever
    # re-surface it.
    if [ "$kind" = secondmate ] && ! status_is_paused_or_captain_held "$last"; then
      continue
    fi
    tail40=$(fm_backend_capture "$(window_backend "$w")" "$w" 40 "$(window_label "$w")" 2>/dev/null) || continue
    h=$(printf '%s' "$tail40" | hash_pane)
    hf="$STATE/.hash-$key"
    cf="$STATE/.count-$key"
    sf="$STATE/.stale-$key"
    ssf="$STATE/.stale-since-$key"
    ewf="$STATE/.wedge-escalations-$key"
    pf="$STATE/.paused-$key"   # flag: this key's stale is using the bounded pause cadence
    prev=$(cat "$hf" 2>/dev/null || true)
    # Busy match: a backend's native semantic state when available (herdr), else
    # the last 6 non-blank lines only (the TUI footer area, where every verified
    # harness renders its busy indicator) so busy-looking strings in displayed
    # content cannot suppress stale detection. Read once per window per poll and
    # reused below so a busy verdict is consistent within one cycle.
    if window_is_busy "$w" "$tail40"; then busy_now=0; else busy_now=1; fi
    if [ "$h" = "$prev" ]; then
      n=$(( $(cat "$cf" 2>/dev/null || echo 0) + 1 ))
      echo "$n" > "$cf"
      if [ "$n" -ge 2 ] && [ "$busy_now" -ne 0 ]; then
        # The pane is idle/stale at hash $h. Triage decides whether this wakes
        # firstmate. Detection itself is unchanged from above.
        if [ "$kind" = secondmate ]; then
          case "$(pause_state_class "$w" "$task")" in
            paused) handle_paused_stale "$w" "$task" "$h" ;;
            *)      clear_pause_tracking "$key" ;;
          esac
        elif afk_present; then
          # Daemon owns triage: one-shot per distinct stale hash, as before.
          if [ "$(cat "$sf" 2>/dev/null || true)" != "$h" ]; then
            fm_wake_append stale "$w" "stale: $w" || exit 1
            printf '%s' "$h" > "$sf"
            wake "stale: $w"
          fi
        elif stale_is_terminal "$w" "$STATE"; then
          # The log's last line is captain-relevant - but that alone is not
          # proof the crew is actually done: a crew's own status log gets no
          # new entry once firstmate hands it to a no-mistakes validation
          # (AGENTS.md's sparse status-reporting contract), so the log can
          # keep showing a "done:"/needs-decision/blocked leftover from
          # BEFORE that validation started for the run's entire (possibly
          # many-minutes) duration, while stale_is_terminal - which has no
          # run-step awareness - keeps reporting it as still-current on every
          # poll. Root cause of the 2026-07 herdr false-surface incidents: a
          # validating crew was surfaced as stale every few minutes despite an
          # actively-running pipeline, purely because of this stale leftover
          # line. On a NEW hash, give an active run/busy pane (the same
          # authoritative source fm-crew-state.sh itself already prioritizes
          # over the log) a chance to override before trusting the log.
          if [ "$(cat "$sf" 2>/dev/null || true)" != "$h" ]; then
            if crew_is_provably_working "$(window_to_task "$w" "$STATE")"; then
              printf '%s' "$h" > "$sf"
              date +%s > "$ssf"
              clear_defer_tracking "$key"
              triage_log "absorbed stale (provably working, overriding a stale captain-relevant status): $w"
            else
              fm_wake_append stale "$w" "stale: $w" || exit 1
              printf '%s' "$h" > "$sf"
              rm -f "$ssf"
              clear_defer_tracking "$key"
              mark_surfaced "$STATE/$(window_to_task "$w" "$STATE").status"
              wake "stale: $w"
            fi
          elif [ -e "$ssf" ]; then
            # This exact hash was already overridden as provably-working (a
            # wedge timer is running for it) - keep treating it that way
            # without re-reading the crew state every poll, and without
            # letting the still-captain-relevant log line re-surface it.
            wedge_timer_check "$w" "$ssf" "stale (overridden terminal status)" "$ewf" "$task"
          fi
          # else: already surfaced as genuinely terminal on a prior poll of
          # this same hash - nothing left to do (matches the original,
          # unmodified terminal-status behavior).
        else
          # Non-terminal stale: a crew gone quiet without a captain-relevant status.
          # Decided once per distinct stale hash (the costly state reads run only
          # on first sight, never every poll) via pause_state_class, which returns:
          #   - working: an actively-running pipeline legitimately sits on a static
          #     pane (e.g. waiting on CI), so absorb and start the wedge timer so a
          #     genuinely frozen run still escalates past STALE_ESCALATE_SECS;
          #   - paused: a declared wait pause_state_class admits (its header owns which
          #     liveness evidence each kind of crew must supply), so absorb on the long
          #     PAUSE_RESURFACE_SECS cadence instead of wedge-escalating;
          #   - none: no running pipeline, no exact busy verdict, no admitted declared wait.
          #     Surface immediately so firstmate inspects the inconclusive state
          #     (it may be done via an interactive menu that wrote no done: status,
          #     waiting on a decision, or wedged) instead of leaving the finish to
          #     wait out the timer.
          if [ "$(cat "$sf" 2>/dev/null || true)" != "$h" ]; then
            task=$(window_to_task "$w" "$STATE")
            case "$(pause_state_class "$w" "$task")" in
              working)
                clear_pause_tracking "$key"
                printf '%s' "$h" > "$sf"
                date +%s > "$ssf"
                triage_log "absorbed non-terminal stale (provably working): $w"
                ;;
              paused)
                handle_paused_stale "$w" "$task" "$h"
                ;;
              *)
                surface_nonterminal_stale "$w" "$h"
                ;;
            esac
          else
            task=$(window_to_task "$w" "$STATE")
            if [ -e "$pf" ] || status_is_paused_or_captain_held "$(last_status_line "$STATE/$task.status")"; then
              case "$(pause_state_class "$w" "$task")" in
                paused)  handle_paused_stale "$w" "$task" "$h" ;;
                working) clear_pause_state "$key"
                         printf '%s' "$h" > "$sf"
                         wedge_timer_check "$w" "$ssf" "non-terminal stale (provably working after a declared pause)" "$ewf" "$task"
                         triage_log "absorbed non-terminal stale (provably working): $w" ;;
                *)       handle_paused_stale "$w" "$task" "$h" ;;
              esac
            else
              wedge_timer_check "$w" "$ssf" "non-terminal stale" "$ewf" "$task"
            fi
          fi
        fi
      else
        # Pane busy or not yet stably stale: reset pending escalation bookkeeping,
        # unless a genuinely busy pane has gone too long with no completed turn -
        # then route it through busy_turn_bound_check, which hands the crossed
        # bound to the same wedge timer unless the crew declared the wait itself.
        paused_bound=1
        if [ "$busy_now" -eq 0 ] && busy_turn_over_age "$task"; then
          busy_turn_bound_check "$w" "$task" "$h" "$ssf" "$ewf" && paused_bound=0
        else
          rm -f "$ssf" "$ewf"
          clear_defer_tracking "$key"
        fi
        # A busy pane normally means real work resumed, so stale pause bookkeeping
        # is cleared - but not in the same poll the declared-pause cadence just
        # recorded it, or the re-surface throttle it depends on would be erased and
        # the pause would re-surface every poll instead of once per long cadence.
        if [ "$paused_bound" -ne 0 ] && [ -e "$pf" ] && { [ "$n" -ge 2 ] || ! status_is_paused_or_captain_held "$(last_status_line "$STATE/$(window_to_task "$w" "$STATE").status")"; }; then
          clear_pause_tracking "$key"
        fi
      fi
    else
      printf '%s' "$h" > "$hf"
      echo 0 > "$cf"
      paused_bound=1
      if [ "$busy_now" -eq 0 ] && busy_turn_over_age "$task"; then
        busy_turn_bound_check "$w" "$task" "$h" "$ssf" "$ewf" && paused_bound=0
      else
        rm -f "$ssf" "$ewf"
        clear_defer_tracking "$key"
      fi
      task=$(window_to_task "$w" "$STATE")
      if ! afk_present && status_is_paused_or_captain_held "$(last_status_line "$STATE/$task.status")" && [ "$busy_now" -ne 0 ]; then
        case "$(pause_state_class "$w" "$task")" in
          paused) handle_paused_stale "$w" "$task" "$h" ;;
          *)      clear_pause_tracking "$key" ;;
        esac
      elif [ "$paused_bound" -ne 0 ] && [ -e "$pf" ]; then
        # Same rule as the stable-hash branch: never clear pause bookkeeping the
        # declared-pause cadence recorded on this very poll.
        clear_pause_tracking "$key"
      fi
    fi
  done < <(recorded_windows)

  # Heartbeat: the watcher runs a cheap fleet-scan at a regular cadence no matter
  # what. Time-based via .last-heartbeat mtime; interval doubles per consecutive
  # no-change heartbeat (idle fleet) up to HEARTBEAT_MAX, and resets on any
  # surfaced non-heartbeat wake.
  streak=$(cat "$STATE/.heartbeat-streak" 2>/dev/null || echo 0)
  [ "$streak" -gt 12 ] && streak=12
  hb=$(( HEARTBEAT * (1 << streak) ))
  [ "$hb" -gt "$HEARTBEAT_MAX" ] && hb=$HEARTBEAT_MAX
  if [ "$(age_of "$STATE/.last-heartbeat")" -ge "$hb" ]; then
    # Triage: in always-on mode a heartbeat is benign unless the cheap fleet-scan
    # turns up a captain-relevant status the per-wake path missed. Absorb the
    # no-change case (advance the schedule and back off exactly as wake() would,
    # without exiting); the away-mode daemon, when present, owns triage and wants
    # every heartbeat.
    if afk_present; then
      fm_wake_append heartbeat heartbeat heartbeat || exit 1
      touch "$STATE/.last-heartbeat"
      wake "heartbeat"
    elif heartbeat_scan_finds_actionable; then
      # Backstop: a captain-relevant status the per-wake path absorbed by mistake.
      # Enqueue first, then mark every captain-relevant status surfaced so the next
      # heartbeat does not re-fire them (enqueue-before-suppress preserved).
      fm_wake_append heartbeat heartbeat heartbeat || exit 1
      touch "$STATE/.last-heartbeat"
      mark_all_captain_relevant_surfaced
      wake "heartbeat"
    else
      touch "$STATE/.last-heartbeat"
      echo $(( $(cat "$STATE/.heartbeat-streak" 2>/dev/null || echo 0) + 1 )) > "$STATE/.heartbeat-streak"
      triage_log "absorbed heartbeat (no captain-relevant change)"
    fi
  fi

  # Terminal wait: a bounded native-event wait for push-capable homes (herdr),
  # else the blind poll sleep. See event_wait_or_sleep.
  event_wait_or_sleep
done
