#!/usr/bin/env bash
# Regression test for fm-spawn.sh's occupied-checkout refusal (the
# assert_worktree_unclaimed call after the isolation assertion).
#
# A treehouse pool binds a non-leased worktree to its worker only through the
# processes living in it, so a slot whose worker has no process with a cwd
# inside it - because a sibling teardown returned the path, or because the
# worker's own processes live elsewhere - is handed straight back out by the
# next `treehouse get`. Before this refusal existed, fm-spawn checked only that
# the resolved path was a real git worktree distinct from the primary checkout,
# so both tasks recorded the same worktree= and the second worker's
# `git checkout -b` rewrote the working tree of the first, still-live worker.
#
# These cases drive a fake pool that always hands back the same worktree and
# assert the second spawn refuses, names the conflicting task, and touches
# neither the shared checkout nor its own metadata - while an ordinary spawn
# onto a free worktree and a same-task relaunch both still succeed.
#
# The orca cases cover the refusal firing while destructive abort cleanup is
# armed: the orca spawn path arms an EXIT-trap cleanup (kill the terminal,
# remove the worktree, publish fallback metadata) before the occupied-checkout
# check runs, and a refusal must drop that arming so the trap does to the
# contested checkout none of what the refusal forbids.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-worktree-collision)

# make_collision_fakebin <dir> [treehouse-status-json]: a fake tmux whose
# `#{pane_current_path}` query always answers FM_FAKE_PANE_PATH (the pool
# handing the same worktree out twice), plus a fake treehouse whose
# `status --json` answers the supplied pool state (empty = no pool JSON, the
# unreadable-lease-state case).
make_collision_fakebin() {
  local dir=$1 json=${2:-} fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/treehouse" <<SH
#!/usr/bin/env bash
set -u
if [ "\${1:-}" = status ] && [ "\${2:-}" = --json ]; then
  printf '%s' '$json'
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/treehouse"
  printf '%s\n' "$fakebin"
}

# add_orca_fake <fakebin-dir>: a fake orca CLI that reports a ready runtime,
# hands back FM_FAKE_ORCA_WT as the created worktree (with a terminal handle),
# and logs every call to FM_FAKE_ORCA_LOG. Its `worktree rm` REALLY deletes the
# contested checkout, so a refusal that leaves the abort cleanup armed destroys
# the co-tenant's checkout and fails the intact-checkout assertions below.
add_orca_fake() {
  local fakebin=$1
  cat > "$fakebin/orca" <<'SH'
#!/usr/bin/env bash
set -u
{
  printf 'orca'
  for a in "$@"; do printf '\x1f%s' "$a"; done
  printf '\n'
} >> "${FM_FAKE_ORCA_LOG:?}"
case "${1:-} ${2:-}" in
  'status --json')
    printf '{"ok":true,"result":{"runtime":{"reachable":true,"state":"ready"}}}\n'
    ;;
  'repo show'|'repo add')
    printf '{"ok":true,"result":{"repo":{"id":"repo-1"}}}\n'
    ;;
  'worktree create')
    printf '{"ok":true,"result":{"worktree":{"id":"wt-1","path":"%s"},"terminal":{"handle":"term-1"}}}\n' "${FM_FAKE_ORCA_WT:?}"
    ;;
  'worktree rm')
    rm -rf "${FM_FAKE_ORCA_WT:?}"
    printf '{"ok":true}\n'
    ;;
  *)
    printf '{"ok":true}\n'
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/orca"
}

# make_collision_case <name> [treehouse-status-json]: a home, a project, and one
# pool worktree that every spawn in the case is handed.
make_collision_case() {
  local name=$1 json=${2:-} case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_collision_fakebin "$case_dir/fake" "$json")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  printf '%s|%s|%s|%s\n' "$home" "$proj" "$wt" "$fakebin"
}

read_collision_record() {
  IFS='|' read -r HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

# run_collision_spawn <id> [pane-path]: spawn <id> against the case's project,
# with the pane landing in [pane-path] (the shared worktree by default).
run_collision_spawn() {
  local id=$1 pane=${2:-$WT_DIR}
  mkdir -p "$HOME_DIR/data/$id"
  printf 'brief for %s\n' "$id" > "$HOME_DIR/data/$id/brief.md"
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$pane" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
}

# run_orca_collision_spawn <id>: spawn <id> on the orca path, where the fake
# orca hands back the case's shared worktree and the abort cleanup is armed
# before the occupied-checkout check runs.
run_orca_collision_spawn() {
  local id=$1
  mkdir -p "$HOME_DIR/data/$id"
  printf 'brief for %s\n' "$id" > "$HOME_DIR/data/$id/brief.md"
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 \
    FM_FAKE_ORCA_LOG="$ORCA_LOG" FM_FAKE_ORCA_WT="$WT_DIR" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off --backend orca 2>&1
}

assert_no_destructive_orca_calls() {
  ! grep -q $'\x1fworktree\x1frm' "$ORCA_LOG" \
    || fail "the refused spawn still removed the orca worktree"
  ! grep -q $'\x1fterminal\x1fclose' "$ORCA_LOG" \
    || fail "the refused spawn still closed the orca terminal"
}

# The incident: a second spawn is handed the checkout a live task already
# records. It must refuse, name that task, and publish nothing.
test_second_spawn_onto_occupied_checkout_refuses() {
  local rec live new out status
  live=collide-live-a1
  new=collide-new-b2
  rec=$(make_collision_case occupied)
  read_collision_record "$rec"

  out=$(run_collision_spawn "$live")
  expect_code 0 "$?" "the first spawn should take the free worktree"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$live.meta" \
    "the first task did not record the pool worktree"

  out=$(run_collision_spawn "$new")
  status=$?
  expect_code 1 "$status" "the second spawn onto an occupied checkout should refuse"
  assert_contains "$out" "$live" "the refusal did not name the conflicting task"
  assert_contains "$out" "already records as its worktree" \
    "the refusal did not report the conflicting durable record"
  assert_absent "$HOME_DIR/state/$new.meta" \
    "the refused spawn still published metadata for a checkout another task owns"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$live.meta" \
    "the live task's own record was disturbed by the refusal"
  pass "a second spawn onto an occupied checkout refuses and names the conflicting task"
}

# The refusal must land before anything is written into the shared checkout, so
# the live worker's tree is byte-identical afterwards.
test_refusal_leaves_the_shared_checkout_untouched() {
  local rec live new before after
  live=collide-quiet-c3
  new=collide-quiet-d4
  rec=$(make_collision_case untouched)
  read_collision_record "$rec"

  run_collision_spawn "$live" > /dev/null
  before=$( (cd "$WT_DIR" && LC_ALL=C ls -A; git -C "$WT_DIR" status --porcelain) )
  run_collision_spawn "$new" > /dev/null || true
  after=$( (cd "$WT_DIR" && LC_ALL=C ls -A; git -C "$WT_DIR" status --porcelain) )

  [ "$before" = "$after" ] || fail "the refused spawn modified the shared checkout"$'\n'"before:"$'\n'"$before"$'\n'"after:"$'\n'"$after"
  assert_absent "$FM_TASKTMP_ROOT/fm-$new" "the refused spawn created its per-task temp root"
  pass "a refused spawn leaves the occupied checkout and its own scratch state untouched"
}

# The claim is on the resolved worktree, not on the exact string: a pane that
# reports a symlinked route into the same checkout is the same collision.
test_symlinked_route_to_an_occupied_checkout_refuses() {
  local rec live new link out status
  live=collide-real-e5
  new=collide-link-f6
  rec=$(make_collision_case symlinked)
  read_collision_record "$rec"
  link="$TMP_ROOT/symlinked/link-to-wt"
  ln -s "$WT_DIR" "$link"

  run_collision_spawn "$live" > /dev/null
  out=$(run_collision_spawn "$new" "$link")
  status=$?
  expect_code 1 "$status" "a symlinked route into an occupied checkout should refuse"
  assert_contains "$out" "$live" "the refusal did not name the conflicting task"
  assert_absent "$HOME_DIR/state/$new.meta" \
    "the refused spawn published metadata for a symlinked route into an occupied checkout"
  pass "a symlinked route into an occupied checkout is refused as the same collision"
}

# A worktree the pool records as leased to someone else is another home's
# durable claim, invisible in this home's metadata.
test_pool_lease_by_another_holder_refuses() {
  local rec id json out status
  id=collide-leased-g7
  if ! command -v jq > /dev/null 2>&1 && ! command -v python3 > /dev/null 2>&1; then
    echo "# skip: neither jq nor python3 is available to read pool lease state"
    return 0
  fi
  rec=$(make_collision_case leased-placeholder)
  read_collision_record "$rec"
  # Rebuild the fake treehouse now that the worktree path is known.
  json="[{\"name\":\"1\",\"path\":\"$WT_DIR\",\"status\":\"leased\",\"lease_id\":\"abc\",\"lease_holder\":\"other-home-mate\",\"processes\":[]}]"
  FAKEBIN_DIR=$(make_collision_fakebin "$TMP_ROOT/leased-placeholder/fake2" "$json")

  out=$(run_collision_spawn "$id")
  status=$?
  expect_code 1 "$status" "a spawn onto a worktree leased to another holder should refuse"
  assert_contains "$out" "other-home-mate" "the refusal did not name the lease holder"
  assert_absent "$HOME_DIR/state/$id.meta" \
    "the refused spawn published metadata for a worktree leased to another holder"
  pass "a worktree leased to another holder refuses and names that holder"
}

# The check must not fire on a task's own record: recovery relaunches reuse the
# same id and the same worktree.
test_same_task_relaunch_is_not_a_collision() {
  local rec id out status
  id=collide-relaunch-h8
  rec=$(make_collision_case relaunch)
  read_collision_record "$rec"

  run_collision_spawn "$id" > /dev/null
  out=$(run_collision_spawn "$id")
  status=$?
  expect_code 0 "$status" "relaunching the same task into its own worktree should succeed"
  assert_contains "$out" "spawned $id" "the relaunch did not report success"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "the relaunch did not record its own worktree"
  pass "a same-task relaunch into its own recorded worktree is not a collision"
}

# An unrelated task recorded elsewhere must not block a free worktree.
test_free_worktree_still_spawns() {
  local rec id other out status
  id=collide-free-i9
  other=collide-elsewhere-j1
  rec=$(make_collision_case free)
  read_collision_record "$rec"
  fm_write_meta "$HOME_DIR/state/$other.meta" \
    "window=firstmate:fm-$other" \
    "worktree=$TMP_ROOT/free/some-other-worktree" \
    "project=$PROJ_DIR" \
    "harness=codex" \
    "kind=ship"

  out=$(run_collision_spawn "$id")
  status=$?
  expect_code 0 "$status" "a spawn onto a free worktree should still succeed"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "the spawn did not record its worktree"
  pass "an unrelated task's record does not block a free worktree"
}

# The per-task build cache belongs to the spawn: it creates one home-scoped
# directory per task and records it, so teardown has a path it can prove belongs
# to this task and to no co-tenant.
test_spawn_creates_and_records_the_task_build_cache() {
  local rec id status
  id=collide-cache-n4
  rec=$(make_collision_case cache)
  read_collision_record "$rec"

  run_collision_spawn "$id" > /dev/null
  status=$?
  expect_code 0 "$status" "a spawn onto a free worktree should succeed"
  assert_grep "build_cache=$HOME_DIR/build-caches/$id" "$HOME_DIR/state/$id.meta" \
    "the spawn did not record the task's build cache"
  [ -d "$HOME_DIR/build-caches/$id" ] \
    || fail "the spawn did not create the task's build cache directory"
  pass "a spawn creates and records one home-scoped build cache per task"
}

# The durable-record refusal with orca's destructive abort cleanup armed: the
# EXIT trap must kill no terminal, remove no worktree, and publish no fallback
# metadata for the refused task.
test_orca_collision_refusal_runs_no_armed_cleanup() {
  local rec live new out status
  live=collide-orca-live-k2
  new=collide-orca-new-m3
  if ! command -v node > /dev/null 2>&1; then
    echo "# skip: node is not available to drive the orca backend adapter"
    return 0
  fi
  rec=$(make_collision_case orca-armed)
  read_collision_record "$rec"
  add_orca_fake "$FAKEBIN_DIR"
  ORCA_LOG="$TMP_ROOT/orca-armed/orca.log"
  : > "$ORCA_LOG"
  fm_write_meta "$HOME_DIR/state/$live.meta" \
    "window=firstmate:fm-$live" \
    "worktree=$WT_DIR" \
    "project=$PROJ_DIR" \
    "harness=codex" \
    "kind=ship"

  out=$(run_orca_collision_spawn "$new")
  status=$?
  expect_code 1 "$status" "an orca spawn onto an occupied checkout should refuse"
  assert_contains "$out" "$live" "the refusal did not name the conflicting task"
  [ -d "$WT_DIR" ] || fail "the armed abort cleanup removed the contested checkout"
  [ -f "$WT_DIR/README.md" ] || fail "the contested checkout lost its contents"
  git -C "$WT_DIR" status --porcelain > /dev/null 2>&1 \
    || fail "the contested checkout is no longer a working git worktree"
  assert_absent "$HOME_DIR/state/$new.meta" \
    "the refused orca spawn published metadata for an occupied checkout"
  assert_no_destructive_orca_calls
  pass "an orca collision refusal disarms the destructive abort cleanup"
}

# The pool-lease refusal is a separate exit path and must drop the same arming.
test_orca_lease_refusal_runs_no_armed_cleanup() {
  local rec id json out status
  id=collide-orca-leased-n4
  if ! command -v node > /dev/null 2>&1; then
    echo "# skip: node is not available to drive the orca backend adapter"
    return 0
  fi
  if ! command -v jq > /dev/null 2>&1 && ! command -v python3 > /dev/null 2>&1; then
    echo "# skip: neither jq nor python3 is available to read pool lease state"
    return 0
  fi
  rec=$(make_collision_case orca-leased)
  read_collision_record "$rec"
  json="[{\"name\":\"1\",\"path\":\"$WT_DIR\",\"status\":\"leased\",\"lease_id\":\"abc\",\"lease_holder\":\"other-home-mate\",\"processes\":[]}]"
  FAKEBIN_DIR=$(make_collision_fakebin "$TMP_ROOT/orca-leased/fake2" "$json")
  add_orca_fake "$FAKEBIN_DIR"
  ORCA_LOG="$TMP_ROOT/orca-leased/orca.log"
  : > "$ORCA_LOG"

  out=$(run_orca_collision_spawn "$id")
  status=$?
  expect_code 1 "$status" "an orca spawn onto a leased worktree should refuse"
  assert_contains "$out" "other-home-mate" "the refusal did not name the lease holder"
  [ -d "$WT_DIR" ] || fail "the armed abort cleanup removed the leased checkout"
  [ -f "$WT_DIR/README.md" ] || fail "the leased checkout lost its contents"
  assert_absent "$HOME_DIR/state/$id.meta" \
    "the refused orca spawn published metadata for a leased worktree"
  assert_no_destructive_orca_calls
  pass "an orca lease refusal disarms the destructive abort cleanup"
}

# The secondmate path knows its worktree - the home itself - before any pane
# exists, and every pre-launch step writes into it: the ff sync, the state
# directory, the inheritance and trace-context propagation. The record axis
# must refuse before the first of those writes. The fixture's home sits one
# commit behind its primary on main, so a regressed order (check after the ff
# sync) visibly advances HEAD and fails the byte-unchanged assertions below.
test_secondmate_collision_refuses_before_touching_the_home() {
  local case_dir primary home active live new fakebin out status c1 before after
  live=collide-sm-live-p5
  new=collide-sm-new-q6
  case_dir="$TMP_ROOT/secondmate-early"
  primary="$case_dir/primary"
  home="$case_dir/sm-home"
  active="$case_dir/active-home"
  mkdir -p "$active/data/$new" "$active/state" "$active/config" "$active/projects"
  touch "$active/state/.last-watcher-beat"
  printf 'brief for %s\n' "$new" > "$active/data/$new/brief.md"
  git init -q -b main "$primary"
  printf 'state/\ndata/\nconfig/\nprojects/\n.fm-secondmate-home\n' > "$primary/.gitignore"
  printf 'v1\n' > "$primary/AGENTS.md"
  mkdir -p "$primary/bin"
  printf 'echo a\n' > "$primary/bin/tool.sh"
  git -C "$primary" add -A
  git -C "$primary" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm c1
  c1=$(git -C "$primary" rev-parse HEAD)
  printf 'v2\n' > "$primary/AGENTS.md"
  git -C "$primary" add -A
  git -C "$primary" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm c2
  git clone -q "$primary" "$home" 2>/dev/null
  git -C "$home" reset -q --hard "$c1"
  printf '%s\n' "$new" > "$home/.fm-secondmate-home"
  fm_write_meta "$active/state/$live.meta" \
    "window=firstmate:fm-$live" \
    "worktree=$home" \
    "project=$primary" \
    "harness=codex" \
    "kind=ship"
  fakebin=$(make_collision_fakebin "$case_dir/fake")

  before=$( (cd "$home" && LC_ALL=C ls -A; git -C "$home" status --porcelain) )
  out=$(FM_ROOT_OVERRIDE="$primary" FM_HOME="$active" \
    FM_STATE_OVERRIDE="$active/state" FM_DATA_OVERRIDE="$active/data" \
    FM_PROJECTS_OVERRIDE="$active/projects" FM_CONFIG_OVERRIDE="$active/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$new" "$home" codex --secondmate 2>&1)
  status=$?
  after=$( (cd "$home" && LC_ALL=C ls -A; git -C "$home" status --porcelain) )

  expect_code 1 "$status" "a secondmate spawn onto a home another task records should refuse"
  assert_contains "$out" "$live" "the refusal did not name the conflicting task"
  assert_contains "$out" "refusing to launch $new into an occupied checkout" \
    "the spawn did not fail with the occupied-checkout refusal"
  [ "$(git -C "$home" rev-parse HEAD)" = "$c1" ] \
    || fail "the refused spawn fast-forwarded the contested home off $c1"
  [ "$(git -C "$home" symbolic-ref --short HEAD)" = main ] \
    || fail "the refused spawn moved the contested home off its branch"
  [ ! -e "$home/state" ] || fail "the refused spawn created the home's state directory"
  [ ! -e "$home/config" ] || fail "the refused spawn propagated config into the home"
  [ ! -e "$home/data" ] || fail "the refused spawn copied inherited material into the home's data"
  [ "$before" = "$after" ] || fail "the refused spawn modified the contested home"$'\n'"before:"$'\n'"$before"$'\n'"after:"$'\n'"$after"
  assert_absent "$active/state/$new.meta" \
    "the refused secondmate spawn still published metadata"
  pass "a secondmate collision refuses before the first write into the home"
}

test_second_spawn_onto_occupied_checkout_refuses
test_refusal_leaves_the_shared_checkout_untouched
test_secondmate_collision_refuses_before_touching_the_home
test_symlinked_route_to_an_occupied_checkout_refuses
test_pool_lease_by_another_holder_refuses
test_orca_collision_refusal_runs_no_armed_cleanup
test_orca_lease_refusal_runs_no_armed_cleanup
test_same_task_relaunch_is_not_a_collision
test_free_worktree_still_spawns
test_spawn_creates_and_records_the_task_build_cache

echo "# all fm-spawn-worktree-collision tests passed"
