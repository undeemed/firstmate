#!/usr/bin/env bash
# fm-tasktmp-lib.sh - the single owner of per-task scratch-root resolution.
#
# Sourced, never executed. Every spawned worker gets one disk-backed scratch
# root, and this library is the only place that decides where it lives.
#
#   fm_tasktmp_root
#       Prints the parent directory that holds every per-task scratch root.
#       Resolution order:
#         1. FM_TASKTMP_ROOT   - operator override, must be an absolute path.
#         2. $XDG_CACHE_HOME/firstmate/tasktmp
#         3. $HOME/.cache/firstmate/tasktmp
#       With none of those resolvable (no override and no absolute HOME or
#       XDG_CACHE_HOME), it prints an actionable error and returns 1 rather
#       than falling back to a temporary filesystem.
#
#   fm_tasktmp_dir <task-id>
#       Prints that task's own scratch root, <root>/fm-<task-id>. The caller
#       creates it; bin/fm-teardown.sh removes the whole directory from the
#       tasktmp= line bin/fm-spawn.sh records in the task metadata.
#
# WHY DISK, NOT /tmp: on a shared build host /tmp is commonly a tmpfs with a
# per-user quota well under its apparent size (measured on the reference host:
# a 12G tmpfs whose uid-1000 hard limit is 9,608,675 KiB, 80% of the mount).
# A fleet of parallel workers exhausts that shared cap, and the resulting
# EDQUOT surfaces as unrelated-looking failures: "Disk quota exceeded" while
# `df` still reports tens of gigabytes free, rustc and ld dying mid-link, and
# test runners reporting "exited abnormally". Rooting scratch in the cache
# directory puts it on the real filesystem, which the quota does not bound.
# Read that cap with the quotactl_fd syscall (443) on an fd of the mount:
# tmpfs has no block device, so plain quotactl fails with "Block device
# required" and quota/repquota are usually not installed.
set -u

fm_tasktmp_root() {
  local override="${FM_TASKTMP_ROOT:-}" cache="${XDG_CACHE_HOME:-}" home="${HOME:-}"
  if [ -n "$override" ]; then
    case "$override" in
      /*)
        printf '%s\n' "${override%/}"
        return 0
        ;;
      *)
        echo "error: FM_TASKTMP_ROOT must be an absolute path (got: $override)" >&2
        return 1
        ;;
    esac
  fi
  case "$cache" in
    /*)
      printf '%s\n' "${cache%/}/firstmate/tasktmp"
      return 0
      ;;
  esac
  case "$home" in
    /*)
      printf '%s\n' "${home%/}/.cache/firstmate/tasktmp"
      return 0
      ;;
  esac
  echo "error: cannot resolve a disk-backed task scratch root: set FM_TASKTMP_ROOT to an absolute path (HOME and XDG_CACHE_HOME are unusable)" >&2
  return 1
}

fm_tasktmp_dir() {
  local id="${1:-}" root
  if [ -z "$id" ]; then
    echo "error: fm_tasktmp_dir requires a task id" >&2
    return 1
  fi
  root=$(fm_tasktmp_root) || return 1
  printf '%s\n' "$root/fm-$id"
}
