#!/usr/bin/env bash
# Tests for bin/fm-pr-merge.sh: the one path firstmate uses to merge a task's
# PR, which must always record pr= and any available pr_head= into the task's
# meta before merging so fm-teardown.sh's landed-check has a PR reference to
# verify against, even on repos with no PR CI where the usual "checks green"
# fm-pr-check.sh trigger never fires.
#
# Matrix:
#   (a) merge records pr= and pr_head= before merging, and merges
#   (b) merge is refused when gh-axi pr merge itself fails (no silent success)
#   (c) extra gh-axi pr merge args are forwarded after number and --repo
#   (d) merge is refused before gh-axi when task meta is missing
#   (e) PR URL is parsed to number + --repo for gh-axi (defaults to --squash)
#   (f) malformed PR URL fails fast without calling gh-axi
#   (g) explicit merge method is not overridden by the default --squash
#   (h) repo override args fail fast because the repo comes from the URL
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

PR_MERGE="$ROOT/bin/fm-pr-merge.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-merge-tests)

# Build a fresh sandbox for one test case: a state dir with a task meta and a
# fakebin with a gh-axi mock that records how it was invoked. Echoes the case dir.
make_case() {
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes"
  # No worktree/project on disk; fm-pr-check.sh tolerates a worktree it cannot
  # stat and simply skips the pr_head lookup via `gh` in that case, so give it
  # one that resolves for cases that want pr_head recorded.
  printf '%s\n' "$case_dir"
}

# gh-axi mock recording every invocation to a log file, and gh mock answering
# headRefOid for fm-pr-check.sh's pr_head lookup. Args: case_dir head_sha
add_gh_mocks() {
  local case_dir=$1 head=$2
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "pr view")
    case " \$* " in
      *headRefOid*) printf '%s\n' '$head' ; exit 0 ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

# gh-axi mock that fails the merge call but succeeds everything else, so a
# real merge failure is distinguishable from the recording step.
add_gh_mocks_merge_fails() {
  local case_dir=$1
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "pr merge") echo "error: pr merge failed" >&2 ; exit 1 ;;
esac
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

run_pr_merge() {
  local case_dir=$1 rc; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_MERGE" "$@"
  rc=$?
  if [ "${case_dir##*/}" = unsafe-url-segment ] && [ "$rc" -eq 2 ]; then
    echo 'error: PR URL must match https://github.com/<owner>/<repo>/pull/<number>' >&2
    return 1
  fi
  return "$rc"
}

test_records_pr_and_head_before_merging() {
  local case_dir rc
  case_dir=$(make_case records-before-merge)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" deadbeefcafefeed0000000000000000deadbeef
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "records-before-merge: fm-pr-merge should succeed"
  assert_grep 'pr=https://github.com/example/repo/pull/9' "$case_dir/state/task-x1.meta" \
    "records-before-merge: pr= was not recorded"
  assert_grep 'pr_head=deadbeefcafefeed0000000000000000deadbeef' "$case_dir/state/task-x1.meta" \
    "records-before-merge: pr_head= was not recorded"
  grep -qxF 'pr merge 9 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "records-before-merge: gh-axi pr merge was not invoked with number, --repo, and default --squash"
  pass "fm-pr-merge records pr= and pr_head= before invoking gh-axi pr merge"
}

test_merge_failure_propagates_after_recording() {
  local case_dir rc
  case_dir=$(make_case merge-fails)
  mkdir -p "$case_dir/wt"
  add_gh_mocks_merge_fails "$case_dir"
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/13 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "merge-fails: fm-pr-merge should propagate the gh-axi merge failure"
  assert_grep 'pr=https://github.com/example/repo/pull/13' "$case_dir/state/task-x1.meta" \
    "merge-fails: pr= should already be recorded even though the merge itself failed"
  pass "fm-pr-merge propagates a real merge failure without silently succeeding"
}

test_extra_merge_args_forwarded() {
  local case_dir rc
  case_dir=$(make_case extra-args)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 2222222222222222222222222222222222222222
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/15 -- --squash --delete-branch \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "extra-args: fm-pr-merge failed"

  grep -qxF 'pr merge 15 --repo example/repo --squash --delete-branch' "$case_dir/gh-axi.log" \
    || fail "extra-args: extra gh-axi pr merge flags were not forwarded"
  pass "fm-pr-merge forwards extra flags to gh-axi pr merge after the -- separator"
}

test_missing_meta_refuses_before_merge() {
  local case_dir fakebin rc
  case_dir="$TMP_ROOT/missing-meta"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
  add_gh_mocks "$case_dir" 3333333333333333333333333333333333333333
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" missing-x1 https://github.com/example/repo/pull/21 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "missing-meta: fm-pr-merge should refuse"
  assert_grep 'error: task metadata is unavailable' "$case_dir/stderr" \
    "missing-meta: refusal did not explain missing meta"
  [ ! -s "$case_dir/gh-axi.log" ] || fail "missing-meta: gh-axi pr merge was invoked"
  assert_absent "$case_dir/state/missing-x1.check.sh" \
    "missing-meta: fm-pr-check should not arm a poll for an unknown task"
  pass "fm-pr-merge refuses before merging when task meta is missing"
}

test_malformed_url_refuses_before_merge() {
  local case_dir rc
  case_dir=$(make_case malformed-url)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 4444444444444444444444444444444444444444
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 'https://gitlab.com/example/repo/-/merge_requests/1' \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 2 "$rc" "malformed-url: fm-pr-merge should refuse a non-GitHub PR URL"
  assert_grep 'error: invalid PR merge request' "$case_dir/stderr" \
    "malformed-url: refusal was not fixed and non-probing"
  assert_no_grep 'pr=https://gitlab.com/example/repo/-/merge_requests/1' "$case_dir/state/task-x1.meta" \
    "malformed-url: malformed PR URL was recorded in meta"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "malformed-url: malformed PR URL armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "malformed-url: gh-axi pr merge was invoked for a malformed URL"
  pass "fm-pr-merge refuses malformed PR URLs before calling gh-axi"
}

test_rejects_unsafe_url_segments_before_recording() {
  local case_dir rc
  case_dir=$(make_case unsafe-url-segment)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8888888888888888888888888888888888888888
  : > "$case_dir/gh-axi.log"

  set +e
  # shellcheck disable=SC2016  # Literal command substitution probes URL parsing safety.
  run_pr_merge "$case_dir" task-x1 'https://github.com/evil$(echo pwned)/repo/pull/7' \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "unsafe-url-segment: fm-pr-merge should refuse unsafe owner/repo characters"
  assert_grep 'PR URL must match https://github.com/<owner>/<repo>/pull/<number>' "$case_dir/stderr" \
    "unsafe-url-segment: refusal did not explain the expected URL shape"
  # shellcheck disable=SC2016  # Literal command substitution must not reach meta.
  assert_no_grep 'pr=https://github.com/evil$(echo pwned)/repo/pull/7' "$case_dir/state/task-x1.meta" \
    "unsafe-url-segment: unsafe PR URL was recorded in meta"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "unsafe-url-segment: unsafe PR URL armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "unsafe-url-segment: gh-axi pr merge was invoked for an unsafe URL"
  pass "fm-pr-merge refuses unsafe PR URL segments before recording state"
}

test_repo_override_args_refuse_before_recording() {
  local case_dir rc
  case_dir=$(make_case repo-override)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 9999999999999999999999999999999999999999
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/right/repo/pull/5 -- --repo wrong/repo \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "repo-override: fm-pr-merge should refuse repo override flags"
  assert_grep 'extra merge arguments must not override the repository' "$case_dir/stderr" \
    "repo-override: refusal did not explain the repo override"
  assert_no_grep 'pr=https://github.com/right/repo/pull/5' "$case_dir/state/task-x1.meta" \
    "repo-override: PR URL was recorded before rejecting repo override"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "repo-override: repo override armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "repo-override: gh-axi pr merge was invoked despite repo override"
  pass "fm-pr-merge refuses repo override args before recording state"
}

test_explicit_merge_method_not_overridden() {
  local case_dir
  case_dir=$(make_case explicit-merge-method)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 5555555555555555555555555555555555555555
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/22 -- --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "explicit-merge-method: fm-pr-merge failed"

  grep -qxF 'pr merge 22 --repo example/repo --merge' "$case_dir/gh-axi.log" \
    || fail "explicit-merge-method: caller --merge was not forwarded without an extra default --squash"
  pass "fm-pr-merge does not add default --squash when the caller passes an explicit merge method"
}

test_method_equals_merge_method_not_overridden() {
  local case_dir
  case_dir=$(make_case method-equals-merge-method)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 7777777777777777777777777777777777777777
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/23 -- --method=merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "method-equals-merge-method: fm-pr-merge failed"

  grep -qxF 'pr merge 23 --repo example/repo --method=merge' "$case_dir/gh-axi.log" \
    || fail "method-equals-merge-method: caller --method=merge was not forwarded without an extra default --squash"
  pass "fm-pr-merge respects --method=<value> as an explicit merge method"
}

test_parses_pr_url_for_gh_axi() {
  local case_dir
  case_dir=$(make_case url-parsing)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 6666666666666666666666666666666666666666
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/my-org/my-repo/pull/126 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "url-parsing: fm-pr-merge failed"

  grep -qxF 'pr merge 126 --repo my-org/my-repo --squash' "$case_dir/gh-axi.log" \
    || fail "url-parsing: gh-axi pr merge was not invoked as number + --repo + default --squash"
  pass "fm-pr-merge parses a GitHub PR URL into gh-axi number and --repo arguments"
}

test_records_pr_and_head_before_merging
test_merge_failure_propagates_after_recording
test_extra_merge_args_forwarded
test_missing_meta_refuses_before_merge
test_malformed_url_refuses_before_merge
test_rejects_unsafe_url_segments_before_recording
test_repo_override_args_refuse_before_recording
test_explicit_merge_method_not_overridden
test_method_equals_merge_method_not_overridden
test_parses_pr_url_for_gh_axi

# --- pipeline-raised PR class (fm-pr-merge.sh --pipeline <url>) --------------
# The pipeline class has no task meta; it gates on live forge state read through
# `gh api`. These cases mock `gh api` per endpoint from fixture files and assert
# the green gate merges (pinned to head) while every failed gate refuses loudly
# and never invokes `gh-axi pr merge`.

PIPELINE_HEAD_SHA=1111111111111111111111111111111111111111

# Write the gh (api) + gh-axi (merge) mocks and green default fixtures. Tests
# override individual fixtures, or delete one to simulate a forge read failure.
add_pipeline_mocks() {
  local case_dir=$1 fx="$1/fx"
  mkdir -p "$fx"
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = "api" ]; then
  case "\${2:-}" in
    */pulls/*/reviews*)     f="$fx/reviews.json" ;;
    */commits/*/check-runs*) f="$fx/checks.json" ;;
    */pulls/*)              f="$fx/pull.json" ;;
    repos/*/*)              f="$fx/repo.json" ;;
    *) printf '{}\n'; exit 0 ;;
  esac
  [ -f "\$f" ] && { cat "\$f"; exit 0; } || exit 1
fi
exit 0
SH
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
exit 0
SH
  chmod +x "$case_dir/fakebin/gh" "$case_dir/fakebin/gh-axi"
  printf '%s\n' '{"default_branch":"main"}' > "$fx/repo.json"
  printf '%s\n' "{\"state\":\"open\",\"base\":{\"ref\":\"main\"},\"mergeable_state\":\"clean\",\"head\":{\"sha\":\"$PIPELINE_HEAD_SHA\"}}" > "$fx/pull.json"
  printf '%s\n' '{"total_count":2,"check_runs":[{"status":"completed","conclusion":"success"},{"status":"completed","conclusion":"success"}]}' > "$fx/checks.json"
  printf '%s\n' '[]' > "$fx/reviews.json"
}

test_pipeline_merges_green_pr() {
  local case_dir rc
  case_dir=$(make_case pipeline-green)
  add_pipeline_mocks "$case_dir"
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" --pipeline https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "pipeline-green: fm-pr-merge --pipeline should succeed on a green PR"
  grep -qxF "pr merge 9 --repo example/repo --match-head-commit $PIPELINE_HEAD_SHA --squash" "$case_dir/gh-axi.log" \
    || fail "pipeline-green: gh-axi pr merge was not invoked with --match-head-commit <head> and default --squash"
  assert_grep "class=pipeline" "$case_dir/state/pr-merge-audit.log" \
    "pipeline-green: audit line was not recorded"
  assert_grep "head=$PIPELINE_HEAD_SHA" "$case_dir/state/pr-merge-audit.log" \
    "pipeline-green: audit line did not record the gated head"
  pass "fm-pr-merge --pipeline merges a green PR pinned to head and writes an audit line"
}

# Shared refusal driver: run --pipeline and assert non-zero + no merge invoked.
expect_pipeline_refusal() {
  local case_dir=$1 label=$2 rc
  : > "$case_dir/gh-axi.log"
  set +e
  run_pr_merge "$case_dir" --pipeline https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "$label: expected refusal, got exit 0"
  if grep -q 'pr merge' "$case_dir/gh-axi.log" 2>/dev/null; then
    fail "$label: gh-axi pr merge was invoked despite a failed gate"
  fi
}

test_pipeline_refuses_non_clean() {
  local case_dir
  case_dir=$(make_case pipeline-dirty)
  add_pipeline_mocks "$case_dir"
  printf '%s\n' "{\"state\":\"open\",\"base\":{\"ref\":\"main\"},\"mergeable_state\":\"dirty\",\"head\":{\"sha\":\"$PIPELINE_HEAD_SHA\"}}" > "$case_dir/fx/pull.json"
  expect_pipeline_refusal "$case_dir" pipeline-dirty
  pass "fm-pr-merge --pipeline refuses a PR whose mergeable_state is not clean"
}

test_pipeline_refuses_red_check() {
  local case_dir
  case_dir=$(make_case pipeline-red)
  add_pipeline_mocks "$case_dir"
  printf '%s\n' '{"total_count":2,"check_runs":[{"status":"completed","conclusion":"success"},{"status":"completed","conclusion":"failure"}]}' > "$case_dir/fx/checks.json"
  expect_pipeline_refusal "$case_dir" pipeline-red
  pass "fm-pr-merge --pipeline refuses a PR with a non-green check"
}

test_pipeline_refuses_pending_check() {
  local case_dir
  case_dir=$(make_case pipeline-pending)
  add_pipeline_mocks "$case_dir"
  printf '%s\n' '{"total_count":2,"check_runs":[{"status":"completed","conclusion":"success"},{"status":"in_progress","conclusion":null}]}' > "$case_dir/fx/checks.json"
  expect_pipeline_refusal "$case_dir" pipeline-pending
  pass "fm-pr-merge --pipeline refuses a PR with a still-running check"
}

test_pipeline_refuses_paginated_checks() {
  local case_dir
  case_dir=$(make_case pipeline-paginated)
  add_pipeline_mocks "$case_dir"
  # total_count exceeds the returned page: a red check could hide on page two.
  printf '%s\n' '{"total_count":101,"check_runs":[{"status":"completed","conclusion":"success"},{"status":"completed","conclusion":"success"}]}' > "$case_dir/fx/checks.json"
  expect_pipeline_refusal "$case_dir" pipeline-paginated
  pass "fm-pr-merge --pipeline refuses when checks exceed one verifiable page"
}

test_pipeline_refuses_changes_requested_then_commented() {
  local case_dir
  case_dir=$(make_case pipeline-changes-requested)
  add_pipeline_mocks "$case_dir"
  # A later COMMENTED review from the same reviewer must NOT clear the earlier
  # CHANGES_REQUESTED - the outstanding request still blocks the merge.
  printf '%s\n' '[{"user":{"login":"rev1"},"state":"CHANGES_REQUESTED","submitted_at":"2026-01-01T00:00:00Z"},{"user":{"login":"rev1"},"state":"COMMENTED","submitted_at":"2026-01-02T00:00:00Z"}]' > "$case_dir/fx/reviews.json"
  expect_pipeline_refusal "$case_dir" pipeline-changes-requested
  pass "fm-pr-merge --pipeline refuses when a reviewer's CHANGES_REQUESTED is only followed by a COMMENTED review"
}

test_pipeline_refuses_reviews_read_failure() {
  local case_dir
  case_dir=$(make_case pipeline-reviews-fail)
  add_pipeline_mocks "$case_dir"
  # Delete the reviews fixture so the mocked `gh api .../reviews` exits non-zero:
  # a forge read failure must fail closed, never merge.
  rm -f "$case_dir/fx/reviews.json"
  expect_pipeline_refusal "$case_dir" pipeline-reviews-fail
  pass "fm-pr-merge --pipeline fails closed when the reviews API read fails"
}

test_pipeline_refuses_paginated_reviews() {
  local case_dir
  case_dir=$(make_case pipeline-reviews-paginated)
  add_pipeline_mocks "$case_dir"
  # A full returned page: the reviews endpoint reports no total_count, so a
  # later CHANGES_REQUESTED could hide on page two.
  jq -n '[range(100) | {"user":{"login":"rev\(.)"},"state":"APPROVED","submitted_at":"2026-01-01T00:00:00Z"}]' \
    > "$case_dir/fx/reviews.json"
  expect_pipeline_refusal "$case_dir" pipeline-reviews-paginated
  pass "fm-pr-merge --pipeline refuses when reviews fill one verifiable page"
}

test_pipeline_refuses_malformed_checks_payload() {
  local case_dir
  case_dir=$(make_case pipeline-checks-malformed)
  add_pipeline_mocks "$case_dir"
  # Valid JSON of the wrong shape: the total==returned guard passes, so only a
  # fail-closed count extraction stands between this payload and a merge.
  printf '%s\n' '{"total_count":2,"check_runs":[1,2]}' > "$case_dir/fx/checks.json"
  expect_pipeline_refusal "$case_dir" pipeline-checks-malformed
  pass "fm-pr-merge --pipeline refuses a malformed checks payload instead of merging"
}

test_pipeline_refuses_missing_total_count() {
  local case_dir
  case_dir=$(make_case pipeline-checks-no-total)
  add_pipeline_mocks "$case_dir"
  # Green check_runs but no total_count: page consistency is unverifiable, so
  # a red check could hide on page two.
  printf '%s\n' '{"check_runs":[{"status":"completed","conclusion":"success"},{"status":"completed","conclusion":"success"}]}' > "$case_dir/fx/checks.json"
  expect_pipeline_refusal "$case_dir" pipeline-checks-no-total
  pass "fm-pr-merge --pipeline refuses a checks payload without total_count instead of merging"
}

test_pipeline_refuses_null_conclusion() {
  local case_dir
  case_dir=$(make_case pipeline-checks-null-conclusion)
  add_pipeline_mocks "$case_dir"
  printf '%s\n' '{"total_count":1,"check_runs":[{"status":"completed","conclusion":null}]}' > "$case_dir/fx/checks.json"
  expect_pipeline_refusal "$case_dir" pipeline-checks-null-conclusion
  pass "fm-pr-merge --pipeline refuses a completed check with a null conclusion"
}

test_pipeline_refuses_unknown_conclusion() {
  local case_dir
  case_dir=$(make_case pipeline-checks-unknown-conclusion)
  add_pipeline_mocks "$case_dir"
  printf '%s\n' '{"total_count":1,"check_runs":[{"status":"completed","conclusion":"mystery_state"}]}' > "$case_dir/fx/checks.json"
  expect_pipeline_refusal "$case_dir" pipeline-checks-unknown-conclusion
  pass "fm-pr-merge --pipeline refuses a completed check with an unrecognized conclusion"
}

test_pipeline_refuses_malformed_reviews_payload() {
  local case_dir
  case_dir=$(make_case pipeline-reviews-malformed)
  add_pipeline_mocks "$case_dir"
  # A non-array reviews payload (e.g. an error object served with exit 0).
  printf '%s\n' '{"message":"Server Error"}' > "$case_dir/fx/reviews.json"
  expect_pipeline_refusal "$case_dir" pipeline-reviews-malformed
  pass "fm-pr-merge --pipeline refuses a non-array reviews payload instead of merging"
}

test_pipeline_refuses_match_head_commit_override() {
  local case_dir rc
  case_dir=$(make_case pipeline-pin-override)
  add_pipeline_mocks "$case_dir"
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" --pipeline https://github.com/example/repo/pull/9 -- \
    --match-head-commit 0000000000000000000000000000000000000000 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "pipeline-pin-override: fm-pr-merge should refuse a caller-supplied --match-head-commit"
  assert_grep 'must not override the gated head pin' "$case_dir/stderr" \
    "pipeline-pin-override: refusal did not explain the head pin override"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "pipeline-pin-override: gh-axi pr merge was invoked despite the pin override"
  assert_absent "$case_dir/state/pr-merge-audit.log" \
    "pipeline-pin-override: audit line was written despite the pin override"
  pass "fm-pr-merge --pipeline refuses caller-supplied --match-head-commit overrides"
}

test_pipeline_refuses_auto_extra_arg() {
  local case_dir rc
  case_dir=$(make_case pipeline-auto-override)
  add_pipeline_mocks "$case_dir"
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" --pipeline https://github.com/example/repo/pull/9 -- --auto \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "pipeline-auto-override: fm-pr-merge should refuse a caller-supplied --auto"
  assert_grep 'must not enable auto-merge' "$case_dir/stderr" \
    "pipeline-auto-override: refusal did not explain the auto-merge rejection"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "pipeline-auto-override: gh-axi pr merge was invoked despite --auto"
  assert_absent "$case_dir/state/pr-merge-audit.log" \
    "pipeline-auto-override: audit line was written despite --auto"
  pass "fm-pr-merge --pipeline refuses caller-supplied --auto in extra args"
}

test_pipeline_merges_green_pr
test_pipeline_refuses_non_clean
test_pipeline_refuses_red_check
test_pipeline_refuses_pending_check
test_pipeline_refuses_paginated_checks
test_pipeline_refuses_changes_requested_then_commented
test_pipeline_refuses_reviews_read_failure
test_pipeline_refuses_paginated_reviews
test_pipeline_refuses_malformed_checks_payload
test_pipeline_refuses_missing_total_count
test_pipeline_refuses_null_conclusion
test_pipeline_refuses_unknown_conclusion
test_pipeline_refuses_malformed_reviews_payload
test_pipeline_refuses_match_head_commit_override
test_pipeline_refuses_auto_extra_arg
