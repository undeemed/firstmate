#!/usr/bin/env bash
# Merge a PR through the one guarded firstmate merge path. Two accepted classes:
#
#   task class:     fm-pr-merge.sh <task-id> <pr-url> [-- <extra gh-axi pr merge args>]
#     Records pr= and any available pr_head= into the task's state/<task-id>.meta
#     via bin/fm-pr-check.sh before merging, so teardown can verify landed work
#     after squash merges.
#
#   pipeline class: fm-pr-merge.sh --pipeline <pr-url> [-- <extra gh-axi pr merge args>]
#     For pipeline-raised PRs (e.g. no-mistakes-raised) that have no owning task
#     meta. Instead of task-meta recording it enforces an explicit green gate -
#     PR open, targets the repository default branch, mergeable_state=clean, all
#     checks completed with none pending and none non-green, and no outstanding
#     requested-changes review - then merges pinned to the exact gated head SHA
#     (--match-head-commit) and records the merge to state/pr-merge-audit.log.
#     This is an EXTENSION of the guard, not a bypass: every gate that fails, and
#     every forge read that fails, refuses loudly and exits non-zero (fail
#     closed), exactly as the task class refuses on missing meta.
#
# The full canonical GitHub PR URL is parsed by bin/fm-pr-lib.sh and the derived
# owner/repository and PR number are passed to gh-axi as separate arguments.
#
# Merge method defaults to --squash when the caller passes none of --squash,
# --merge, --rebase, or --method after the optional -- separator. Extra args
# must not include --repo or -R because the repository comes only from the URL.
# Pipeline-class extra args must not include --match-head-commit either, because
# the head pin comes only from the gate.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

PIPELINE_HEAD=""

caller_has_merge_method() {
  local arg
  for arg in "$@"; do
    case "$arg" in
    --squash | --merge | --rebase | --method | --method=*) return 0 ;;
    esac
  done
  return 1
}

reject_repo_overrides() {
  local arg
  for arg in "$@"; do
    case "$arg" in
    --repo | --repo=* | -R | -R?*)
      echo "error: extra merge arguments must not override the repository" >&2
      return 1
      ;;
    esac
  done
}

reject_pipeline_pin_overrides() {
  local arg
  for arg in "$@"; do
    case "$arg" in
    --match-head-commit | --match-head-commit=*)
      echo "error: extra merge arguments must not override the gated head pin" >&2
      return 1
      ;;
    esac
  done
}

pipeline_refuse() {
  echo "error: pipeline merge refused - $1" >&2
}

# Extract a count from a JSON payload, failing closed: non-zero unless jq
# succeeds and the result is a non-negative integer.
jq_count() {
  local json=$1 filter=$2 value
  value=$(printf '%s' "$json" | jq "$filter" 2>/dev/null) || return 1
  case "$value" in
  '' | *[!0-9]*) return 1 ;;
  esac
  printf '%s\n' "$value"
}

# Enforce the pipeline-class green gate against the live forge. Every gate and
# every forge read fails closed (loud refusal, non-zero). On success it records
# an audit line and exports PIPELINE_HEAD (the exact gated head SHA) so the
# merge can pin to it with --match-head-commit.
pipeline_merge_gate() {
  local pull repo_json default_branch state base mstate head checks total returned pending red reviews review_count changes_requested
  if ! pull=$(gh api "repos/$PR_OWNER/$PR_REPO/pulls/$PR_NUMBER" 2>/dev/null); then
    pipeline_refuse "PR #$PR_NUMBER could not be read from $PR_OWNER/$PR_REPO"
    return 1
  fi
  if ! repo_json=$(gh api "repos/$PR_OWNER/$PR_REPO" 2>/dev/null); then
    pipeline_refuse "could not resolve $PR_OWNER/$PR_REPO default branch"
    return 1
  fi
  default_branch=$(printf '%s' "$repo_json" | jq -r '.default_branch' 2>/dev/null)
  if [ -z "$default_branch" ] || [ "$default_branch" = null ]; then
    pipeline_refuse "could not resolve $PR_OWNER/$PR_REPO default branch"
    return 1
  fi
  state=$(printf '%s' "$pull" | jq -r '.state')
  base=$(printf '%s' "$pull" | jq -r '.base.ref')
  mstate=$(printf '%s' "$pull" | jq -r '.mergeable_state')
  head=$(printf '%s' "$pull" | jq -r '.head.sha')
  if [ "$state" != open ]; then
    pipeline_refuse "PR #$PR_NUMBER is not open (state=$state)"
    return 1
  fi
  if [ "$base" != "$default_branch" ]; then
    pipeline_refuse "PR #$PR_NUMBER does not target the default branch (base=$base, default=$default_branch)"
    return 1
  fi
  if [ "$mstate" != clean ]; then
    pipeline_refuse "PR #$PR_NUMBER is not mergeable_state=clean (got=$mstate)"
    return 1
  fi
  if [ -z "$head" ] || [ "$head" = null ]; then
    pipeline_refuse "PR #$PR_NUMBER head SHA is unavailable"
    return 1
  fi
  # per_page=100 plus a total_count consistency check: if the forge reports more
  # checks than fit one page, refuse rather than risk a red check on page two.
  if ! checks=$(gh api "repos/$PR_OWNER/$PR_REPO/commits/$head/check-runs?per_page=100" 2>/dev/null); then
    pipeline_refuse "PR #$PR_NUMBER checks could not be read"
    return 1
  fi
  if ! total=$(jq_count "$checks" '.total_count // (.check_runs | length)') ||
    ! returned=$(jq_count "$checks" '.check_runs | length'); then
    pipeline_refuse "PR #$PR_NUMBER checks payload is malformed"
    return 1
  fi
  if [ "$total" -eq 0 ]; then
    pipeline_refuse "PR #$PR_NUMBER has no checks to verify"
    return 1
  fi
  if [ "$total" != "$returned" ]; then
    pipeline_refuse "PR #$PR_NUMBER reports $total checks exceeding one verifiable page ($returned read)"
    return 1
  fi
  if ! pending=$(jq_count "$checks" '[.check_runs[] | select(.status != "completed")] | length') ||
    ! red=$(jq_count "$checks" '[.check_runs[] | select(.conclusion == "failure" or .conclusion == "cancelled" or .conclusion == "timed_out" or .conclusion == "action_required" or .conclusion == "startup_failure" or .conclusion == "stale")] | length'); then
    pipeline_refuse "PR #$PR_NUMBER checks payload is malformed"
    return 1
  fi
  if [ "$pending" -ne 0 ]; then
    pipeline_refuse "PR #$PR_NUMBER has $pending check(s) still running"
    return 1
  fi
  if [ "$red" -ne 0 ]; then
    pipeline_refuse "PR #$PR_NUMBER has $red non-green check(s)"
    return 1
  fi
  # Reviews fail closed. A reviewer's effective verdict is their latest APPROVED
  # or CHANGES_REQUESTED review; COMMENTED and DISMISSED reviews do not clear a
  # prior CHANGES_REQUESTED, so they are excluded before taking the latest.
  if ! reviews=$(gh api "repos/$PR_OWNER/$PR_REPO/pulls/$PR_NUMBER/reviews?per_page=100" 2>/dev/null); then
    pipeline_refuse "PR #$PR_NUMBER reviews could not be read"
    return 1
  fi
  if ! review_count=$(jq_count "$reviews" 'if type == "array" then length else error end'); then
    pipeline_refuse "PR #$PR_NUMBER reviews payload is malformed"
    return 1
  fi
  # The reviews endpoint reports no total_count, so a full page means a later
  # review could hide on page two: refuse rather than trust an unverifiable page.
  if [ "$review_count" -ge 100 ]; then
    pipeline_refuse "PR #$PR_NUMBER has $review_count reviews exceeding one verifiable page"
    return 1
  fi
  if ! changes_requested=$(jq_count "$reviews" '[.[] | select(.state == "APPROVED" or .state == "CHANGES_REQUESTED")] | group_by(.user.login) | map(last) | [.[] | select(.state == "CHANGES_REQUESTED")] | length'); then
    pipeline_refuse "PR #$PR_NUMBER reviews payload is malformed"
    return 1
  fi
  if [ "$changes_requested" -ne 0 ]; then
    pipeline_refuse "PR #$PR_NUMBER has $changes_requested outstanding requested-changes review(s)"
    return 1
  fi
  mkdir -p "$STATE" || {
    pipeline_refuse "state directory unavailable for audit log"
    return 1
  }
  printf '%s\tpr=%s\thead=%s\tclass=pipeline\turl=%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$PR_NUMBER" "$head" "$URL" >>"$STATE/pr-merge-audit.log" || {
    pipeline_refuse "audit log could not be written"
    return 1
  }
  PIPELINE_HEAD=$head
}

# --- class dispatch ---------------------------------------------------------
CLASS=task
if [ "${1:-}" = "--pipeline" ]; then
  CLASS=pipeline
  shift
fi

if [ "$CLASS" = pipeline ]; then
  if [ "$#" -lt 1 ]; then
    echo "error: invalid PR merge request" >&2
    exit 2
  fi
  RAW_URL=$1
  # bin/fm-pr-lib.sh parses GitLab merge request URLs, but merge still addresses
  # only GitHub by owner/repository. Hold that refusal exactly as the task class.
  if ! fm_pr_url_parse "$RAW_URL" || [ "$FM_PR_PROVIDER" != github ]; then
    echo "error: invalid PR merge request" >&2
    exit 2
  fi
  shift
else
  if [ "$#" -lt 2 ]; then
    echo "error: invalid PR merge request" >&2
    exit 2
  fi
  ID=$1
  RAW_URL=$2
  if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL" ||
    [ "$FM_PR_PROVIDER" != github ]; then
    echo "error: invalid PR merge request" >&2
    exit 2
  fi
  shift 2
fi
URL=$FM_PR_URL
PR_OWNER=$FM_PR_OWNER
PR_REPO=$FM_PR_REPO
PR_NUMBER=$FM_PR_NUMBER
[ "${1:-}" = "--" ] && shift

reject_repo_overrides "$@" || exit 1

if [ "$CLASS" = pipeline ]; then
  reject_pipeline_pin_overrides "$@" || exit 1
  pipeline_merge_gate || exit 1
else
  # Task-derived paths are constructed only after the canonical ID validation.
  META="$STATE/$ID.meta"
  if [ ! -f "$META" ] || [ -L "$META" ]; then
    echo "error: task metadata is unavailable" >&2
    exit 1
  fi
  "$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL"
  grep -qxF "pr=$URL" "$META" || {
    echo "error: PR metadata recording failed" >&2
    exit 1
  }
fi

merge_args=()
# Pipeline merges pin to the exact gated head so a commit pushed between the
# gate and the merge cannot land unvetted.
if [ "$CLASS" = pipeline ]; then
  merge_args+=(--match-head-commit "$PIPELINE_HEAD")
fi
if ! caller_has_merge_method "$@"; then
  merge_args+=(--squash)
fi

gh-axi pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" "${merge_args[@]+"${merge_args[@]}"}" "$@"
