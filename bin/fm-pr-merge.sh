#!/usr/bin/env bash
# Merge a task's PR or MR after recording pr= and any available pr_head= through
# bin/fm-pr-check.sh, so teardown can verify landed work after squash merges.
# The full canonical URL is parsed by bin/fm-pr-lib.sh. A GitHub pull request is
# addressed through gh-axi by the derived owner and repository; a GitLab merge
# request is addressed through glab by the project URL rebuilt from the parsed
# host and path, so any instance works and no host is hardcoded.
#
# Merge method on GitHub defaults to --squash when the caller passes none of
# --squash, --merge, --rebase, or --method after the optional -- separator.
# GitLab adds no method flag at all: its merge method is the project's own
# setting, which the merge API applies, and imposing squash there would override
# that convention rather than mirror the GitHub default.
#
# That implicit default is guarded, because a squash collapses every commit on
# the pull request into one and destroys its ancestry permanently on the remote.
# When the caller passes no merge method, the pull request's commit and changed-
# file counts are read live from REST (gh api repos/<owner>/<repo>/pulls/<n>,
# never GraphQL, whose budget the whole fleet shares) and the merge is REFUSED,
# naming the counts it saw, when either exceeds SQUASH_GUARD_MAX_COMMITS (15) or
# SQUASH_GUARD_MAX_FILES (100). A count that cannot be read refuses the same way
# rather than squashing on an unverified assumption. An explicit --squash,
# --merge, --rebase, or --method always wins and skips the guard entirely, so
# the operator can still squash a stack deliberately. The guard also warns when
# the head branch name or PR description names a stack, but the counts are the
# hard gate. GitLab is unaffected because no squash is ever imposed there.
#
# A GitLab merge is refused unless every pre-merge condition holds, each read
# live at merge time rather than taken from recorded metadata: the merge request
# is open, detailed_merge_status is mergeable, has_conflicts is false,
# blocking_discussions_resolved is true, and the head pipeline succeeded at the
# exact current head commit. Every failing condition is reported, not just the
# first. The verified head is then passed to glab as --sha, so a push that lands
# between that read and the merge fails the merge instead of landing commits
# nothing verified. A recorded pr_head that disagrees with the live head is
# reported rather than trusted, because a rebase moves the head and leaves the
# recorded value stale. Reading that state needs glab and jq, and either one
# absent stops the merge before any state is recorded.
#
# Extra args must not include --repo or -R in any form, including a bundled
# short-option cluster such as -yR, because the repository comes only from the
# URL, nor --sha on GitLab because the head comes only from the live read.
#
# Two accepted classes:
#
#   task class:     fm-pr-merge.sh <task-id> <pr-url> [-- <extra forge merge args>]
#     Records pr= and any available pr_head= into the task's state/<task-id>.meta
#     via bin/fm-pr-check.sh before merging, as described above. GitHub and
#     GitLab are both accepted here.
#
#   pipeline class: fm-pr-merge.sh --pipeline <pr-url> [-- <extra gh-axi pr merge args>]
#     For pipeline-raised PRs (e.g. no-mistakes-raised) that have no owning task
#     meta. GitHub only. Instead of task-meta recording it enforces an explicit
#     green gate - PR open, targets the repository default branch,
#     mergeable_state=clean, all checks completed with none pending and none
#     non-green, and no outstanding requested-changes review - then merges pinned
#     to the exact gated head SHA (--match-head-commit) and records the merge to
#     state/pr-merge-audit.log. This is an EXTENSION of the guard, not a bypass:
#     every gate that fails, and every forge read that fails, refuses loudly and
#     exits non-zero, exactly as the task class refuses on missing meta.
#     Pipeline-class extra args must not include --match-head-commit or --auto,
#     because the head pin comes only from the gate and auto-merge drops it.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

PIPELINE_HEAD=""

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
  # bin/fm-pr-lib.sh parses GitLab merge request URLs, but the pipeline class
  # addresses only GitHub by owner/repository, so a GitLab URL is refused here.
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
  if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL"; then
    echo "error: invalid PR merge request" >&2
    exit 2
  fi
  shift 2
fi
URL=$FM_PR_URL
PROVIDER=$FM_PR_PROVIDER
PR_OWNER=$FM_PR_OWNER
PR_REPO=$FM_PR_REPO
PR_NUMBER=$FM_PR_NUMBER
# glab resolves the instance from the project URL passed to -R, so the host is
# rebuilt from the parsed identity rather than read from any ambient default.
PROJECT_URL="https://$FM_PR_HOST/$FM_PR_PATH"
[ "${1:-}" = "--" ] && shift

caller_has_merge_method() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --squash|--merge|--rebase|--method|--method=*) return 0 ;;
    esac
  done
  return 1
}

reject_repo_overrides() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --repo|--repo=*)
        echo "error: extra merge arguments must not override the repository" >&2
        return 1
        ;;
      --*) ;;
      # A single-dash argument is a short-option cluster, which both CLIs expand
      # one character at a time, so -yR carries --repo exactly as a bare -R does.
      -*R*)
        echo "error: extra merge arguments must not override the repository" >&2
        return 1
        ;;
    esac
  done
}

reject_head_overrides() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --sha|--sha=*)
        echo "error: extra merge arguments must not override the head commit" >&2
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
    --auto | --auto=*)
      echo "error: extra merge arguments must not enable auto-merge, which drops the gated head pin" >&2
      return 1
      ;;
    esac
  done
}

pipeline_refuse() {
  echo "error: pipeline merge refused - $1" >&2
}

# Counts above which the implicit --squash default is refused. They sit between
# ordinary delivery and a stack: the ten most recent PRs of this repo carried at
# most 11 commits over 16 files, including the pipeline's own review-fix and
# documentation commits, while the stacked ladder whose ancestry a default
# squash destroyed carried 249 commits over 379 files. Set them high enough that
# routine work never trains an operator to pass --squash reflexively.
SQUASH_GUARD_MAX_COMMITS=15
SQUASH_GUARD_MAX_FILES=100

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

# How the operator proceeds after a squash refusal, printed by every one of them.
squash_guard_alternatives() {
  echo '  pass --squash to squash it anyway, or --merge or --rebase to keep the commits' >&2
}

# A pull request whose commit count cannot be read is not squashed by default,
# because the default is the destructive option and nothing verified it is safe.
squash_guard_unreadable() {
  printf 'error: refusing to squash %s by default - its commit count could not be read from %s/%s\n' \
    "$URL" "$PR_OWNER" "$PR_REPO" >&2
  echo '  squashing would flatten every commit on the pull request into one commit and destroy their ancestry permanently' >&2
  squash_guard_alternatives
}

# The soft signal: a head branch or description that names a stack. Echoes one
# reason when it finds one, and returns non-zero when it does not.
squash_guard_stack_hint() {
  local head_ref=$1 body=$2 lowered
  lowered=$(printf '%s' "$head_ref" | tr '[:upper:]' '[:lower:]')
  case "$lowered" in
    *stack*|*ladder*|*rung*)
      printf 'the head branch "%s" names a stack\n' "$head_ref"
      return 0
      ;;
  esac
  lowered=$(printf '%s' "$body" | tr '[:upper:]' '[:lower:]')
  case "$lowered" in
    *stacked*|*"part of a stack"*|*"stack of"*)
      echo 'the pull request description names a stack'
      return 0
      ;;
  esac
  return 1
}

# Guard the implicit --squash default. Called only when the caller passed no
# merge method, so an explicit one never reaches it. Reads the pull request from
# REST unless the caller already holds that exact payload ($1), which the
# pipeline gate does, so no merge path spends a second forge read. Returns
# non-zero, reporting the counts it saw, when squashing would flatten a stack.
squash_default_guard() {
  local pull=${1:-} commits files head_ref body hint=''
  if [ -z "$pull" ]; then
    if ! pull=$(gh api "repos/$PR_OWNER/$PR_REPO/pulls/$PR_NUMBER" 2>/dev/null); then
      squash_guard_unreadable
      return 1
    fi
  fi
  if ! commits=$(jq_count "$pull" '.commits') || ! files=$(jq_count "$pull" '.changed_files'); then
    squash_guard_unreadable
    return 1
  fi
  head_ref=$(printf '%s' "$pull" | jq -r '.head.ref // ""' 2>/dev/null) || head_ref=''
  body=$(printf '%s' "$pull" | jq -r '.body // ""' 2>/dev/null) || body=''
  hint=$(squash_guard_stack_hint "$head_ref" "$body") || hint=''

  if [ "$commits" -le "$SQUASH_GUARD_MAX_COMMITS" ] && [ "$files" -le "$SQUASH_GUARD_MAX_FILES" ]; then
    if [ -n "$hint" ]; then
      printf 'notice: %s carries %s commit(s) and %s changed file(s), and %s; the default squash will flatten them into one commit\n' \
        "$URL" "$commits" "$files" "$hint" >&2
    fi
    return 0
  fi
  printf 'error: refusing to squash %s by default - it carries %s commits and %s changed files\n' \
    "$URL" "$commits" "$files" >&2
  printf '  squashing would flatten those %s commits into one commit and destroy their ancestry permanently\n' \
    "$commits" >&2
  [ -z "$hint" ] || printf '  %s\n' "$hint" >&2
  squash_guard_alternatives
  return 1
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
  if ! total=$(jq_count "$checks" '.total_count') ||
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
    ! red=$(jq_count "$checks" '[.check_runs[] | select(.status == "completed" and ((.conclusion == "success" or .conclusion == "neutral" or .conclusion == "skipped") | not))] | length'); then
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
  # The same squash guard the task class applies, run against the payload this
  # gate already read and before the audit line, so a refusal records no merge.
  if [ "$DEFAULT_SQUASH" = yes ]; then
    squash_default_guard "$pull" || return 1
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

reject_repo_overrides "$@" || exit 1

# The squash guard applies only to the implicit default, so both classes resolve
# that once, before any forge read, and never guard an explicit merge method.
if caller_has_merge_method "$@"; then
  DEFAULT_SQUASH=no
else
  DEFAULT_SQUASH=yes
fi

if [ "$CLASS" = pipeline ]; then
  reject_pipeline_pin_overrides "$@" || exit 1
  pipeline_merge_gate || exit 1
  # Pipeline merges pin to the exact gated head so a commit pushed between the
  # gate and the merge cannot land unvetted.
  merge_args=(--match-head-commit "$PIPELINE_HEAD")
  if [ "$DEFAULT_SQUASH" = yes ]; then
    merge_args+=(--squash)
  fi
  gh-axi pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" "${merge_args[@]}" "$@"
  exit
fi

[ "$PROVIDER" != gitlab ] || reject_head_overrides "$@" || exit 1

# Task-derived paths are constructed only after the canonical ID validation.
META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi

# Reading the merge request state needs both tools. Report them together and
# before anything is recorded, so a missing tool is a named prerequisite rather
# than a merge that is armed and then refused for an unexplained reason.
GITLAB_MISSING=
if [ "$PROVIDER" = gitlab ]; then
  command -v glab >/dev/null 2>&1 || GITLAB_MISSING="glab"
  if ! command -v jq >/dev/null 2>&1; then
    GITLAB_MISSING="${GITLAB_MISSING:+$GITLAB_MISSING and }jq"
  fi
  if [ -n "$GITLAB_MISSING" ]; then
    echo "error: merging a GitLab merge request requires $GITLAB_MISSING on PATH" >&2
    exit 1
  fi
fi

# The recorded head is read before bin/fm-pr-check.sh rewrites the metadata,
# because that script re-records pr= and drops a pr_head= it cannot resolve.
RECORDED_HEAD=
if [ "$PROVIDER" = gitlab ]; then
  RECORDED_HEAD=$(grep '^pr_head=' "$META" | tail -1 | cut -d= -f2- || true)
fi

"$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL"
grep -qxF "pr=$URL" "$META" || {
  echo "error: PR metadata recording failed" >&2
  exit 1
}

# Pre-merge conditions for a GitLab merge request, read from one live view of
# the merge request. Sets FM_PR_MERGE_HEAD to the verified head on success and
# returns non-zero after reporting every condition that failed.
FM_PR_MERGE_HEAD=
gitlab_verify_mergeable() {
  local json fields line
  local total=0 named=0 refusals=''
  local state='' detail='' conflicts='' discussions=''
  local live_head='' pipeline_sha='' pipeline_status=''

  # GITLAB_HOST is set to the same host the project URL already carries, so the
  # instance is taken from the parsed URL by both signals and never from the
  # operator's configured default.
  if ! json=$(GITLAB_HOST="$FM_PR_HOST" glab mr view "$PR_NUMBER" -R "$PROJECT_URL" -F json 2>/dev/null) \
    || [ -z "$json" ]; then
    echo "error: could not read the GitLab merge request state before merging" >&2
    return 1
  fi
  # One named field per line. The names keep a trailing empty value readable
  # after command substitution strips blank lines, and an absent or null field
  # becomes an empty string or the literal "null", neither of which satisfies any
  # check below, so an unreadable field refuses the merge instead of passing it.
  if ! fields=$(printf '%s' "$json" | jq -r '
      if type == "object" then
        "state=" + ((.state // "") | tostring),
        "detail=" + ((.detailed_merge_status // "") | tostring),
        "conflicts=" + (.has_conflicts | tostring),
        "discussions=" + (.blocking_discussions_resolved | tostring),
        "head=" + ((.sha // "") | tostring),
        "pipeline_sha=" + ((.head_pipeline.sha // "") | tostring),
        "pipeline_status=" + ((.head_pipeline.status // "") | tostring)
      else
        error("merge request payload is not an object")
      end' 2>/dev/null); then
    echo "error: could not read the GitLab merge request state before merging" >&2
    return 1
  fi
  while IFS= read -r line; do
    total=$((total + 1))
    case "$line" in
      state=*) state=${line#state=} ;;
      detail=*) detail=${line#detail=} ;;
      conflicts=*) conflicts=${line#conflicts=} ;;
      discussions=*) discussions=${line#discussions=} ;;
      head=*) live_head=${line#head=} ;;
      pipeline_sha=*) pipeline_sha=${line#pipeline_sha=} ;;
      pipeline_status=*) pipeline_status=${line#pipeline_status=} ;;
      *) continue ;;
    esac
    named=$((named + 1))
  done <<FIELDS
$fields
FIELDS
  # Every field named exactly once and no unnamed line: a value carrying a
  # newline would split into a line no name matches, so it is refused here
  # rather than silently truncated into a value a check could accept.
  if [ "$named" -ne 7 ] || [ "$total" -ne 7 ]; then
    echo "error: could not read the GitLab merge request state before merging" >&2
    return 1
  fi

  if ! fm_pr_head_valid "$live_head"; then
    echo "error: could not read the GitLab merge request head commit before merging" >&2
    return 1
  fi
  # A rebase moves the head and leaves the recorded value behind, so the
  # disagreement is reported and the live head is what gets verified and merged.
  if [ -n "$RECORDED_HEAD" ] && [ "$RECORDED_HEAD" != "$live_head" ]; then
    printf 'notice: recorded head %s disagrees with the live head %s; verifying the live head\n' \
      "$RECORDED_HEAD" "$live_head" >&2
  fi

  [ "$state" = opened ] \
    || refusals="$refusals  - state is \"${state:-unreadable}\", not open
"
  [ "$detail" = mergeable ] \
    || refusals="$refusals  - detailed_merge_status is \"${detail:-unreadable}\", not mergeable
"
  [ "$conflicts" = false ] \
    || refusals="$refusals  - has_conflicts is \"${conflicts:-unreadable}\", not false
"
  [ "$discussions" = true ] \
    || refusals="$refusals  - blocking_discussions_resolved is \"${discussions:-unreadable}\", not true
"
  [ "$pipeline_status" = success ] \
    || refusals="$refusals  - the head pipeline status is \"${pipeline_status:-none}\", not success
"
  [ "$pipeline_sha" = "$live_head" ] \
    || refusals="$refusals  - the head pipeline ran at \"${pipeline_sha:-none}\", not at the current head $live_head
"

  if [ -n "$refusals" ]; then
    printf 'error: refusing to merge %s\n' "$URL" >&2
    printf '%s' "$refusals" >&2
    return 1
  fi
  printf 'verified: %s is open and mergeable, with a successful pipeline at head %s\n' \
    "$URL" "$live_head" >&2
  FM_PR_MERGE_HEAD=$live_head
}

case "$PROVIDER" in
  github)
    merge_args=()
    if [ "$DEFAULT_SQUASH" = yes ]; then
      squash_default_guard || exit 1
      merge_args=(--squash)
    fi
    gh-axi pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" "${merge_args[@]+"${merge_args[@]}"}" "$@"
    ;;
  gitlab)
    gitlab_verify_mergeable || exit 1
    # --sha binds the merge to the head this run verified, so a push that lands
    # in between is refused by GitLab instead of merged unverified. --yes only
    # skips the interactive confirmation, which no supervised run can answer;
    # the conditions above are what authorize the merge.
    GITLAB_HOST="$FM_PR_HOST" glab mr merge "$PR_NUMBER" -R "$PROJECT_URL" \
      --sha "$FM_PR_MERGE_HEAD" --yes "$@"
    ;;
  *)
    echo "error: invalid PR merge request" >&2
    exit 2
    ;;
esac
