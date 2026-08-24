#!/usr/bin/env bash
# Manual E2E evidence driver for PR "root per-task scratch on disk and export
# TMPDIR alongside GOTMPDIR". Runs the REAL bin/fm-spawn.sh and REAL
# bin/fm-teardown.sh against the same stub tmux/kimi fixtures the behavior
# suite uses, with NO FM_TASKTMP_ROOT override and NO XDG_CACHE_HOME, so the
# scratch root resolves through the default disk-backed path:
#   $HOME/.cache/firstmate/tasktmp/fm-<id>
set -u
WORKTREE="/home/ubuntu/.no-mistakes/worktrees/5d83c95b53c3/01M0T1JYXG6CYA0VDSW9TMJ7YM"
. "$WORKTREE/tests/lib.sh"
unset CLAUDECODE PI_CODING_AGENT FM_PI_HARNESS GROK_AGENT CURSOR_AGENT CURSOR_INVOKED_AS
SPAWN="$ROOT/bin/fm-spawn.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-e2e-evidence)
PYTHON_BIN=$(command -v python3) || { echo "need python3" >&2; exit 1; }
PYTHON_BIN_DIR=$(dirname "$PYTHON_BIN")
JQ_BIN=$(command -v jq) || { echo "need jq" >&2; exit 1; }
BASE_PATH=${FM_TEST_BASE_PATH:-$PYTHON_BIN_DIR:/usr/bin:/bin:/usr/sbin:/sbin}
cleanup_driver() { rm -rf "$TMP_ROOT"; fm_test_cleanup; }
trap cleanup_driver EXIT

# --- helpers reused verbatim from tests/fm-kimi-harness.test.sh ---
eval "$(sed -n '36,189p' "$WORKTREE/tests/fm-kimi-harness.test.sh")"

id="e2e-evidence-$$"
echo "# E2E transcript: real fm-spawn + fm-teardown, commit $(git -C "$WORKTREE" rev-parse --short HEAD), $(date -u +%FT%TZ)"
rec=$(make_spawn_case e2e "$id")
read_spawn_record "$rec"

echo
echo "== 1. Real fm-spawn run (FM_TASKTMP_ROOT unset, XDG_CACHE_HOME unset, HOME=\$case/home) =="
out=$(FM_TASKTMP_ROOT= XDG_CACHE_HOME= FM_FAKE_KIMI_SWALLOW_FIRST=yes run_spawn \
  "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" \
  --model kimi-code/k3 --effort high)
rc=$?
echo "$out"
echo "spawn exit code: $rc"
[ "$rc" -eq 0 ] || exit 1

expected_root="$HOME_DIR/.cache/firstmate/tasktmp/fm-$id"
echo
echo "== 2. Scratch root created on disk under the user cache dir (not /tmp) =="
find "$expected_root" | sort

echo
echo "== 3. Recorded in the task's durable metadata =="
grep '^tasktmp=' "$HOME_DIR/state/$id.meta"

echo
echo "== 4. Env exports sent into the crewmate pane (stub tmux send-keys log) =="
grep -E "export (TMPDIR|GOTMPDIR)=" "$CASE_DIR/tmux-calls.log"

echo
echo "== 5. Legacy shared-tmpfs path is NOT created =="
if [ -e "/tmp/fm-$id" ]; then echo "FAIL: /tmp/fm-$id exists"; exit 1; fi
echo "OK: /tmp/fm-$id does not exist"

echo
echo "== 6. Real fm-teardown removes exactly the recorded root =="
HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
  FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
  FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
  FM_SPAWN_NO_GUARD=1 PATH="$FAKEBIN_DIR:$BASE_PATH" \
  "$TEARDOWN" "$id" --force >/dev/null 2>&1 || { echo "teardown failed" >&2; exit 1; }
if [ -e "$expected_root" ]; then echo "FAIL: scratch root survived teardown"; exit 1; fi
echo "OK: fm-teardown removed $expected_root"
echo
echo "# E2E result: PASS"
