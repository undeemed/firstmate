#!/usr/bin/env bash
# Tests for bin/fm-pr-merge.sh: the one path firstmate uses to merge a task's
# PR, which must always record pr= and any available pr_head= into the task's
# meta before merging so fm-teardown.sh's landed-check has a PR reference to
# verify against, even on repos with no PR CI where the usual "checks green"
# fm-pr-check.sh trigger never fires.
# The merge audit records these tests assert are written through
# bin/fm-forge-audit-lib.sh.
#
# Matrix:
#   (a) a verified merge records pr= and pr_head=
#   (b) merge is refused when gh-axi pr merge itself fails (no silent success)
#   (c) extra gh-axi pr merge args are forwarded after number and --repo
#   (d) merge is refused before gh-axi when task meta is missing
#   (e) PR URL is parsed to number + --repo for gh-axi (defaults to --squash)
#   (f) malformed PR URL fails fast without calling gh-axi
#   (g) explicit merge method is not overridden by the default --squash
#   (h) repo override args fail fast because the repo comes from the URL,
#       including a bundled short-option cluster that carries -R
#   (i) a GitLab MR URL resolves and merges through glab instead of erroring
#   (j) glab is addressed by the host from the URL, never an assumed one
#   (k) no merge method is imposed on GitLab, so the project's own one applies
#   (l) each pre-merge condition refuses independently, and all of them report
#   (m) a stale recorded pr_head= is reported and the live head is verified
#   (n) an unreadable merge request state refuses rather than merging blind
#   (o) glab or jq absent refuses before any state is recorded
#   (p) --sha in extra GitLab args fails fast, and still forwards on GitHub
#   (q) a GitLab refusal still leaves pr= recorded and the merge poll armed
#   (r) the implicit --squash default is refused on a stacked PR, naming the
#       counts it read live from REST, while a small PR still squashes, an
#       explicit method still wins, and GitLab is never consulted for counts
#   (s) every merge is recorded in the home's forge write audit log BEFORE the
#       forge is called, naming the home and the task, and the log states on
#       creation what it does not capture
#   (t) a forge write that cannot be recorded refuses the merge outright
#   (u) neither caller arguments nor the environment reach the audit log
#
# The forge mocks copy the audit log as they are invoked, so a case can assert
# what the log already held at the moment the forge was called.
#
#   (v1) GitHub success is accepted only after the PR is read back as merged
#   (s) an open GitHub PR that is neither merged nor queued fails verification
#   (t) a GitHub PR in the merge queue is reported as queued, not merged
#   (u) a queue-required refusal names the exact compatible retry flags
#   (v) a failed poll setup cannot be reported as a verified GitHub merge
#   (w) a zero-exit queue-required refusal keeps merge semantics unchanged
#   (x) an unreadable outcome after a successful merge call keeps the PR
#       recorded and the merge poll armed
#   (y) agreeing queue rules still produce exact retry flags
#   (z) conflicting queue rules report ambiguous retry guidance
#   (aa) gh-axi remains usable when gh is absent
#   (ab) a landed merge whose fallback outcome read fails keeps its poll armed
#   (ac) a successful merge in a secondmate home reports the landed PR upward
#       once, on the route its parent binding names, and a repeat merge of the
#       same PR does not duplicate that line
#   (ad) a refused or failed merge reports nothing
#   (ae) a successful merge in a main home leaves a durable wake naming the PR
#   (af) a secondmate home with no usable parent binding says so loudly instead
#       of merging in silence
#   (ag) an accepted queued GitHub merge emits nothing and leaves its poll armed
#   (ah) an accepted queued GitLab merge emits nothing and leaves its poll armed
#   (ai) an uncommitted marker retry never loses the durable outcome
#   (aj) distinct merged PRs for a reused task each survive queue deduplication
#   (ak) pr= is already recorded when the forge call that can land the merge runs
#   (al) a failed gh read falls back to the gh-axi view, which can prove a merge
#   (am) a failed merge command still names an outcome read that proves a landed
#       or queued pull request, without masking the forge failure
#   (an) a refusal after a zero-exit merge quotes the forge's own output, marked
#       apart from the wrapper's verdict and never leaked to stdout
#   (ao) a caller-requested auto-merge on a queue-less base refuses and says
#       auto-merge is armed with nothing merged or queued yet
#   (ap) a caller-requested auto-merge whose merge command failed refuses
#       without ever claiming auto-merge was armed
#   (aq) an outcome read that fails after a zero-exit merge still quotes the
#       forge's own output, the only evidence left
#   (ar) auto-merge with the queue's own method that is still unqueued refuses
#       without echoing back the flags just used, and names the next step
#   (as) a caller method the queue does not use still gets exact retry flags
#   (at) an unrecognised queue method still names the queue requirement and
#       guesses no method
#   (au) unreadable branch rules are reported apart from a queue-less base
#   (av) a base branch with no queue rule says nothing about a merge queue
#   (aw) a refusal built on the gh-axi view says the merge queue could not be
#       observed, and judges that view's state like the queue-aware one
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

PR_MERGE="$ROOT/bin/fm-pr-merge.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-merge-tests)
BASE_PATH=$PATH

# The GitLab fixture. A placeholder host that resolves nowhere, and a namespace
# deeper than one group, because a GitLab project has no owner/repository pair.
MR_HOST=gitlab.example
MR_PATH=group/subgroup/project
MR_PROJECT_URL="https://$MR_HOST/$MR_PATH"
MR_URL="$MR_PROJECT_URL/-/merge_requests/7"
MR_HEAD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
MR_STALE_HEAD=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

JQ_BIN=$(command -v jq) || fail "these tests read glab's JSON with the real jq, which was not found"
REAL_MV=$(command -v mv) || fail "these tests need mv to simulate a failed poll publish"

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
  printf '%s\n' \
    'state=MERGED' \
    'merged=true' \
    'queued=false' \
    'base=main' > "$case_dir/github-outcome"
  : > "$case_dir/github-rules"
  : > "$case_dir/gh.log"
  # No worktree/project on disk; fm-pr-check.sh tolerates a worktree it cannot
  # stat and simply skips the pr_head lookup via `gh` in that case, so give it
  # one that resolves for cases that want pr_head recorded.
  printf '%s\n' "$case_dir"
}

# write_pull_json <case_dir> [commits] [changed_files] [head_ref] [body]
# The REST pull payload the squash guard reads at merge time. The defaults
# describe an ordinary single-topic PR, which must still squash by default.
write_pull_json() {
  local case_dir=$1 commits=${2:-1} files=${3:-3} head_ref=${4:-fm/task-x1} body=${5:-}
  printf '{"commits":%s,"changed_files":%s,"head":{"ref":"%s"},"body":"%s"}\n' \
    "$commits" "$files" "$head_ref" "$body" > "$case_dir/pull.json"
}

# gh-axi mock recording every invocation to a log file, and gh mock answering
# the REST head read behind fm-pr-check.sh's pr_head lookup plus the REST pull
# payload the squash guard reads. GraphQL `gh pr view` is deliberately answered
# by nothing, so a return to it records no head at all. Every gh invocation is
# logged, so a test can prove the merge path added no GraphQL call. A
# gh-api-fails marker in the case dir makes the REST reads fail.
# Args: case_dir head_sha
add_gh_mocks() {
  local case_dir=$1 head=$2
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
[ -z "${FM_TEST_AUDIT_SNAPSHOT:-}" ] || cp "$FM_STATE_OVERRIDE/forge-write-audit.log" "$FM_TEST_AUDIT_SNAPSHOT" 2>/dev/null || :
case "${1:-} ${2:-}" in
  "pr merge") printf 'merged:\n  number: %s\n  status: ok\n' "${3:-}" ;;
  "pr view")
    [ "$#" -eq 5 ] && [ "${4:-}" = --repo ] || exit 2
    printf 'pull_request:\n  number: %s\n  state: %s\n' "$3" "${FM_TEST_GH_MERGE_STATE:-merged}"
    ;;
esac
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\$FM_TEST_GH_LOG"
if [ "\${1:-}" = api ]; then
  case " \$* " in
    *" --jq .head.sha "*)
      [ ! -e "$case_dir/gh-api-fails" ] || exit 1
      printf '%s\n' '$head'
      exit 0
      ;;
  esac
  case "\${2:-}" in
    */pulls/*)
      [ ! -e "$case_dir/gh-api-fails" ] || exit 1
      cat "$case_dir/pull.json"
      exit 0
      ;;
  esac
fi
case "\${1:-} \${2:-}" in
  "pr view")
    case " \$* " in
      *headRefOid*) printf '%s\n' '$head' ; exit 0 ;;
    esac
    ;;
  "api graphql")
    cat "\$FM_TEST_GH_OUTCOME"
    exit 0
    ;;
  api\ *)
    cat "\$FM_TEST_GH_RULES"
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
  : > "$case_dir/gh.log"
  write_pull_json "$case_dir"
}

# gh-axi mock that fails the merge call but succeeds everything else, so a
# real merge failure is distinguishable from the recording step.
add_gh_mocks_merge_fails() {
  local case_dir=$1
  add_gh_mocks "$case_dir" cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "pr merge") echo "error: pr merge failed" >&2 ; exit 1 ;;
  esac
  exit 0
SH
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\$FM_TEST_GH_LOG"
if [ "\${1:-}" = api ]; then
  case " \$* " in
    *" --jq .head.sha "*) printf '%s\n' cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd; exit 0 ;;
  esac
  case "\${2:-}" in
    */pulls/*) [ ! -f "$case_dir/pull.json" ] || { cat "$case_dir/pull.json"; exit 0; } ;;
  esac
fi
case "\${1:-} \${2:-}" in
  "api graphql")
    cat "\$FM_TEST_GH_OUTCOME"
    exit 0
    ;;
  api\ *)
    cat "\$FM_TEST_GH_RULES"
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

# gh mock that still answers fm-pr-check.sh's head lookup but cannot answer the
# outcome read, so a merge call that returned success is followed by a live
# state nothing can prove. Args: case_dir head_sha
add_gh_mock_outcome_read_fails() {
  local case_dir=$1 head=$2
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\$FM_TEST_GH_LOG"
if [ "\${1:-}" = api ]; then
  case " \$* " in
    *" --jq .head.sha "*) printf '%s\n' '$head'; exit 0 ;;
  esac
  case "\${2:-}" in
    */pulls/*) [ ! -f "$case_dir/pull.json" ] || { cat "$case_dir/pull.json"; exit 0; } ;;
  esac
fi
case "\${1:-} \${2:-}" in
  "pr view")
    case " \$* " in
      *headRefOid*) printf '%s\n' '$head' ; exit 0 ;;
    esac
    ;;
  "api graphql")
    echo 'error: could not reach the GitHub API' >&2
    exit 1
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh"
}

# gh-axi mock that merges but cannot answer its own view, so a case can prove
# what happens when neither reader can establish the outcome. Args: case_dir
add_gh_axi_mock_view_fails() {
  local case_dir=$1
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "pr merge") printf 'merged:\n  number: %s\n  status: ok\n' "${3:-}" ;;
  "pr view") exit 1 ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi"
}

add_failing_poll_publish_mv() {
  local case_dir=$1
  cat > "$case_dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in
    */.fm-pr-poll-data.*) exit 1 ;;
  esac
done
exec "$FM_TEST_REAL_MV" "$@"
SH
  chmod +x "$case_dir/fakebin/mv"
}

# glab mock recording every invocation together with the GITLAB_HOST it was
# given, so a test can prove the instance came from the URL. `mr view` answers
# from the case's JSON payload; marker files in the case dir drive the failure
# modes, so no test has to leak environment into a shared runner.
add_glab_mock() {
  local case_dir=$1
  cat > "$case_dir/fakebin/glab" <<'SH'
#!/usr/bin/env bash
printf 'GITLAB_HOST=%s %s\n' "${GITLAB_HOST-<unset>}" "$*" >> "$FM_TEST_GLAB_LOG"
case_dir=$(dirname "$FM_TEST_GLAB_JSON")
case "${1:-} ${2:-}" in
  "mr view")
    [ ! -e "$case_dir/glab-view-fails" ] || exit 1
    if [ -e "$case_dir/glab-merge-called" ] && [ ! -e "$case_dir/glab-stays-open" ]; then
      cat "$case_dir/mr-post.json"
    else
      cat "$FM_TEST_GLAB_JSON"
    fi
    exit 0
    ;;
  "mr merge")
    [ -z "${FM_TEST_AUDIT_SNAPSHOT:-}" ] || cp "$FM_STATE_OVERRIDE/forge-write-audit.log" "$FM_TEST_AUDIT_SNAPSHOT" 2>/dev/null || :
    [ ! -e "$case_dir/glab-merge-fails" ] || { echo "error: mr merge failed" >&2 ; exit 1 ; }
    : > "$case_dir/glab-merge-called"
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/glab"
  ln -sf "$JQ_BIN" "$case_dir/fakebin/jq"
}

# write_mr_json <file> [<field>=<value> ...]
# A merge request payload that satisfies every pre-merge condition, with the
# named fields overridden so one case drives exactly one condition. Values are
# written into the JSON as-is, so a value may carry a JSON escape.
write_mr_json() {
  local file=$1 kv key value
  local state=opened detail=mergeable conflicts=false discussions=true
  local head=$MR_HEAD pipeline_sha=$MR_HEAD pipeline_status=success pipeline=present
  shift
  for kv in "$@"; do
    key=${kv%%=*}
    value=${kv#*=}
    case "$key" in
      state) state=$value ;;
      detail) detail=$value ;;
      conflicts) conflicts=$value ;;
      discussions) discussions=$value ;;
      head) head=$value ;;
      pipeline_sha) pipeline_sha=$value ;;
      pipeline_status) pipeline_status=$value ;;
      pipeline) pipeline=$value ;;
      *) fail "write_mr_json: unknown field '$key'" ;;
    esac
  done
  if [ "$pipeline" = present ]; then
    pipeline=$(printf '{"sha":"%s","status":"%s"}' "$pipeline_sha" "$pipeline_status")
  fi
  printf '{"iid":7,"state":"%s","detailed_merge_status":"%s","has_conflicts":%s,' \
    "$state" "$detail" "$conflicts" > "$file"
  printf '"blocking_discussions_resolved":%s,"sha":"%s","head_pipeline":%s}\n' \
    "$discussions" "$head" "$pipeline" >> "$file"
}

# make_gitlab_case <name> [<field>=<value> ...]: a case dir with both forge
# mocks and a merge request payload. Echoes the case dir.
make_gitlab_case() {
  local name=$1 case_dir
  shift
  case_dir=$(make_case "$name")
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" cccccccccccccccccccccccccccccccccccccccc
  add_glab_mock "$case_dir"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/glab.log"
  write_mr_json "$case_dir/mr.json" "$@"
  write_mr_json "$case_dir/mr-post.json" state=merged
  printf '%s\n' "$case_dir"
}

# mirror_path_without <dir> <tool> [<bindir> ...]: the whole search path
# re-exposed by symlink except one tool, because a real copy anywhere on PATH
# would prove nothing. The named bindirs are mirrored ahead of the search path,
# so the case's own mocks answer for every tool that is not the omitted one and
# the refusal names that tool alone whatever the host happens to have installed.
mirror_path_without() {
  local dir=$1 omit=$2 search bindir entry name
  shift 2
  mkdir -p "$dir"
  search=$(printf '%s\n' "$@"; printf '%s\n' "$BASE_PATH" | tr ':' '\n')
  while IFS= read -r bindir; do
    [ -d "$bindir" ] || continue
    for entry in "$bindir"/*; do
      [ -e "$entry" ] || continue
      name=${entry##*/}
      [ "$name" = "$omit" ] && continue
      [ -e "$dir/$name" ] || ln -s "$entry" "$dir/$name" 2>/dev/null
    done
  done <<EOF
$search
EOF
  ! PATH="$dir" command -v "$omit" >/dev/null 2>&1 \
    || fail "the $omit-free search path still resolved $omit"
}

# The merge line glab was asked to run, so a test asserts one exact invocation
# rather than a substring of the whole log.
glab_merge_line() {
  grep -F ' mr merge ' "$1" || true
}

run_pr_merge() {
  local case_dir=$1 rc; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_HOME="${FM_TEST_HOME:-$case_dir}" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_TEST_AUDIT_SNAPSHOT="${FM_TEST_AUDIT_SNAPSHOT:-}" \
  FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
  FM_TEST_GH_LOG="$case_dir/gh.log" \
  FM_TEST_GH_OUTCOME="$case_dir/github-outcome" \
  FM_TEST_GH_RULES="$case_dir/github-rules" \
  FM_TEST_META_AT_MERGE="$case_dir/meta-at-merge" \
  FM_TEST_REAL_MV="$REAL_MV" \
  FM_TEST_GLAB_LOG="$case_dir/glab.log" \
  FM_TEST_GLAB_JSON="$case_dir/mr.json" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_MERGE" "$@"
  rc=$?
  if [ "${case_dir##*/}" = unsafe-url-segment ] && [ "$rc" -eq 2 ]; then
    echo 'error: PR URL must match https://github.com/<owner>/<repo>/pull/<number>' >&2
    return 1
  fi
  return "$rc"
}

write_github_outcome() {
  local case_dir=$1 state=$2 merged=$3 queued=$4 base=$5
  printf '%s\n' \
    "state=$state" \
    "merged=$merged" \
    "queued=$queued" \
    "base=$base" > "$case_dir/github-outcome"
}

test_verified_merge_records_pr_and_head() {
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
  assert_grep 'api repos/example/repo/pulls/9 --jq .head.sha' "$case_dir/gh.log" \
    "records-before-merge: pr_head= was not read from the REST pull request resource"
  assert_no_grep 'pr view' "$case_dir/gh.log" \
    "records-before-merge: the head was read with GraphQL gh pr view"
  # The one GraphQL call this path may make is the post-merge outcome read that
  # proves the pull request actually landed; the head itself stays on REST.
  [ "$(grep -c graphql "$case_dir/gh.log")" -le 1 ] \
    || fail "records-before-merge: an extra GraphQL call was introduced on the task merge path"
  grep -qxF 'pr merge 9 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "records-before-merge: gh-axi pr merge was not invoked with number, --repo, and default --squash"
  pass "fm-pr-merge records pr= and pr_head= for a verified GitHub merge"
}

# The forge call is the point of no return: once gh-axi has merged, nothing this
# script does afterwards can un-merge it. Proving pr= is already in the task's
# meta at that moment is what makes a later failure unable to lose the merge.
test_pr_metadata_is_recorded_before_the_forge_call() {
  local case_dir rc
  case_dir=$(make_case records-ahead-of-forge-call)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 5151515151515151515151515151515151515151
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "pr merge")
    cat "$FM_STATE_OVERRIDE/task-x1.meta" > "$FM_TEST_META_AT_MERGE"
    printf 'merged:\n  number: %s\n  status: ok\n' "${3:-}"
    ;;
  "pr view")
    printf 'pull_request:\n  number: %s\n  state: merged\n' "$3"
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/meta-at-merge"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/62 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "records-ahead-of-forge-call: fm-pr-merge should succeed"
  assert_grep 'pr merge 62 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    "records-ahead-of-forge-call: the merge abstraction was never invoked"
  assert_grep 'pr=https://github.com/example/repo/pull/62' "$case_dir/meta-at-merge" \
    "records-ahead-of-forge-call: the merge ran before pr= was recorded"
  pass "fm-pr-merge records pr= before the forge call can land the merge"
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

test_github_merged_outcome_is_verified() {
  local case_dir rc
  case_dir=$(make_case github-verified-merged)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 1010101010101010101010101010101010101010
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/51 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "github-verified-merged: a merged PR should succeed"
  assert_grep 'verified: https://github.com/example/repo/pull/51 is merged' \
    "$case_dir/stdout" "github-verified-merged: success was not reported as verified"
  assert_grep 'api graphql' "$case_dir/gh.log" \
    "github-verified-merged: the PR outcome was not read back after merging"
  pass "fm-pr-merge verifies a genuinely merged GitHub pull request"
}

test_github_verified_merge_requires_poll_recording() {
  local case_dir rc
  case_dir=$(make_case github-poll-recording-fails)
  add_gh_mocks "$case_dir" 1111111111111111111111111111111111111111
  add_failing_poll_publish_mv "$case_dir"
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/55 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-poll-recording-fails: poll setup failure should fail the merge wrapper"
  assert_grep 'error: could not publish PR poll' "$case_dir/stderr" \
    "github-poll-recording-fails: poll setup failure was not reported"
  assert_no_grep 'verified: ' "$case_dir/stdout" \
    "github-poll-recording-fails: failed poll setup was reported as a verified merge"
  assert_grep 'pr=https://github.com/example/repo/pull/55' "$case_dir/state/task-x1.meta" \
    "github-poll-recording-fails: metadata was not retained for the attempted merge"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "github-poll-recording-fails: the failed poll setup left a runnable poll"
  pass "fm-pr-merge refuses to claim a merge when poll recording fails"
}

test_github_open_unqueued_outcome_refuses() {
  local case_dir rc
  case_dir=$(make_case github-open-unqueued)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 2020202020202020202020202020202020202020
  write_github_outcome "$case_dir" OPEN false false master
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/52 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-open-unqueued: an unproved merge must fail"
  assert_grep 'state=OPEN, merged=false, isInMergeQueue=false' "$case_dir/stderr" \
    "github-open-unqueued: refusal did not name the concrete observed state"
  assert_grep 'pr=https://github.com/example/repo/pull/52' "$case_dir/state/task-x1.meta" \
    "github-open-unqueued: the attempted merge lost its PR reference"
  assert_present "$case_dir/state/task-x1.check.sh" \
    "github-open-unqueued: the attempted merge did not leave its poll armed"
  pass "fm-pr-merge refuses a GitHub merge call that leaves the PR open and unqueued"
}

test_github_unreadable_outcome_keeps_pr_bookkeeping() {
  local case_dir rc
  case_dir=$(make_case github-outcome-read-fails)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 3131313131313131313131313131313131313131
  add_gh_mock_outcome_read_fails "$case_dir" 3131313131313131313131313131313131313131
  add_gh_axi_mock_view_fails "$case_dir"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/57 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-outcome-read-fails: an unreadable outcome must fail"
  assert_grep 'could not read the GitHub pull request outcome after the merge attempt' \
    "$case_dir/stderr" "github-outcome-read-fails: the unreadable outcome was not reported"
  assert_grep 'the gh read failed and the gh-axi view could not prove the outcome either' \
    "$case_dir/stderr" "github-outcome-read-fails: the refusal did not name both failed reads"
  assert_no_grep 'verified: ' "$case_dir/stdout" \
    "github-outcome-read-fails: an unproved merge was reported as verified"
  # The merge call itself returned success, so the pull request may well have
  # landed. Losing the reference here would leave teardown with nothing to
  # verify against and no merge poll to catch up.
  assert_grep 'pr=https://github.com/example/repo/pull/57' "$case_dir/state/task-x1.meta" \
    "github-outcome-read-fails: a successful merge call lost its PR reference"
  assert_present "$case_dir/state/task-x1.check.sh" \
    "github-outcome-read-fails: no merge poll was armed for a merge that may have landed"
  pass "fm-pr-merge keeps PR bookkeeping when it cannot read a successful merge call's outcome"
}

test_github_refusal_quotes_the_forge_output() {
  local case_dir rc
  case_dir=$(make_case github-refusal-quotes-forge)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 6161616161616161616161616161616161616161
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "pr merge") echo "will be added to the merge queue when all requirements are met" ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi"
  write_github_outcome "$case_dir" OPEN false false main
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/65 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-refusal-quotes-forge: an unproved merge must fail"
  assert_grep 'error: > will be added to the merge queue when all requirements are met' \
    "$case_dir/stderr" \
    "github-refusal-quotes-forge: the forge's own explanation was discarded on the refusal"
  assert_grep "not this script's verdict" "$case_dir/stderr" \
    "github-refusal-quotes-forge: the forge's text was not marked as the forge's own"
  assert_grep 'error: GitHub merge outcome was not successful: state=OPEN, merged=false, isInMergeQueue=false' \
    "$case_dir/stderr" "github-refusal-quotes-forge: the wrapper's own verdict was lost"
  # A forge sentence about the merge queue must never stand on its own line, or
  # it reads as this script's verdict rather than as quoted forge output.
  ! grep -qxF 'will be added to the merge queue when all requirements are met' \
    "$case_dir/stderr" \
    || fail "github-refusal-quotes-forge: forge text was emitted as the wrapper's own line"
  assert_no_grep 'will be added to the merge queue' "$case_dir/stdout" \
    "github-refusal-quotes-forge: the forge's unverified report leaked to stdout"
  assert_no_grep 'verified: ' "$case_dir/stdout" \
    "github-refusal-quotes-forge: an unproved merge was reported as verified"
  pass "fm-pr-merge refuses with the forge's own output quoted apart from its verdict"
}

test_github_auto_merge_without_queue_refuses_legibly() {
  local case_dir rc spelling
  for spelling in --auto --auto=true; do
    case_dir=$(make_case "github-auto-no-queue${spelling#--auto}")
    mkdir -p "$case_dir/wt"
    add_gh_mocks "$case_dir" 7171717171717171717171717171717171717171
    write_github_outcome "$case_dir" OPEN false false main
    : > "$case_dir/github-rules"
    : > "$case_dir/gh-axi.log"
    : > "$case_dir/gh.log"

    set +e
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/66 \
      -- "$spelling" --merge \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e

    expect_code 1 "$rc" "github-auto-no-queue: an armed but unlanded auto-merge must still fail"
    assert_grep 'state=OPEN, merged=false, isInMergeQueue=false' "$case_dir/stderr" \
      "github-auto-no-queue: refusal did not name the concrete observed state"
    assert_grep 'auto-merge was requested and armed for https://github.com/example/repo/pull/66' \
      "$case_dir/stderr" "github-auto-no-queue: the refusal never explained the armed auto-merge"
    assert_grep 'nothing is merged or in the merge queue yet' "$case_dir/stderr" \
      "github-auto-no-queue: the refusal left the operator to infer the pending state"
    grep -qxF "pr merge 66 --repo example/repo $spelling --merge" "$case_dir/gh-axi.log" \
      || fail "github-auto-no-queue: the attempted merge was changed unexpectedly"
    [ "$(wc -l < "$case_dir/gh-axi.log" | tr -d '[:space:]')" = 1 ] \
      || fail "github-auto-no-queue: the wrapper attempted more than one merge"
    assert_grep 'pr=https://github.com/example/repo/pull/66' "$case_dir/state/task-x1.meta" \
      "github-auto-no-queue: the attempted merge lost its PR reference"
    assert_present "$case_dir/state/task-x1.check.sh" \
      "github-auto-no-queue: the attempted merge did not leave its poll armed"
  done
  pass "fm-pr-merge explains an armed auto-merge that landed nothing on a queue-less base"
}

test_github_failed_merge_never_claims_armed_auto_merge() {
  local case_dir rc
  case_dir=$(make_case github-auto-merge-command-fails)
  mkdir -p "$case_dir/wt"
  add_gh_mocks_merge_fails "$case_dir"
  write_github_outcome "$case_dir" OPEN false false main
  : > "$case_dir/github-rules"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/67 -- --auto --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-auto-merge-command-fails: the forge failure must still fail the wrapper"
  assert_grep 'error: pr merge failed' "$case_dir/stderr" \
    "github-auto-merge-command-fails: the original forge error was masked"
  assert_grep 'state=OPEN, merged=false, isInMergeQueue=false' "$case_dir/stderr" \
    "github-auto-merge-command-fails: refusal did not name the concrete observed state"
  assert_no_grep 'armed' "$case_dir/stderr" \
    "github-auto-merge-command-fails: a failed merge command was reported as an armed auto-merge"
  assert_grep 'auto-merge was requested for https://github.com/example/repo/pull/67' \
    "$case_dir/stderr" \
    "github-auto-merge-command-fails: the refusal never said auto-merge had only been requested"
  assert_no_grep 'verified: ' "$case_dir/stdout" \
    "github-auto-merge-command-fails: a failed merge command was reported as verified"
  pass "fm-pr-merge never reports auto-merge as armed when the merge command failed"
}

test_github_failed_merge_with_queue_flags_never_claims_acceptance() {
  local case_dir rc
  case_dir=$(make_case github-failed-merge-queue-flags)
  mkdir -p "$case_dir/wt"
  add_gh_mocks_merge_fails "$case_dir"
  write_github_outcome "$case_dir" OPEN false false main
  printf 'merge_method=MERGE\n' > "$case_dir/github-rules"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/74 -- --auto --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-failed-merge-queue-flags: the forge failure must still fail the wrapper"
  assert_grep 'error: pr merge failed' "$case_dir/stderr" \
    "github-failed-merge-queue-flags: the original forge error was masked"
  assert_grep 'state=OPEN, merged=false, isInMergeQueue=false' "$case_dir/stderr" \
    "github-failed-merge-queue-flags: refusal did not name the concrete observed state"
  assert_no_grep 'was accepted with the exact flags' "$case_dir/stderr" \
    "github-failed-merge-queue-flags: a failed merge command was reported as an accepted request"
  assert_no_grep 'armed' "$case_dir/stderr" \
    "github-failed-merge-queue-flags: a failed merge command was reported as an armed auto-merge"
  assert_grep 'base branch main requires the merge queue; retry with:' "$case_dir/stderr" \
    "github-failed-merge-queue-flags: the failed merge command lost its concrete retry guidance"
  assert_grep 'task-x1 https://github.com/example/repo/pull/74 -- --auto --merge' "$case_dir/stderr" \
    "github-failed-merge-queue-flags: the retry guidance named no queue flags"
  assert_no_grep 'verified: ' "$case_dir/stdout" \
    "github-failed-merge-queue-flags: a failed merge command was reported as verified"
  pass "fm-pr-merge claims no acceptance for a failed merge command carrying queue flags"
}

test_github_accepted_queue_flags_do_not_echo_back_the_same_command() {
  local case_dir rc
  case_dir=$(make_case github-accepted-queue-flags)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8181818181818181818181818181818181818181
  write_github_outcome "$case_dir" OPEN false false main
  printf 'merge_method=MERGE\n' > "$case_dir/github-rules"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/68 -- --auto --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-accepted-queue-flags: an unproved merge must still fail"
  assert_grep 'state=OPEN, merged=false, isInMergeQueue=false' "$case_dir/stderr" \
    "github-accepted-queue-flags: refusal did not name the concrete observed state"
  assert_grep 'this run refuses even though the request for https://github.com/example/repo/pull/68 was accepted with the exact flags base branch main requires (--auto --merge)' \
    "$case_dir/stderr" \
    "github-accepted-queue-flags: the refusal did not explain that the right flags were already used"
  assert_grep "re-check the pull request's merge queue state" "$case_dir/stderr" \
    "github-accepted-queue-flags: the refusal named no concrete next step"
  assert_no_grep 'retry with:' "$case_dir/stderr" \
    "github-accepted-queue-flags: the refusal echoed back the command that just refused"
  assert_no_grep 'verified: ' "$case_dir/stdout" \
    "github-accepted-queue-flags: an unproved merge was reported as verified"
  pass "fm-pr-merge does not echo back queue flags the caller already used"
}

test_github_mismatched_queue_flags_still_name_the_retry() {
  local case_dir rc
  case_dir=$(make_case github-mismatched-queue-flags)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8282828282828282828282828282828282828282
  write_github_outcome "$case_dir" OPEN false false main
  printf 'merge_method=REBASE\n' > "$case_dir/github-rules"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/69 -- --auto --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-mismatched-queue-flags: an unproved merge must still fail"
  assert_grep 'base branch main requires the merge queue; retry with:' "$case_dir/stderr" \
    "github-mismatched-queue-flags: a caller method the queue does not use lost its retry guidance"
  assert_grep '-- --auto --rebase' "$case_dir/stderr" \
    "github-mismatched-queue-flags: the exact compatible flags were not named"
  pass "fm-pr-merge still names retry flags when the caller used a different method"
}

test_github_unrecognised_queue_method_still_names_the_queue() {
  local case_dir rc
  case_dir=$(make_case github-unrecognised-queue-method)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8383838383838383838383838383838383838383
  write_github_outcome "$case_dir" OPEN false false main
  printf 'merge_method=FASTFORWARD\n' > "$case_dir/github-rules"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/70 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-unrecognised-queue-method: an unproved merge must fail"
  assert_grep 'base branch main requires the merge queue, but its configured merge method (FASTFORWARD) is not one this script recognises' \
    "$case_dir/stderr" \
    "github-unrecognised-queue-method: a readable queue rule produced no queue mention"
  assert_no_grep 'retry with:' "$case_dir/stderr" \
    "github-unrecognised-queue-method: retry flags were named for a method nothing recognises"
  assert_no_grep '--auto --' "$case_dir/stderr" \
    "github-unrecognised-queue-method: a merge method was guessed for the caller"
  pass "fm-pr-merge names the queue requirement even when its method is unrecognised"
}

test_github_unreadable_queue_rules_are_not_reported_as_no_queue() {
  local case_dir rc
  case_dir=$(make_case github-unreadable-queue-rules)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8484848484848484848484848484848484848484
  write_github_outcome "$case_dir" OPEN false false main
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\$FM_TEST_GH_LOG"
if [ "\${1:-}" = api ]; then
  case " \$* " in
    *" --jq .head.sha "*) printf '%s\n' 8484848484848484848484848484848484848484; exit 0 ;;
  esac
  case "\${2:-}" in
    */pulls/*) [ ! -f "$case_dir/pull.json" ] || { cat "$case_dir/pull.json"; exit 0; } ;;
  esac
fi
case "\${1:-} \${2:-}" in
  "pr view")
    case " \$* " in
      *headRefOid*) printf '%s\n' 8484848484848484848484848484848484848484 ; exit 0 ;;
    esac
    ;;
  "api graphql")
    cat "\$FM_TEST_GH_OUTCOME"
    exit 0
    ;;
  api\ *) exit 1 ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/71 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-unreadable-queue-rules: an unproved merge must fail"
  assert_grep 'the branch rules for base branch main could not be read' "$case_dir/stderr" \
    "github-unreadable-queue-rules: an unreadable rules response read like a queue-less base"
  assert_no_grep 'retry with:' "$case_dir/stderr" \
    "github-unreadable-queue-rules: retry flags were named from rules nothing could read"
  pass "fm-pr-merge distinguishes unreadable branch rules from a base with no merge queue"
}

test_github_no_queue_rule_says_nothing_about_a_queue() {
  local case_dir rc
  case_dir=$(make_case github-no-queue-rule)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8585858585858585858585858585858585858585
  write_github_outcome "$case_dir" OPEN false false main
  : > "$case_dir/github-rules"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/72 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-no-queue-rule: an unproved merge must fail"
  assert_grep 'state=OPEN, merged=false, isInMergeQueue=false' "$case_dir/stderr" \
    "github-no-queue-rule: refusal did not name the concrete observed state"
  assert_no_grep 'merge queue' "$case_dir/stderr" \
    "github-no-queue-rule: a base with no queue rule was told it requires the merge queue"
  pass "fm-pr-merge says nothing about a merge queue when the base branch has no queue rule"
}

test_github_fallback_view_refusal_says_the_queue_was_unobservable() {
  local case_dir ghless_path rc
  case_dir=$(make_case github-fallback-unobservable-queue)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8686868686868686868686868686868686868686
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "pr merge") printf 'merged:\n  number: %s\n  status: ok\n' "${3:-}" ;;
  "pr view") printf 'pull_request:\n  number: %s\n  state: open\n' "$3" ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi"
  rm "$case_dir/fakebin/gh"
  ghless_path="$case_dir/path-without-gh"
  mirror_path_without "$ghless_path" gh "$case_dir/fakebin"
  : > "$case_dir/gh-axi.log"

  set +e
  PATH="$ghless_path" run_pr_merge "$case_dir" task-x1 \
    https://github.com/example/repo/pull/73 -- --auto --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-fallback-unobservable-queue: an unproved merge must fail"
  assert_grep 'isInMergeQueue=unknown' "$case_dir/stderr" \
    "github-fallback-unobservable-queue: refusal did not name the concrete observed state"
  assert_grep 'the merge queue could not be observed for https://github.com/example/repo/pull/73' \
    "$case_dir/stderr" \
    "github-fallback-unobservable-queue: the refusal implied an unqueued PR it could not see"
  assert_grep "re-check the pull request's merge queue state" "$case_dir/stderr" \
    "github-fallback-unobservable-queue: the refusal named no concrete next step"
  # The lowercase state the fallback view reports must be judged the same way
  # the queue-aware read's uppercase enum is, or every explanation is skipped.
  assert_grep 'auto-merge was requested and armed for https://github.com/example/repo/pull/73' \
    "$case_dir/stderr" \
    "github-fallback-unobservable-queue: the fallback view's state skipped the auto-merge explanation"
  assert_no_grep 'verified: ' "$case_dir/stdout" \
    "github-fallback-unobservable-queue: an unproved merge was reported as verified"
  pass "fm-pr-merge says the merge queue was unobservable when only the gh-axi view answered"
}

test_github_unreadable_outcome_refusal_quotes_the_forge_output() {
  local case_dir rc
  case_dir=$(make_case github-unreadable-outcome-quotes-forge)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8787878787878787878787878787878787878787
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "pr merge") echo "will be added to the merge queue when all requirements are met" ;;
  "pr view") exit 1 ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi"
  add_gh_mock_outcome_read_fails "$case_dir" 8787878787878787878787878787878787878787
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/74 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-unreadable-outcome-quotes-forge: an unreadable outcome must fail"
  assert_grep 'could not read the GitHub pull request outcome after the merge attempt' \
    "$case_dir/stderr" \
    "github-unreadable-outcome-quotes-forge: the unreadable outcome was not reported"
  assert_grep 'error: > will be added to the merge queue when all requirements are met' \
    "$case_dir/stderr" \
    "github-unreadable-outcome-quotes-forge: the forge's only evidence was discarded"
  ! grep -qxF 'will be added to the merge queue when all requirements are met' \
    "$case_dir/stderr" \
    || fail "github-unreadable-outcome-quotes-forge: forge text was emitted as the wrapper's own line"
  assert_no_grep 'verified: ' "$case_dir/stdout" \
    "github-unreadable-outcome-quotes-forge: an unproved merge was reported as verified"
  assert_present "$case_dir/state/task-x1.check.sh" \
    "github-unreadable-outcome-quotes-forge: the attempted merge lost its merge poll"
  pass "fm-pr-merge quotes the forge output when it cannot read the outcome either"
}

test_github_failed_gh_read_falls_back_to_gh_axi() {
  local case_dir rc
  case_dir=$(make_case github-gh-read-falls-back)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 5151515151515151515151515151515151515151
  add_gh_mock_outcome_read_fails "$case_dir" 5151515151515151515151515151515151515151
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/63 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "github-gh-read-falls-back: a merge the gh-axi view proves must succeed"
  assert_grep 'pr view 63 --repo example/repo' "$case_dir/gh-axi.log" \
    "github-gh-read-falls-back: the gh-axi view was never consulted after gh's read failed"
  assert_grep 'verified: https://github.com/example/repo/pull/63 is merged' \
    "$case_dir/stdout" "github-gh-read-falls-back: the proven merge was not reported"
  assert_grep 'pr=https://github.com/example/repo/pull/63' "$case_dir/state/task-x1.meta" \
    "github-gh-read-falls-back: the merged PR was not recorded for teardown"
  pass "fm-pr-merge falls back to the gh-axi view when gh's read fails"
}

test_github_failed_merge_names_an_observed_landed_state() {
  local case_dir rc
  case_dir=$(make_case github-failed-merge-actually-landed)
  mkdir -p "$case_dir/wt"
  add_gh_mocks_merge_fails "$case_dir"
  write_github_outcome "$case_dir" MERGED true false main
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/64 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-failed-merge-actually-landed: the forge failure must still fail the wrapper"
  assert_grep 'error: pr merge failed' "$case_dir/stderr" \
    "github-failed-merge-actually-landed: the original forge error was masked"
  assert_grep 'state=MERGED, merged=true, isInMergeQueue=false' "$case_dir/stderr" \
    "github-failed-merge-actually-landed: the observed landed state was never named"
  assert_no_grep 'verified: ' "$case_dir/stdout" \
    "github-failed-merge-actually-landed: a failed merge command was reported as verified"
  assert_grep 'pr=https://github.com/example/repo/pull/64' "$case_dir/state/task-x1.meta" \
    "github-failed-merge-actually-landed: the landed PR lost its reference"
  pass "fm-pr-merge names a landed state hiding behind a failed GitHub merge command"
}

test_github_without_gh_still_uses_gh_axi_merge() {
  local case_dir ghless_path rc
  case_dir=$(make_case github-without-gh)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 4141414141414141414141414141414141414141
  rm "$case_dir/fakebin/gh"
  ghless_path="$case_dir/path-without-gh"
  mirror_path_without "$ghless_path" gh "$case_dir/fakebin"
  : > "$case_dir/gh-axi.log"

  # Without gh the squash guard cannot read the commit count it must see before
  # flattening history, so this case states the method explicitly - exactly what
  # that refusal tells an operator to do - and then proves the gh-axi path.
  set +e
  PATH="$ghless_path" run_pr_merge "$case_dir" task-x1 \
    https://github.com/example/repo/pull/60 -- --squash \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "github-without-gh: gh-axi can prove a landed merge without gh"
  assert_grep 'pr merge 60 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    "github-without-gh: the configured merge abstraction was not invoked"
  assert_grep 'pr view 60 --repo example/repo' "$case_dir/gh-axi.log" \
    "github-without-gh: the gh-axi fallback did not verify the landed state"
  assert_grep 'verified: https://github.com/example/repo/pull/60 is merged' \
    "$case_dir/stdout" "github-without-gh: the fallback did not report the proven merge"
  pass "fm-pr-merge reaches and verifies the gh-axi merge path without gh"
}

test_github_without_gh_failed_read_keeps_bookkeeping() {
  local case_dir ghless_path rc
  case_dir=$(make_case github-without-gh-read-fails)
  mkdir -p "$case_dir/wt"
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "pr merge") exit 0 ;;
  "pr view") exit 1 ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi"
  ghless_path="$case_dir/path-without-gh"
  mirror_path_without "$ghless_path" gh "$case_dir/fakebin"
  : > "$case_dir/gh-axi.log"

  # Explicit method for the same reason as the case above: with no gh the squash
  # guard has no counts to read, so the implicit default is refused before the
  # merge this case is about.
  set +e
  PATH="$ghless_path" run_pr_merge "$case_dir" task-x1 \
    https://github.com/example/repo/pull/61 -- --squash \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-without-gh-read-fails: an unreadable outcome must fail"
  assert_grep 'pr merge 61 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    "github-without-gh-read-fails: the merge call did not happen before the failed read"
  assert_grep 'could not read the GitHub pull request outcome after the merge attempt' \
    "$case_dir/stderr" "github-without-gh-read-fails: the failed read was not reported"
  assert_grep 'pr=https://github.com/example/repo/pull/61' "$case_dir/state/task-x1.meta" \
    "github-without-gh-read-fails: a landed merge lost its PR metadata"
  assert_present "$case_dir/state/task-x1.check.sh" \
    "github-without-gh-read-fails: a landed merge lost its merge poll"
  pass "fm-pr-merge preserves bookkeeping when gh is absent and the fallback read fails"
}

test_github_zero_exit_queue_required_refuses_with_exact_retry() {
  local case_dir rc
  case_dir=$(make_case github-zero-exit-queue-required)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 2121212121212121212121212121212121212121
  write_github_outcome "$case_dir" OPEN false false 'release/2026'
  printf 'merge_method=REBASE\n' > "$case_dir/github-rules"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/56 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-zero-exit-queue-required: an unproved merge must fail"
  assert_grep 'state=OPEN, merged=false, isInMergeQueue=false' "$case_dir/stderr" \
    "github-zero-exit-queue-required: refusal did not name the concrete observed state"
  assert_grep 'base branch release/2026 requires the merge queue' "$case_dir/stderr" \
    "github-zero-exit-queue-required: refusal did not name the queue requirement"
  assert_grep '-- --auto --rebase' "$case_dir/stderr" \
    "github-zero-exit-queue-required: refusal did not name the exact compatible flags"
  assert_grep 'api --paginate repos/example/repo/rules/branches/release%2F2026' "$case_dir/gh.log" \
    "github-zero-exit-queue-required: queue rules were not read with pagination and encoded branch path"
  grep -qxF 'pr merge 56 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "github-zero-exit-queue-required: the attempted merge was changed unexpectedly"
  [ "$(wc -l < "$case_dir/gh-axi.log" | tr -d '[:space:]')" = 1 ] \
    || fail "github-zero-exit-queue-required: the wrapper attempted more than one merge"
  assert_no_grep --auto "$case_dir/gh-axi.log" \
    "github-zero-exit-queue-required: queue flags were auto-applied to the attempted merge"
  assert_grep 'pr=https://github.com/example/repo/pull/56' "$case_dir/state/task-x1.meta" \
    "github-zero-exit-queue-required: the attempted merge lost its PR reference"
  assert_present "$case_dir/state/task-x1.check.sh" \
    "github-zero-exit-queue-required: the attempted merge did not leave its poll armed"
  pass "fm-pr-merge reports exact queue retry flags after a zero-exit false success"
}

test_github_closed_unqueued_outcome_omits_retry_flags() {
  local case_dir rc
  case_dir=$(make_case github-closed-unqueued)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 2323232323232323232323232323232323232323
  write_github_outcome "$case_dir" CLOSED false false master
  printf 'merge_method=MERGE\n' > "$case_dir/github-rules"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/57 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-closed-unqueued: an unproved merge must fail"
  assert_grep 'state=CLOSED, merged=false, isInMergeQueue=false' "$case_dir/stderr" \
    "github-closed-unqueued: refusal did not name the concrete observed state"
  assert_no_grep 'requires the merge queue' "$case_dir/stderr" \
    "github-closed-unqueued: closed PR received unusable queue guidance"
  assert_no_grep '-- --auto --merge' "$case_dir/stderr" \
    "github-closed-unqueued: closed PR received retry flags"
  assert_grep 'pr=https://github.com/example/repo/pull/57' "$case_dir/state/task-x1.meta" \
    "github-closed-unqueued: the attempted merge lost its PR reference"
  assert_present "$case_dir/state/task-x1.check.sh" \
    "github-closed-unqueued: the attempted merge did not leave its poll armed"
  pass "fm-pr-merge omits merge-queue retry guidance for a closed GitHub PR"
}

test_github_queued_outcome_is_verified() {
  local case_dir rc
  case_dir=$(make_case github-verified-queued)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 3030303030303030303030303030303030303030
  write_github_outcome "$case_dir" OPEN false true master
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/53 -- --auto --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "github-verified-queued: a queued PR should succeed"
  assert_grep 'verified: https://github.com/example/repo/pull/53 is queued' \
    "$case_dir/stdout" "github-verified-queued: success was not reported as queued"
  assert_no_grep 'merged:' "$case_dir/stdout" \
    "github-verified-queued: the forge CLI's unverified merged report leaked through"
  assert_grep 'pr=https://github.com/example/repo/pull/53' "$case_dir/state/task-x1.meta" \
    "github-verified-queued: the queued PR was not recorded for teardown"
  pass "fm-pr-merge accepts and accurately reports a GitHub merge-queue entry"
}

test_github_queue_required_refusal_names_retry_flags() {
  local case_dir rc
  case_dir=$(make_case github-queue-required)
  mkdir -p "$case_dir/wt"
  add_gh_mocks_merge_fails "$case_dir"
  write_github_outcome "$case_dir" OPEN false false master
  printf 'merge_method=MERGE\n' > "$case_dir/github-rules"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/54 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-queue-required: an incompatible direct merge must fail"
  assert_grep 'error: pr merge failed' "$case_dir/stderr" \
    "github-queue-required: the original forge failure was not preserved"
  assert_grep 'base branch master requires the merge queue' "$case_dir/stderr" \
    "github-queue-required: refusal did not name the queue requirement"
  grep -F -- '-- --auto --merge' "$case_dir/stderr" >/dev/null \
    || fail "github-queue-required: refusal did not name the exact compatible flags"
  grep -qxF 'pr merge 54 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "github-queue-required: the wrapper silently changed the attempted merge semantics"
  assert_present "$case_dir/state/task-x1.check.sh" \
    "github-queue-required: the failed forge call did not leave the merge poll armed"
  pass "fm-pr-merge explains how to retry with the required GitHub merge queue method"
}

test_github_agreeing_queue_rules_keep_retry_guidance() {
  local case_dir rc
  case_dir=$(make_case github-agreeing-queue-rules)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 2424242424242424242424242424242424242424
  write_github_outcome "$case_dir" OPEN false false main
  printf 'merge_method=REBASE\nmerge_method=REBASE\n' > "$case_dir/github-rules"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/58 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-agreeing-queue-rules: an unproved merge must fail"
  assert_grep 'base branch main requires the merge queue' "$case_dir/stderr" \
    "github-agreeing-queue-rules: refusal did not name the queue requirement"
  assert_grep '-- --auto --rebase' "$case_dir/stderr" \
    "github-agreeing-queue-rules: agreeing rules omitted exact retry flags"
  assert_no_grep 'exact retry flags are ambiguous' "$case_dir/stderr" \
    "github-agreeing-queue-rules: agreeing rules were reported as ambiguous"
  pass "fm-pr-merge aggregates agreeing merge-queue rules"
}

test_github_conflicting_queue_rules_report_ambiguity() {
  local case_dir rc
  case_dir=$(make_case github-conflicting-queue-rules)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 2525252525252525252525252525252525252525
  write_github_outcome "$case_dir" OPEN false false main
  printf 'merge_method=MERGE\nmerge_method=SQUASH\nmerge_method=SQUASH\n' \
    > "$case_dir/github-rules"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/59 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-conflicting-queue-rules: an unproved merge must fail"
  assert_grep 'base branch main has conflicting merge queue methods (MERGE, SQUASH)' \
    "$case_dir/stderr" \
    "github-conflicting-queue-rules: conflicting methods were not named"
  assert_no_grep '-- --auto --merge' "$case_dir/stderr" \
    "github-conflicting-queue-rules: an exact retry method was guessed"
  assert_no_grep '-- --auto --squash' "$case_dir/stderr" \
    "github-conflicting-queue-rules: an exact retry method was guessed"
  assert_no_grep 'SQUASH, SQUASH' "$case_dir/stderr" \
    "github-conflicting-queue-rules: a repeated queue method was named twice"
  pass "fm-pr-merge reports ambiguity for conflicting merge-queue rules"
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
  # A near-miss GitLab URL: one namespace segment where a project needs at
  # least two. A well-formed merge request URL is merged now, so the refusal
  # has to be proven on a URL that genuinely does not parse.
  run_pr_merge "$case_dir" task-x1 'https://gitlab.com/example/-/merge_requests/1' \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 2 "$rc" "malformed-url: fm-pr-merge should refuse a malformed merge request URL"
  assert_grep 'error: invalid PR merge request' "$case_dir/stderr" \
    "malformed-url: refusal was not fixed and non-probing"
  assert_no_grep 'pr=https://gitlab.com/example/-/merge_requests/1' "$case_dir/state/task-x1.meta" \
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

# A bundled short-option cluster carries -R without ever being exactly -R, and
# both CLIs expand it one character at a time, so the guard has to read the
# whole cluster. On GitLab that redirect names an instance, not only a
# repository, so it must refuse before anything is recorded or read.
test_bundled_repo_override_args_refuse_before_recording() {
  local case_dir rc
  case_dir=$(make_case bundled-repo-override)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" abababababababababababababababababababab
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/right/repo/pull/6 -- -dR wrong/repo \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "bundled-repo-override: fm-pr-merge should refuse a bundled repo override"
  assert_grep 'extra merge arguments must not override the repository' "$case_dir/stderr" \
    "bundled-repo-override: refusal did not explain the repo override"
  assert_no_grep 'pr=https://github.com/right/repo/pull/6' "$case_dir/state/task-x1.meta" \
    "bundled-repo-override: PR URL was recorded before rejecting the bundled repo override"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "bundled-repo-override: a bundled repo override armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "bundled-repo-override: gh-axi pr merge was invoked despite the bundled repo override"

  case_dir=$(make_gitlab_case bundled-repo-override-gitlab)

  set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" -- -yR https://other.example/g/p \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "bundled-repo-override-gitlab: fm-pr-merge should refuse a bundled instance override"
  assert_grep 'extra merge arguments must not override the repository' "$case_dir/stderr" \
    "bundled-repo-override-gitlab: refusal did not explain the repo override"
  assert_no_grep "pr=$MR_URL" "$case_dir/state/task-x1.meta" \
    "bundled-repo-override-gitlab: the URL was recorded before rejecting the bundled override"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "bundled-repo-override-gitlab: a bundled override armed a merge poll"
  [ ! -s "$case_dir/glab.log" ] \
    || fail "bundled-repo-override-gitlab: glab was invoked despite the bundled override"

  # Only a cluster carrying the repository flag is refused: every other short
  # cluster is still the caller's business and still reaches the forge.
  case_dir=$(make_case bundled-non-repo-cluster)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" bcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbc
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/8 -- -d \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "bundled-non-repo-cluster: fm-pr-merge refused a short flag that overrides nothing"

  grep -qxF 'pr merge 8 --repo example/repo --squash -d' "$case_dir/gh-axi.log" \
    || fail "bundled-non-repo-cluster: a short flag carrying no repository override was not forwarded"
  pass "fm-pr-merge refuses a bundled short-option repo override and forwards other short flags"
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

test_gitlab_url_resolves_and_merges() {
  local case_dir rc merge_line
  case_dir=$(make_gitlab_case gitlab-merges)

  set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "gitlab-merges: a well-formed merge request URL should merge, not error"
  assert_grep "pr=$MR_URL" "$case_dir/state/task-x1.meta" \
    "gitlab-merges: pr= was not recorded before merging"
  assert_grep "GITLAB_HOST=$MR_HOST mr view 7 -R $MR_PROJECT_URL -F json" "$case_dir/glab.log" \
    "gitlab-merges: the pre-merge state was not read from the project URL"
  merge_line=$(glab_merge_line "$case_dir/glab.log")
  [ "$merge_line" = "GITLAB_HOST=$MR_HOST mr merge 7 -R $MR_PROJECT_URL --sha $MR_HEAD --yes" ] \
    || fail "gitlab-merges: unexpected merge invocation: '$merge_line'"
  assert_grep "successful pipeline at head $MR_HEAD" "$case_dir/stderr" \
    "gitlab-merges: the verified head was not reported"
  [ ! -s "$case_dir/gh-axi.log" ] || fail "gitlab-merges: a merge request reached the GitHub CLI"
  pass "fm-pr-merge merges a GitLab merge request through glab instead of refusing it"
}

test_gitlab_host_comes_from_the_url() {
  local case_dir rc host path project_url url
  host=gl.self-hosted.example
  path=deep/nested/group/project
  project_url="https://$host/$path"
  url="$project_url/-/merge_requests/31"
  case_dir=$(make_gitlab_case gitlab-host-from-url)

  set +e
  run_pr_merge "$case_dir" task-x1 "$url" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "gitlab-host-from-url: a self-hosted merge request should merge"
  assert_grep "GITLAB_HOST=$host mr view 31 -R $project_url -F json" "$case_dir/glab.log" \
    "gitlab-host-from-url: the read did not use the host from the URL"
  assert_grep "GITLAB_HOST=$host mr merge 31 -R $project_url" "$case_dir/glab.log" \
    "gitlab-host-from-url: the merge did not use the host from the URL"
  assert_no_grep 'gitlab.com' "$case_dir/glab.log" \
    "gitlab-host-from-url: a host was assumed instead of taken from the URL"
  assert_no_grep '<unset>' "$case_dir/glab.log" \
    "gitlab-host-from-url: glab was left to resolve the instance from its own default"
  pass "fm-pr-merge takes the GitLab instance from the URL rather than assuming one"
}

test_gitlab_imposes_no_merge_method() {
  local case_dir rc merge_line flag
  case_dir=$(make_gitlab_case gitlab-no-method)

  set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "gitlab-no-method: merge should succeed"
  merge_line=$(glab_merge_line "$case_dir/glab.log")
  for flag in --squash --rebase --merge --method; do
    case "$merge_line" in
      *"$flag"*) fail "gitlab-no-method: '$flag' was imposed on GitLab: '$merge_line'" ;;
    esac
  done
  pass "fm-pr-merge imposes no merge method on GitLab, leaving the project's own one"
}

test_gitlab_extra_args_forwarded() {
  local case_dir rc merge_line
  case_dir=$(make_gitlab_case gitlab-extra-args)

  set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" -- --remove-source-branch \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "gitlab-extra-args: merge should succeed"
  merge_line=$(glab_merge_line "$case_dir/glab.log")
  [ "$merge_line" = "GITLAB_HOST=$MR_HOST mr merge 7 -R $MR_PROJECT_URL --sha $MR_HEAD --yes --remove-source-branch" ] \
    || fail "gitlab-extra-args: extra glab flags were not forwarded: '$merge_line'"
  pass "fm-pr-merge forwards extra flags to glab mr merge after the -- separator"
}

test_gitlab_merge_failure_propagates() {
  local case_dir rc
  case_dir=$(make_gitlab_case gitlab-merge-fails)
  : > "$case_dir/glab-merge-fails"

  set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "gitlab-merge-fails: a failing glab merge should not report success"
  assert_grep "pr=$MR_URL" "$case_dir/state/task-x1.meta" \
    "gitlab-merge-fails: pr= should already be recorded even though the merge failed"
  pass "fm-pr-merge propagates a real glab merge failure without silently succeeding"
}

# Each pre-merge condition, driven one at a time, so no condition can be
# carried by another. The refusal names that condition, no merge is attempted,
# and pr= is still recorded and the poll still armed exactly as the GitHub path
# leaves them when gh-axi itself fails.
test_gitlab_each_condition_refuses_independently() {
  local case_dir rc name expected spec
  set -- \
    "state|state=closed|state is \"closed\", not open" \
    "detail|detail=need_rebase|detailed_merge_status is \"need_rebase\", not mergeable" \
    "conflicts|conflicts=true|has_conflicts is \"true\", not false" \
    "discussions|discussions=false|blocking_discussions_resolved is \"false\", not true" \
    "pipeline-status|pipeline_status=failed|the head pipeline status is \"failed\", not success" \
    "pipeline-sha|pipeline_sha=$MR_STALE_HEAD|the head pipeline ran at \"$MR_STALE_HEAD\", not at the current head $MR_HEAD" \
    "no-pipeline|pipeline=null|the head pipeline status is \"none\", not success"
  for spec in "$@"; do
    name=${spec%%|*}
    expected=${spec##*|}
    spec=${spec#*|}
    case_dir=$(make_gitlab_case "gitlab-refuse-$name" "${spec%%|*}")

    set +e
    run_pr_merge "$case_dir" task-x1 "$MR_URL" \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e

    expect_code 1 "$rc" "gitlab-refuse-$name: fm-pr-merge should refuse"
    assert_grep "error: refusing to merge $MR_URL" "$case_dir/stderr" \
      "gitlab-refuse-$name: refusal did not name the merge request"
    assert_grep "$expected" "$case_dir/stderr" \
      "gitlab-refuse-$name: refusal did not name the failing condition"
    [ -z "$(glab_merge_line "$case_dir/glab.log")" ] \
      || fail "gitlab-refuse-$name: a merge was attempted despite the refusal"
    assert_grep "pr=$MR_URL" "$case_dir/state/task-x1.meta" \
      "gitlab-refuse-$name: a refusal should still leave the recorded PR reference"
    assert_present "$case_dir/state/task-x1.check.sh" \
      "gitlab-refuse-$name: a refusal should still leave the merge poll armed"
  done
  pass "fm-pr-merge refuses on each GitLab pre-merge condition independently"
}

test_gitlab_reports_every_failing_condition() {
  local case_dir rc expected
  case_dir=$(make_gitlab_case gitlab-refuse-all \
    state=closed detail=conflict conflicts=true discussions=false \
    pipeline_status=failed "pipeline_sha=$MR_STALE_HEAD")

  set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "gitlab-refuse-all: fm-pr-merge should refuse"
  for expected in \
    'state is "closed", not open' \
    'detailed_merge_status is "conflict", not mergeable' \
    'has_conflicts is "true", not false' \
    'blocking_discussions_resolved is "false", not true' \
    'the head pipeline status is "failed", not success' \
    "the head pipeline ran at \"$MR_STALE_HEAD\", not at the current head $MR_HEAD"
  do
    assert_grep "$expected" "$case_dir/stderr" \
      "gitlab-refuse-all: '$expected' was not reported"
  done
  pass "fm-pr-merge reports every failing GitLab condition, not only the first"
}

test_gitlab_stale_recorded_head_is_reported() {
  local case_dir rc merge_line
  case_dir=$(make_gitlab_case gitlab-stale-head)
  # The recorded head is what a rebase leaves behind. It is read before
  # fm-pr-check.sh rewrites the metadata, which drops a head it cannot resolve
  # for a GitLab task, so reading it afterwards would find nothing at all.
  printf 'pr_head=%s\n' "$MR_STALE_HEAD" >> "$case_dir/state/task-x1.meta"

  set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "gitlab-stale-head: the live head satisfies every condition, so it should merge"
  assert_grep "recorded head $MR_STALE_HEAD disagrees with the live head $MR_HEAD" \
    "$case_dir/stderr" "gitlab-stale-head: the stale recorded head was trusted silently"
  merge_line=$(glab_merge_line "$case_dir/glab.log")
  case "$merge_line" in
    *"--sha $MR_HEAD"*) : ;;
    *) fail "gitlab-stale-head: the merge was not bound to the live head: '$merge_line'" ;;
  esac
  assert_no_grep "pr_head=$MR_STALE_HEAD" "$case_dir/state/task-x1.meta" \
    "gitlab-stale-head: the recording step no longer drops an unresolvable GitLab head"
  pass "fm-pr-merge reports a stale recorded head and verifies the live one"
}

test_gitlab_unreadable_state_refuses() {
  local case_dir rc name
  for name in view-fails not-an-object split-value; do
    case_dir=$(make_gitlab_case "gitlab-unreadable-$name")
    case "$name" in
      view-fails) : > "$case_dir/glab-view-fails" ;;
      not-an-object) printf '[]\n' > "$case_dir/mr.json" ;;
      # A value carrying a newline splits into a line no field name matches, so
      # it must refuse rather than be truncated into a value a check accepts.
      split-value) write_mr_json "$case_dir/mr.json" 'state=opened\nnot-a-field' ;;
    esac

    set +e
    run_pr_merge "$case_dir" task-x1 "$MR_URL" \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e

    expect_code 1 "$rc" "gitlab-unreadable-$name: fm-pr-merge should refuse"
    assert_grep 'could not read the GitLab merge request state before merging' \
      "$case_dir/stderr" "gitlab-unreadable-$name: refusal did not name the unreadable state"
    [ -z "$(glab_merge_line "$case_dir/glab.log")" ] \
      || fail "gitlab-unreadable-$name: a merge was attempted on an unreadable state"
  done
  pass "fm-pr-merge refuses an unreadable GitLab merge request state rather than merging blind"
}

test_gitlab_invalid_head_refuses() {
  local case_dir rc
  case_dir=$(make_gitlab_case gitlab-invalid-head head=not-a-sha)

  set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "gitlab-invalid-head: fm-pr-merge should refuse"
  assert_grep 'could not read the GitLab merge request head commit before merging' \
    "$case_dir/stderr" "gitlab-invalid-head: refusal did not name the unreadable head"
  [ -z "$(glab_merge_line "$case_dir/glab.log")" ] \
    || fail "gitlab-invalid-head: a merge was bound to a head that is not a commit"
  pass "fm-pr-merge refuses a GitLab head commit it cannot validate"
}

test_gitlab_missing_tool_refuses_before_recording() {
  local case_dir rc tool other
  for tool in glab jq; do
    if [ "$tool" = glab ]; then other=jq; else other=glab; fi
    case_dir=$(make_gitlab_case "gitlab-no-$tool")
    mirror_path_without "$case_dir/no$tool" "$tool" "$case_dir/fakebin"
    # One tool absent, the other still answered by this case's own mock, so the
    # refusal names exactly one tool on a host that ships neither.
    PATH="$case_dir/no$tool" command -v "$other" >/dev/null 2>&1 \
      || fail "gitlab-no-$tool: the $tool-free search path lost the $other mock as well"

    set +e
    FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$case_dir/state" \
    FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
    FM_TEST_GLAB_LOG="$case_dir/glab.log" \
    FM_TEST_GLAB_JSON="$case_dir/mr.json" \
    PATH="$case_dir/no$tool" \
      "$PR_MERGE" task-x1 "$MR_URL" > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e

    expect_code 1 "$rc" "gitlab-no-$tool: fm-pr-merge should refuse"
    assert_grep "error: merging a GitLab merge request requires $tool on PATH" \
      "$case_dir/stderr" "gitlab-no-$tool: refusal did not name the missing tool"
    assert_no_grep "pr=$MR_URL" "$case_dir/state/task-x1.meta" \
      "gitlab-no-$tool: a PR reference was recorded despite the missing tool"
    assert_absent "$case_dir/state/task-x1.check.sh" \
      "gitlab-no-$tool: a merge poll was armed despite the missing tool"
  done
  pass "fm-pr-merge refuses before recording anything when glab or jq is absent"
}

test_gitlab_head_override_args_refuse_before_recording() {
  local case_dir rc
  case_dir=$(make_gitlab_case gitlab-head-override)

  set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" -- --sha "$MR_STALE_HEAD" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "gitlab-head-override: fm-pr-merge should refuse a caller head override"
  assert_grep 'extra merge arguments must not override the head commit' "$case_dir/stderr" \
    "gitlab-head-override: refusal did not explain the head override"
  assert_no_grep "pr=$MR_URL" "$case_dir/state/task-x1.meta" \
    "gitlab-head-override: the URL was recorded before rejecting the head override"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "gitlab-head-override: a head override armed a merge poll"
  [ ! -s "$case_dir/glab.log" ] || fail "gitlab-head-override: glab was invoked despite the head override"
  pass "fm-pr-merge refuses a GitLab head override before recording state"
}

test_github_still_forwards_sha_arg() {
  local case_dir
  case_dir=$(make_case github-sha-arg)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" dddddddddddddddddddddddddddddddddddddddd
  : > "$case_dir/gh-axi.log"

  # --sha is rejected only where the head is firstmate's to determine. GitHub's
  # extra args are the caller's business exactly as they were.
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/44 -- --sha abc123 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "github-sha-arg: fm-pr-merge failed"

  grep -qxF 'pr merge 44 --repo example/repo --squash --sha abc123' "$case_dir/gh-axi.log" \
    || fail "github-sha-arg: the GitHub path stopped forwarding a caller --sha"
  pass "fm-pr-merge leaves GitHub extra-arg handling unchanged, including --sha"
}

# --- squash-safety guard on the implicit default ----------------------------
# A squash collapses every commit on the PR into one, so the implicit default
# has to know what it is about to flatten. The counts come from one live REST
# read; an explicit merge method skips the guard entirely.

# The stacked shape whose ancestry a default squash destroyed: many commits
# across many files, carried on one pull request.
STACK_COMMITS=249
STACK_FILES=379

test_default_squash_refused_for_stacked_pr() {
  local case_dir rc
  case_dir=$(make_case squash-guard-stack)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 1010101010101010101010101010101010101010
  write_pull_json "$case_dir" "$STACK_COMMITS" "$STACK_FILES" fm/ladder-rung-17
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/241 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "squash-guard-stack: fm-pr-merge should refuse to squash a stacked PR by default"
  assert_grep "it carries $STACK_COMMITS commits and $STACK_FILES changed files" "$case_dir/stderr" \
    "squash-guard-stack: the refusal did not name the counts it actually read"
  assert_grep "flatten those $STACK_COMMITS commits into one commit and destroy their ancestry permanently" \
    "$case_dir/stderr" "squash-guard-stack: the refusal did not state the consequence"
  assert_grep 'pass --squash to squash it anyway' "$case_dir/stderr" \
    "squash-guard-stack: the refusal did not say how to proceed deliberately"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "squash-guard-stack: the merge was attempted despite the refusal"
  assert_grep 'api repos/example/repo/pulls/241' "$case_dir/gh.log" \
    "squash-guard-stack: the counts were not read from REST at merge time"
  assert_no_grep 'graphql' "$case_dir/gh.log" \
    "squash-guard-stack: a GraphQL call was introduced on the merge path"
  pass "fm-pr-merge refuses the default squash on a stacked PR and names the counts"
}

test_squash_guard_boundary_is_more_than_the_threshold() {
  local case_dir rc
  # At the threshold the default still squashes, one commit past it refuses, so
  # the gate is "more than", not "at least", and neither side is vacuous.
  case_dir=$(make_case squash-guard-at-threshold)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 1818181818181818181818181818181818181818
  write_pull_json "$case_dir" 15 100
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/249 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "squash-guard-at-threshold: a PR exactly at the threshold should still squash"
  grep -qxF 'pr merge 249 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "squash-guard-at-threshold: the default --squash was not applied at the threshold"

  case_dir=$(make_case squash-guard-past-threshold)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 1919191919191919191919191919191919191919
  write_pull_json "$case_dir" 16 100
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/250 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "squash-guard-past-threshold: one commit past the threshold should refuse"
  assert_grep 'it carries 16 commits and 100 changed files' "$case_dir/stderr" \
    "squash-guard-past-threshold: the refusal did not name the counts it actually read"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "squash-guard-past-threshold: the merge was attempted despite the refusal"
  pass "fm-pr-merge squashes at the guard threshold and refuses one commit past it"
}

test_default_squash_refused_on_changed_file_threshold() {
  local case_dir rc
  case_dir=$(make_case squash-guard-files)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 1212121212121212121212121212121212121212
  # Few commits, but a change far too broad to flatten without being asked.
  write_pull_json "$case_dir" 3 400
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/242 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "squash-guard-files: fm-pr-merge should refuse on the changed-file threshold"
  assert_grep 'it carries 3 commits and 400 changed files' "$case_dir/stderr" \
    "squash-guard-files: the refusal did not name the counts it actually read"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "squash-guard-files: the merge was attempted despite the refusal"
  pass "fm-pr-merge refuses the default squash when the changed-file count is too large"
}

test_single_commit_pr_still_squashes_by_default() {
  local case_dir
  case_dir=$(make_case squash-guard-single-commit)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 1313131313131313131313131313131313131313
  write_pull_json "$case_dir" 1 11
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/243 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "squash-guard-single-commit: an ordinary single-commit PR should still merge"

  grep -qxF 'pr merge 243 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "squash-guard-single-commit: the default --squash was not applied as before"
  assert_no_grep 'refusing to squash' "$case_dir/stderr" \
    "squash-guard-single-commit: a single-commit PR was refused"
  # One GraphQL call is the post-merge outcome read that proves the pull request
  # landed; the guard's own counts still come from REST.
  [ "$(grep -c graphql "$case_dir/gh.log")" -le 1 ] \
    || fail "squash-guard-single-commit: an extra GraphQL call was introduced on the merge path"
  pass "fm-pr-merge still squashes a single-commit PR by default, exactly as before"
}

test_explicit_squash_overrides_the_refusal() {
  local case_dir
  case_dir=$(make_case squash-guard-explicit)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 1414141414141414141414141414141414141414
  write_pull_json "$case_dir" "$STACK_COMMITS" "$STACK_FILES"
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/244 -- --squash \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "squash-guard-explicit: an explicit --squash should still squash a stacked PR"

  grep -qxF 'pr merge 244 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "squash-guard-explicit: an explicit --squash was not forwarded"
  assert_no_grep 'refusing to squash' "$case_dir/stderr" \
    "squash-guard-explicit: an explicit --squash was refused"
  pass "fm-pr-merge lets an explicit --squash override the stacked-PR refusal"
}

test_merge_and_rebase_unaffected_by_squash_guard() {
  local case_dir method number=245
  for method in merge rebase; do
    case_dir=$(make_case "squash-guard-explicit-$method")
    mkdir -p "$case_dir/wt"
    add_gh_mocks "$case_dir" 1515151515151515151515151515151515151515
    write_pull_json "$case_dir" "$STACK_COMMITS" "$STACK_FILES"
    : > "$case_dir/gh-axi.log"

    run_pr_merge "$case_dir" task-x1 "https://github.com/example/repo/pull/$number" -- "--$method" \
      > "$case_dir/stdout" 2> "$case_dir/stderr" \
      || fail "squash-guard-explicit-$method: --$method should be unaffected by the squash guard"

    grep -qxF "pr merge $number --repo example/repo --$method" "$case_dir/gh-axi.log" \
      || fail "squash-guard-explicit-$method: --$method was not forwarded unchanged"
    assert_no_grep 'refusing to squash' "$case_dir/stderr" \
      "squash-guard-explicit-$method: an explicit --$method was refused"
    # The pr_head lookup reads the same REST resource, so the count read is
    # identified by the whole line: it is the one with no --jq selector.
    ! grep -qxF "api repos/example/repo/pulls/$number" "$case_dir/gh.log" \
      || fail "squash-guard-explicit-$method: an explicit merge method still spent a count read"
    number=$((number + 1))
  done
  pass "fm-pr-merge leaves an explicit --merge or --rebase completely unguarded"
}

test_unreadable_commit_count_refuses_the_default_squash() {
  local case_dir rc
  case_dir=$(make_case squash-guard-unreadable)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 1616161616161616161616161616161616161616
  : > "$case_dir/gh-api-fails"
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/247 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "squash-guard-unreadable: an unverifiable count should not be squashed by default"
  assert_grep 'its commit count could not be read' "$case_dir/stderr" \
    "squash-guard-unreadable: the refusal did not name the unreadable count"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "squash-guard-unreadable: the merge was attempted on an unverified count"
  pass "fm-pr-merge refuses the default squash when the commit count cannot be read"
}

test_stack_named_branch_warns_but_still_merges() {
  local case_dir
  case_dir=$(make_case squash-guard-stack-hint)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 1717171717171717171717171717171717171717
  # Under both thresholds, so the counts allow the squash and only the soft
  # branch-name signal remains: it warns, it does not gate.
  write_pull_json "$case_dir" 4 9 fm/stack-rung-02
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/248 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "squash-guard-stack-hint: the count check is the hard gate, so this should merge"

  grep -qxF 'pr merge 248 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "squash-guard-stack-hint: the default --squash was not applied"
  assert_grep 'the head branch "fm/stack-rung-02" names a stack' "$case_dir/stderr" \
    "squash-guard-stack-hint: a stack-named branch produced no warning"
  pass "fm-pr-merge warns on a stack-named branch while keeping the counts as the hard gate"
}

test_gitlab_untouched_by_squash_guard() {
  local case_dir rc merge_line
  case_dir=$(make_gitlab_case gitlab-no-squash-guard)
  # Any GitHub count read would fail here, so a merge that still succeeds proves
  # the GitLab path never consults one: it imposes no squash to guard.
  : > "$case_dir/gh-api-fails"

  set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "gitlab-no-squash-guard: the GitLab path should be unaffected by the squash guard"
  merge_line=$(glab_merge_line "$case_dir/glab.log")
  [ "$merge_line" = "GITLAB_HOST=$MR_HOST mr merge 7 -R $MR_PROJECT_URL --sha $MR_HEAD --yes" ] \
    || fail "gitlab-no-squash-guard: unexpected merge invocation: '$merge_line'"
  assert_no_grep 'refusing to squash' "$case_dir/stderr" \
    "gitlab-no-squash-guard: a squash refusal reached the GitLab path"
  assert_no_grep 'api repos' "$case_dir/gh.log" \
    "gitlab-no-squash-guard: the GitLab path spent a GitHub count read"
  pass "fm-pr-merge leaves the GitLab merge path untouched by the squash guard"
}

# --- durable merge outcome ---------------------------------------------------
# A merge that lands must leave a record outside the merging agent's memory.
# bin/fm-merge-outcome-lib.sh owns where that record goes; these cases pin the
# behavior through the real merge entrypoint.

# make_home_case <name> [<route> [<parent-home>]]: a case dir whose home is a
# secondmate home bound to a parent, or a plain main home when no route is
# given. Echoes the case dir; the home is "$case_dir/home".
make_home_case() {
  local name=$1 route=${2:-} parent=${3:-} case_dir home
  case_dir=$(make_case "$name")
  home="$case_dir/home"
  mkdir -p "$home" "$case_dir/wt"
  if [ -n "$route" ]; then
    printf '%s\n' mate-x >"$home/.fm-secondmate-home"
    {
      printf 'schema=fm-secondmate-parent.v1\n'
      printf 'route=%s\n' "$route"
      [ "$route" != local ] || printf 'parent_home=%s\n' "$parent"
    } >"$home/.fm-secondmate-parent"
  fi
  printf '%s\n' "$case_dir"
}

parent_reply_lines() {  # <file> <url>
  grep -c -F "$2" "$1" 2>/dev/null || true
}

test_secondmate_merge_reports_upward_once() {
  local case_dir replies url
  url=https://github.com/example/repo/pull/61
  case_dir=$(make_home_case secondmate-merge-reports remote)
  add_gh_mocks "$case_dir" 5555555555555555555555555555555555555555
  : >"$case_dir/gh-axi.log"
  replies="$case_dir/state/parent-replies.status"

  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" \
    >"$case_dir/stdout" 2>"$case_dir/stderr" || fail "secondmate-merge-reports: merge failed"

  assert_grep "done [key=merged-task-x1]: merged task-x1 $url" "$replies" \
    "secondmate-merge-reports: the landed PR was not reported upward"
  [ "$(wc -l <"$replies")" -eq 1 ] \
    || fail "secondmate-merge-reports: one merge produced more than one upward line"

  # The same merge again: the forge accepts it in this fixture, so only the
  # at-most-once contract can keep the parent from being told twice.
  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" \
    >"$case_dir/stdout2" 2>"$case_dir/stderr2" || fail "secondmate-merge-reports: repeat merge failed"
  [ "$(parent_reply_lines "$replies" "$url")" -eq 1 ] \
    || fail "secondmate-merge-reports: a repeat merge of the same PR duplicated the upward line"
  pass "a merge a secondmate home performs itself is reported upward exactly once"
}

test_secondmate_merge_reports_on_the_local_route() {
  local case_dir parent_status url
  url=https://github.com/example/repo/pull/62
  case_dir=$(make_home_case secondmate-merge-local local "$TMP_ROOT/secondmate-merge-local/parent")
  mkdir -p "$TMP_ROOT/secondmate-merge-local/parent/state"
  add_gh_mocks "$case_dir" 6666666666666666666666666666666666666666
  : >"$case_dir/gh-axi.log"
  parent_status="$TMP_ROOT/secondmate-merge-local/parent/state/mate-x.status"

  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" \
    >"$case_dir/stdout" 2>"$case_dir/stderr" || fail "secondmate-merge-local: merge failed"

  assert_grep "done [key=merged-task-x1]: merged task-x1 $url" "$parent_status" \
    "secondmate-merge-local: the landed PR did not reach the parent home's channel"
  [ ! -e "$case_dir/state/parent-replies.status" ] \
    || fail "secondmate-merge-local: a local-route report also wrote the remote reply channel"
  pass "a locally routed secondmate home reports the landed PR into its parent's own channel"
}

test_failed_merge_reports_nothing() {
  local case_dir rc
  case_dir=$(make_home_case failed-merge-silent remote)
  add_gh_mocks_merge_fails "$case_dir"
  : >"$case_dir/gh-axi.log"

  set +e
  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/63 \
    >"$case_dir/stdout" 2>"$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "failed-merge-silent: a failed merge should propagate"
  assert_absent "$case_dir/state/parent-replies.status" \
    "failed-merge-silent: a merge that never landed was reported as landed"
  pass "a refused or failed merge reports no outcome"
}

test_gitlab_refusal_reports_nothing() {
  local case_dir rc
  case_dir=$(make_gitlab_case gitlab-refusal-silent state=merged)
  mkdir -p "$case_dir/home"
  printf '%s\n' mate-x >"$case_dir/home/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=remote\n' >"$case_dir/home/.fm-secondmate-parent"

  set +e
  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$MR_URL" \
    >"$case_dir/stdout" 2>"$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "gitlab-refusal-silent: a refused GitLab merge should exit non-zero"
  assert_absent "$case_dir/state/parent-replies.status" \
    "gitlab-refusal-silent: a refused merge request was reported as landed"
  pass "a GitLab merge refused before the forge call reports no outcome"
}

test_gitlab_merge_reports_upward() {
  local case_dir url
  case_dir=$(make_gitlab_case gitlab-merge-reports)
  mkdir -p "$case_dir/home"
  printf '%s\n' mate-x >"$case_dir/home/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=remote\n' >"$case_dir/home/.fm-secondmate-parent"
  url=$MR_URL

  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" \
    >"$case_dir/stdout" 2>"$case_dir/stderr" || fail "gitlab-merge-reports: merge failed"

  assert_grep "done [key=merged-task-x1]: merged task-x1 $url" \
    "$case_dir/state/parent-replies.status" \
    "gitlab-merge-reports: a landed merge request was not reported upward"
  pass "a landed GitLab merge request is reported upward on the same channel"
}

test_queued_gitlab_merge_leaves_the_poll_armed() {
  local case_dir
  case_dir=$(make_gitlab_case queued-gitlab-merge)
  mkdir -p "$case_dir/home"
  : >"$case_dir/glab-stays-open"

  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$MR_URL" \
    >"$case_dir/stdout" 2>"$case_dir/stderr" \
    || fail "queued-gitlab-merge: accepted merge command failed"

  assert_absent "$case_dir/state/.wake-queue" \
    "queued-gitlab-merge: a queued merge was reported as landed"
  [ -f "$case_dir/state/task-x1.check.sh" ] \
    || fail "queued-gitlab-merge: the merge poll was not left armed"
  [ ! -e "$case_dir/state/task-x1.pr-poll-merge-notified" ] \
    || fail "queued-gitlab-merge: a queued merge was marked as reported"
  pass "a queued GitLab merge stays silent and leaves confirmation to the armed poll"
}

test_main_home_merge_leaves_a_durable_wake() {
  local case_dir url
  url=https://github.com/example/repo/pull/64
  case_dir=$(make_home_case main-merge-wake)
  add_gh_mocks "$case_dir" 7777777777777777777777777777777777777777
  : >"$case_dir/gh-axi.log"

  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" \
    >"$case_dir/stdout" 2>"$case_dir/stderr" || fail "main-merge-wake: merge failed"

  assert_grep "$url" "$case_dir/state/.wake-queue" \
    "main-merge-wake: a merge this home performed left no durable record naming the PR"
  [ "$(grep -c -F "$url" "$case_dir/state/.wake-queue")" -eq 1 ] \
    || fail "main-merge-wake: one merge produced more than one durable record"
  assert_absent "$case_dir/state/parent-replies.status" \
    "main-merge-wake: a main home wrote a parent reply channel it does not have"
  pass "a merge a main home performs itself leaves one durable wake naming the PR"
}

test_queued_github_merge_leaves_the_poll_armed() {
  local case_dir url
  url=https://github.com/example/repo/pull/66
  case_dir=$(make_home_case queued-github-merge)
  add_gh_mocks "$case_dir" 9999999999999999999999999999999999999999
  write_github_outcome "$case_dir" OPEN false true main
  : >"$case_dir/gh-axi.log"

  FM_TEST_GH_MERGE_STATE=open FM_TEST_HOME="$case_dir/home" \
    run_pr_merge "$case_dir" task-x1 "$url" \
      >"$case_dir/stdout" 2>"$case_dir/stderr" \
    || fail "queued-github-merge: accepted merge command failed"

  assert_absent "$case_dir/state/.wake-queue" \
    "queued-github-merge: a queued merge was reported as landed"
  [ -f "$case_dir/state/task-x1.check.sh" ] \
    || fail "queued-github-merge: the merge poll was not left armed"
  [ ! -e "$case_dir/state/task-x1.pr-poll-merge-notified" ] \
    || fail "queued-github-merge: a queued merge was marked as reported"
  pass "a queued GitHub merge stays silent and leaves confirmation to the armed poll"
}

test_distinct_merged_prs_keep_distinct_wakes() {
  local case_dir first_url second_url
  first_url=https://github.com/example/repo/pull/68
  second_url=https://github.com/example/repo/pull/69
  case_dir=$(make_home_case distinct-merge-wakes)
  add_gh_mocks "$case_dir" bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  : >"$case_dir/gh-axi.log"

  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$first_url" \
    >"$case_dir/stdout-1" 2>"$case_dir/stderr-1" \
    || fail "distinct-merge-wakes: first merge failed"
  rm -f "$case_dir/state/task-x1.check.sh" \
    "$case_dir/state/task-x1.pr-poll" \
    "$case_dir/state/task-x1.pr-poll-registration"
  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$second_url" \
    >"$case_dir/stdout-2" 2>"$case_dir/stderr-2" \
    || fail "distinct-merge-wakes: second merge failed"

  [ "$(grep -c -F "$first_url" "$case_dir/state/.wake-queue")" -eq 1 ] \
    || fail "distinct-merge-wakes: first merge wake was missing or duplicated"
  [ "$(grep -c -F "$second_url" "$case_dir/state/.wake-queue")" -eq 1 ] \
    || fail "distinct-merge-wakes: second merge wake was missing or duplicated"
  FM_STATE_OVERRIDE="$case_dir/state" "$ROOT/bin/fm-wake-drain.sh" \
    >"$case_dir/drain.out" 2>"$case_dir/drain.err" \
    || fail "distinct-merge-wakes: wake drain failed"
  assert_grep "$first_url" "$case_dir/drain.out" \
    "distinct-merge-wakes: queue deduplication collapsed the first PR"
  assert_grep "$second_url" "$case_dir/drain.out" \
    "distinct-merge-wakes: queue deduplication collapsed the second PR"
  pass "distinct merged PRs for one task retain distinct captain-facing wakes"
}

test_uncommitted_marker_retry_is_never_silent() {
  local case_dir url count
  url=https://github.com/example/repo/pull/67
  case_dir=$(make_home_case uncommitted-wake-retry)
  add_gh_mocks "$case_dir" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  : >"$case_dir/gh-axi.log"
  cat >"$case_dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
case "${!#}" in
  *.pr-poll-merge-notified)
    if mkdir "$FM_TEST_MARKER_FAILURE.claim" 2>/dev/null; then
      exit 1
    fi
    ;;
esac
exec "$FM_TEST_REAL_MV" "$@"
SH
  chmod +x "$case_dir/fakebin/mv"
  export FM_TEST_MARKER_FAILURE="$case_dir/marker-failure"
  export FM_TEST_REAL_MV
  FM_TEST_REAL_MV=$(command -v mv)

  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" \
    >"$case_dir/stdout-1" 2>"$case_dir/stderr-1" \
    || fail "uncommitted-wake-retry: landed merge was reported as failed"
  assert_grep 'could not record the outcome' "$case_dir/stderr-1" \
    "uncommitted-wake-retry: failed marker commit was not loud"
  [ -f "$case_dir/state/task-x1.check.sh" ] \
    || fail "uncommitted-wake-retry: failed commit disarmed the retry poll"
  count=$(grep -c -F "$url" "$case_dir/state/.wake-queue")
  [ "$count" -ge 1 ] \
    || fail "uncommitted-wake-retry: failed marker commit lost the durable outcome"
  [ ! -e "$case_dir/state/task-x1.pr-poll-merge-notified" ] \
    || fail "uncommitted-wake-retry: failed marker commit was treated as complete"

  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" \
    >"$case_dir/stdout-2" 2>"$case_dir/stderr-2" \
    || fail "uncommitted-wake-retry: retry failed"
  unset FM_TEST_MARKER_FAILURE FM_TEST_REAL_MV
  count=$(grep -c -F "$url" "$case_dir/state/.wake-queue")
  [ "$count" -ge 1 ] \
    || fail "uncommitted-wake-retry: retry left the merge silent"
  [ -f "$case_dir/state/task-x1.pr-poll-merge-notified" ] \
    || fail "uncommitted-wake-retry: retry did not commit the canonical marker"
  pass "an uncommitted marker retry preserves at least one durable outcome"
}

test_secondmate_without_parent_binding_is_loud() {
  local case_dir rc url
  url=https://github.com/example/repo/pull/65
  case_dir=$(make_home_case unbound-secondmate)
  add_gh_mocks "$case_dir" 8888888888888888888888888888888888888888
  : >"$case_dir/gh-axi.log"
  # A secondmate identity with no parent binding: exactly the seeding gap that
  # let three real merges land in silence.
  printf '%s\n' mate-x >"$case_dir/home/.fm-secondmate-home"

  set +e
  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" \
    >"$case_dir/stdout" 2>"$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "unbound-secondmate: the merge itself landed and must not be reported as failed"
  assert_grep 'could not report it upward' "$case_dir/stderr" \
    "unbound-secondmate: a merge that could not be reported upward said nothing about it"
  assert_absent "$case_dir/state/.wake-queue" \
    "unbound-secondmate: a secondmate home fell back to the main-home record"
  pass "a secondmate home that cannot report upward says so instead of merging in silence"
}

test_github_zero_exit_queue_required_refuses_with_exact_retry
test_github_closed_unqueued_outcome_omits_retry_flags
test_github_agreeing_queue_rules_keep_retry_guidance
test_github_conflicting_queue_rules_report_ambiguity
test_verified_merge_records_pr_and_head
test_pr_metadata_is_recorded_before_the_forge_call
test_merge_failure_propagates_after_recording
test_github_open_unqueued_outcome_refuses
test_github_unreadable_outcome_keeps_pr_bookkeeping
test_github_refusal_quotes_the_forge_output
test_github_unreadable_outcome_refusal_quotes_the_forge_output
test_github_accepted_queue_flags_do_not_echo_back_the_same_command
test_github_mismatched_queue_flags_still_name_the_retry
test_github_unrecognised_queue_method_still_names_the_queue
test_github_unreadable_queue_rules_are_not_reported_as_no_queue
test_github_no_queue_rule_says_nothing_about_a_queue
test_github_fallback_view_refusal_says_the_queue_was_unobservable
test_github_auto_merge_without_queue_refuses_legibly
test_github_failed_merge_never_claims_armed_auto_merge
test_github_failed_merge_with_queue_flags_never_claims_acceptance
test_github_failed_gh_read_falls_back_to_gh_axi
test_github_failed_merge_names_an_observed_landed_state
test_github_without_gh_still_uses_gh_axi_merge
test_github_without_gh_failed_read_keeps_bookkeeping
test_github_merged_outcome_is_verified
test_github_verified_merge_requires_poll_recording
test_github_queued_outcome_is_verified
test_github_queue_required_refusal_names_retry_flags
test_extra_merge_args_forwarded
test_missing_meta_refuses_before_merge
test_malformed_url_refuses_before_merge
test_rejects_unsafe_url_segments_before_recording
test_repo_override_args_refuse_before_recording
test_bundled_repo_override_args_refuse_before_recording
test_explicit_merge_method_not_overridden
test_method_equals_merge_method_not_overridden
test_parses_pr_url_for_gh_axi
test_github_still_forwards_sha_arg
test_gitlab_url_resolves_and_merges
test_gitlab_host_comes_from_the_url
test_gitlab_imposes_no_merge_method
test_gitlab_extra_args_forwarded
test_gitlab_merge_failure_propagates
test_gitlab_each_condition_refuses_independently
test_gitlab_reports_every_failing_condition
test_gitlab_stale_recorded_head_is_reported
test_gitlab_unreadable_state_refuses
test_gitlab_invalid_head_refuses
test_gitlab_missing_tool_refuses_before_recording
test_gitlab_head_override_args_refuse_before_recording
test_default_squash_refused_for_stacked_pr
test_default_squash_refused_on_changed_file_threshold
test_squash_guard_boundary_is_more_than_the_threshold
test_single_commit_pr_still_squashes_by_default
test_explicit_squash_overrides_the_refusal
test_merge_and_rebase_unaffected_by_squash_guard
test_unreadable_commit_count_refuses_the_default_squash
test_stack_named_branch_warns_but_still_merges
test_gitlab_untouched_by_squash_guard

# --- pipeline-raised PR class (fm-pr-merge.sh --pipeline <url>) --------------
# The pipeline class has no task meta; it gates on live forge state read through
# `gh api`. These cases mock `gh api` per endpoint from fixture files and assert
# the green gate merges (pinned to head) while every failed gate refuses loudly
# and never invokes `gh-axi pr merge`.

PIPELINE_HEAD_SHA=1111111111111111111111111111111111111111

# pipeline_pull_json <case_dir> [state] [base] [mergeable_state] [commits] [files]
# The one pull payload the pipeline class reads. The squash guard reuses that
# same payload, so the gate fields and the counts live in one fixture.
pipeline_pull_json() {
  local case_dir=$1 state=${2:-open} base=${3:-main} mstate=${4:-clean}
  local commits=${5:-1} files=${6:-4}
  printf '{"state":"%s","base":{"ref":"%s"},"mergeable_state":"%s","head":{"sha":"%s"},"commits":%s,"changed_files":%s,"body":""}\n' \
    "$state" "$base" "$mstate" "$PIPELINE_HEAD_SHA" "$commits" "$files" > "$case_dir/fx/pull.json"
}

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
[ -z "${FM_TEST_AUDIT_SNAPSHOT:-}" ] || cp "$FM_STATE_OVERRIDE/forge-write-audit.log" "$FM_TEST_AUDIT_SNAPSHOT" 2>/dev/null || :
exit 0
SH
  chmod +x "$case_dir/fakebin/gh" "$case_dir/fakebin/gh-axi"
  printf '%s\n' '{"default_branch":"main"}' > "$fx/repo.json"
  pipeline_pull_json "$case_dir"
  printf '%s\n' '{"total_count":2,"check_runs":[{"status":"completed","conclusion":"success"},{"status":"completed","conclusion":"success"}]}' > "$fx/checks.json"
  printf '%s\n' '[]' > "$fx/reviews.json"
}

test_pipeline_merges_green_pr() {
  local case_dir rc FM_TEST_AUDIT_SNAPSHOT
  case_dir=$(make_case pipeline-green)
  add_pipeline_mocks "$case_dir"
  : > "$case_dir/gh-axi.log"
  FM_TEST_AUDIT_SNAPSHOT="$case_dir/audit-at-call"

  set +e
  run_pr_merge "$case_dir" --pipeline https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "pipeline-green: fm-pr-merge --pipeline should succeed on a green PR"
  grep -qxF "pr merge 9 --repo example/repo --match-head-commit $PIPELINE_HEAD_SHA --squash" "$case_dir/gh-axi.log" \
    || fail "pipeline-green: gh-axi pr merge was not invoked with --match-head-commit <head> and default --squash"
  assert_present "$case_dir/audit-at-call" \
    "pipeline-green: the forge was called before the write was recorded"
  assert_grep "class=pipeline" "$case_dir/audit-at-call" \
    "pipeline-green: audit line was not recorded"
  assert_grep "task=-" "$case_dir/audit-at-call" \
    "pipeline-green: a pipeline merge has no owning task and must say so"
  assert_grep "head=$PIPELINE_HEAD_SHA" "$case_dir/audit-at-call" \
    "pipeline-green: audit line did not record the gated head"
  pass "fm-pr-merge --pipeline merges a green PR pinned to head and records the write first"
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
  pipeline_pull_json "$case_dir" open main dirty
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
  assert_absent "$case_dir/state/forge-write-audit.log" \
    "pipeline-pin-override: a merge was recorded despite the pin override"
  pass "fm-pr-merge --pipeline refuses caller-supplied --match-head-commit overrides"
}

test_pipeline_refuses_stacked_default_squash() {
  local case_dir
  case_dir=$(make_case pipeline-stack)
  add_pipeline_mocks "$case_dir"
  pipeline_pull_json "$case_dir" open main clean 249 379
  expect_pipeline_refusal "$case_dir" pipeline-stack
  assert_grep 'it carries 249 commits and 379 changed files' "$case_dir/stderr" \
    "pipeline-stack: the refusal did not name the counts it actually read"
  assert_absent "$case_dir/state/forge-write-audit.log" \
    "pipeline-stack: a merge was recorded despite the squash refusal"
  pass "fm-pr-merge --pipeline refuses the default squash on a stacked PR"
}

test_pipeline_explicit_squash_merges_a_stack() {
  local case_dir rc
  case_dir=$(make_case pipeline-stack-explicit)
  add_pipeline_mocks "$case_dir"
  pipeline_pull_json "$case_dir" open main clean 249 379
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" --pipeline https://github.com/example/repo/pull/9 -- --squash \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "pipeline-stack-explicit: an explicit --squash should still merge a green stacked PR"
  grep -qxF "pr merge 9 --repo example/repo --match-head-commit $PIPELINE_HEAD_SHA --squash" "$case_dir/gh-axi.log" \
    || fail "pipeline-stack-explicit: an explicit --squash was not forwarded with the gated head pin"
  pass "fm-pr-merge --pipeline lets an explicit --squash override the stacked-PR refusal"
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
  assert_absent "$case_dir/state/forge-write-audit.log" \
    "pipeline-auto-override: a merge was recorded despite --auto"
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
test_pipeline_refuses_stacked_default_squash
test_pipeline_explicit_squash_merges_a_stack

# --- forge write audit log --------------------------------------------------
# Fourteen homes share one forge credential and the forge reports the same
# provenance for all of them, so the only record that can say which home merged
# is the one the acting home writes itself, before it acts.

AUDIT_LOG=state/forge-write-audit.log

test_audit_precedes_github_merge() {
  local case_dir FM_TEST_AUDIT_SNAPSHOT
  case_dir=$(make_case audit-github)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 5555555555555555555555555555555555555555
  : > "$case_dir/gh-axi.log"
  FM_TEST_AUDIT_SNAPSHOT="$case_dir/audit-at-call"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/31 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "audit-github: fm-pr-merge failed"

  assert_present "$case_dir/audit-at-call" \
    "audit-github: gh-axi pr merge ran before the write was recorded"
  assert_grep "home=$case_dir" "$case_dir/audit-at-call" \
    "audit-github: the record does not name the home that acted"
  assert_grep "task=task-x1" "$case_dir/audit-at-call" \
    "audit-github: the record does not name the task"
  assert_grep "action=pr-merge	target=https://github.com/example/repo/pull/31" \
    "$case_dir/audit-at-call" "audit-github: the record does not name the action and its target"
  head -1 "$case_dir/$AUDIT_LOG" | grep -qF 'absence of a line is not proof that no write occurred' \
    || fail "audit-github: the log does not state on creation what it fails to capture"
  pass "fm-pr-merge records a GitHub merge, and the log's own limit, before calling the forge"
}

test_audit_precedes_gitlab_merge() {
  local case_dir FM_TEST_AUDIT_SNAPSHOT
  case_dir=$(make_gitlab_case audit-gitlab)
  FM_TEST_AUDIT_SNAPSHOT="$case_dir/audit-at-call"

  run_pr_merge "$case_dir" task-x1 "$MR_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "audit-gitlab: fm-pr-merge failed"

  assert_present "$case_dir/audit-at-call" \
    "audit-gitlab: glab mr merge ran before the write was recorded"
  assert_grep "task=task-x1	action=mr-merge	target=$MR_URL" "$case_dir/audit-at-call" \
    "audit-gitlab: the record does not name the task, action, and target"
  assert_grep "head=$MR_HEAD" "$case_dir/audit-at-call" \
    "audit-gitlab: the record does not name the verified head"
  pass "fm-pr-merge records a GitLab merge before calling the forge"
}

test_audit_failure_refuses_the_merge() {
  local case_dir rc
  case_dir=$(make_case audit-unwritable)
  mkdir -p "$case_dir/wt"
  # A directory where the log belongs: the append fails however it is attempted.
  mkdir -p "$case_dir/$AUDIT_LOG"
  add_gh_mocks "$case_dir" 6666666666666666666666666666666666666666
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/32 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "audit-unwritable: an unrecordable merge should refuse"
  assert_grep 'forge write audit log could not be appended' "$case_dir/stderr" \
    "audit-unwritable: the refusal did not name the unwritable log"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "audit-unwritable: the forge was called even though the write could not be recorded"
  pass "fm-pr-merge refuses to merge rather than act unlogged"
}

test_audit_excludes_credential_material() {
  local case_dir
  case_dir=$(make_case audit-no-secrets)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 7777777777777777777777777777777777777777
  : > "$case_dir/gh-axi.log"

  export GH_TOKEN=ghp_environmentcredential000
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/33 -- \
    --squash --auth-token=ghp_argumentcredential111 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "audit-no-secrets: fm-pr-merge failed"
  unset GH_TOKEN

  # Non-vacuous: the secret-shaped argument really did reach the forge call.
  grep -qxF 'pr merge 33 --repo example/repo --squash --auth-token=ghp_argumentcredential111' \
    "$case_dir/gh-axi.log" || fail "audit-no-secrets: the extra argument never reached the merge"
  assert_no_grep 'ghp_argumentcredential111' "$case_dir/$AUDIT_LOG" \
    "audit-no-secrets: a caller argument reached the audit log"
  assert_no_grep 'ghp_environmentcredential000' "$case_dir/$AUDIT_LOG" \
    "audit-no-secrets: an environment credential reached the audit log"
  pass "the audit log carries no caller argument and no environment credential"
}

test_audit_precedes_github_merge
test_audit_precedes_gitlab_merge
test_audit_failure_refuses_the_merge
test_audit_excludes_credential_material
test_secondmate_merge_reports_upward_once
test_secondmate_merge_reports_on_the_local_route
test_gitlab_merge_reports_upward
test_queued_gitlab_merge_leaves_the_poll_armed
test_failed_merge_reports_nothing
test_gitlab_refusal_reports_nothing
test_main_home_merge_leaves_a_durable_wake
test_queued_github_merge_leaves_the_poll_armed
test_distinct_merged_prs_keep_distinct_wakes
test_uncommitted_marker_retry_is_never_silent
test_secondmate_without_parent_binding_is_loud
