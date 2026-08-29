#!/usr/bin/env bash
# Record a PR-ready task: store one validated canonical pr=<url> and the forge's
# exact pr_head=<sha> when available, then atomically arm a static merge poll.
# The watcher check source is byte-for-byte bin/fm-pr-poll.sh; task and PR data
# live only in a private sidecar and are never interpolated into shell source.
# A GitHub pull request URL and a GitLab merge request URL are both accepted,
# including a merge request on a self-hosted GitLab instance.
#
# This is also the one point that enforces a task's declared PR body contract.
# The pipeline that opens a PR composes the published body itself, so body
# content a brief asks for never reaches the forge on its own. A task that
# genuinely requires published content - a repository policy that demands an
# AI-assistance disclosure, for example - declares it at brief time with
# bin/fm-brief.sh --pr-body-required, which stores that content at
# data/<task-id>/pr-body-required.md. When that file exists, this script reads
# the PUBLISHED body back from the forge over REST, appends the declared block
# as the body's final lines unless the body already ends with it, then reads
# the body back over REST once more to confirm the published result. The
# description sent is never the evidence. A task that declares nothing has its
# body neither read nor written, so its published body is exactly what the
# pipeline composed.
# The refusal is loud and total: declared content that cannot be published
# records no pr=, arms no merge poll, and stops the merge in
# bin/fm-pr-merge.sh, which runs this script before it merges.
# Usage: fm-pr-check.sh <task-id> <pr-url>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-forge-audit-lib.sh
. "$SCRIPT_DIR/fm-forge-audit-lib.sh"

if [ "$#" -ne 2 ]; then
  echo "error: invalid PR check request" >&2
  exit 2
fi
ID=$1
RAW_URL=$2
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL"; then
  echo "error: invalid PR check request" >&2
  exit 2
fi
URL=$FM_PR_URL
PROVIDER=$FM_PR_PROVIDER
HOST=$FM_PR_HOST
PROJECT_PATH=$FM_PR_PATH
NUMBER=$FM_PR_NUMBER
# Set only for github; the REST head read below addresses the repository with them.
OWNER=$FM_PR_OWNER
REPO=$FM_PR_REPO

# Task-derived paths are constructed only after the canonical ID validation.
META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ] || [ "$(fm_pr_file_link_count "$META")" != 1 ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi

# A prior exact merged result may have queued its durable wake immediately
# before interruption.
# Finish only its identity-bound receipt before publishing a replacement poll.
fm_pr_poll_retirement_recover_one "$STATE" "$ID" "$SCRIPT_DIR/fm-pr-poll.sh" || {
  echo "error: pending PR poll retirement could not be validated" >&2
  exit 1
}

# Refuse to arm a GitLab watch with no glab on PATH. The poll is silent on
# every error by design, so a missing CLI would be indistinguishable from a
# merge request that is never merged. Arming is the one point where that can be
# reported, so the absent tool stops the watch here instead of watching nothing.
if [ "$PROVIDER" = gitlab ] && ! command -v glab >/dev/null 2>&1; then
  echo "error: watching a GitLab merge request requires glab on PATH" >&2
  exit 1
fi

# Neutralize any pre-fix poll before recording or arming this task. The
# migration never executes legacy artifacts and holds watcher exclusion while
# it quarantines or rebuilds them.
"$SCRIPT_DIR/fm-pr-check-migrate.sh" --checks-safe || exit 1
"$FM_ROOT/bin/fm-guard.sh" || true

# pr_head is recorded only when the forge's CLI can supply it. gh reads the head
# commit straight from the REST pull request resource, addressed by the owner,
# repository, and number already parsed from the URL; plain glab exposes it only
# inside its JSON output, which would need a JSON processor firstmate does not
# require, so a GitLab task records no pr_head.
# That read is REST rather than `gh pr view --json headRefOid`, which is
# GraphQL: bin/fm-pr-merge.sh runs this script on every task-class merge, the
# fleet's busiest GitHub path, so it must not spend the scarcer shared GraphQL
# budget on a field REST answers directly.
# Both consumers already treat pr_head as optional:
# bin/fm-teardown.sh reads the head from the forge at teardown rather than from
# metadata and falls back to its provider-agnostic content check, and
# bin/fm-review-diff.sh resolves the head from the remote when none is recorded.
# bin/fm-pr-merge.sh reads a GitLab head live at merge time for the same reason,
# and treats a recorded value that disagrees as stale rather than authoritative.
WT=$(grep '^worktree=' "$META" | tail -1 | cut -d= -f2- || true)
PR_HEAD=
if [ "$PROVIDER" = github ] && [ -n "$WT" ] && [ -d "$WT" ] && command -v gh >/dev/null 2>&1; then
  if REMOTE_HEAD=$(cd "$WT" && gh api "repos/$OWNER/$REPO/pulls/$NUMBER" --jq .head.sha 2>/dev/null) \
    && fm_pr_head_valid "$REMOTE_HEAD"; then
    PR_HEAD=$REMOTE_HEAD
  fi
fi

# --- declared PR body contract ----------------------------------------------
# Trailing whitespace and CR carry no meaning in a rendered body, so both sides
# are compared with them removed.
body_trim_tail() {  # <text>
  local s=${1-}
  s=${s//$'\r'/}
  printf '%s' "${s%"${s##*[![:space:]]}"}"
}

BODY_TMP=

# Names the task and the exact content that is not published, then stops.
body_refuse() {  # <reason> <declared-content>
  [ -z "$BODY_TMP" ] || rm -f -- "$BODY_TMP"
  printf 'error: task %s declares required pull request body content that %s does not carry: %s\n' \
    "$ID" "$URL" "$1" >&2
  printf -- '--- declared content, not published ---\n%s\n--- end declared content ---\n' "$2" >&2
  exit 1
}

# One REST read of the published body, empty when the PR has none.
body_read_published() {
  gh api "repos/$OWNER/$REPO/pulls/$NUMBER" --jq '.body // ""' 2>/dev/null
}

REQUIRED_FILE="$DATA/$ID/pr-body-required.md"
if [ -f "$REQUIRED_FILE" ]; then
  REQUIRED=$(body_trim_tail "$(cat "$REQUIRED_FILE")")
  [ -n "$REQUIRED" ] || {
    echo "error: task $ID declares required pull request body content, but $REQUIRED_FILE is empty" >&2
    exit 1
  }
  [ "$PROVIDER" = github ] \
    || body_refuse "publishing declared body content is implemented for GitHub only" "$REQUIRED"
  command -v gh >/dev/null 2>&1 \
    || body_refuse "reading the published body needs gh on PATH" "$REQUIRED"

  PUBLISHED=$(body_read_published) \
    || body_refuse "the published body could not be read back over REST" "$REQUIRED"
  PUBLISHED=$(body_trim_tail "$PUBLISHED")

  case "$PUBLISHED" in
    *"$REQUIRED") ;;
    *)
      BODY_TMP=$(mktemp "$STATE/.fm-pr-body.XXXXXX") || exit 1
      if [ -n "$PUBLISHED" ]; then
        printf '%s\n\n%s\n' "$PUBLISHED" "$REQUIRED" > "$BODY_TMP" || exit 1
      else
        printf '%s\n' "$REQUIRED" > "$BODY_TMP" || exit 1
      fi
      forge_audit pr-body-append "$ID" "$URL" || exit 1
      # -F body=@- keeps a body of any length off argv.
      gh api --method PATCH "repos/$OWNER/$REPO/pulls/$NUMBER" -F body=@- --silent \
        < "$BODY_TMP" >/dev/null 2>&1 \
        || body_refuse "the forge refused the body update" "$REQUIRED"
      rm -f -- "$BODY_TMP"
      BODY_TMP=
      # The only evidence that counts: what the forge publishes, read back over
      # REST rather than assumed from the update just sent.
      PUBLISHED=$(body_read_published) \
        || body_refuse "the published body could not be read back over REST after the update" "$REQUIRED"
      PUBLISHED=$(body_trim_tail "$PUBLISHED")
      case "$PUBLISHED" in
        *"$REQUIRED") ;;
        *) body_refuse "the published body still does not end with it after the update" "$REQUIRED" ;;
      esac
      ;;
  esac
fi

META_TMP=
META_LOCK=
META_LOCK_HELD=0
pr_check_cleanup() {
  fm_pr_poll_cleanup
  [ -z "$META_TMP" ] || rm -f -- "$META_TMP"
  if [ "$META_LOCK_HELD" = 1 ]; then
    fm_lock_release "$META_LOCK" || true
    META_LOCK_HELD=0
  fi
}
trap pr_check_cleanup EXIT
trap 'exit 1' HUP INT TERM
fm_pr_poll_prepare "$STATE" "$ID" "$PROVIDER" "$URL" "$HOST" "$PROJECT_PATH" "$NUMBER" "$SCRIPT_DIR/fm-pr-poll.sh" \
  || { echo "error: could not prepare PR poll" >&2; exit 1; }

META_LOCK=$(fm_meta_lock_path "$META") || exit 1
fm_lock_acquire_wait "$META_LOCK"
META_LOCK_HELD=1
[ -f "$META" ] && [ ! -L "$META" ] && [ "$(fm_pr_file_link_count "$META")" = 1 ] \
  || { echo "error: task metadata is unavailable" >&2; exit 1; }
META_DEVICE=$(fm_pr_file_device "$META") || exit 1
STATE_DEVICE=$(fm_pr_file_device "$STATE") || exit 1
[ "$META_DEVICE" = "$STATE_DEVICE" ] || { echo "error: task metadata is unavailable" >&2; exit 1; }
META_TMP=$(mktemp "$STATE/.fm-pr-meta.XXXXXX") || exit 1
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    pr=*|pr_head=*) ;;
    *) printf '%s\n' "$line" >> "$META_TMP" || exit 1 ;;
  esac
done < "$META"
printf 'pr=%s\n' "$URL" >> "$META_TMP" || exit 1
[ -z "$PR_HEAD" ] || printf 'pr_head=%s\n' "$PR_HEAD" >> "$META_TMP" || exit 1
chmod 0600 "$META_TMP" || exit 1
fm_pr_private_file_valid "$META_TMP" 600 "$STATE_DEVICE" || exit 1
fm_pr_metadata_identity_parse "$META_TMP" || exit 1
[ "$FM_PR_META_PROVIDER" = "$PROVIDER" ] && [ "$FM_PR_META_URL" = "$URL" ] \
  && [ "$FM_PR_META_HOST" = "$HOST" ] && [ "$FM_PR_META_PATH" = "$PROJECT_PATH" ] \
  && [ "$FM_PR_META_NUMBER" = "$NUMBER" ] || exit 1
fm_pr_regular_destination_on_device_or_absent "$META" "$STATE_DEVICE" || exit 1
mv -f -- "$META_TMP" "$META" || exit 1
META_TMP=
fm_pr_private_file_valid "$META" 600 "$STATE_DEVICE" || exit 1
fm_pr_metadata_identity_parse "$META" || exit 1
[ "$FM_PR_META_PROVIDER" = "$PROVIDER" ] && [ "$FM_PR_META_URL" = "$URL" ] \
  && [ "$FM_PR_META_HOST" = "$HOST" ] && [ "$FM_PR_META_PATH" = "$PROJECT_PATH" ] \
  && [ "$FM_PR_META_NUMBER" = "$NUMBER" ] || exit 1
fm_lock_release "$META_LOCK"
META_LOCK_HELD=0

fm_pr_poll_publish_prepared || {
  echo "error: could not publish PR poll" >&2
  exit 1
}
printf 'armed: state/%s.check.sh\n' "$ID"
