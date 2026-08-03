#!/usr/bin/env bash
# Regression test for fm-spawn.sh acquiring the task worktree by LEASE
# (bin/fm-spawn.sh, `treehouse get --lease --lease-holder "$ID"`).
#
# fm-spawn used to type a bare `treehouse get` into the task pane and then poll
# the pane's cwd until it moved. That took no reservation, so the worktree's
# occupancy rested entirely on a live process whose cwd was inside it: per
# `treehouse prune --help`, a tree is stale when treehouse manages it, there is
# no owner reservation, no process is running inside it, it is clean, and HEAD
# is merged. The moment the crewmate cd'd out - it did not have to exit - the
# tree became both re-assignable by the next `treehouse get` and prunable by the
# constant sweep, out from under live work. That cost a crewmate its tree
# mid-rebase on 2026-08-03.
#
# The property under test is therefore NOT "the pane ends up in the worktree" -
# that was true of the broken code too. It is that the tree is RESERVED: after a
# successful spawn treehouse reports it leased to the task id, and a prune dry
# run does not list it even though no process has its cwd inside it.
#
# The fake treehouse below models exactly that reservation and nothing else: its
# prune holds the other four staleness conditions fixed and varies only the
# owner reservation, so a regression to an unleased acquisition fails here
# rather than passing on a technicality.

set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-worktree-lease)

# make_lease_fakebin <dir>: a fake tmux that swallows window ops, plus a fake
# treehouse that keeps real lease state in $FM_FAKE_LEASES over the pool listed
# in $FM_FAKE_POOL. Echoes the fakebin dir.
#
#   get [--lease --lease-holder H]  hand out the first pool entry that is not
#                                   leased, recording the lease when asked
#   return [--force] <path>         release that entry's lease
#   status                          "leased <path> (held by H)" or "in-use <path>"
#   prune                           list what a prune WOULD reclaim: every pool
#                                   entry with no owner reservation
make_lease_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|send-keys|set-window-option) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
leases=${FM_FAKE_LEASES:?}
pool=${FM_FAKE_POOL:?}
: >> "$leases"

held() {  # <path> -> 0 if leased
  awk -F'\t' -v w="$1" '$1 == w { found = 1 } END { exit !found }' "$leases"
}
holder_of() {  # <path> -> lease holder, empty if free
  awk -F'\t' -v w="$1" '$1 == w { print $2; exit }' "$leases"
}

cmd=${1:-}
shift || true
case "$cmd" in
  get)
    lease=0 holder=
    while [ $# -gt 0 ]; do
      case $1 in
        --lease) lease=1 ;;
        --lease-holder) shift; holder=${1:-} ;;
      esac
      shift
    done
    # Banners go to stderr on the real thing; only the path is on stdout.
    echo "treehouse: handing out a worktree" >&2
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      held "$p" && continue
      [ "$lease" = 1 ] && printf '%s\t%s\n' "$p" "$holder" >> "$leases"
      printf '%s\n' "$p"
      exit 0
    done < "$pool"
    echo "treehouse: no free worktree" >&2
    exit 1 ;;
  return)
    [ "${1:-}" = --force ] && shift
    p=${1:?}
    tmp="$leases.tmp"
    awk -F'\t' -v w="$p" '$1 != w' "$leases" > "$tmp"
    mv "$tmp" "$leases"
    exit 0 ;;
  status)
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      h=$(holder_of "$p")
      if [ -n "$h" ]; then
        printf 'leased    %s (held by %s)\n' "$p" "$h"
      else
        printf 'in-use    %s\n' "$p"
      fi
    done < "$pool"
    exit 0 ;;
  prune)
    # Every other staleness condition (managed, no process inside, clean, HEAD
    # merged) is held true here, so this lists exactly the unreserved trees.
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      held "$p" && continue
      printf 'would prune %s\n' "$p"
    done < "$pool"
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/treehouse"
  printf '%s\n' "$fakebin"
}

run_spawn() {  # <home> <id> <proj> <fakebin> <leases> <pool>
  local home=$1 id=$2 proj=$3 fakebin=$4 leases=$5 pool=$6
  mkdir -p "$home/data/$id"
  printf 'brief\n' > "$home/data/$id/brief.md"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_LEASES="$leases" FM_FAKE_POOL="$pool" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" codex 2>&1
}

test_spawn_leases_the_worktree() {
  local home proj wt fakebin leases pool id out status

  home="$TMP_ROOT/lease-home"; mkdir -p "$home/data"
  proj="$TMP_ROOT/lease-proj"
  wt="$TMP_ROOT/lease-wt"
  id="spawnleasea1"
  fm_git_worktree "$proj" "$wt" "fm/$id"

  fakebin=$(make_lease_fakebin "$TMP_ROOT/lease-fake")
  leases="$TMP_ROOT/lease-state"; : > "$leases"
  pool="$TMP_ROOT/lease-pool"; printf '%s\n' "$wt" > "$pool"

  out=$(run_spawn "$home" "$id" "$proj" "$fakebin" "$leases" "$pool"); status=$?
  expect_code 0 "$status" "spawn should succeed against a leasable pool"$'\n'"$out"
  assert_grep "worktree=$wt" "$home/state/$id.meta" \
    "spawn did not record the leased worktree in the task's durable record"

  # The reservation exists and names the task, the way home-seed labels homes.
  assert_grep "$wt"$'\t'"$id" "$leases" \
    "spawn did not take a treehouse lease held by the task id"

  # ... and treehouse agrees, rather than reporting the tree merely in-use with
  # occupancy resting on a live process's cwd.
  out=$(FM_FAKE_LEASES="$leases" FM_FAKE_POOL="$pool" "$fakebin/treehouse" status)
  assert_contains "$out" "leased    $wt (held by $id)" \
    "treehouse does not report the spawned task's worktree as leased"

  # The whole bug: no process has its cwd inside $wt right now (nothing was ever
  # started there - the pane is a stub), and the tree must STILL survive a prune.
  out=$(FM_FAKE_LEASES="$leases" FM_FAKE_POOL="$pool" "$fakebin/treehouse" prune)
  assert_not_contains "$out" "$wt" \
    "prune would reclaim the task's worktree with no process inside it - the lease is not protecting it"

  rm -rf "/tmp/fm-$id"
  pass "fm-spawn: the task worktree is leased to the task id and survives a prune with no process inside it"
}

# The lease is durable in treehouse's state, so a spawn that dies between
# acquiring it and recording worktree= must hand the slot back itself: prune
# never reclaims a leased tree, so a leaked lease costs the pool a slot forever.
test_aborted_spawn_returns_the_lease() {
  local home proj fakebin leases pool id out status

  home="$TMP_ROOT/abort-home"; mkdir -p "$home/data"
  proj="$TMP_ROOT/abort-proj"
  id="spawnleaseb2"
  fm_git_init_commit "$proj"

  fakebin=$(make_lease_fakebin "$TMP_ROOT/abort-fake")
  leases="$TMP_ROOT/abort-state"; : > "$leases"
  # The only pool entry IS the project clone, so the isolation guard refuses
  # after the lease is already held.
  pool="$TMP_ROOT/abort-pool"; printf '%s\n' "$proj" > "$pool"

  out=$(run_spawn "$home" "$id" "$proj" "$fakebin" "$leases" "$pool"); status=$?
  expect_code 1 "$status" "spawn should refuse a lease that resolves to the project clone"$'\n'"$out"
  assert_contains "$out" "did not yield an isolated worktree" \
    "aborted spawn lacked the isolation error"
  assert_absent "$home/state/$id.meta" "aborted spawn must not record a task"
  [ ! -s "$leases" ] || fail "aborted spawn leaked its lease: $(cat "$leases")"

  pass "fm-spawn: a spawn that aborts after leasing returns the pool slot"
}

test_spawn_leases_the_worktree
test_aborted_spawn_returns_the_lease
echo "# all fm-spawn-worktree-lease tests passed"
