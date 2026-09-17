# shellcheck shell=bash
# Spawn memory floor: refuse a FRESH spawn while the host is short of RAM.
# Usage: . bin/fm-spawn-memory-floor-lib.sh; fm_spawn_memory_floor_check || exit 1
#
# Why this exists (2026-09-17 incident): ten swarms-platform lanes ran at once
# on a 24 GB box. Each live lane was 5-8 GB (next dev, tsc, browser, agent),
# all of them active, so the memory guardian - which reaps STALE panes - had
# nothing it was allowed to kill while 52 GB of swap filled and load hit 300.
# Reaping is the wrong tool for that shape; the only place concurrency can be
# bounded without destroying work is here, before the worktree is leased.
#
# Setting: config/spawn-memory-floor-mb (env FM_SPAWN_MEMORY_FLOOR_MB wins),
# one whole number of megabytes. A fresh spawn is refused while MemAvailable
# is below it. Absent or 0 disables the gate; a malformed value refuses the
# spawn loudly rather than silently disabling protection. MemAvailable alone
# is measured - free swap is deliberately NOT counted, because "there is swap
# left" is exactly the state that ends in a thrashing, unreachable host.
# Relaunches never pass through this gate: they reuse a lane that already
# exists. Hosts without /proc/meminfo (macOS) skip the gate.

FM_SPAWN_MEMORY_FLOOR_FILE="spawn-memory-floor-mb"
FM_SPAWN_MEMORY_MEMINFO="${FM_SPAWN_MEMORY_MEMINFO:-/proc/meminfo}"

# fm_spawn_memory_floor_value: print the effective floor in MB (0 = disabled).
# Returns 1 with an error on stderr for a malformed setting.
fm_spawn_memory_floor_value() {
  local dir="${FM_CONFIG_OVERRIDE:-${FM_HOME:-.}/config}" raw=
  if [ -n "${FM_SPAWN_MEMORY_FLOOR_MB:-}" ]; then
    raw=$FM_SPAWN_MEMORY_FLOOR_MB
  elif [ -f "$dir/$FM_SPAWN_MEMORY_FLOOR_FILE" ]; then
    raw=$(tr -d '[:space:]' < "$dir/$FM_SPAWN_MEMORY_FLOOR_FILE")
  fi
  if [ -z "$raw" ]; then
    printf '0'
    return 0
  fi
  case "$raw" in
    *[!0-9]*|'')
      echo "error: config/$FM_SPAWN_MEMORY_FLOOR_FILE must be a whole number of megabytes (0 disables), got '$raw'" >&2
      return 1
      ;;
  esac
  printf '%s' "$((10#$raw))"
}

# fm_spawn_memory_available_mb: MemAvailable in MB, or empty when unreadable.
fm_spawn_memory_available_mb() {
  [ -r "$FM_SPAWN_MEMORY_MEMINFO" ] || return 0
  awk '/^MemAvailable:/ { printf "%d", $2 / 1024; exit }' "$FM_SPAWN_MEMORY_MEMINFO"
}

# fm_spawn_memory_floor_check: 0 when the spawn may proceed, 1 (with the
# refusal on stderr) when the host is below the floor or the setting is bad.
fm_spawn_memory_floor_check() {
  local floor avail
  floor=$(fm_spawn_memory_floor_value) || return 1
  [ "$floor" -gt 0 ] || return 0
  avail=$(fm_spawn_memory_available_mb)
  [ -n "$avail" ] || return 0
  if [ "$avail" -lt "$floor" ]; then
    echo "error: spawn refused: host MemAvailable is ${avail} MB, below config/$FM_SPAWN_MEMORY_FLOOR_FILE=${floor} MB. Every live lane costs RAM the host no longer has; wait for a lane to finish or tear one down, then spawn again. Set the file to 0 to disable this gate." >&2
    return 1
  fi
  return 0
}
