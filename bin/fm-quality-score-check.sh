#!/usr/bin/env bash
# Absolute structural-quality band check for every agent session.
#
# The sibling regression gate (`sentrux gate`, wired into the Claude Stop hook)
# only answers "did this change make the repository worse than its baseline".
# That lets a repository sit permanently at a bad absolute score as long as no
# single turn degrades it. This check owns the other half of the captain's
# standing order: the CURRENT score must stay inside an absolute band, whatever
# the baseline says.
#
# It runs `sentrux gate .` at the repository root and reads the current score
# from the one line that carries it:
#
#   Quality:      9120 -> 6899
#              baseline    current
#
# The right-hand number is the current score and the only one this check uses.
# See docs/quality-score-gate.md for the band, the wiring points, and the
# fail-open rule.
#
# Usage:
#   bin/fm-quality-score-check.sh [--cwd <dir>] [--quiet]
#
# --cwd  directory to resolve the repository from (default: $PWD).
# --quiet  suppress the below-aim advisory warning. A below-floor block always
#          prints its reason, because a silent block is unactionable.
#
# Thresholds are environment-tunable so the captain can retune the band without
# editing this script:
#   FM_QUALITY_MIN  lowest acceptable score (default 6200) - below this blocks.
#   FM_QUALITY_AIM  target score (default 7000) - below this warns.
#
# Exit/output contract:
#   PASS  - exit 0 and no output, when the score is at or above FM_QUALITY_AIM.
#   WARN  - exit 0 with a one-line warning on stderr, when the score is at or
#           above FM_QUALITY_MIN but below FM_QUALITY_AIM.
#   BLOCK - exit 2 with a short actionable reason on stderr, when the score is
#           below FM_QUALITY_MIN.
#   FAIL OPEN - exit 0 and no output for anything unmeasurable: sentrux absent,
#           an unresolvable cwd, no repository above the cwd, a sentrux run that
#           fails for any reason, or output with no parseable Quality line. A
#           gate that cannot measure must never block work.
set -u

CWD=""
QUIET=0

usage() {
  cat <<'EOF'
Usage: fm-quality-score-check.sh [--cwd <dir>] [--quiet]

Checks the CURRENT sentrux quality score of the repository containing <dir>
against an absolute band.

  --cwd <dir>   directory to resolve the repository from (default: $PWD)
  --quiet       suppress the below-aim warning (a below-floor block still prints)

Environment:
  FM_QUALITY_MIN  lowest acceptable score (default 6200); below it exits 2
  FM_QUALITY_AIM  target score (default 7000); below it warns and exits 0

Exits 0 and prints nothing when the score cannot be measured.
EOF
}

# Walk up from a directory to the nearest ancestor holding a .git entry. A
# worktree or submodule carries .git as a file, so both forms count.
find_repo_root() {
  local dir=$1
  while [ -n "$dir" ] && [ "$dir" != "/" ]; do
    if [ -e "$dir/.git" ]; then
      printf '%s\n' "$dir"
      return 0
    fi
    dir=${dir%/*}
  done
  [ -e "/.git" ] && {
    printf '/\n'
    return 0
  }
  return 1
}

while [ "$#" -gt 0 ]; do
  case "$1" in
  --cwd)
    [ "$#" -ge 2 ] || exit 0
    CWD=$2
    shift 2
    ;;
  --quiet)
    QUIET=1
    shift
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    # An unknown flag is a caller bug, not a quality verdict: fail open.
    exit 0
    ;;
  esac
done

# A threshold that is not a plain integer is treated as unset rather than as a
# reason to block, for the same fail-open reason.
MIN=${FM_QUALITY_MIN:-6200}
AIM=${FM_QUALITY_AIM:-7000}
case "$MIN" in '' | *[!0-9]*) MIN=6200 ;; esac
case "$AIM" in '' | *[!0-9]*) AIM=7000 ;; esac

command -v sentrux >/dev/null 2>&1 || exit 0

[ -n "$CWD" ] || CWD=$PWD
CWD=$(CDPATH='' cd -- "$CWD" 2>/dev/null && pwd -P) || exit 0

REPO=$(find_repo_root "$CWD") || exit 0

# `sentrux gate` exits nonzero on its own DEGRADED verdict, which is a verdict
# and not a run failure, so the exit status is deliberately ignored here. A
# genuine failure (crash, unsupported tree, missing baseline) shows up as output
# with no parseable score line, which falls open below.
GATE=$(cd "$REPO" && sentrux gate . 2>&1) || true

# The score line is `Quality:` followed by the baseline, an arrow, and the
# current score. Take the LAST number on the first such line.
SCORE=$(printf '%s\n' "$GATE" |
  sed -n 's/^Quality:[[:space:]]*[0-9][0-9]*[[:space:]]*->[[:space:]]*\([0-9][0-9]*\).*$/\1/p' |
  head -n 1)
case "$SCORE" in '' | *[!0-9]*) exit 0 ;; esac

if [ "$SCORE" -lt "$MIN" ]; then
  printf 'Quality score %s is below the %s floor (aim %s) in %s.\n' \
    "$SCORE" "$MIN" "$AIM" "$REPO" >&2
  printf 'This change is not shippable until the structure is fixed or the change is split.\n' >&2
  exit 2
fi

if [ "$SCORE" -lt "$AIM" ]; then
  [ "$QUIET" -eq 1 ] || printf 'Quality score %s is above the %s floor but below the %s aim in %s.\n' \
    "$SCORE" "$MIN" "$AIM" "$REPO" >&2
  exit 0
fi

exit 0
