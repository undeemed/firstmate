#!/usr/bin/env bash
# Tests for bin/fm-consult.sh - the per-tier codex consult gate.
#
# Asserts the tier -> codex-model mapping, the xhigh effort flag, and graceful
# non-blocking degradation when codex is unavailable or fails. It makes NO real
# codex calls (codex is stubbed via FM_CONSULT_CODEX) so it never touches quota
# and never triggers a /usage reset.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CONSULT="$ROOT/bin/fm-consult.sh"
TMP_ROOT=$(fm_test_tmproot fm-consult-tests)
mkdir -p "$TMP_ROOT"

# A codex stub that records its full argument line to $CODEX_ARGS_LOG and exits 0.
STUB="$TMP_ROOT/codex-echo"
cat > "$STUB" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" > "${CODEX_ARGS_LOG:?}"
echo "codex answer"
exit 0
SH
chmod +x "$STUB"

# A codex stub that always fails (unauthenticated / quota-exhausted analogue).
STUB_FAIL="$TMP_ROOT/codex-fail"
cat > "$STUB_FAIL" <<'SH'
#!/usr/bin/env bash
echo "codex: not logged in" >&2
exit 1
SH
chmod +x "$STUB_FAIL"

run_consult() {  # log-file <args...>
  local log=$1; shift
  CODEX_ARGS_LOG="$log" FM_CONSULT_CODEX="$STUB" "$CONSULT" "$@"
}

test_tier_model_mapping() {
  local log out
  log="$TMP_ROOT/args"

  out=$(run_consult "$log" firstmate "why is X failing") || fail "firstmate consult failed"
  assert_contains "$(cat "$log")" "--model gpt-5.6-sol" "firstmate must consult gpt-5.6-sol"
  assert_contains "$(cat "$log")" 'model_reasoning_effort="xhigh"' "firstmate consult must run at xhigh"
  assert_contains "$out" "codex answer" "firstmate consult did not relay codex output"

  run_consult "$log" secondmate "advise" >/dev/null || fail "secondmate consult failed"
  assert_contains "$(cat "$log")" "--model gpt-5.6-sol" "secondmate default must consult gpt-5.6-sol"

  run_consult "$log" --terra secondmate "advise harder" >/dev/null || fail "secondmate --terra consult failed"
  assert_contains "$(cat "$log")" "--model gpt-5.6-terra" "secondmate --terra must consult gpt-5.6-terra"

  run_consult "$log" crewmate "advise" >/dev/null || fail "crewmate consult failed"
  assert_contains "$(cat "$log")" "--model gpt-5.6-terra" "crewmate must consult gpt-5.6-terra"

  # --terra only affects the secondmate tier; the other tiers ignore it.
  run_consult "$log" --terra firstmate "advise" >/dev/null || fail "firstmate --terra consult failed"
  assert_contains "$(cat "$log")" "--model gpt-5.6-sol" "--terra must not change the firstmate model"

  # A non-interactive exec, read-only sandbox by default, never a git-repo gate,
  # with the read-only directive prepended to the question.
  #
  # Test-hermeticity fix (out-of-scope-but-required engineering-excellence):
  # FM_CONSULT_SANDBOX may be exported ambiently (this container exports
  # danger-full-access globally per PR #8, because bwrap cannot run here). The
  # default-sandbox assertion must hold regardless of that ambient value, so run
  # this one case with the variable saved and unset, then restore it. The other
  # case that needs the override (test_sandbox_override) is left untouched.
  local saved_sandbox had_sandbox=0
  saved_sandbox="${FM_CONSULT_SANDBOX-}"
  [ -n "${FM_CONSULT_SANDBOX+set}" ] && had_sandbox=1
  unset FM_CONSULT_SANDBOX
  run_consult "$log" firstmate "advise" >/dev/null || fail "default-sandbox consult failed"
  [ "$had_sandbox" = 1 ] && export FM_CONSULT_SANDBOX="$saved_sandbox"
  assert_contains "$(cat "$log")" "exec" "consult must use codex exec (non-interactive)"
  assert_contains "$(cat "$log")" "--sandbox read-only" "consult must default to a read-only codex sandbox"
  assert_contains "$(cat "$log")" "Read-only advisory consult" "consult must prepend the read-only directive to the question"
  pass "fm-consult maps each tier to its codex model at xhigh (secondmate --terra escalates)"
}

test_sandbox_override() {
  local log
  log="$TMP_ROOT/args-sandbox"

  # FM_CONSULT_SANDBOX replaces the default read-only sandbox mode; the
  # read-only directive still rides with the question.
  CODEX_ARGS_LOG="$log" FM_CONSULT_CODEX="$STUB" FM_CONSULT_SANDBOX=danger-full-access \
    "$CONSULT" firstmate "advise" >/dev/null || fail "sandbox-override consult failed"
  assert_contains "$(cat "$log")" "--sandbox danger-full-access" "FM_CONSULT_SANDBOX must override the sandbox mode"
  assert_not_contains "$(cat "$log")" "--sandbox read-only" "an overridden sandbox must replace read-only, not add to it"
  assert_contains "$(cat "$log")" "Read-only advisory consult" "the read-only directive must survive a sandbox override"
  pass "fm-consult honors FM_CONSULT_SANDBOX while keeping the read-only directive"
}

test_flaglike_words_in_question_are_preserved() {
  local log out
  log="$TMP_ROOT/args-flagwords"

  # A -h word inside an unquoted multi-word question must not become a silent
  # usage-and-exit-0; the consult must still run with the word intact.
  out=$(run_consult "$log" firstmate what does -h mean here) || fail "flag-words: -h consult failed"
  assert_contains "$out" "codex answer" "flag-words: -h in the question must still consult codex"
  assert_contains "$(cat "$log")" "what does -h mean here" "flag-words: -h must stay part of the question"

  # A literal --terra after the tier is question text, never a consumed flag.
  run_consult "$log" firstmate should I pass --terra here >/dev/null || fail "flag-words: --terra consult failed"
  assert_contains "$(cat "$log")" "--model gpt-5.6-sol" "flag-words: a mid-question --terra must not change the model"
  assert_contains "$(cat "$log")" "should I pass --terra here" "flag-words: --terra must stay part of the question"

  # An explicit -- ends flag parsing; flags before it still apply.
  run_consult "$log" --terra -- secondmate question after separator >/dev/null || fail "flag-words: -- consult failed"
  assert_contains "$(cat "$log")" "--model gpt-5.6-terra" "flag-words: flags before -- must still apply"
  assert_contains "$(cat "$log")" "question after separator" "flag-words: positionals after -- must be preserved"
  pass "fm-consult treats everything from the tier onward as the question (flags only before it)"
}

test_unknown_tier_errors() {
  local rc
  set +e
  run_consult "$TMP_ROOT/args2" bogus "q" >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 2 "$rc" "unknown tier should exit 2"
  pass "fm-consult rejects an unknown tier with a usage error"
}

test_missing_question_errors() {
  local rc
  set +e
  run_consult "$TMP_ROOT/args3" firstmate >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 2 "$rc" "missing question should exit 2"
  pass "fm-consult requires a question"
}

test_graceful_when_codex_absent() {
  local rc out
  set +e
  out=$(FM_CONSULT_CODEX="definitely-not-a-real-codex-binary-xyz" "$CONSULT" firstmate "hello" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "codex-absent: consult must exit non-zero"
  assert_contains "$out" "codex not found" "codex-absent: consult did not explain the missing codex"
  assert_contains "$out" "advisory" "codex-absent: consult did not signal it is advisory/non-blocking"
  pass "fm-consult degrades gracefully (non-zero, advisory) when codex is absent"
}

test_graceful_when_codex_fails() {
  local rc out
  set +e
  out=$(FM_CONSULT_CODEX="$STUB_FAIL" "$CONSULT" crewmate "hello" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "codex-fail: consult must exit non-zero when codex fails"
  assert_contains "$out" "consult failed" "codex-fail: consult did not report the failure"
  assert_contains "$out" "advisory" "codex-fail: consult did not signal it is advisory/non-blocking"
  pass "fm-consult degrades gracefully when codex errors (unauth/quota-exhausted)"
}

test_tier_model_mapping
test_sandbox_override
test_flaglike_words_in_question_are_preserved
test_unknown_tier_errors
test_missing_question_errors
test_graceful_when_codex_absent
test_graceful_when_codex_fails
