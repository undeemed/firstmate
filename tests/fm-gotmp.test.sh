#!/usr/bin/env bash
# Behavior tests for the per-task scratch root (fm-tasktmp) and its cleanup.
#
# fm-spawn gives each task one disk-backed temp root, resolved by
# bin/fm-tasktmp-lib.sh, with the general temp nested at tmp/ and Go's build temp at
# gotmp/. It exports TMPDIR and GOTMPDIR into the crewmate pane and records tasktmp=
# in the task's meta. fm-teardown removes exactly the recorded root on cleanup,
# including a root recorded before that root moved off the shared temporary
# filesystem.
#
# These tests exercise the real fm-tasktmp-lib.sh in a subshell, and fm-teardown
# directly as a subprocess against a fake FM_HOME/FM_ROOT built so the real script
# resolves into it, with stub helper scripts.
# The isolated fm-spawn subprocess in fm-kimi-harness.test.sh covers temp-root
# creation, metadata publication, and the pane environment exports.
set -u

# This suite does not source tests/lib.sh, so exempt its teardown subprocess from
# the gate-lifecycle refusal (bin/fm-gate-refuse-lib.sh) the way lib.sh does for
# the rest of the suite: the no-mistakes gate runs this suite from a gate worktree,
# which the guard would otherwise refuse.
export FM_GATE_REFUSE_BYPASS=1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
TASKTMP_LIB="$ROOT/bin/fm-tasktmp-lib.sh"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

TMP_ROOT=
LEGACY_TMPFS_FIXTURE=

cleanup() {
  if [ -n "${TMP_ROOT:-}" ]; then
    rm -rf "$TMP_ROOT"
  fi
  if [ -n "${LEGACY_TMPFS_FIXTURE:-}" ]; then
    rm -rf "$LEGACY_TMPFS_FIXTURE"
  fi
}
trap cleanup EXIT

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-gotmp-tests.XXXXXX")

# Build a fake FM_HOME/FM_ROOT so the real fm-teardown.sh (symlinked in) resolves
# state and helper scripts inside it. Stub the helper scripts fm-teardown calls so no
# live tmux/treehouse/fleet state is touched. A nonexistent worktree path makes both
# `if [ -d "$WT" ]` guards skip, so teardown runs straight to the cleanup + state rm.
make_fake_root() {
  local id=$1 tasktmp=$2
  local fake="$TMP_ROOT/$id"
  mkdir -p "$fake/bin/backends" "$fake/state"
  # Symlink the REAL teardown so the test exercises actual code, not a copy.
  ln -s "$TEARDOWN" "$fake/bin/fm-teardown.sh"
  # fm-backend.sh + its tmux adapter: symlink the REAL files (teardown sources
  # fm-backend.sh unconditionally, and dispatches the kill call through the
  # tmux adapter; both are unchanged by this suite's fixture, just newly
  # required siblings since the P1 backend extraction).
  ln -s "$ROOT/bin/fm-backend.sh" "$fake/bin/fm-backend.sh"
  ln -s "$ROOT/bin/backends/tmux.sh" "$fake/bin/backends/tmux.sh"
  ln -s "$ROOT/bin/fm-tmux-lib.sh" "$fake/bin/fm-tmux-lib.sh"
  ln -s "$ROOT/bin/fm-cursor-lib.sh" "$fake/bin/fm-cursor-lib.sh"
  ln -s "$ROOT/bin/fm-composer-lib.sh" "$fake/bin/fm-composer-lib.sh"
  ln -s "$ROOT/bin/fm-nm-run-lib.sh" "$fake/bin/fm-nm-run-lib.sh"
  # fm-lock-lib.sh: teardown sources it for the shared lock-staleness proof.
  ln -s "$ROOT/bin/fm-lock-lib.sh" "$fake/bin/fm-lock-lib.sh"
  # Lifecycle serialization, status presentation retirement, and shared adapter
  # ownership are sourced by teardown.
  ln -s "$ROOT/bin/fm-control-lib.sh" "$fake/bin/fm-control-lib.sh"
  ln -s "$ROOT/bin/fm-classify-lib.sh" "$fake/bin/fm-classify-lib.sh"
  # fm-timeout-lib.sh: the shared hard bound fm-classify-lib.sh sources for the
  # wedge detector's bounded worktree write probe.
  ln -s "$ROOT/bin/fm-timeout-lib.sh" "$fake/bin/fm-timeout-lib.sh"
  # fm-gate-refuse-lib.sh: teardown sources it before any fleet mutation.
  ln -s "$ROOT/bin/fm-gate-refuse-lib.sh" "$fake/bin/fm-gate-refuse-lib.sh"
  # fm-pr-lib.sh: teardown uses its canonical task-ID validator for poll cleanup.
  ln -s "$ROOT/bin/fm-pr-lib.sh" "$fake/bin/fm-pr-lib.sh"
  # fm-public-followup-lib.sh (and the fm-x-lib.sh it sources): teardown sources
  # it for the relay-activation gate on the promised-public-reply check. Neither
  # does anything in this fixture, which has no .env, but both are real siblings
  # teardown now requires.
  ln -s "$ROOT/bin/fm-public-followup-lib.sh" "$fake/bin/fm-public-followup-lib.sh"
  ln -s "$ROOT/bin/fm-x-lib.sh" "$fake/bin/fm-x-lib.sh"
  ln -s "$ROOT/bin/fm-secondmate-registry-lib.sh" "$fake/bin/fm-secondmate-registry-lib.sh"
  ln -s "$ROOT/bin/fm-secondmate-parent-lib.sh" "$fake/bin/fm-secondmate-parent-lib.sh"
  # Receiver-wake retirement sources the pending-reply library, which in turn
  # requires the marker helper even for this ordinary-task teardown fixture.
  ln -s "$ROOT/bin/fm-pending-reply-lib.sh" "$fake/bin/fm-pending-reply-lib.sh"
  ln -s "$ROOT/bin/fm-marker-lib.sh" "$fake/bin/fm-marker-lib.sh"
  ln -s "$ROOT/bin/fm-operational-input.sh" "$fake/bin/fm-operational-input.sh"
  # fm-wake-lib.sh: teardown sources it for serialized secondmate lifecycle locks.
  ln -s "$ROOT/bin/fm-wake-lib.sh" "$fake/bin/fm-wake-lib.sh"
  # fm-retire-lib.sh: teardown sources it for retirement-finality purges.
  ln -s "$ROOT/bin/fm-retire-lib.sh" "$fake/bin/fm-retire-lib.sh"
  # fm-worktree-claim-lib.sh: teardown sources it for the shared-checkout co-tenant rules.
  ln -s "$ROOT/bin/fm-worktree-claim-lib.sh" "$fake/bin/fm-worktree-claim-lib.sh"
  # fm-guard.sh: stub (teardown calls it with `|| true`).
  cat > "$fake/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fake/bin/fm-guard.sh"
  # fm-fleet-sync.sh: stub (called for non-scout/non-local-only teardowns).
  cat > "$fake/bin/fm-fleet-sync.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fake/bin/fm-fleet-sync.sh"
  # fm-tasks-axi-lib.sh: stub (teardown sources it). Report no backend so
  # backlog_refresh_reminder takes the plain-message path; no tasks-axi here.
  cat > "$fake/bin/fm-tasks-axi-lib.sh" <<'SH'
fm_tasks_axi_backend_available() { return 1; }
SH
  # Meta with a nonexistent worktree so the dirty/treehouse blocks skip.
  cat > "$fake/state/$id.meta" <<META
window=fakeses:fm-$id
worktree=$TMP_ROOT/nonexistent-worktree-$id
project=$TMP_ROOT/nonexistent-project-$id
harness=claude
kind=ship
mode=no-mistakes
yolo=off
tasktmp=$tasktmp
META
  printf '%s' "$fake"
}

# --- fm-teardown side (real subprocess) ---

test_teardown_removes_tasktmp_dir() {
  local id=td-rm-z2
  local task_tmp="$TMP_ROOT/fm-$id"
  mkdir -p "$task_tmp/gotmp"
  printf 'leftover\n' > "$task_tmp/gotmp/build-artifact"
  local fake
  fake=$(make_fake_root "$id" "$task_tmp")
  # Sanity: dir + contents exist before teardown.
  [ -d "$task_tmp/gotmp" ] || fail "precondition: gotmp missing before teardown"
  # Run the REAL teardown against the fake root.
  FM_HOME="$fake" bash "$fake/bin/fm-teardown.sh" "$id" >/dev/null 2>&1 \
    || fail "teardown exited non-zero with a valid tasktmp"
  [ ! -e "$task_tmp" ] \
    || fail "teardown did not remove the tasktmp dir ($task_tmp still exists)"
  pass "fm-teardown removes the dir pointed to by tasktmp= in meta"
}

test_teardown_skips_gracefully_without_tasktmp() {
  # Backward compat: a meta from a pre-fix task has no tasktmp= line. Teardown must
  # not error and must not remove anything.
  local id=td-absent-z3
  local fake="$TMP_ROOT/$id-root"
  mkdir -p "$fake/bin/backends" "$fake/state"
  ln -s "$TEARDOWN" "$fake/bin/fm-teardown.sh"
  ln -s "$ROOT/bin/fm-backend.sh" "$fake/bin/fm-backend.sh"
  ln -s "$ROOT/bin/backends/tmux.sh" "$fake/bin/backends/tmux.sh"
  ln -s "$ROOT/bin/fm-tmux-lib.sh" "$fake/bin/fm-tmux-lib.sh"
  ln -s "$ROOT/bin/fm-cursor-lib.sh" "$fake/bin/fm-cursor-lib.sh"
  ln -s "$ROOT/bin/fm-composer-lib.sh" "$fake/bin/fm-composer-lib.sh"
  ln -s "$ROOT/bin/fm-nm-run-lib.sh" "$fake/bin/fm-nm-run-lib.sh"
  ln -s "$ROOT/bin/fm-lock-lib.sh" "$fake/bin/fm-lock-lib.sh"
  ln -s "$ROOT/bin/fm-control-lib.sh" "$fake/bin/fm-control-lib.sh"
  ln -s "$ROOT/bin/fm-classify-lib.sh" "$fake/bin/fm-classify-lib.sh"
  # fm-timeout-lib.sh: the shared hard bound fm-classify-lib.sh sources for the
  # wedge detector's bounded worktree write probe.
  ln -s "$ROOT/bin/fm-timeout-lib.sh" "$fake/bin/fm-timeout-lib.sh"
  # fm-gate-refuse-lib.sh: teardown sources it before any fleet mutation.
  ln -s "$ROOT/bin/fm-gate-refuse-lib.sh" "$fake/bin/fm-gate-refuse-lib.sh"
  # fm-pr-lib.sh: teardown uses its canonical task-ID validator for poll cleanup.
  ln -s "$ROOT/bin/fm-pr-lib.sh" "$fake/bin/fm-pr-lib.sh"
  # fm-public-followup-lib.sh (and the fm-x-lib.sh it sources): teardown sources
  # it for the relay-activation gate on the promised-public-reply check. Neither
  # does anything in this fixture, which has no .env, but both are real siblings
  # teardown now requires.
  ln -s "$ROOT/bin/fm-public-followup-lib.sh" "$fake/bin/fm-public-followup-lib.sh"
  ln -s "$ROOT/bin/fm-x-lib.sh" "$fake/bin/fm-x-lib.sh"
  ln -s "$ROOT/bin/fm-secondmate-registry-lib.sh" "$fake/bin/fm-secondmate-registry-lib.sh"
  ln -s "$ROOT/bin/fm-secondmate-parent-lib.sh" "$fake/bin/fm-secondmate-parent-lib.sh"
  ln -s "$ROOT/bin/fm-pending-reply-lib.sh" "$fake/bin/fm-pending-reply-lib.sh"
  ln -s "$ROOT/bin/fm-marker-lib.sh" "$fake/bin/fm-marker-lib.sh"
  ln -s "$ROOT/bin/fm-operational-input.sh" "$fake/bin/fm-operational-input.sh"
  ln -s "$ROOT/bin/fm-wake-lib.sh" "$fake/bin/fm-wake-lib.sh"
  # fm-retire-lib.sh: teardown sources it for retirement-finality purges.
  ln -s "$ROOT/bin/fm-retire-lib.sh" "$fake/bin/fm-retire-lib.sh"
  # fm-worktree-claim-lib.sh: teardown sources it for the shared-checkout co-tenant rules.
  ln -s "$ROOT/bin/fm-worktree-claim-lib.sh" "$fake/bin/fm-worktree-claim-lib.sh"
  cat > "$fake/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fake/bin/fm-guard.sh"
  cat > "$fake/bin/fm-fleet-sync.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fake/bin/fm-fleet-sync.sh"
  cat > "$fake/bin/fm-tasks-axi-lib.sh" <<'SH'
fm_tasks_axi_backend_available() { return 1; }
SH
  # No tasktmp= line at all.
  cat > "$fake/state/$id.meta" <<META
window=fakeses:fm-$id
worktree=$TMP_ROOT/nonexistent-wt-$id
project=$TMP_ROOT/nonexistent-proj-$id
harness=claude
kind=ship
mode=no-mistakes
yolo=off
META
  FM_HOME="$fake" bash "$fake/bin/fm-teardown.sh" "$id" >/dev/null 2>&1 \
    || fail "teardown exited non-zero when tasktmp= was absent"
  pass "fm-teardown skips gracefully when tasktmp= is absent (backward compat)"
}

test_teardown_skips_gracefully_when_dir_missing() {
  # tasktmp= points to a path that does not exist. Teardown must not error.
  local id=td-missing-z4
  local task_tmp="$TMP_ROOT/never-created-fm-$id"
  # Intentionally do NOT create $task_tmp.
  [ ! -e "$task_tmp" ] || fail "precondition: task_tmp should not exist yet"
  local fake
  fake=$(make_fake_root "$id" "$task_tmp")
  FM_HOME="$fake" bash "$fake/bin/fm-teardown.sh" "$id" >/dev/null 2>&1 \
    || fail "teardown exited non-zero when tasktmp dir was missing"
  [ ! -e "$task_tmp" ] || fail "teardown created/left the tasktmp dir unexpectedly"
  pass "fm-teardown skips gracefully when tasktmp= points to a nonexistent dir"
}

test_teardown_removes_legacy_tmpfs_tasktmp() {
  # A task spawned before the scratch root moved off the shared temporary
  # filesystem recorded tasktmp=/tmp/fm-<id>. Teardown must remove that exact
  # recorded path instead of re-deriving today's root, or the old directory leaks.
  local id="td-legacy-z5-$$"
  local legacy="/tmp/fm-$id"
  LEGACY_TMPFS_FIXTURE=$legacy
  local current_root="$TMP_ROOT/$id-current-root"
  mkdir -p "$legacy/gotmp" \
    || fail "precondition: could not create the legacy temp root $legacy"
  printf 'leftover\n' > "$legacy/gotmp/build-artifact"
  local fake
  fake=$(make_fake_root "$id" "$legacy")
  FM_HOME="$fake" FM_TASKTMP_ROOT="$current_root" \
    bash "$fake/bin/fm-teardown.sh" "$id" >/dev/null 2>&1 || {
    rm -rf "$legacy"
    fail "teardown exited non-zero with a legacy tasktmp"
  }
  [ ! -e "$legacy" ] || {
    rm -rf "$legacy"
    fail "teardown left the legacy tasktmp dir behind ($legacy still exists)"
  }
  [ ! -e "$current_root/fm-$id" ] \
    || fail "teardown re-derived a current-root path instead of using the recorded one"
  pass "fm-teardown removes a tasktmp recorded on the shared temporary filesystem"
}

# --- fm-tasktmp-lib.sh side (real library, subshell per case) ---

# tasktmp_call <env-assignments...> -- <function> [args...]
# Runs one library call in a clean subshell so no case leaks env into the next.
tasktmp_call() {
  local -a envs=()
  while [ "$#" -gt 0 ] && [ "$1" != -- ]; do
    envs+=("$1")
    shift
  done
  shift
  # The single-quoted body is the child shell's script, not this shell's: the
  # positional parameters it expands are the ones passed after it.
  # shellcheck disable=SC2016
  env -u FM_TASKTMP_ROOT -u XDG_CACHE_HOME -u HOME "${envs[@]}" \
    bash -c '. "$1"; shift; "$@"' _ "$TASKTMP_LIB" "$@"
}

test_root_prefers_the_operator_override() {
  local out
  out=$(tasktmp_call FM_TASKTMP_ROOT=/srv/scratch XDG_CACHE_HOME=/c HOME=/h -- fm_tasktmp_root) \
    || fail "an absolute FM_TASKTMP_ROOT should resolve"
  [ "$out" = /srv/scratch ] || fail "override not honored (got: $out)"
  out=$(tasktmp_call FM_TASKTMP_ROOT=/srv/scratch/ -- fm_tasktmp_dir demo-id) \
    || fail "fm_tasktmp_dir should resolve under an absolute override"
  [ "$out" = /srv/scratch/fm-demo-id ] \
    || fail "task dir is not <root>/fm-<id> with the trailing slash trimmed (got: $out)"
  pass "fm_tasktmp_root prefers FM_TASKTMP_ROOT and fm_tasktmp_dir nests fm-<id> under it"
}

test_root_refuses_a_relative_override() {
  local out rc
  out=$(tasktmp_call FM_TASKTMP_ROOT=scratch HOME=/h -- fm_tasktmp_root 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "a relative FM_TASKTMP_ROOT should be refused (got: $out)"
  case "$out" in
    *"FM_TASKTMP_ROOT must be an absolute path"*) ;;
    *) fail "the refusal did not name the absolute-path requirement (got: $out)" ;;
  esac
  pass "fm_tasktmp_root refuses a relative FM_TASKTMP_ROOT instead of guessing"
}

test_root_falls_back_to_the_cache_directory() {
  local out
  out=$(tasktmp_call XDG_CACHE_HOME=/c HOME=/h -- fm_tasktmp_root) \
    || fail "XDG_CACHE_HOME should resolve a root"
  [ "$out" = /c/firstmate/tasktmp ] || fail "XDG_CACHE_HOME root is wrong (got: $out)"
  out=$(tasktmp_call HOME=/h -- fm_tasktmp_root) \
    || fail "HOME should resolve a root when XDG_CACHE_HOME is unset"
  [ "$out" = /h/.cache/firstmate/tasktmp ] || fail "HOME root is wrong (got: $out)"
  case "$out" in
    /tmp/*) fail "the default root landed on the shared temporary filesystem" ;;
  esac
  pass "fm_tasktmp_root falls back to XDG_CACHE_HOME then HOME, never to /tmp"
}

test_root_refuses_when_nothing_resolves() {
  local out rc
  out=$(tasktmp_call -- fm_tasktmp_root 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "an unresolvable root should be refused (got: $out)"
  case "$out" in
    *FM_TASKTMP_ROOT*) ;;
    *) fail "the refusal did not name the override that fixes it (got: $out)" ;;
  esac
  out=$(tasktmp_call HOME=relative XDG_CACHE_HOME=also-relative -- fm_tasktmp_root 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "relative HOME/XDG_CACHE_HOME should not resolve a root (got: $out)"
  pass "fm_tasktmp_root refuses rather than falling back to a temporary filesystem"
}

test_task_dir_requires_an_id() {
  local out rc
  out=$(tasktmp_call FM_TASKTMP_ROOT=/srv/scratch -- fm_tasktmp_dir 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "fm_tasktmp_dir should refuse an empty task id (got: $out)"
  pass "fm_tasktmp_dir refuses without a task id"
}

test_teardown_removes_tasktmp_dir
test_teardown_skips_gracefully_without_tasktmp
test_teardown_skips_gracefully_when_dir_missing
test_teardown_removes_legacy_tmpfs_tasktmp
test_root_prefers_the_operator_override
test_root_refuses_a_relative_override
test_root_falls_back_to_the_cache_directory
test_root_refuses_when_nothing_resolves
test_task_dir_requires_an_id
