#!/usr/bin/env bash
# Behavior tests for omp (Oh My Pi) harness IDENTITY: which process shapes
# resolve to the omp harness, and which must not.
#
# omp is a pi fork executed by bun. Only ONE shape has been measured (omp 17.3.4
# on Linux, recorded in docs/verification/supervision.md): bun renames the
# process, so a live session reports comm=omp while argv[0] still says bun, and
# no omp process carries the package bundle path in argv. The bun-plus-bundle
# shape below is therefore defensive coverage for a shape no measurement has
# produced, not an observed fleet reality. Both must resolve, and neither may
# be reached by a name that merely contains "omp".
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HARNESS="$ROOT/bin/fm-harness.sh"
LOCK="$ROOT/bin/fm-lock.sh"
BUNDLE='/usr/local/lib/node_modules/@oh-my-pi/pi-coding-agent/dist/cli.js'
TMP_ROOT=$(fm_test_tmproot fm-omp-harness)

# Write a fake `ps` into <fakebin> that answers comm=/args=/ppid= for a
# single-frame ancestry: pid $$ reports <comm>/<args>, everything above is init.
fake_ps_single_frame() {
  local fakebin=$1 comm=$2 args=$3
  cat > "$fakebin/ps" <<SH
#!/usr/bin/env bash
set -u
field= pid=
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    -o) field=\$2; shift 2 ;;
    -p) pid=\$2; shift 2 ;;
    *) shift ;;
  esac
done
case "\$field" in
  comm=) printf '%s\n' '$comm' ;;
  args=) printf '%s\n' '$args' ;;
  ppid=) printf '%s\n' 1 ;;
esac
SH
  chmod +x "$fakebin/ps"
}

# --- detection ---------------------------------------------------------------

test_detect_own_env_marker() {
  local out
  out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT OMPCODE=1 "$HARNESS")
  [ "$out" = omp ] || fail "OMPCODE=1 should detect omp, got '$out'"
  pass "fm-harness detect_own: the OMPCODE=1 env marker resolves omp"
}

test_detect_own_env_marker_wins_over_inherited_claudecode() {
  local out
  # omp exports OMPCODE=1 and CLAUDECODE=1 TOGETHER into every child it spawns,
  # so this is the real shape, not a contrived one. If the claude marker were
  # tested first, every omp session would silently identify as claude.
  out=$(env -u PI_CODING_AGENT -u GROK_AGENT OMPCODE=1 CLAUDECODE=1 "$HARNESS")
  [ "$out" = omp ] || fail "omp's own marker must outrank the CLAUDECODE it also exports, got '$out'"
  # Prove the ordering is what decided it: without OMPCODE the same environment
  # must still resolve claude, so this case cannot pass by claude detection
  # being broken outright.
  out=$(env -u PI_CODING_AGENT -u GROK_AGENT -u OMPCODE CLAUDECODE=1 "$HARNESS")
  [ "$out" = claude ] || fail "CLAUDECODE=1 alone should still resolve claude, got '$out'"
  pass "fm-harness detect_own: OMPCODE outranks the CLAUDECODE omp also exports"
}

test_detect_own_bun_bundle_path() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/detect-bun")
  # Defensive shape, not an observed one: the kernel exec name is still bun and
  # only argv carries the package bundle. No measured omp process reports this,
  # so the case pins the bundle arm's contract rather than a fleet reality.
  # Every harness env marker is cleared so the verdict can only come from ancestry.
  fake_ps_single_frame "$fakebin" '/root/.bun/bin/bun' "bun $BUNDLE"
  out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u OMPCODE \
    PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" = omp ] || fail "a bun process running the omp bundle should resolve omp, got '$out'"
  pass "fm-harness detect_own: the bun interpreter running omp's bundle resolves omp"
}

test_detect_own_rejects_omp_lookalike_names() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/detect-lookalike")
  # The omp identity is matched on an anchored name, so a command that merely
  # CONTAINS omp must not reach it. docker-compose is the realistic collision.
  fake_ps_single_frame "$fakebin" '/usr/bin/docker-compose' 'docker-compose up'
  out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u OMPCODE \
    PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" != omp ] || fail "an omp-lookalike command name was detected as the omp harness"
  pass "fm-harness detect_own: omp-lookalike command names do not resolve omp"
}

# --- session-lock holder recognition -----------------------------------------

test_fm_lock_recognizes_omp_holder() {
  local home fakebin out
  home="$TMP_ROOT/lock-home"
  fakebin=$(fm_fakebin "$TMP_ROOT/lock-fake")
  mkdir -p "$home/state"
  printf '%s\n' "$$" > "$home/state/.lock"
  # Post-rename shape: bun has renamed the process, so comm is omp.
  fake_ps_single_frame "$fakebin" 'omp' 'bun /usr/local/bin/omp --approval-mode yolo'
  out=$(FM_HOME="$home" PATH="$fakebin:$PATH" "$LOCK" status)
  assert_contains "$out" "lock: held by live harness pid" \
    "fm-lock did not recognize a renamed omp process as a live holder"
  pass "fm-lock recognizes an omp holder by its renamed process name"
}

test_fm_lock_recognizes_omp_bundle_holder() {
  local home fakebin out
  home="$TMP_ROOT/lock-bundle-home"
  fakebin=$(fm_fakebin "$TMP_ROOT/lock-bundle-fake")
  mkdir -p "$home/state"
  printf '%s\n' "$$" > "$home/state/.lock"
  # Defensive shape, not an observed one: comm is the bun interpreter, which is
  # neither node nor python, so only the package bundle in argv can identify
  # this process. No measured omp process reports this shape.
  fake_ps_single_frame "$fakebin" '/root/.bun/bin/bun' "bun $BUNDLE"
  out=$(FM_HOME="$home" PATH="$fakebin:$PATH" "$LOCK" status)
  assert_contains "$out" "lock: held by live harness pid" \
    "fm-lock did not recognize omp's bundle path as a live holder"
  pass "fm-lock recognizes an omp holder by its pi-coding-agent bundle path"
}

test_fm_lock_rejects_omp_lookalike_holder() {
  local home fakebin out
  home="$TMP_ROOT/lock-lookalike-home"
  fakebin=$(fm_fakebin "$TMP_ROOT/lock-lookalike-fake")
  mkdir -p "$home/state"
  printf '%s\n' "$$" > "$home/state/.lock"
  # The same live pid, reported under a name that merely contains omp. If the
  # identity were unanchored this would claim the home's lock.
  fake_ps_single_frame "$fakebin" 'composer' '/opt/compose/bin/composer run'
  out=$(FM_HOME="$home" PATH="$fakebin:$PATH" "$LOCK" status)
  assert_not_contains "$out" "lock: held by live harness pid" \
    "an omp-lookalike command name was accepted as a live lock holder"
  pass "fm-lock does not accept omp-lookalike command names as holders"
}
test_detect_own_env_marker
test_detect_own_env_marker_wins_over_inherited_claudecode
test_detect_own_bun_bundle_path
test_detect_own_rejects_omp_lookalike_names
test_fm_lock_recognizes_omp_holder
test_fm_lock_recognizes_omp_bundle_holder
test_fm_lock_rejects_omp_lookalike_holder
