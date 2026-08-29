#!/usr/bin/env bash
# Regression tests for the declared pull request body contract: content a brief
# declares as required reaches the PUBLISHED body, verified by reading that body
# back from the forge over REST, and a declaration that cannot be published
# refuses loudly instead of shipping a quietly incomplete body.
# The body update is an outbound forge write, so it is also audited through
# bin/fm-forge-audit-lib.sh.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BRIEF="$ROOT/bin/fm-brief.sh"
PR_CHECK="$ROOT/bin/fm-pr-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-body-required)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

DISCLOSURE='This pull request was produced with AI assistance, as this repository requires.'
PIPELINE_BODY='## Summary

Adds the thing.

## Quality report

- review: passed
- tests: passed'

# A home with a fake forge whose published body is a real file, so every
# assertion below reads what the forge would serve rather than what was sent.
make_case() {  # <name>
  local dir="$TMP_ROOT/$1" fakebin
  fakebin="$dir/fakebin"
  mkdir -p "$dir/home/state" "$dir/home/data/task-a" "$dir/wt" "$fakebin" "$dir/root/bin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$dir/root/bin/fm-guard.sh"
  chmod +x "$dir/root/bin/fm-guard.sh"
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_LOG"
case " $* " in
  *" --jq .head.sha "*)
    printf '%s\n' 0123456789abcdef0123456789abcdef01234567
    exit 0
    ;;
  *" --method PATCH "*)
    sent=$(cat)
    [ "${FM_TEST_GH_PATCH_FAIL:-0}" = 0 ] || exit 1
    # A forge that accepts the request and publishes something else is the
    # exact failure a local check cannot see.
    [ "${FM_TEST_GH_PATCH_DROP:-0}" = 0 ] || exit 0
    printf '%s' "$sent" > "$FM_TEST_PR_BODY"
    exit 0
    ;;
  *" --jq "*".body"*)
    [ "${FM_TEST_GH_GET_FAIL:-0}" = 0 ] || exit 1
    cat "$FM_TEST_PR_BODY"
    exit 0
    ;;
esac
exit 0
SH
  # Only the GitLab arming precondition needs this; it never publishes a body.
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fakebin/glab"
  chmod +x "$fakebin/gh" "$fakebin/glab"
  : > "$dir/gh.log"
  printf '%s\n' "$PIPELINE_BODY" > "$dir/published-body"
  fm_write_meta "$dir/home/state/task-a.meta" \
    "window=firstmate:fm-task-a" \
    "endpoint_task_id=task-a" \
    "worktree=$dir/wt" \
    "kind=ship" \
    "mode=no-mistakes"
  printf '%s\n' "$dir"
}

declare_body() {  # <dir> <content>
  printf '%s\n' "$2" > "$1/home/data/task-a/pr-body-required.md"
}

# Every case uses the task id task-a; this wrapper keeps the call sites short.
run_task_check() {  # <dir> [pr-url]
  local dir=$1 url=${2:-https://github.com/o/r/pull/10}
  FM_ROOT_OVERRIDE="$dir/root" FM_HOME="$dir/home" \
    FM_TEST_GH_LOG="$dir/gh.log" FM_TEST_PR_BODY="$dir/published-body" \
    PATH="$dir/fakebin:$BASE_PATH" \
    "$PR_CHECK" task-a "$url" > "$dir/check.out" 2> "$dir/check.err"
}

patch_calls() {  # <dir>
  grep -c -- '--method PATCH' "$1/gh.log" || true
}

body_reads() {  # <dir>
  grep -c -- '--jq .body' "$1/gh.log" || true
}

test_declared_content_is_published_as_the_last_line() {
  local dir
  dir=$(make_case declared-placed)
  declare_body "$dir" "$DISCLOSURE"

  run_task_check "$dir" || fail "the PR check refused a publishable declaration: $(cat "$dir/check.err")"

  [ "$(tail -n 1 "$dir/published-body")" = "$DISCLOSURE" ] \
    || fail "the declared sentence is not the published body's last line: $(cat "$dir/published-body")"
  assert_grep 'Quality report' "$dir/published-body" "the pipeline's own body was lost"
  [ "$(patch_calls "$dir")" = 1 ] || fail "expected exactly one published body update"
  # One read before the update and one after it: the second is the evidence.
  [ "$(body_reads "$dir")" = 2 ] || fail "the published body was not read back after the update"
  assert_grep 'action=pr-body-append' "$dir/home/state/forge-write-audit.log" \
    "the body update was not recorded in the forge write audit log"
  assert_grep 'pr=https://github.com/o/r/pull/10' "$dir/home/state/task-a.meta" \
    "the task did not record its PR after the body was published"
  [ -f "$dir/home/state/task-a.check.sh" ] || fail "the merge poll was not armed"
  pass "declared body content is published as the body's last line and read back over REST"
}

test_nothing_declared_leaves_the_published_body_untouched() {
  local dir before after
  dir=$(make_case none-unchanged)
  before=$(shasum -a 256 "$dir/published-body" | awk '{print $1}')

  run_task_check "$dir" || fail "the PR check refused a task with no declaration: $(cat "$dir/check.err")"

  after=$(shasum -a 256 "$dir/published-body" | awk '{print $1}')
  [ "$before" = "$after" ] || fail "an undeclared task's published body changed"
  [ "$(patch_calls "$dir")" = 0 ] || fail "an undeclared task updated the published body"
  [ "$(body_reads "$dir")" = 0 ] || fail "an undeclared task read the published body"
  pass "a task that declares nothing leaves the published body byte-identical"
}

test_content_already_last_is_not_appended_twice() {
  local dir
  dir=$(make_case declared-idempotent)
  declare_body "$dir" "$DISCLOSURE"
  printf '%s\n\n%s\n' "$PIPELINE_BODY" "$DISCLOSURE" > "$dir/published-body"

  run_task_check "$dir" || fail "the PR check refused an already-compliant body: $(cat "$dir/check.err")"

  [ "$(patch_calls "$dir")" = 0 ] || fail "an already-compliant body was updated again"
  [ "$(grep -c "$DISCLOSURE" "$dir/published-body")" = 1 ] \
    || fail "the declared sentence was duplicated in the published body"
  pass "a body that already ends with the declared content is left alone"
}

assert_refused() {  # <dir> <case-name>
  local dir=$1 name=$2
  assert_grep 'error: task task-a declares required pull request body content' "$dir/check.err" \
    "$name did not name the task in its refusal"
  assert_grep "$DISCLOSURE" "$dir/check.err" "$name did not name the content it could not carry"
  assert_no_grep 'pr=' "$dir/home/state/task-a.meta" "$name recorded a PR anyway"
  [ ! -e "$dir/home/state/task-a.check.sh" ] || fail "$name armed a merge poll anyway"
}

test_a_refused_update_stops_the_task_and_names_the_content() {
  local dir
  dir=$(make_case declared-refused)
  declare_body "$dir" "$DISCLOSURE"

  FM_TEST_GH_PATCH_FAIL=1 run_task_check "$dir" && fail "a refused body update reported success"
  assert_refused "$dir" "a refused body update"
  pass "a forge that refuses the body update stops the task and names the content"
}

test_a_dropped_update_is_caught_by_the_read_back() {
  local dir
  dir=$(make_case declared-dropped)
  declare_body "$dir" "$DISCLOSURE"

  # The forge accepts the update and publishes the old body: only the read-back
  # can see it, which is why the read-back is the contract.
  FM_TEST_GH_PATCH_DROP=1 run_task_check "$dir" && fail "a silently dropped body update reported success"
  assert_refused "$dir" "a silently dropped body update"
  assert_grep 'still does not end with it' "$dir/check.err" \
    "the refusal did not come from the read-back"
  pass "a body update the forge silently drops is caught by the REST read-back"
}

test_an_unreadable_body_refuses_rather_than_assumes() {
  local dir
  dir=$(make_case declared-unreadable)
  declare_body "$dir" "$DISCLOSURE"

  FM_TEST_GH_GET_FAIL=1 run_task_check "$dir" && fail "an unreadable published body reported success"
  assert_refused "$dir" "an unreadable published body"
  pass "a published body that cannot be read refuses instead of assuming it is compliant"
}

test_a_forge_without_a_supported_body_write_refuses() {
  local dir
  dir=$(make_case declared-gitlab)
  declare_body "$dir" "$DISCLOSURE"

  run_task_check "$dir" https://gitlab.com/g/p/-/merge_requests/7 \
    && fail "a merge request with declared body content reported success"
  assert_refused "$dir" "a merge request with declared body content"
  pass "a forge whose body write is unimplemented refuses instead of dropping the content"
}

test_the_brief_declares_the_content_and_tells_the_worker_to_leave_it_alone() {
  local dir out
  dir="$TMP_ROOT/brief"
  mkdir -p "$dir/data" "$dir/state"
  printf '%s\n' "$DISCLOSURE" > "$dir/disclosure.txt"

  out=$(FM_DATA_OVERRIDE="$dir/data" FM_STATE_OVERRIDE="$dir/state" \
    "$BRIEF" task-a demo --mode no-mistakes --pr-body-required "$dir/disclosure.txt" 2>&1) \
    || fail "the brief refused a valid declaration: $out"
  assert_grep "$DISCLOSURE" "$dir/data/task-a/pr-body-required.md" \
    "the declaration was not stored for the publication gate"
  assert_grep 'PUBLISHED pull request body must END with' "$dir/data/task-a/brief.md" \
    "the brief does not state the declared body requirement"
  assert_grep 'Do not write it into the body' "$dir/data/task-a/brief.md" \
    "the brief does not stop the worker hand-writing the content"
  pass "a declaring brief stores the content and tells the worker not to hand-write it"
}

test_a_declaration_is_refused_where_no_body_is_published() {
  local dir out
  dir="$TMP_ROOT/brief-refusals"
  mkdir -p "$dir/data" "$dir/state"
  printf '%s\n' "$DISCLOSURE" > "$dir/disclosure.txt"
  : > "$dir/blank.txt"

  out=$(FM_DATA_OVERRIDE="$dir/data" FM_STATE_OVERRIDE="$dir/state" \
    "$BRIEF" task-local demo --mode local-only --pr-body-required "$dir/disclosure.txt" 2>&1) \
    && fail "a local-only brief accepted declared body content"
  assert_contains "$out" 'publishes a PR' "the local-only refusal did not name the reason"
  [ ! -e "$dir/data/task-local" ] || fail "the refused local-only brief left task files behind"

  out=$(FM_DATA_OVERRIDE="$dir/data" FM_STATE_OVERRIDE="$dir/state" \
    "$BRIEF" task-scout demo --scout --pr-body-required "$dir/disclosure.txt" 2>&1) \
    && fail "a scout brief accepted declared body content"

  out=$(FM_DATA_OVERRIDE="$dir/data" FM_STATE_OVERRIDE="$dir/state" \
    "$BRIEF" task-blank demo --mode no-mistakes --pr-body-required "$dir/blank.txt" 2>&1) \
    && fail "a blank declaration file was accepted"
  assert_contains "$out" 'blank' "the blank-declaration refusal did not name the reason"
  pass "a declaration is refused where no body is published and when it carries nothing"
}

test_declared_content_is_published_as_the_last_line
test_nothing_declared_leaves_the_published_body_untouched
test_content_already_last_is_not_appended_twice
test_a_refused_update_stops_the_task_and_names_the_content
test_a_dropped_update_is_caught_by_the_read_back
test_an_unreadable_body_refuses_rather_than_assumes
test_a_forge_without_a_supported_body_write_refuses
test_the_brief_declares_the_content_and_tells_the_worker_to_leave_it_alone
test_a_declaration_is_refused_where_no_body_is_published
