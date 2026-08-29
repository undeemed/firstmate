#!/usr/bin/env bash
# Durable worktree-claim records, shared by the two scripts that must know
# whether a checkout belongs to exactly one task.
#
# A pool worktree is bound to a task ONLY by that task's durable
# state/<id>.meta worktree= record. treehouse's occupancy for a non-leased
# worktree is process-based, so a slot whose worker happens to have no process
# with a cwd inside it is handed straight back out; bin/fm-spawn.sh's header
# owns that mechanism and its proof.
#
# Both callers ask this same question of the same records:
#   bin/fm-spawn.sh    - refuse to launch into a checkout another task claims.
#   bin/fm-teardown.sh - refuse to attribute, reap, or return a checkout
#     another task claims by directory alone, because every one of those acts
#     on the whole directory and would reach that task's live worker.
#
# Callers of fm_worktree_claimants must source bin/fm-backend.sh first, for the
# shared meta reader.

# The resolved physical path, or the raw path when it cannot be resolved: a
# recorded worktree that no longer exists must still compare equal to itself.
fm_worktree_real_path() { # <path>
  local path=$1 real
  if real=$(cd "$path" 2>/dev/null && pwd -P); then
    printf '%s\n' "$real"
  else
    printf '%s\n' "$path"
  fi
}

# Print every OTHER task id in <state-dir> whose meta records <worktree>, one
# per line.
fm_worktree_claimants() { # <state-dir> <self-id> <worktree>
  local state=$1 self=$2 wt=$3 wt_real meta other_id other_wt
  [ -n "$wt" ] || return 1
  [ -d "$state" ] || return 1
  wt_real=$(fm_worktree_real_path "$wt")
  for meta in "$state"/*.meta; do
    [ -f "$meta" ] || continue
    other_id=${meta##*/}
    other_id=${other_id%.meta}
    [ "$other_id" != "$self" ] || continue
    other_wt=$(fm_meta_get "$meta" worktree)
    [ -n "$other_wt" ] || continue
    [ "$(fm_worktree_real_path "$other_wt")" = "$wt_real" ] || continue
    printf '%s\n' "$other_id"
  done
}
