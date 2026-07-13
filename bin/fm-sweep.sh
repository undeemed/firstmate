#!/usr/bin/env bash
# fm-sweep.sh - constant, safety-gated sweep/prune of THIS firstmate home's
# disposable 3rd mates (crewmates) and orphaned pool worktrees.
#
# The fleet is a strict three-tier hierarchy (AGENTS.md "Fleet hierarchy"):
# firstmate -> one persistent secondmate per project repo -> disposable 3rd mates
# (crewmates). 3rd mates are meant to be swept continuously: this script is the
# reaper. It runs from session start (bin/fm-session-start.sh, when the session
# holds the fleet lock) AND every supervision cycle on a bounded cadence
# (bin/fm-watch.sh), so each home - main firstmate and every secondmate - keeps
# its own children cleaned without a human ever closing a pane by hand.
#
# SCOPE: this home's own children only, never another home's.
#   - meta-tracked tasks: $FM_HOME/state/<id>.meta with kind=ship or kind=scout.
#     kind=secondmate is NEVER swept (secondmates are persistent by design).
#   - orphaned pool worktrees under $FM_HOME/projects/*.
# A secondmate home runs this exact script against its OWN home, so the same
# mechanism reaps a secondmate's 3rd mates too.
#
# SAFETY IS DELEGATED TO THE SINGLE OWNERS - this script reimplements no
# landed-work check:
#   - For each meta-tracked reap candidate it calls bin/fm-teardown.sh <id>
#     (NEVER --force). fm-teardown owns the full landed-work definition
#     (remote-reachable, merged-PR-head containment, content already in the
#     default branch, local-only merges, scout reports) and REFUSES anything
#     not landed. A refusal means "leave it, report why", never an obstacle to
#     work around. fm-teardown also closes the backend endpoint on success, so a
#     done+landed crew's bare-shell/agentless pane (e.g. a herdr pane left after
#     the agent /exited, which otherwise keeps tripping the watcher's stale
#     detection) is closed rather than left to churn.
#   - For orphaned pool worktrees it calls `treehouse prune --yes` per project
#     pool. treehouse prune is the single owner of pool landed-safety: it removes
#     a worktree only when treehouse manages it, no owner reservation or running
#     process is using it, it has no uncommitted changes, and its HEAD is already
#     merged into the default branch. That "no running process / no reservation"
#     gate is what makes it safe against a just-spawned crew and against a live
#     crew's worktree, and matches the brief's orphan definition exactly. It is
#     scoped per pool via the working directory; --all/--global is never used, so
#     a sibling home's pools are never touched. The firstmate repo's OWN pool
#     (FM_ROOT, where the primary itself and project-less firstmate-repo crews
#     live) is deliberately out of scope for this automated prune: meta-tracked
#     firstmate-repo crews are still reaped by the fm-teardown path above, and
#     leaving the primary's own pool to manual `treehouse prune` avoids ever
#     pruning the pool the running primary lives in.
#
# REAP GATE (cheap-first; fm-teardown is the final safety net either way):
#   1. dead endpoint (fm_backend_target_exists is false, or no target recorded)
#      -> candidate, but only on the SECOND consecutive dead probe. A single
#      failed probe is not a confident dead reading: fm_backend_target_exists
#      reports an unqueryable pane (herdr server down, an unauthenticated cmux
#      socket, a transient CLI error) as gone, so the first dead reading only
#      records state/<id>.sweep-dead and SKIPS the task this sweep. The task
#      becomes a candidate when that marker already existed, i.e. it was dead
#      on the previous sweep too - the same confident-dead bar the secondmate
#      liveness sweep requires. The marker is cleared whenever the endpoint is
#      observed alive, and fm-teardown removes it with the task's other state
#      files so it never leaks. A crashed/exited crew, whose lease would
#      otherwise leak, is still reaped - one sweep later.
#   2. else the endpoint is alive: read the crew's authoritative current state
#      (bin/fm-crew-state.sh). state == done -> candidate (idle-done: a merged
#      ship, a checks-passed PR that teardown will refuse until merged, or a
#      finished scout whose report exists). Any other alive state - working,
#      parked, blocked, failed, or unknown - is LEFT untouched. Leaving alive
#      non-done crews is what guarantees a live WORKING agent is never reaped and,
#      critically, that a just-spawned crew (alive, state unknown until it starts)
#      is never mistaken for an orphan.
#
# Before tearing down a candidate that still has a pending state/<id>.check.sh
# (e.g. firstmate's merged-PR poll), the sweep runs that check ONCE (bounded by
# FM_CHECK_TIMEOUT) and folds any output into the summary as a "check <id>: ..."
# line, so an externally-merged PR is surfaced before teardown removes the poll.
#
# PROPERTIES: lock-gated by its callers (session-start runs it only when it holds
# the fleet lock; the watcher is a per-home singleton), best-effort and non-fatal
# (one task's failure never aborts the sweep), idempotent, fast, and quiet when
# there is nothing to reap. When it does act it prints a bounded plain-text
# summary to stdout (checks/reaped/left-why/orphans); callers relay it
# (session-start as a SWEEP: digest line) or discard it (the watcher, for which
# reaping is silent maintenance). A best-effort concurrency guard makes
# overlapping runs a no-op.
#
# Usage: fm-sweep.sh
# Env:
#   FM_CREW_STATE_BIN   override the crew-state reader (tests stub it)
#   FM_SWEEP_MAX_LINES  cap the summary at N lines (default 40)
#   FM_SWEEP_PRUNE_ORPHANS=0  skip the treehouse-prune orphan pass
#   FM_CHECK_TIMEOUT    seconds allowed for a pre-teardown check.sh run (default 30)
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-lock-lib.sh
. "$SCRIPT_DIR/fm-lock-lib.sh"

CREW_STATE_BIN="${FM_CREW_STATE_BIN:-$SCRIPT_DIR/fm-crew-state.sh}"
TEARDOWN="$SCRIPT_DIR/fm-teardown.sh"
# Prefix the shared staleness-proof diagnostics (bin/fm-lock-lib.sh) so a
# sweep-lock message is recognizable.
FM_LOCK_LOG_PREFIX=fm-sweep
MAX_LINES=${FM_SWEEP_MAX_LINES:-40}
case "$MAX_LINES" in ''|*[!0-9]*) MAX_LINES=40 ;; esac
CHECK_TIMEOUT=${FM_CHECK_TIMEOUT:-30}
case "$CHECK_TIMEOUT" in ''|*[!0-9]*) CHECK_TIMEOUT=30 ;; esac
SWEEP_LOCK="$STATE/.sweep.lock"
SWEEP_LOCK_STALE_SECS=${FM_SWEEP_LOCK_STALE_SECS:-600}
case "$SWEEP_LOCK_STALE_SECS" in ''|*[!0-9]*) SWEEP_LOCK_STALE_SECS=600 ;; esac

# Best-effort concurrency guard: an mkdir lock so two overlapping sweeps (a
# manual run over a watcher-launched one, say) cannot race fm-teardown on the
# same task. A stale lock left by a killed sweep is reclaimed once it is provably
# abandoned (no live holder AND old enough), reusing the shared staleness proof.
# The lock directory itself is the existence/age-checked path: it is created
# atomically by the mkdir, so there is no window in which a killed sweep leaves
# a lock the proof cannot see.
acquire_sweep_lock() {
  mkdir "$SWEEP_LOCK" 2>/dev/null && return 0
  if fm_lock_is_provably_stale "$SWEEP_LOCK" "" "$SWEEP_LOCK_STALE_SECS"; then
    rm -rf "$SWEEP_LOCK" 2>/dev/null || true
    mkdir "$SWEEP_LOCK" 2>/dev/null && return 0
  fi
  return 1
}

# The crew's authoritative current-state token (the <X> in "state: <X> · ...").
crew_state_token() {  # <id>
  local id=$1 line
  line=$("$CREW_STATE_BIN" "$id" 2>/dev/null) || return 0
  case "$line" in state:*) ;; *) return 0 ;; esac
  line=${line#state: }
  printf '%s' "${line%% *}"
}

# Run a task's pending state/<id>.check.sh once, bounded, best-effort. Same
# contract and timeout ladder as the watcher's check pass (bin/fm-watch.sh
# run_check): output only when firstmate should wake.
run_task_check() {  # <check-script>
  local c=$1
  if command -v timeout >/dev/null 2>&1; then
    timeout "$CHECK_TIMEOUT" bash "$c" 2>/dev/null || true
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$CHECK_TIMEOUT" bash "$c" 2>/dev/null || true
  else
    # shellcheck disable=SC2016  # single quotes are deliberate: Perl expands its own variables.
    perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$CHECK_TIMEOUT" bash "$c" 2>/dev/null || true
  fi
}

CHECKS=()
REAPED=()
LEFT=()
ORPHANS=()

sweep_metas() {
  local meta id kind wt backend target state exists out reason
  local dead_marker chk chk_out
  [ -d "$STATE" ] || return 0
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    id=$(basename "$meta" .meta)
    kind=$(fm_meta_get "$meta" kind)
    [ -n "$kind" ] || kind=ship
    case "$kind" in
      ship|scout) ;;
      *) continue ;;   # secondmate (persistent) or any unknown kind: never swept
    esac
    # A well-formed task meta always records worktree= (fm-spawn writes it). A
    # meta without one is malformed, not a real disposable crew, so leave it for
    # firstmate to notice rather than reap it.
    wt=$(fm_meta_get "$meta" worktree)
    [ -n "$wt" ] || continue

    backend=$(fm_backend_of_meta "$meta")
    target=$(fm_backend_target_of_meta "$meta")

    # Cheap first: a gone endpoint is a candidate, but only on the SECOND
    # consecutive dead probe (see the REAP GATE header): a single failed probe
    # can be a transient backend outage, not a confident dead reading, so the
    # first one records state/<id>.sweep-dead and skips the task this sweep.
    # An alive observation clears the marker. Only for a still-alive endpoint
    # do we pay the crew-state read, and only to distinguish idle-done from
    # everything else. A live non-done crew (working, parked, blocked, failed,
    # or a just-spawned unknown) is always left.
    dead_marker="$STATE/$id.sweep-dead"
    exists=yes
    if [ -n "$target" ]; then
      fm_backend_target_exists "$backend" "$target" "fm-$id" 2>/dev/null || exists=no
    else
      exists=no
    fi
    if [ "$exists" = yes ]; then
      rm -f "$dead_marker" 2>/dev/null || true
      state=$(crew_state_token "$id")
      [ "$state" = "done" ] || continue
    elif [ ! -e "$dead_marker" ]; then
      touch "$dead_marker" 2>/dev/null || true
      continue
    fi

    # Surface a pending merge/check poll before teardown removes it: run the
    # task's check.sh once and fold any wake output into the summary.
    chk="$STATE/$id.check.sh"
    if [ -f "$chk" ]; then
      chk_out=$(run_task_check "$chk" | sed -n '1p')
      [ -n "$chk_out" ] && CHECKS+=("$id: $chk_out")
    fi

    if out=$("$TEARDOWN" "$id" 2>&1); then
      REAPED+=("$id ($kind)")
    else
      reason=$(printf '%s\n' "$out" | grep -m1 -E 'REFUSED|error:' 2>/dev/null | sed 's/^[[:space:]]*//' || true)
      [ -n "$reason" ] || reason="teardown declined"
      LEFT+=("$id: $reason")
    fi
  done
}

sweep_orphan_worktrees() {
  [ "${FM_SWEEP_PRUNE_ORPHANS:-1}" != 0 ] || return 0
  command -v treehouse >/dev/null 2>&1 || return 0
  [ -d "$PROJECTS" ] || return 0
  local proj name out summary
  for proj in "$PROJECTS"/*; do
    [ -d "$proj" ] || continue
    git -C "$proj" rev-parse --git-dir >/dev/null 2>&1 || continue
    name=$(basename "$proj")
    # treehouse prune owns pool landed-safety; --yes executes, scoped to THIS
    # pool via cwd (never --all/--global). Best-effort: a prune failure or a
    # non-treehouse-managed clone is a silent no-op.
    out=$( cd "$proj" && treehouse prune --yes 2>&1 ) || continue
    # Report only when it plainly reclaimed something: a past-tense action word
    # on a line that is not an idle answer ("nothing to prune", "nothing
    # removed", "0 removed"). The common no-op answer stays quiet.
    summary=$(printf '%s\n' "$out" \
      | grep -iE 'pruned|removed|reclaimed' \
      | grep -ivE '(^|[[:space:]])(nothing|none|no|0)([[:space:]]|$)' \
      | head -1 | sed 's/^[[:space:]]*//' || true)
    if [ -n "$summary" ]; then
      ORPHANS+=("$name: $summary")
    fi
  done
}

emit_summary() {
  local total=0 item printed=0
  total=$(( ${#CHECKS[@]} + ${#REAPED[@]} + ${#LEFT[@]} + ${#ORPHANS[@]} ))
  [ "$total" -gt 0 ] || return 0
  for item in "${CHECKS[@]:-}"; do
    [ -n "$item" ] || continue
    [ "$printed" -lt "$MAX_LINES" ] && printf 'check %s\n' "$item"
    printed=$((printed + 1))
  done
  for item in "${REAPED[@]:-}"; do
    [ -n "$item" ] || continue
    [ "$printed" -lt "$MAX_LINES" ] && printf 'reaped %s\n' "$item"
    printed=$((printed + 1))
  done
  for item in "${LEFT[@]:-}"; do
    [ -n "$item" ] || continue
    [ "$printed" -lt "$MAX_LINES" ] && printf 'left %s\n' "$item"
    printed=$((printed + 1))
  done
  for item in "${ORPHANS[@]:-}"; do
    [ -n "$item" ] || continue
    [ "$printed" -lt "$MAX_LINES" ] && printf 'orphan worktrees %s\n' "$item"
    printed=$((printed + 1))
  done
  [ "$printed" -gt "$MAX_LINES" ] && printf '... (%s more not shown)\n' "$((printed - MAX_LINES))"
  return 0
}

acquire_sweep_lock || exit 0
trap 'rm -rf "$SWEEP_LOCK" 2>/dev/null || true' EXIT

sweep_metas
sweep_orphan_worktrees
emit_summary
exit 0
