#!/usr/bin/env bash
# Shared no-mistakes axi run attribution primitives.
#
# ONE owner for the branch+code-identity matching rule that decides whether a
# no-mistakes run belongs to a given worktree, used by fm-crew-state.sh
# (read-only current-state reporting) and fm-teardown.sh (pre-teardown run
# abort, see its "Fix 1" header comment). Getting this wrong in either
# direction is unsafe: a false negative hides a genuinely parked run, and a
# false positive lets teardown act on a run it does not own.
#
# Bounded call to `no-mistakes "$@"` in dir $1, timeout $2 seconds. The bounded
# form preserves stdout, stderr, and exit status; the checked form discards
# stderr, while fm_nm_run keeps the fail-open query contract for read-only callers.
fm_nm_run_bounded() {  # <dir> <timeout_secs> <args...>
  local dir=$1 timeout_secs=$2 have_timeout=none
  shift 2
  if command -v timeout >/dev/null 2>&1; then have_timeout=timeout
  elif command -v gtimeout >/dev/null 2>&1; then have_timeout=gtimeout
  elif command -v perl >/dev/null 2>&1; then have_timeout=perl
  fi
  case "$have_timeout" in
    timeout)  ( cd "$dir" && timeout "$timeout_secs" no-mistakes "$@" ) ;;
    gtimeout) ( cd "$dir" && gtimeout "$timeout_secs" no-mistakes "$@" ) ;;
    perl)     ( cd "$dir" && perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$timeout_secs" no-mistakes "$@" ) ;;
    *)        return 1 ;;
  esac
}

fm_nm_run_checked() {  # <dir> <timeout_secs> <args...>
  fm_nm_run_bounded "$@" 2>/dev/null
}

fm_nm_run() {  # <dir> <timeout_secs> <args...>
  fm_nm_run_checked "$@" || true
}

fm_nm_trim() {
  local s=${1:-}
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

fm_nm_strip_quotes() {
  local s
  s=$(fm_nm_trim "${1:-}")
  case "$s" in
    \"*\") s=${s#\"}; s=${s%\"} ;;
  esac
  fm_nm_trim "$s"
}

# Print "<step> <seconds>" for the first ACTIVE step in captured `axi status`
# output $1 and how long ago that step last recorded doing something; 1 when the
# output reports no such step. Only an active_steps row carries a quoted
# "<duration> ago: <what it did>" activity, so a row that matches IS an active
# step, while a completed-steps row, a renamed or dropped column, and an
# unparseable age all stop matching and report nothing. The duration is Go's own
# h-m-s form, its fraction truncated because callers compare against
# whole-second bounds; a sub-second age renders in ms/us/ns units instead, which
# this expression deliberately does not match, so it reads as no evidence - the
# escalate-safe direction.
fm_nm_active_step_activity() {  # <toon-output>
  local line
  local re='^[[:space:]]*([A-Za-z_-]+),.*"(([0-9]+)h)?(([0-9]+)m)?([0-9]+)(\.[0-9]+)?s ago:'
  while IFS= read -r line; do
    [[ $line =~ $re ]] || continue
    printf '%s %s' "${BASH_REMATCH[1]}" \
      $(( 10#0${BASH_REMATCH[3]} * 3600 + 10#0${BASH_REMATCH[5]} * 60 + 10#${BASH_REMATCH[6]} ))
    return 0
  done <<< "${1:-}"
  return 1
}

# Scalar value of a TOON key in captured `axi status` output $1.
fm_nm_field() {  # <toon-output> <key>
  printf '%s\n' "$1" | sed -n "s/^[[:space:]]*$2:[[:space:]]*\(.*\)/\1/p" | head -1
}

# The code-identity binding between worktree $1 and run head $2, as exactly one
# of four words on stdout. This is the ONE owner of the rule; every caller reads
# these verdicts instead of re-deriving them:
#   absent       - no head reported (or the worktree has no HEAD): nothing to bind.
#   match        - equal commits (short or full SHA), or the worktree HEAD is an
#                  ancestor of the run head, which is how pipeline fix commits
#                  advance the run tip past local HEAD on the same history.
#   stale        - the run head IS known here but is a strict ancestor of the
#                  worktree HEAD or diverged from it: local work advanced outside
#                  the run, or the branch tip was rewritten. Proof of NOT current.
#   undetermined - the run head is a real value this repository has never seen,
#                  so neither answer can be proven. no-mistakes builds its
#                  pipeline commits in its own managed clone
#                  (~/.no-mistakes/repos/<repo>.git), so from the first fix or
#                  document commit until the push step pushes it and this repo
#                  fetches it back, a live run's head is routinely absent here.
#                  It is NOT evidence that the run belongs to someone else.
fm_nm_head_binding() {  # <worktree> <run_head>
  local wt=$1 run_head=$2 local_full run_full
  [ -n "$run_head" ] || { printf 'absent'; return 0; }
  local_full=$(git -C "$wt" rev-parse HEAD 2>/dev/null) || { printf 'absent'; return 0; }
  run_full=$(git -C "$wt" rev-parse --verify "${run_head}^{commit}" 2>/dev/null) \
    || { printf 'undetermined'; return 0; }
  if [ "$run_full" = "$local_full" ] \
    || git -C "$wt" merge-base --is-ancestor "$local_full" "$run_full" 2>/dev/null; then
    printf 'match'
  else
    printf 'stale'
  fi
}

# 0 only when run head $2 provably matches worktree $1's code identity. An
# undetermined binding is NOT a match: a caller that must tell "provably not
# current" apart from "cannot tell" reads fm_nm_head_binding instead.
fm_nm_head_matches_worktree() {  # <worktree> <run_head>
  [ "$(fm_nm_head_binding "$1" "$2")" = match ]
}
