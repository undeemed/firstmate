#!/usr/bin/env bash
# Tests for bin/fm-sweep.sh - the constant, safety-gated 3rd-mate sweep/prune.
#
# fm-sweep reaps this home's disposable crewmates (kind=ship/scout) whose work
# has LANDED or whose endpoint is dead, delegating every landed-work decision to
# bin/fm-teardown.sh (never --force) and every orphan-pool decision to
# `treehouse prune`. It must PROVABLY leave unlanded work, live/working crews,
# and secondmates untouched.
#
# Matrix (git-level fixtures + tmux/treehouse/crew-state stubs, no herdr):
#   (a) landed + dead endpoint (ship)          -> REAPED, but only on the SECOND
#       consecutive dead probe (state/<id>.sweep-dead gates the first)
#   (b) unlanded + uncommitted changes         -> LEFT (teardown refuses)
#   (c) unmerged fm/ branch, not landed        -> LEFT (teardown refuses)
#   (d) live/working crew, work landed         -> LEFT (working never reaped)
#   (e) kind=secondmate                        -> NEVER swept (skipped)
#   (f) orphan pass runs `treehouse prune --yes` per pool, never --all/--global
#   (g) an alive observation clears the sweep-dead marker (transient outage)
#   (h) a pending check.sh runs once and is surfaced before teardown removes it
#   (i) a fresh sweep lock is a silent no-op; a provably-abandoned one is reclaimed
#   (j) idle treehouse-prune output stays quiet; a real prune is reported
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

SWEEP="$ROOT/bin/fm-sweep.sh"
TMP_ROOT=$(fm_test_tmproot fm-sweep-tests)

# Build a sandbox for one case:
#   $CASE/home/{state,projects,config} - a firstmate home (projects empty so the
#                                        orphan pass no-ops unless a test fills it)
#   $CASE/fakebin/                     - tmux, treehouse, gh-axi, gh stubs
#   $CASE/origin.git, $CASE/project, $CASE/wt - a project clone and task worktree
make_case() {
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/home/state" "$case_dir/home/projects" "$case_dir/home/config" "$fakebin"

  # tmux stub: `display-message` decides endpoint liveness via
  # FM_TEST_TMUX_DISPLAY_RC (default 1 = dead endpoint); everything else (e.g.
  # kill-window) succeeds silently.
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = display-message ]; then
  exit "${FM_TEST_TMUX_DISPLAY_RC:-1}"
fi
exit 0
SH
  # treehouse stub: return (teardown) and prune (orphan pass) both succeed,
  # printing FM_TEST_TREEHOUSE_OUT when set (silent otherwise), and every
  # invocation is logged for the orphan-scoping assertion.
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
[ -n "${FM_TEST_TREEHOUSE_LOG:-}" ] && printf '%s\n' "$*" >> "$FM_TEST_TREEHOUSE_LOG"
[ -n "${FM_TEST_TREEHOUSE_OUT:-}" ] && printf '%s\n' "$FM_TEST_TREEHOUSE_OUT"
exit 0
SH
  # No PR associated with any branch (keeps the landed-work check hermetic).
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []" ; exit 0 ;;
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux" "$fakebin/treehouse" "$fakebin/gh-axi" "$fakebin/gh"

  git init -q --bare "$case_dir/origin.git"
  git -C "$case_dir/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$case_dir/origin.git" "$case_dir/_seed" 2>/dev/null
  git -C "$case_dir/_seed" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "origin baseline"
  git -C "$case_dir/_seed" push -q origin main
  rm -rf "$case_dir/_seed"
  git clone -q "$case_dir/origin.git" "$case_dir/project"
  git -C "$case_dir/project" remote set-head origin main 2>/dev/null || true
  git -C "$case_dir/project" worktree add -q -b fm/task-x1 "$case_dir/wt" main

  # Fresh watcher beacon so fm-teardown's fm-guard call stays quiet.
  touch "$case_dir/home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir"
}

write_meta() {  # case_dir mode kind
  local case_dir=$1 mode=$2 kind=$3
  fm_write_meta "$case_dir/home/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=$kind" \
    "mode=$mode"
}

wt_commit_file() {  # case_dir file content [msg]
  local case_dir=$1 file=$2 content=$3 msg=${4:-add $2}
  printf '%s\n' "$content" > "$case_dir/wt/$file"
  git -C "$case_dir/wt" add -- "$file"
  git -C "$case_dir/wt" -c user.email=t@t -c user.name=t commit -q -m "$msg"
}

# Make a crew-state stub that always reports <state-line>. Echoes its path.
make_crew_state_stub() {  # case_dir state-line
  local case_dir=$1 line=$2 path
  path="$case_dir/crew-state-stub.sh"
  cat > "$path" <<SH
#!/usr/bin/env bash
printf '%s\n' "$line"
SH
  chmod +x "$path"
  printf '%s\n' "$path"
}

# run_sweep <case_dir> [KEY=VAL ...]: extra KEY=VAL become env for the sweep.
run_sweep() {
  local case_dir=$1; shift
  env FM_ROOT_OVERRIDE="$ROOT" \
      FM_HOME="$case_dir/home" \
      FM_STATE_OVERRIDE="$case_dir/home/state" \
      FM_PROJECTS_OVERRIDE="$case_dir/home/projects" \
      FM_CONFIG_OVERRIDE="$case_dir/home/config" \
      PATH="$case_dir/fakebin:$PATH" \
      "$@" "$SWEEP"
}

test_landed_dead_crew_is_reaped_on_second_probe() {
  local case_dir out marker
  case_dir=$(make_case landed-dead)
  write_meta "$case_dir" local-only ship
  wt_commit_file "$case_dir" feature.txt hello "landed work"
  # Merge the work into local main so it is LANDED for a local-only task.
  git -C "$case_dir/project" update-ref refs/heads/main "$(git -C "$case_dir/wt" rev-parse HEAD)"
  marker="$case_dir/home/state/task-x1.sweep-dead"

  # Default tmux stub: display-message exits 1 -> dead endpoint. The FIRST dead
  # probe is not a confident reading: it records the marker and skips, quietly.
  out=$(run_sweep "$case_dir") || fail "landed-dead: first sweep exited non-zero"
  [ -z "$out" ] || fail "landed-dead: first dead probe must stay quiet (got: $out)"
  assert_present "$case_dir/home/state/task-x1.meta" "landed-dead: first dead probe must not reap"
  assert_present "$marker" "landed-dead: first dead probe must record the sweep-dead marker"

  # SECOND consecutive dead probe: confident dead reading -> candidate -> reaped.
  out=$(run_sweep "$case_dir") || fail "landed-dead: second sweep exited non-zero"
  assert_absent "$case_dir/home/state/task-x1.meta" "landed-dead: meta should be removed (reaped)"
  assert_contains "$out" "reaped task-x1" "landed-dead: sweep did not report the reap"
  assert_absent "$marker" "landed-dead: teardown must remove the sweep-dead marker"
  pass "landed + dead-endpoint crew is reaped on the second consecutive dead probe"
}

test_alive_observation_clears_dead_marker() {
  local case_dir out stub marker
  case_dir=$(make_case transient-dead)
  write_meta "$case_dir" local-only ship
  wt_commit_file "$case_dir" feature.txt hello "landed work"
  git -C "$case_dir/project" update-ref refs/heads/main "$(git -C "$case_dir/wt" rev-parse HEAD)"
  marker="$case_dir/home/state/task-x1.sweep-dead"
  touch "$marker"   # a previous sweep hit a transient outage (dead probe)
  stub=$(make_crew_state_stub "$case_dir" "state: working · source: pane · harness busy")

  # The endpoint is back: the marker must be cleared and the crew left alone.
  out=$(run_sweep "$case_dir" FM_TEST_TMUX_DISPLAY_RC=0 FM_CREW_STATE_BIN="$stub") \
    || fail "transient-dead: sweep exited non-zero"

  assert_absent "$marker" "transient-dead: an alive observation must clear the sweep-dead marker"
  assert_present "$case_dir/home/state/task-x1.meta" "transient-dead: crew must not be reaped"
  assert_not_contains "$out" "reaped task-x1" "transient-dead: sweep wrongly reaped after a transient outage"
  pass "an alive observation clears the sweep-dead marker (transient outage never reaps)"
}

test_unlanded_uncommitted_is_left() {
  local case_dir out
  case_dir=$(make_case unlanded-dirty)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "committed"
  printf '%s\n' "uncommitted edit" > "$case_dir/wt/feature.txt"   # dirty

  # Two sweeps: the first dead probe only records the marker; the second is the
  # confident-dead candidate teardown then refuses.
  run_sweep "$case_dir" >/dev/null || fail "unlanded-dirty: first sweep exited non-zero"
  out=$(run_sweep "$case_dir") || fail "unlanded-dirty: sweep exited non-zero"

  assert_present "$case_dir/home/state/task-x1.meta" "unlanded-dirty: meta must remain (left)"
  assert_contains "$out" "left task-x1" "unlanded-dirty: sweep did not report leaving it"
  pass "unlanded crew with uncommitted changes is LEFT (teardown refuses)"
}

test_unmerged_branch_is_left() {
  local case_dir out
  case_dir=$(make_case unmerged-branch)
  write_meta "$case_dir" no-mistakes ship
  # Real commit on the fm/ branch, never pushed, no PR, not on origin/main.
  wt_commit_file "$case_dir" feature.txt hello "unmerged work"

  run_sweep "$case_dir" >/dev/null || fail "unmerged-branch: first sweep exited non-zero"
  out=$(run_sweep "$case_dir") || fail "unmerged-branch: sweep exited non-zero"

  assert_present "$case_dir/home/state/task-x1.meta" "unmerged-branch: meta must remain (left)"
  assert_contains "$out" "left task-x1" "unmerged-branch: sweep did not report leaving it"
  pass "crew with an unmerged fm/ branch is LEFT (teardown refuses)"
}

test_live_working_crew_is_left() {
  local case_dir out stub
  case_dir=$(make_case live-working)
  write_meta "$case_dir" local-only ship
  # Work IS landed: if the working-guard were broken, teardown would reap it.
  wt_commit_file "$case_dir" feature.txt hello "landed but still working"
  git -C "$case_dir/project" update-ref refs/heads/main "$(git -C "$case_dir/wt" rev-parse HEAD)"
  stub=$(make_crew_state_stub "$case_dir" "state: working · source: pane · harness busy")

  # Alive endpoint (display-message exits 0) so crew-state is consulted.
  out=$(run_sweep "$case_dir" FM_TEST_TMUX_DISPLAY_RC=0 FM_CREW_STATE_BIN="$stub") \
    || fail "live-working: sweep exited non-zero"

  assert_present "$case_dir/home/state/task-x1.meta" "live-working: a working crew must never be reaped"
  assert_not_contains "$out" "reaped task-x1" "live-working: sweep wrongly reaped a working crew"
  pass "live/working crew is LEFT even when its work has landed (never reap a working agent)"
}

test_secondmate_is_never_swept() {
  local case_dir out
  case_dir=$(make_case secondmate-skip)
  fm_write_meta "$case_dir/home/state/dom-a1.meta" \
    "window=fm-dom-a1" \
    "worktree=$case_dir/home/dom-home" \
    "project=$case_dir/home/dom-home" \
    "kind=secondmate" \
    "mode=secondmate" \
    "home=$case_dir/home/dom-home"

  # Even with a dead endpoint (default stub), a secondmate is never a candidate.
  out=$(run_sweep "$case_dir") || fail "secondmate-skip: sweep exited non-zero"

  assert_present "$case_dir/home/state/dom-a1.meta" "secondmate-skip: secondmate meta must never be swept"
  assert_not_contains "$out" "dom-a1" "secondmate-skip: sweep touched a secondmate"
  pass "kind=secondmate meta is NEVER swept (persistent by design)"
}

# A landed, confidently-dead crew that a single sweep run will reap (the
# sweep-dead marker is pre-seeded so the two-probe gate is already satisfied).
make_reap_ready_case() {  # name
  local case_dir
  case_dir=$(make_case "$1")
  write_meta "$case_dir" local-only ship
  wt_commit_file "$case_dir" feature.txt hello "landed work"
  git -C "$case_dir/project" update-ref refs/heads/main "$(git -C "$case_dir/wt" rev-parse HEAD)"
  touch "$case_dir/home/state/task-x1.sweep-dead"
  printf '%s\n' "$case_dir"
}

test_pending_check_runs_before_teardown() {
  local case_dir out
  case_dir=$(make_reap_ready_case check-before-teardown)
  printf '%s\n' '#!/usr/bin/env bash' 'echo "PR https://github.com/o/r/pull/7 merged"' \
    > "$case_dir/home/state/task-x1.check.sh"

  out=$(run_sweep "$case_dir") || fail "check-before-teardown: sweep exited non-zero"

  assert_contains "$out" "check task-x1: PR https://github.com/o/r/pull/7 merged" \
    "check-before-teardown: pending check output must be folded into the summary"
  assert_contains "$out" "reaped task-x1" "check-before-teardown: the reap should still proceed"
  assert_absent "$case_dir/home/state/task-x1.check.sh" "check-before-teardown: teardown should remove the check"
  pass "a pending check.sh runs once and its wake output is surfaced before teardown removes it"
}

test_fresh_sweep_lock_is_silent_noop() {
  local case_dir out
  case_dir=$(make_reap_ready_case fresh-lock)
  mkdir "$case_dir/home/state/.sweep.lock"   # fresh: another sweep is running

  out=$(run_sweep "$case_dir") || fail "fresh-lock: sweep exited non-zero"

  [ -z "$out" ] || fail "fresh-lock: sweep must stay quiet while the lock is held (got: $out)"
  assert_present "$case_dir/home/state/task-x1.meta" "fresh-lock: meta must remain while the lock is held"
  pass "a fresh (live) sweep lock makes an overlapping run a silent no-op"
}

test_stale_sweep_lock_is_reclaimed() {
  local case_dir out lock
  case_dir=$(make_reap_ready_case stale-lock)

  # An abandoned lock (a sweep killed without its EXIT trap running): old mtime,
  # no live holder. The lsof stub proves "no holder" (exit 1, empty output).
  lock="$case_dir/home/state/.sweep.lock"
  mkdir "$lock"
  touch -t 202001010000 "$lock"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 1' > "$case_dir/fakebin/lsof"
  chmod +x "$case_dir/fakebin/lsof"

  out=$(run_sweep "$case_dir") || fail "stale-lock: sweep exited non-zero"

  assert_contains "$out" "reaped task-x1" "stale-lock: an abandoned sweep lock must be reclaimed"
  assert_absent "$case_dir/home/state/task-x1.meta" "stale-lock: meta should be removed after the reclaim"
  pass "a provably-abandoned sweep lock is reclaimed (a killed sweep cannot disable the sweep forever)"
}

test_orphan_pass_scopes_prune_per_pool() {
  local case_dir log out
  case_dir=$(make_case orphan-prune)
  # A project clone under the home's projects/ dir drives the orphan pass.
  git init -q "$case_dir/home/projects/proj"
  git -C "$case_dir/home/projects/proj" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  log="$case_dir/treehouse.log"

  out=$(run_sweep "$case_dir" FM_TEST_TREEHOUSE_LOG="$log") || fail "orphan-prune: sweep exited non-zero"

  assert_present "$log" "orphan-prune: treehouse was never invoked"
  assert_grep "prune --yes" "$log" "orphan-prune: did not run 'treehouse prune --yes'"
  assert_no_grep "--all" "$log" "orphan-prune: must never sweep with --all"
  assert_no_grep "--global" "$log" "orphan-prune: must never sweep with --global"
  pass "orphan pass runs 'treehouse prune --yes' per pool, never --all/--global"
}

test_orphan_idle_output_stays_quiet() {
  local case_dir out idle
  case_dir=$(make_case orphan-idle)
  git init -q "$case_dir/home/projects/proj"
  git -C "$case_dir/home/projects/proj" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

  for idle in "nothing to prune" "No worktrees removed" "0 removed"; do
    out=$(run_sweep "$case_dir" FM_TEST_TREEHOUSE_OUT="$idle") \
      || fail "orphan-idle: sweep exited non-zero for '$idle'"
    [ -z "$out" ] || fail "orphan-idle: idle output '$idle' must stay quiet (got: $out)"
  done
  pass "idle treehouse-prune output (nothing to prune / nothing removed / 0 removed) stays quiet"
}

test_orphan_action_output_is_reported() {
  local case_dir out
  case_dir=$(make_case orphan-action)
  git init -q "$case_dir/home/projects/proj"
  git -C "$case_dir/home/projects/proj" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

  out=$(run_sweep "$case_dir" FM_TEST_TREEHOUSE_OUT="Pruned 1 worktree (task-old-z9)") \
    || fail "orphan-action: sweep exited non-zero"

  assert_contains "$out" "orphan worktrees proj: Pruned 1 worktree" "orphan-action: a real prune must be reported"
  pass "a real treehouse prune is reported as an orphan-worktrees line"
}

test_landed_dead_crew_is_reaped_on_second_probe
test_alive_observation_clears_dead_marker
test_unlanded_uncommitted_is_left
test_unmerged_branch_is_left
test_live_working_crew_is_left
test_secondmate_is_never_swept
test_pending_check_runs_before_teardown
test_fresh_sweep_lock_is_silent_noop
test_stale_sweep_lock_is_reclaimed
test_orphan_pass_scopes_prune_per_pool
test_orphan_idle_output_stays_quiet
test_orphan_action_output_is_reported
