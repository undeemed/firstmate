#!/usr/bin/env bash
# Contract: local no-mistakes Test is deterministic, non-agent, and bounded; CI
# owns broad regression.
#
# commands.test must pin a concrete command, because an agent-driven Test step
# has crashed the daemon. It must also stay bounded, so the pinned string may not
# hardcode a complete tests/*.test.sh walk or --all: a fixed full-suite spelling
# duplicates CI and burns local pipeline time no matter what changed. This
# contract requires the changed-file selection of the one-owner runner,
# `bin/fm-test-run.sh --changed`, optionally narrowed by --base and
# --exclude-family, because that keeps the suites a branch edits in scope by
# construction. What the selection resolves to is deliberately not asserted here
# (see .no-mistakes.yaml). Lint stays pinned to bin/fm-lint.sh.
# Remote CI owns broad regression through separate portable and required
# real-Herdr Behavior lanes composed around bin/fm-test-run.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NM="$ROOT/.no-mistakes.yaml"
CI="$ROOT/.github/workflows/ci.yml"

test_nm_yaml_tracked() {
  assert_present "$NM" "tracked .no-mistakes.yaml is missing"
  git -C "$ROOT" ls-files --error-unmatch .no-mistakes.yaml >/dev/null 2>&1 \
    || fail ".no-mistakes.yaml is not tracked by git"
  pass ".no-mistakes.yaml is present and tracked"
}

test_nm_keeps_lint_pin() {
  grep -Fqx "  lint: 'bin/fm-lint.sh'" "$NM" \
    || fail "commands.lint must remain exactly bin/fm-lint.sh"
  pass "commands.lint stays pinned to bin/fm-lint.sh"
}

# Prints the mapped commands.test (string or mapping value), or empty when the
# key is absent or null. An empty value means Test fell back to agent-driven
# handling, which this contract refuses.
nm_commands_test_value() {
  if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
    python3 -c '
import yaml, sys
doc = yaml.safe_load(open(sys.argv[1])) or {}
cmds = doc.get("commands") or {}
val = cmds.get("test") if isinstance(cmds, dict) else None
if val is None or val is False:
    print("")
elif isinstance(val, str):
    print(val)
else:
    print(repr(val))
' "$NM"
    return
  fi
  if command -v ruby >/dev/null 2>&1; then
    ruby -ryaml -e '
doc = YAML.safe_load(File.read(ARGV[0])) || {}
cmds = doc["commands"] || {}
val = cmds.is_a?(Hash) ? cmds["test"] : nil
if val.nil? || val == false
  puts ""
elsif val.is_a?(String)
  puts val
else
  puts val.inspect
end
' "$NM"
    return
  fi
  # Structural fallback: any commands.test line under the commands block.
  awk '
    /^commands:[[:space:]]*$/ { in_cmds=1; next }
    in_cmds && /^[^[:space:]#]/ { in_cmds=0 }
    in_cmds && /^[[:space:]]+test:[[:space:]]*/ {
      sub(/^[[:space:]]+test:[[:space:]]*/, "")
      gsub(/^['\''"]|['\''"]$/, "")
      print
      exit
    }
  ' "$NM"
}

test_nm_pins_bounded_deterministic_test_command() {
  local val
  val=$(nm_commands_test_value) || fail "failed to read commands.test from .no-mistakes.yaml"
  [ -n "$val" ] \
    || fail "commands.test must pin a deterministic non-agent command; an absent value hands Test back to an agent"
  # This refusal matches by spelling, not by measured scope: a bounded selection
  # mode can still resolve to every script. A selection ceiling is tracked
  # separately as backlog nm-test-selection-ceiling-c3.
  case "$val" in
    *'tests/*.test.sh'*|*'--all'*)
      fail "commands.test must not hardcode a full-suite walk; got: $val"
      ;;
  esac
  # The changed-file selection of the one-owner runner is the required shape: it
  # is deterministic, it keeps map composition in a single owner instead of a
  # hand-picked script list, and it cannot drop the suites the branch edits.
  case "$val" in
    'bin/fm-test-run.sh --changed'*) ;;
    *) fail "commands.test must select through bin/fm-test-run.sh --changed; got: $val" ;;
  esac
  # Also refuse a commented-out full-suite remnant that could be re-enabled by habit.
  if grep -E '^[[:space:]]*#?[[:space:]]*test:[[:space:]].*tests/\*\.test\.sh' "$NM" >/dev/null 2>&1; then
    fail ".no-mistakes.yaml still documents a full-suite commands.test line (active or comment)"
  fi
  pass "commands.test pins a bounded deterministic selection of the one-owner runner"
}

# The pinned command must be a real selection mode of the one-owner runner, so a
# rename or flag removal there cannot leave the gate pointing at a dead command.
test_pinned_test_command_is_a_supported_selection() {
  local val runner family
  val=$(nm_commands_test_value) || fail "failed to read commands.test from .no-mistakes.yaml"
  runner=${val%% *}
  [ -x "$ROOT/$runner" ] || fail "commands.test names a runner that is not executable: $runner"
  # Assert only the flags the current pin actually uses, so this check tracks the
  # pin instead of demanding a mode it no longer names.
  case "$val" in
    *' --changed'*)
      grep -Fq -- '--changed' "$ROOT/$runner" \
        || fail "$runner no longer implements --changed, which commands.test depends on"
      ;;
    *) fail "commands.test names no bounded selection flag: $val" ;;
  esac
  case "$val" in
    *' --base '*)
      grep -Fq -- '--base' "$ROOT/$runner" \
        || fail "$runner no longer implements --base, which commands.test depends on"
      ;;
  esac
  case "$val" in
    *' --exclude-family '*)
      grep -Fq -- '--exclude-family' "$ROOT/$runner" \
        || fail "$runner no longer implements --exclude-family, which commands.test depends on"
      family=${val#*--exclude-family }
      family=${family%% *}
      [ -n "$family" ] || fail "commands.test names --exclude-family without a family: $val"
      "$ROOT/$runner" --list-families 2>/dev/null | grep -Fqx "$family" \
        || fail "$runner --list-families does not offer the excluded family: $family"
      ;;
  esac
  pass "the pinned Test command matches a supported bin/fm-test-run.sh selection"
}

test_ci_still_runs_broad_behavior_suite() {
  assert_present "$CI" "ci.yml is missing"
  # Portable shards and the serial remainder cover every portable behavior
  # script through the one owner, with a deterministic inventory guard.
  grep -Fq 'bin/fm-test-run.sh --lane portable-parallel-1' "$CI" \
    || fail "CI must invoke portable parallel shard 1 through fm-test-run.sh"
  grep -Fq 'bin/fm-test-run.sh --lane portable-parallel-2' "$CI" \
    || fail "CI must invoke portable parallel shard 2 through fm-test-run.sh"
  grep -Fq 'bin/fm-test-run.sh --lane portable-serial' "$CI" \
    || fail "CI must invoke the portable serial remainder through fm-test-run.sh"
  grep -Fq 'bin/fm-test-run.sh --check-coverage' "$CI" \
    || fail "CI must prove complete lane coverage through fm-test-run.sh"
  # Guard against regression to an uninstrumented inline loop that drops timing.
  if grep -Eq 'for test_script in tests/\*\.test\.sh' "$CI"; then
    fail "CI Behavior must not re-spell an inline tests/*.test.sh loop; use fm-test-run.sh"
  fi
  # Preserve other CI lanes this task must not shrink.
  grep -Eq 'name:[[:space:]]*Lint shell scripts' "$CI" \
    || fail "CI must retain the lint job"
  grep -Eq 'name:[[:space:]]*Stock macOS Bash snapshot compatibility' "$CI" \
    || fail "CI must retain the macOS stock Bash compatibility job"
  grep -Eq 'name:[[:space:]]*Repo invariants' "$CI" \
    || fail "CI must retain the repo invariants job"
  grep -Fq 'tests-herdr:' "$CI" \
    || fail "CI must retain the required Herdr Behavior job"
  pass "CI still owns partitioned broad behavior coverage and companion jobs"
}

test_nm_yaml_tracked
test_nm_keeps_lint_pin
test_nm_pins_bounded_deterministic_test_command
test_pinned_test_command_is_a_supported_selection
test_ci_still_runs_broad_behavior_suite
