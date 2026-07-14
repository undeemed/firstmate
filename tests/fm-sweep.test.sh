#!/usr/bin/env bash
# Tests for bin/fm-sweep.sh - the constant, safety-gated 3rd-mate sweep/prune.
#
# fm-sweep reaps this home's disposable crewmates (kind=ship/scout) whose agent
# is confidently dead (fm_backend_agent_alive) or idle-done, delegating every
# landed-work decision to bin/fm-teardown.sh (never --force) and every
# orphan-pool decision to `treehouse prune`. It must PROVABLY leave unlanded
# work, live/working crews, unknown agent readings, tasks with an armed
# check.sh merge poll, and secondmates untouched.
#
# Matrix (git-level fixtures + tmux/treehouse/crew-state stubs, no herdr):
#   (a) landed + confidently-dead agent (ship) -> REAPED (bare-shell pane, the
#       fm_backend_agent_alive dead reading)
#   (b) unknown agent reading                  -> LEFT (an unreadable pane, an
#       unattributable command, or no recorded target never licenses a reap)
#   (c) unlanded + uncommitted changes         -> LEFT (teardown refuses)
#   (d) unmerged fm/ branch, not landed        -> LEFT (teardown refuses)
#   (e) live/working crew, work landed         -> LEFT (working never reaped)
#   (f) alive+done PR-ready crew, armed check.sh -> LEFT (pending-check gate)
#   (g) done PR-mode crew, pushed+clean, no check.sh, no pr= -> LEFT on both
#       candidate paths (arming-window guard)
#   (h) pr= recorded, work on the remote, poll already removed -> REAPED
#       (teardown as before)
#   (i) kind=secondmate                        -> NEVER swept (skipped)
#   (j) orphan pass runs `treehouse prune --yes` per pool, never --all/--global
#   (k) a fresh sweep lock is a silent no-op; a provably-abandoned one is reclaimed
#   (l) idle treehouse-prune output stays quiet; a real prune is reported
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

  # tmux stub: `display-message` prints FM_TEST_TMUX_COMM (the pane's
  # foreground command, which fm_backend_agent_alive classifies: a harness
  # name = alive, a bare shell = dead, anything else = unknown) and exits
  # FM_TEST_TMUX_DISPLAY_RC (default 1 = unreadable pane -> unknown);
  # everything else (e.g. kill-window) succeeds silently.
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = display-message ]; then
  [ -n "${FM_TEST_TMUX_COMM:-}" ] && printf '%s\n' "$FM_TEST_TMUX_COMM"
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

test_landed_dead_crew_is_reaped() {
  local case_dir out
  case_dir=$(make_case landed-dead)
  write_meta "$case_dir" local-only ship
  wt_commit_file "$case_dir" feature.txt hello "landed work"
  # Merge the work into local main so it is LANDED for a local-only task.
  git -C "$case_dir/project" update-ref refs/heads/main "$(git -C "$case_dir/wt" rev-parse HEAD)"

  # A bare-shell pane is fm_backend_agent_alive's CONFIDENT dead reading: the
  # agent process exited and left the shell behind.
  out=$(run_sweep "$case_dir" FM_TEST_TMUX_COMM=bash FM_TEST_TMUX_DISPLAY_RC=0) \
    || fail "landed-dead: sweep exited non-zero"

  assert_absent "$case_dir/home/state/task-x1.meta" "landed-dead: meta should be removed (reaped)"
  assert_contains "$out" "reaped task-x1" "landed-dead: sweep did not report the reap"
  pass "landed crew with a confidently-dead agent (bare-shell pane) is reaped"
}

test_unknown_agent_reading_is_left() {
  local case_dir out
  case_dir=$(make_case unknown-agent)
  write_meta "$case_dir" local-only ship
  # Work IS landed: if the unknown-guard were broken, teardown would reap it.
  wt_commit_file "$case_dir" feature.txt hello "landed work"
  git -C "$case_dir/project" update-ref refs/heads/main "$(git -C "$case_dir/wt" rev-parse HEAD)"
  # A meta with no recorded target cannot be confirmed either way -> unknown.
  fm_write_meta "$case_dir/home/state/task-n2.meta" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=local-only"

  # Unreadable pane (default stub: display-message exits 1) -> unknown -> LEFT.
  out=$(run_sweep "$case_dir") || fail "unknown-agent: sweep exited non-zero"
  [ -z "$out" ] || fail "unknown-agent: an unreadable pane must stay quiet (got: $out)"
  assert_present "$case_dir/home/state/task-x1.meta" "unknown-agent: an unreadable pane must never reap"

  # A foreground command that is neither a harness nor a bare shell (a generic
  # interpreter, transient wrapper, ...) is also unknown -> LEFT.
  out=$(run_sweep "$case_dir" FM_TEST_TMUX_COMM=node FM_TEST_TMUX_DISPLAY_RC=0) \
    || fail "unknown-agent: sweep exited non-zero"
  [ -z "$out" ] || fail "unknown-agent: an unattributable command must stay quiet (got: $out)"
  assert_present "$case_dir/home/state/task-x1.meta" "unknown-agent: an unattributable command must never reap"
  assert_present "$case_dir/home/state/task-n2.meta" "unknown-agent: a meta with no recorded target must never be reaped"
  pass "an unknown agent reading (unreadable pane / unattributable command / no target) never reaps"
}

test_unlanded_uncommitted_is_left() {
  local case_dir out
  case_dir=$(make_case unlanded-dirty)
  write_meta "$case_dir" no-mistakes ship
  # pr= recorded so the arming-window guard passes and teardown itself refuses.
  printf 'pr=%s\n' "https://github.com/example/proj/pull/7" >> "$case_dir/home/state/task-x1.meta"
  wt_commit_file "$case_dir" feature.txt hello "committed"
  printf '%s\n' "uncommitted edit" > "$case_dir/wt/feature.txt"   # dirty

  # A confidently-dead candidate (bare-shell pane) that teardown then refuses.
  out=$(run_sweep "$case_dir" FM_TEST_TMUX_COMM=bash FM_TEST_TMUX_DISPLAY_RC=0) \
    || fail "unlanded-dirty: sweep exited non-zero"

  assert_present "$case_dir/home/state/task-x1.meta" "unlanded-dirty: meta must remain (left)"
  assert_contains "$out" "left task-x1" "unlanded-dirty: sweep did not report leaving it"
  pass "unlanded crew with uncommitted changes is LEFT (teardown refuses)"
}

test_unmerged_branch_is_left() {
  local case_dir out
  case_dir=$(make_case unmerged-branch)
  write_meta "$case_dir" no-mistakes ship
  # pr= recorded so the arming-window guard passes and teardown itself refuses.
  printf 'pr=%s\n' "https://github.com/example/proj/pull/7" >> "$case_dir/home/state/task-x1.meta"
  # Real commit on the fm/ branch, never pushed, PR unresolvable, not on
  # origin/main.
  wt_commit_file "$case_dir" feature.txt hello "unmerged work"

  out=$(run_sweep "$case_dir" FM_TEST_TMUX_COMM=bash FM_TEST_TMUX_DISPLAY_RC=0) \
    || fail "unmerged-branch: sweep exited non-zero"

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

  # A live agent process (a harness name in the pane) so crew-state is consulted.
  out=$(run_sweep "$case_dir" FM_TEST_TMUX_COMM=claude FM_TEST_TMUX_DISPLAY_RC=0 FM_CREW_STATE_BIN="$stub") \
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

  # Even with a confidently-dead agent (bare-shell pane), a secondmate is
  # never a candidate.
  out=$(run_sweep "$case_dir" FM_TEST_TMUX_COMM=bash FM_TEST_TMUX_DISPLAY_RC=0) \
    || fail "secondmate-skip: sweep exited non-zero"

  assert_present "$case_dir/home/state/dom-a1.meta" "secondmate-skip: secondmate meta must never be swept"
  assert_not_contains "$out" "dom-a1" "secondmate-skip: sweep touched a secondmate"
  pass "kind=secondmate meta is NEVER swept (persistent by design)"
}

# A landed crew that a sweep run with a confidently-dead agent reading
# (FM_TEST_TMUX_COMM=bash FM_TEST_TMUX_DISPLAY_RC=0) will reap.
make_reap_ready_case() {  # name
  local case_dir
  case_dir=$(make_case "$1")
  write_meta "$case_dir" local-only ship
  wt_commit_file "$case_dir" feature.txt hello "landed work"
  git -C "$case_dir/project" update-ref refs/heads/main "$(git -C "$case_dir/wt" rev-parse HEAD)"
  printf '%s\n' "$case_dir"
}

test_pr_ready_armed_check_is_left() {
  local case_dir out stub chk
  case_dir=$(make_case pr-ready-check)
  write_meta "$case_dir" no-mistakes ship
  # Work is pushed (remote-reachable), so teardown WOULD reap if the
  # pending-check gate were broken.
  wt_commit_file "$case_dir" feature.txt hello "PR work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  # PR open, checks green: crew-state reports done and the merge poll is armed.
  stub=$(make_crew_state_stub "$case_dir" "state: done · source: run · checks green: PR ready for review")
  chk="$case_dir/home/state/task-x1.check.sh"
  printf '%s\n' '#!/usr/bin/env bash' "touch '$case_dir/check-ran'" > "$chk"

  out=$(run_sweep "$case_dir" FM_TEST_TMUX_COMM=claude FM_TEST_TMUX_DISPLAY_RC=0 FM_CREW_STATE_BIN="$stub") \
    || fail "pr-ready-check: sweep exited non-zero"

  [ -z "$out" ] || fail "pr-ready-check: an armed merge poll must stay quiet (got: $out)"
  assert_present "$case_dir/home/state/task-x1.meta" "pr-ready-check: a PR-ready crew must not be reaped while its merge poll is armed"
  assert_present "$chk" "pr-ready-check: the armed merge poll must be preserved for the watcher's check pass"
  assert_absent "$case_dir/check-ran" "pr-ready-check: the sweep must not run the check itself"

  # The gate holds on the confident-dead path too (a crew that exited after
  # opening its PR still awaits the captain's merge).
  out=$(run_sweep "$case_dir" FM_TEST_TMUX_COMM=bash FM_TEST_TMUX_DISPLAY_RC=0) \
    || fail "pr-ready-check: dead-path sweep exited non-zero"
  assert_present "$case_dir/home/state/task-x1.meta" "pr-ready-check: a dead PR-ready crew with an armed poll must also be LEFT"
  assert_present "$chk" "pr-ready-check: the dead path must preserve the armed merge poll too"
  pass "an alive+done PR-ready crew with an armed check.sh is LEFT (pending-check gate)"
}

test_pr_mode_arming_window_is_left() {
  local case_dir out stub
  case_dir=$(make_case arming-window)
  write_meta "$case_dir" no-mistakes ship
  # Pushed + clean: teardown's pushed+clean path never consults the PR, so it
  # WOULD reap if the arming-window guard were broken.
  wt_commit_file "$case_dir" feature.txt hello "PR work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  # Checks green: the crew already reports done, but firstmate has not yet
  # handled the wake - no check.sh armed, no pr= recorded in the meta.
  stub=$(make_crew_state_stub "$case_dir" "state: done · source: run · checks green: PR ready for review")

  out=$(run_sweep "$case_dir" FM_TEST_TMUX_COMM=claude FM_TEST_TMUX_DISPLAY_RC=0 FM_CREW_STATE_BIN="$stub") \
    || fail "arming-window: sweep exited non-zero"
  [ -z "$out" ] || fail "arming-window: an unarmed PR-ready crew must stay quiet (got: $out)"
  assert_present "$case_dir/home/state/task-x1.meta" "arming-window: a done PR-mode crew with no check.sh and no pr= must not be reaped"

  # The guard holds on the confident-dead path too (a crew that exited right
  # after its checks went green, before firstmate armed the poll).
  out=$(run_sweep "$case_dir" FM_TEST_TMUX_COMM=bash FM_TEST_TMUX_DISPLAY_RC=0) \
    || fail "arming-window: dead-path sweep exited non-zero"
  [ -z "$out" ] || fail "arming-window: the dead path must stay quiet too (got: $out)"
  assert_present "$case_dir/home/state/task-x1.meta" "arming-window: a dead PR-mode crew with no check.sh and no pr= must not be reaped"
  pass "a done PR-mode crew in the check-arming window (no check.sh, no pr=) is LEFT on both paths"
}

test_pr_recorded_landed_crew_is_reaped() {
  local case_dir out
  case_dir=$(make_case pr-recorded)
  write_meta "$case_dir" no-mistakes ship
  printf 'pr=%s\n' "https://github.com/example/proj/pull/7" >> "$case_dir/home/state/task-x1.meta"
  # Work pushed (remote-reachable = landed) and the merge poll already removed
  # by the normal post-merge flow: teardown owns the decision as before.
  wt_commit_file "$case_dir" feature.txt hello "merged PR work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/origin.git" update-ref refs/heads/main "$(git -C "$case_dir/wt" rev-parse HEAD)"

  out=$(run_sweep "$case_dir" FM_TEST_TMUX_COMM=bash FM_TEST_TMUX_DISPLAY_RC=0) \
    || fail "pr-recorded: sweep exited non-zero"

  assert_contains "$out" "reaped task-x1" "pr-recorded: a pr=-recorded landed crew must still reap via teardown"
  assert_absent "$case_dir/home/state/task-x1.meta" "pr-recorded: meta should be removed (reaped)"
  pass "a pr=-recorded crew whose work is on the remote still reaps via teardown"
}

test_fresh_sweep_lock_is_silent_noop() {
  local case_dir out
  case_dir=$(make_reap_ready_case fresh-lock)
  mkdir "$case_dir/home/state/.sweep.lock"   # fresh: another sweep is running

  out=$(run_sweep "$case_dir" FM_TEST_TMUX_COMM=bash FM_TEST_TMUX_DISPLAY_RC=0) \
    || fail "fresh-lock: sweep exited non-zero"

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

  out=$(run_sweep "$case_dir" FM_TEST_TMUX_COMM=bash FM_TEST_TMUX_DISPLAY_RC=0) \
    || fail "stale-lock: sweep exited non-zero"

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

test_landed_dead_crew_is_reaped
test_unknown_agent_reading_is_left
test_unlanded_uncommitted_is_left
test_unmerged_branch_is_left
test_live_working_crew_is_left
test_secondmate_is_never_swept
test_pr_ready_armed_check_is_left
test_pr_mode_arming_window_is_left
test_pr_recorded_landed_crew_is_reaped
test_fresh_sweep_lock_is_silent_noop
test_stale_sweep_lock_is_reclaimed
test_orphan_pass_scopes_prune_per_pool
test_orphan_idle_output_stays_quiet
test_orphan_action_output_is_reported
