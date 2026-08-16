#!/usr/bin/env bash
# Behavior tests for the omp (Oh My Pi) adapter: harness identity, launch
# template, per-task extension, teardown cleanup, and session-lock holder
# recognition.
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

SPAWN="$ROOT/bin/fm-spawn.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
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

# --- supervision liveness classification --------------------------------------

test_tmux_classifier_attributes_omp_from_its_foreground_name() {
  local verdict
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-backend.sh"
  fm_backend_source tmux || fail "fm_backend_source tmux failed"

  # Measured on omp 17.3.4 (docs/verification/runtime-backends.md): a live omp
  # pane's TITLE reads bun, because bun launches the bundle, and only the
  # foreground comm reads omp. The title shape must therefore NOT attribute omp
  # on its own - asserting that is what proves the foreground name is carrying
  # the verdict, rather than both sources agreeing by accident.
  verdict=$(fm_backend_tmux_classify_process_name omp)
  [ "$verdict" = agent ] \
    || fail "a live omp pane's foreground name must classify as an agent, got '$verdict'"
  verdict=$(fm_backend_tmux_classify_process_name bun)
  [ "$verdict" = agent ] \
    && fail "the bun launcher name must not attribute omp on its own; the foreground name is the attributing source"

  # Anchored, so the same collisions the session lock rejects stay ambiguous
  # here: misclassifying one as an agent would make an unrelated pane look like
  # a supervisable crewmate.
  for verdict in composer docker-compose; do
    [ "$(fm_backend_tmux_classify_process_name "$verdict")" = agent ] \
      && fail "'$verdict' merely contains omp and must not classify as an agent pane"
  done
  pass "tmux liveness: an omp pane is attributed by its foreground name, not by bun or lookalikes"
}

# --- launch template and per-task extension ----------------------------------

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  # send-keys records each literal payload so a case can assert the launch
  # command fm-spawn actually typed, not just the files it wrote alongside it.
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      prev=
      for a in "$@"; do
        [ "$prev" = -l ] && printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG"
        prev=$a
      done
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh
  printf '%s\n' "$fakebin"
}

make_spawn_case() {
  local name=$1 case_dir home proj wt fakebin launchlog id
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  id="omp-$name-x1"
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'brief\n' > "$home/data/$id/brief.md"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$launchlog|$id"
}

run_omp_spawn() {
  local home=$1 proj=$2 wt=$3 fakebin=$4 launchlog=$5 id=$6
  shift 6
  : > "$launchlog"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$launchlog" PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" omp --mode no-mistakes --yolo off "$@" 2>&1
}

test_omp_spawn_writes_extension_and_autonomy_flag() {
  local rec case_dir home proj wt fakebin launchlog id out status ext launch expected
  rec=$(make_spawn_case spawn)
  IFS='|' read -r case_dir home proj wt fakebin launchlog id <<EOF
$rec
EOF
  out=$(run_omp_spawn "$home" "$proj" "$wt" "$fakebin" "$launchlog" "$id")
  status=$?
  expect_code 0 "$status" "omp spawn should succeed"
  assert_contains "$out" "spawned $id harness=omp" "omp spawn did not report success"

  ext="$home/state/$id.omp-ext.ts"
  # The whole typed command, not a substring, so a dropped autonomy flag or a
  # brief delivered by some other route cannot pass unnoticed.
  launch=$(cat "$launchlog")
  expected="unset OMPCODE CLAUDECODE PI_CODING_AGENT FM_PI_HARNESS GROK_AGENT; omp --auto-approve -e '$ext' \"\$('$ROOT/bin/fm-operational-input.sh' encode launch-brief < '$home/data/$id/brief.md')\""
  [ "$launch" = "$expected" ] || fail "omp launch command is not the verified template"$'\n'"expected: $expected"$'\n'"actual:   $launch"

  assert_present "$ext" "omp per-task turn-end extension was not written"
  # Outside the worktree on purpose, so no project-local extension file is left
  # in the crewmate's checkout.
  assert_absent "$wt/$id.omp-ext.ts" "omp extension leaked into the worktree"
  assert_grep 'harness=omp' "$home/state/$id.meta" "omp spawn did not record the harness"
  pass "fm-spawn: an omp crewmate gets an autonomy flag and its own turn-end extension"
}

test_omp_spawn_is_refused_for_a_secondmate() {
  local case_dir home proj fakebin out status
  case_dir="$TMP_ROOT/secondmate"
  home="$case_dir/home"
  proj="$case_dir/secondmate-home"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data/omp-sm-x1" "$home/projects" "$home/state" "$home/config" "$proj"
  printf 'charter\n' > "$home/data/omp-sm-x1/brief.md"
  touch "$home/state/.last-watcher-beat"
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" PATH="$fakebin:$PATH" \
    "$SPAWN" --secondmate omp-sm-x1 "$proj" omp 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "omp was accepted as a secondmate harness"
  assert_contains "$out" "crewmate/scout adapter only" \
    "omp secondmate refusal did not name the missing supervision support"
  pass "fm-spawn: omp is refused as a secondmate harness"
}

# --- teardown ----------------------------------------------------------------

test_teardown_removes_omp_extension() {
  local rec case_dir home proj wt fakebin launchlog id out status ext
  rec=$(make_spawn_case teardown)
  IFS='|' read -r case_dir home proj wt fakebin launchlog id <<EOF
$rec
EOF
  # Tear down the extension a real spawn actually wrote, not a hand-placed
  # stand-in, so the case cannot pass against a path fm-spawn never uses.
  out=$(run_omp_spawn "$home" "$proj" "$wt" "$fakebin" "$launchlog" "$id")
  status=$?
  expect_code 0 "$status" "omp spawn should succeed before teardown"
  ext="$home/state/$id.omp-ext.ts"
  assert_present "$ext" "omp extension was not written before teardown"

  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    PATH="$fakebin:$PATH" "$TEARDOWN" "$id" --force >/dev/null 2>&1 \
    || fail "omp teardown failed"

  assert_absent "$ext" "teardown left the omp extension behind"
  pass "fm-teardown: removes state/<id>.omp-ext.ts"
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
test_tmux_classifier_attributes_omp_from_its_foreground_name
test_omp_spawn_writes_extension_and_autonomy_flag
test_omp_spawn_is_refused_for_a_secondmate
test_teardown_removes_omp_extension
test_fm_lock_recognizes_omp_holder
test_fm_lock_recognizes_omp_bundle_holder
test_fm_lock_rejects_omp_lookalike_holder
