#!/usr/bin/env bash
# Behavioral coverage for the spawn memory floor (bin/fm-spawn-memory-floor-lib.sh):
# the gate that refuses a fresh spawn while host MemAvailable is under
# config/spawn-memory-floor-mb. Uses a fake /proc/meminfo so the assertions do
# not depend on the test host's memory.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-memory-floor)
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/config"

write_meminfo() {  # <available-kb>
  printf 'MemTotal:       24021684 kB\nMemFree:          157660 kB\nMemAvailable:   %s kB\nSwapTotal:      52428796 kB\nSwapFree:       52428796 kB\n' "$1" > "$TMP_ROOT/meminfo"
}

run_check() {  # [env assignments...]
  # shellcheck disable=SC2016 # $0 is expanded by the child bash, not here.
  env -i PATH="$PATH" HOME="$TMP_ROOT" FM_HOME="$HOME_DIR" FM_SPAWN_MEMORY_MEMINFO="$TMP_ROOT/meminfo" "$@" \
    bash -c '. "$0"; fm_spawn_memory_floor_check' "$ROOT/bin/fm-spawn-memory-floor-lib.sh" 2> "$TMP_ROOT/err"
}

# 1. Absent setting: gate disabled even on a starving host.
write_meminfo 102400
rm -f "$HOME_DIR/config/spawn-memory-floor-mb"
run_check; expect_code 0 $? "absent setting disables the gate"
[ ! -s "$TMP_ROOT/err" ] || fail "absent setting must print nothing"

# 2. Explicit 0: disabled.
printf '0\n' > "$HOME_DIR/config/spawn-memory-floor-mb"
run_check; expect_code 0 $? "zero disables the gate"

# 3. Host below the floor: refused, message names both numbers and the file.
printf '6000\n' > "$HOME_DIR/config/spawn-memory-floor-mb"
write_meminfo $((1400 * 1024))
run_check; expect_code 1 $? "below floor refuses"
assert_grep "spawn refused" "$TMP_ROOT/err" "refusal is loud"
assert_grep "1400 MB" "$TMP_ROOT/err" "refusal states MemAvailable"
assert_grep "spawn-memory-floor-mb=6000" "$TMP_ROOT/err" "refusal states the floor and its file"

# 4. Host at/above the floor: allowed. Swap is irrelevant (fake meminfo has 50 GB free swap throughout).
write_meminfo $((6000 * 1024))
run_check; expect_code 0 $? "at floor proceeds"
write_meminfo $((9000 * 1024))
run_check; expect_code 0 $? "above floor proceeds"

# 5. Env override wins over the file.
write_meminfo $((7000 * 1024))
run_check FM_SPAWN_MEMORY_FLOOR_MB=8000; expect_code 1 $? "env floor above avail refuses"
run_check FM_SPAWN_MEMORY_FLOOR_MB=0; expect_code 0 $? "env 0 disables despite file"

# 6. Malformed setting refuses loudly instead of silently disabling.
printf 'six gigs\n' > "$HOME_DIR/config/spawn-memory-floor-mb"
write_meminfo $((9000 * 1024))
run_check; expect_code 1 $? "malformed setting refuses"
assert_grep "whole number of megabytes" "$TMP_ROOT/err" "malformed setting is explained"

# 7. No meminfo (non-Linux host): gate skips.
printf '6000\n' > "$HOME_DIR/config/spawn-memory-floor-mb"
rm -f "$TMP_ROOT/meminfo"
run_check; expect_code 0 $? "unreadable meminfo skips the gate"

pass "spawn memory floor"
