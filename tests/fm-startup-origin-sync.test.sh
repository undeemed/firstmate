#!/usr/bin/env bash
# Tests for the startup instruction refresh: a landed commit on origin must reach
# the PRIMARY firstmate checkout and, through it, every live secondmate home,
# during the ordinary session-start path (bin/fm-bootstrap.sh) - with no
# /updatefirstmate and no hand-editing.
#
# The gap this pins closed: the startup sweep converges every home to the
# PRIMARY's local default-branch commit (bin/fm-ff-lib.sh), and nothing in that
# path ever fetched origin for the primary itself. A primary left behind after a
# merge therefore made every home converge onto yesterday's instructions while
# the sweep truthfully reported success.
#
# The guarantees under test:
#   - A commit landed on origin reaches the primary AND every live secondmate
#     home in one ordinary startup run, and the primary line names the re-read
#     it now owes.
#   - FAST-FORWARD ONLY is preserved exactly: single-parent advance, never a
#     merge commit, and a dirty, diverged, or off-default primary is left
#     untouched with its work intact.
#   - Drift that CANNOT be repaired is reported, never silent: an unmovable
#     primary reports how far behind origin it is and that the whole fleet
#     converges to it, and a skipped home reports that it is behind too.
#   - A seeded secondmate home keeps following its parent: its own startup
#     neither fetches origin nor advances itself.
#   - A read-only (detect-only) session mutates nothing.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

fm_git_identity fmtest fmtest@example.com

TMP_ROOT=$(fm_test_tmproot fm-startup-origin-sync)
export FM_BACKEND=tmux

# Hermetic backend detection: the dev shell's ambient runtime markers must not
# flip these cases onto a non-tmux backend.
unset TMUX TMUX_PANE HERDR_ENV HERDR_PANE_ID HERDR_SESSION HERDR_SOCKET_PATH \
  CMUX_WORKSPACE_ID CMUX_SURFACE_ID CMUX_SOCKET_PATH CMUX_TAB_ID CMUX_PANEL_ID 2>/dev/null || true

# --- world builders --------------------------------------------------------

# new_world <name>: a bare origin holding one commit, a PRIMARY firstmate clone
# on main, and the primary's gitignored operational dirs with real content (so a
# fast-forward can be proven not to touch them). Echoes the world dir.
new_world() {
  local name=$1 w
  w="$TMP_ROOT/$name"
  mkdir -p "$w"

  git init -q --bare "$w/origin.git"
  git -C "$w/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$w/origin.git" "$w/seed" 2>/dev/null

  printf 'projects/\nstate/\ndata/\nconfig/\n.no-mistakes/\n.fm-secondmate-home\n' > "$w/seed/.gitignore"
  printf 'v1\n' > "$w/seed/AGENTS.md"
  printf 'r1\n' > "$w/seed/README.md"
  mkdir -p "$w/seed/bin" "$w/seed/.agents/skills"
  printf 'echo a\n' > "$w/seed/bin/tool.sh"
  printf 's1\n' > "$w/seed/.agents/skills/note.md"
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm c1
  git -C "$w/seed" push -q origin main

  git clone -q "$w/origin.git" "$w/main"
  git -C "$w/main" remote set-head origin main >/dev/null 2>&1 || true
  mkdir -p "$w/main/state" "$w/main/data" "$w/main/config" "$w/main/projects"
  touch "$w/main/state/.last-watcher-beat"
  printf 'backlog content\n' > "$w/main/data/backlog.md"
  printf '%s\n' "$w"
}

# add_sm <w> <id>: a live secondmate home laid out the way bin/fm-home-seed.sh
# leaves one - a DETACHED worktree of the primary, the seed marker, its own
# operational dirs, and a live kind=secondmate meta in the primary's state dir.
add_sm() {
  local w=$1 id=$2
  git -C "$w/main" worktree add -q --detach "$w/$id" main
  printf '%s\n' "$id" > "$w/$id/.fm-secondmate-home"
  mkdir -p "$w/$id/data" "$w/$id/state" "$w/$id/config" "$w/$id/projects"
  printf 'charter\n' > "$w/$id/data/charter.md"
  {
    printf 'window=firstmate:fm-%s\n' "$id"
    printf 'kind=secondmate\n'
    printf 'harness=codex\n'
    printf 'home=%s/%s\n' "$w" "$id"
  } > "$w/main/state/$id.meta"
}

# land_on_origin <w> [mode]: land one commit on origin, as a merged PR does.
# instr (default) changes the loaded instruction surface; readme does not.
# Echoes the landed commit.
land_on_origin() {
  local w=$1 mode=${2:-instr}
  git -C "$w/seed" pull -q origin main >/dev/null 2>&1 || true
  printf 'r-%s\n' "$mode" >> "$w/seed/README.md"
  if [ "$mode" = instr ]; then
    printf 'v2\n' > "$w/seed/AGENTS.md"
    printf 'echo b\n' > "$w/seed/bin/tool.sh"
  fi
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm "land-$mode"
  git -C "$w/seed" push -q origin main
  git -C "$w/seed" rev-parse HEAD
}

head_of() { git -C "$1" rev-parse HEAD; }

# A toolchain complete enough that bootstrap reports nothing but the behavior
# under test. tmux answers the liveness/nudge probes; gh is authenticated.
make_fake_toolchain() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  fm_fake_exit0 "$fakebin" node chrome-devtools-axi
  fm_fake_version_tool "$fakebin" lavish-axi FM_FAKE_LAVISH_AXI_VERSION 0.1.46
  fm_fake_version_tool "$fakebin" gh-axi FM_FAKE_GH_AXI_VERSION 0.1.29
  fm_fake_version_tool "$fakebin" quota-axi FM_FAKE_QUOTA_AXI_VERSION 0.1.29
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "$*" in
  list-windows*) sed -n 's/^window=[^:]*://p' "${FM_HOME:?}"/state/*.meta 2>/dev/null; exit 0 ;;
  *display-message*'#{pane_current_command}'*) printf '%s\n' codex; exit 0 ;;
  *display-message*'#{pane_id}'*) printf '%s\n' '%1'; exit 0 ;;
  *display-message*'#{cursor_y}'*) printf '%s\n' 0; exit 0 ;;
  *capture-pane*) printf '\n'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/gh"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = get ] && [ "${2:-}" = --help ]; then
  printf '%s\n' 'Usage: treehouse get [--lease]'
fi
exit 0
SH
  chmod +x "$fakebin/treehouse"
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' 'no-mistakes version v1.31.2 (fake)'
fi
exit 0
SH
  chmod +x "$fakebin/no-mistakes"
  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "--version ") printf '%s\n' '0.2.4' ;;
  "update --help") printf '%s\n' 'usage: tasks-axi update <id> [flags]' '  --archive-body' ;;
  "mv --help") printf '%s\n' 'usage: tasks-axi mv <id> [<id>...] --to <path-or-dir>' ;;
esac
exit 0
SH
  chmod +x "$fakebin/tasks-axi"
  printf '%s\n' "$fakebin"
}

# run_startup <w> <home> [env assignments...]: the ordinary session-start sweep
# for the home whose checkout is <home>.
run_startup() {
  local w=$1 home=$2 fakebin
  shift 2
  fakebin="$w/fakebin"
  [ -d "$fakebin" ] || fakebin=$(make_fake_toolchain "$w")
  env PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    FM_SEND_SETTLE=0 "$@" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null
}

# --- T1: the reproduction converges ----------------------------------------
# Land a commit on origin, run the ordinary startup path, and both the primary
# and its live home must be on it - by a single-parent fast-forward, with the
# home still detached and the gitignored operational dirs untouched.
test_startup_converges_from_origin() {
  local w landed out
  w=$(new_world converge)
  add_sm "$w" sm1
  landed=$(land_on_origin "$w")

  out=$(run_startup "$w" "$w/main")

  [ "$(head_of "$w/main")" = "$landed" ] || fail "primary did not advance to the landed commit"
  [ "$(head_of "$w/sm1")" = "$landed" ] || fail "secondmate home did not converge to the landed commit"
  assert_contains "$out" "FIRSTMATE_SYNC: primary checkout updated " "the primary advance is reported"
  assert_contains "$out" "instructions changed: AGENTS.md" "the changed instruction surface is named"
  assert_contains "$out" "re-read AGENTS.md" "the report names the re-read it owes"
  [ "$(git -C "$w/main" symbolic-ref --short HEAD 2>/dev/null)" = main ] \
    || fail "primary left its default branch"
  git -C "$w/sm1" symbolic-ref -q HEAD >/dev/null && fail "secondmate home is no longer detached"
  [ "$(git -C "$w/main" rev-list --parents -n1 HEAD | wc -w | tr -d ' ')" -eq 2 ] \
    || fail "primary tip is not a single-parent fast-forward"
  assert_grep "backlog content" "$w/main/data/backlog.md" "the update must not touch data/"
  assert_grep "charter" "$w/sm1/data/charter.md" "the update must not touch a home's data/"
  pass "T1 a commit landed on origin reaches the primary and every live home in one ordinary startup"
}

# --- T2: an unmovable primary is reported, never forced --------------------
test_dirty_primary_reported_not_forced() {
  local w landed before out
  w=$(new_world dirty-primary)
  add_sm "$w" sm1
  landed=$(land_on_origin "$w")
  before=$(head_of "$w/main")
  printf 'uncommitted local edit\n' >> "$w/main/AGENTS.md"

  out=$(run_startup "$w" "$w/main")

  [ "$(head_of "$w/main")" = "$before" ] || fail "dirty primary was moved"
  [ "$landed" != "$before" ] || fail "fixture did not actually land a new commit"
  grep -q 'uncommitted local edit' "$w/main/AGENTS.md" || fail "local edit was discarded"
  assert_contains "$out" "FIRSTMATE_SYNC: primary checkout is 1 commit(s) behind origin/main" \
    "unrepairable drift reports how far behind the primary is"
  assert_contains "$out" "dirty working tree" "the reason the primary could not advance is named"
  assert_contains "$out" "every secondmate home converges to this checkout" \
    "the report says the drift is fleet-wide, not local to the primary"
  pass "T2 a dirty primary is left untouched and its drift is reported, not silent"
}

# --- T3: an off-default primary is reported the same way -------------------
test_feature_branch_primary_reported() {
  local w before out
  w=$(new_world feature-primary)
  land_on_origin "$w" >/dev/null
  git -C "$w/main" checkout -q -b feature/wip
  before=$(head_of "$w/main")

  out=$(run_startup "$w" "$w/main")

  [ "$(head_of "$w/main")" = "$before" ] || fail "off-default primary was moved"
  assert_contains "$out" "FIRSTMATE_SYNC: primary checkout is 1 commit(s) behind origin/main" \
    "an off-default primary still reports its drift"
  assert_contains "$out" "on feature/wip, expected main" "the reason is named"
  pass "T3 a primary on a feature branch is left alone and its drift is still reported"
}

# --- T4: a home that cannot be advanced reports that it is behind ----------
test_dirty_home_reports_behind() {
  local w landed before out
  w=$(new_world dirty-home)
  add_sm "$w" sm1
  landed=$(land_on_origin "$w")
  before=$(head_of "$w/sm1")
  printf 'home work in progress\n' >> "$w/sm1/README.md"

  out=$(run_startup "$w" "$w/main")

  [ "$(head_of "$w/main")" = "$landed" ] || fail "primary did not advance"
  [ "$(head_of "$w/sm1")" = "$before" ] || fail "dirty home was moved"
  grep -q 'home work in progress' "$w/sm1/README.md" || fail "home's uncommitted work was discarded"
  assert_contains "$out" "SECONDMATE_SYNC: secondmate sm1: skipped: dirty working tree (1 commit(s) behind)" \
    "a skipped home reports that it is behind, not just that it was skipped"
  pass "T4 a home holding unlanded work is left untouched and reported as behind"
}

# --- T5: a secondmate home keeps following its parent ----------------------
# Its own startup must neither fetch origin nor advance itself past the primary.
test_secondmate_home_startup_does_not_self_fetch() {
  local w before out fakebin log real_git
  w=$(new_world home-startup)
  add_sm "$w" sm1
  land_on_origin "$w" >/dev/null
  before=$(head_of "$w/sm1")

  fakebin=$(make_fake_toolchain "$w")
  log="$w/fetch.log"
  real_git=$(command -v git)
  cat > "$fakebin/git" <<SH
#!/usr/bin/env bash
for a in "\$@"; do
  if [ "\$a" = fetch ]; then printf 'FETCH %s\n' "\$*" >> '$log'; fi
done
exec '$real_git' "\$@"
SH
  chmod +x "$fakebin/git"

  out=$(run_startup "$w" "$w/sm1")

  [ "$(head_of "$w/sm1")" = "$before" ] || fail "a secondmate home advanced itself past its parent"
  assert_not_contains "$out" "FIRSTMATE_SYNC:" "a secondmate home must not report itself as the primary"
  [ ! -f "$log" ] || fail "a secondmate home's startup fetched origin: $(cat "$log")"
  pass "T5 a seeded secondmate home neither fetches origin nor advances itself at startup"
}

# --- T6: a read-only session mutates nothing -------------------------------
test_detect_only_leaves_primary_untouched() {
  local w before out
  w=$(new_world detect-only)
  add_sm "$w" sm1
  land_on_origin "$w" >/dev/null
  before=$(head_of "$w/main")

  out=$(run_startup "$w" "$w/main" FM_BOOTSTRAP_DETECT_ONLY=1)

  [ "$(head_of "$w/main")" = "$before" ] || fail "a detect-only run moved the primary"
  [ "$(head_of "$w/sm1")" = "$before" ] || fail "a detect-only run moved a home"
  assert_not_contains "$out" "FIRSTMATE_SYNC:" "a detect-only run performs no instruction refresh"
  pass "T6 a detect-only (read-only) session performs no instruction refresh"
}

# --- T7: idempotent ---------------------------------------------------------
test_second_run_is_quiet() {
  local w landed out
  w=$(new_world idempotent)
  add_sm "$w" sm1
  landed=$(land_on_origin "$w")
  run_startup "$w" "$w/main" >/dev/null

  out=$(run_startup "$w" "$w/main")

  [ "$(head_of "$w/main")" = "$landed" ] || fail "primary drifted on the second run"
  assert_not_contains "$out" "FIRSTMATE_SYNC:" "an already-current primary reports nothing"
  pass "T7 a second startup on an already-current primary is quiet"
}

test_startup_converges_from_origin
test_dirty_primary_reported_not_forced
test_feature_branch_primary_reported
test_dirty_home_reports_behind
test_secondmate_home_startup_does_not_self_fetch
test_detect_only_leaves_primary_untouched
test_second_run_is_quiet

echo "# all fm-startup-origin-sync tests passed"
