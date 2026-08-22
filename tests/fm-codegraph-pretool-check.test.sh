#!/usr/bin/env bash
# shellcheck disable=SC1091
# Behavior tests for the CodeGraph-first PreToolUse seatbelt
# (docs/codegraph-pretool-check.md).
#
# bin/fm-codegraph-pretool-check.sh is both the transport and the decision owner:
# it denies a raw repository code search only inside a repository that carries a
# .codegraph/ index, and allows everything else. This suite proves the allow/deny
# matrix through both the CLI and the Claude stdin JSON entry forms, the indexed-
# versus-unindexed scoping, the pipe/stdin and outside/vendored/*.log carve-outs,
# the environment and inline escape hatches, the structured search-tool path, the
# fail-open transport behavior, and the empty-stdout-on-deny output contract. No
# harness is spawned.
#
# extensions/fm-codegraph-guard.ts is the pi/omp transport in front of that
# decision owner, and it owns one decision of its own: what happens when the
# checker cannot run at all. That policy is exercised here too, by driving the
# extension's exported tool_call handler directly.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-codegraph-pretool-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-codegraph-pretool-check)

# An indexed repository: a Git working tree carrying a .codegraph/ index, plus
# ordinary code and the vendored/log paths the carve-outs recognize.
INDEXED="$TMP_ROOT/indexed"
mkdir -p "$INDEXED/src" "$INDEXED/.git" "$INDEXED/.codegraph" "$INDEXED/node_modules/pkg"
printf 'fn main() {}\n' >"$INDEXED/src/main.rs"
printf 'log line\n' >"$INDEXED/app.log"

# A second directory inside the indexed repo, used to prove a `cd` into it is
# still judged against the same index.
mkdir -p "$INDEXED/src/deep"

# A plain repository with no .codegraph/ index: the check must be inert here.
PLAIN="$TMP_ROOT/plain"
mkdir -p "$PLAIN/src" "$PLAIN/.git"

# A repository nested inside the indexed one, with no index of its own. The
# index above it belongs to the outer project, so the guard must stay inert.
NESTED="$INDEXED/vendored-repo"
mkdir -p "$NESTED/src" "$NESTED/.git"

# An indexed directory that is not a repository root, with a plain repository
# beneath it. Indexing a whole home directory must not make every repository
# under it look indexed.
ANCESTOR="$TMP_ROOT/ancestor"
mkdir -p "$ANCESTOR/.codegraph" "$ANCESTOR/repo/src" "$ANCESTOR/repo/.git"

# A directory outside the indexed repo, used as an outside-the-repo target.
OUTSIDE="$TMP_ROOT/outside"
mkdir -p "$OUTSIDE"

# --- entry-form drivers -----------------------------------------------------

# check_cli <cwd> <tool> [command]: run the CLI form; sets RC/OUT/ERR.
check_cli() {
  local cwd=$1 tool=$2 cmd=${3-}
  local out_file err_file
  out_file=$(mktemp "$TMP_ROOT/out.XXXXXX")
  err_file=$(mktemp "$TMP_ROOT/err.XXXXXX")
  if [ "$#" -ge 3 ]; then
    "$CHECK" --tool "$tool" --command "$cmd" --cwd "$cwd" >"$out_file" 2>"$err_file"
  else
    "$CHECK" --tool "$tool" --cwd "$cwd" >"$out_file" 2>"$err_file"
  fi
  RC=$?
  OUT=$(cat "$out_file")
  ERR=$(cat "$err_file")
}

# check_stdin <json>: run the Claude stdin JSON form; sets RC/OUT/ERR.
check_stdin() {
  local json=$1 out_file err_file
  out_file=$(mktemp "$TMP_ROOT/out.XXXXXX")
  err_file=$(mktemp "$TMP_ROOT/err.XXXXXX")
  printf '%s' "$json" | "$CHECK" >"$out_file" 2>"$err_file"
  RC=$?
  OUT=$(cat "$out_file")
  ERR=$(cat "$err_file")
}

# --- verdict assertions -----------------------------------------------------

expect_allow() {
  [ "$RC" -eq 0 ] || fail "$1: expected allow (exit 0), got $RC; stderr: $ERR"
  [ -z "$OUT" ] || fail "$1: allow must leave stdout empty; got: $OUT"
  [ -z "$ERR" ] || fail "$1: allow must leave stderr empty; got: $ERR"
  pass "$1"
}

expect_deny() {
  [ "$RC" -eq 2 ] || fail "$1: expected deny (exit 2), got $RC; stderr: $ERR"
  [ -z "$OUT" ] || fail "$1: deny must leave stdout empty; got: $OUT"
  case "$ERR" in
  *"codegraph explore"*) ;;
  *) fail "$1: deny reason must offer the codegraph explore alternative; got: $ERR" ;;
  esac
  case "$ERR" in
  *FM_ALLOW_RAW_SEARCH*) ;;
  *) fail "$1: deny reason must name the escape hatch; got: $ERR" ;;
  esac
  pass "$1"
}

# --- the required allow/deny matrix -----------------------------------------

test_deny_raw_search_in_indexed_repo() {
  check_cli "$INDEXED" bash 'rg foo src/'
  expect_deny "deny rg foo src/ in a CodeGraph-indexed repo"
}

test_allow_raw_search_without_index() {
  check_cli "$PLAIN" bash 'rg foo src/'
  expect_allow "allow rg foo src/ in a repo with no .codegraph/"
}

test_allow_pipe_into_grep() {
  check_cli "$INDEXED" bash 'cat file | grep foo'
  expect_allow "allow cat file | grep foo (grep is downstream of a pipe)"
}

test_allow_env_escape_hatch() {
  local out_file err_file
  out_file=$(mktemp "$TMP_ROOT/out.XXXXXX")
  err_file=$(mktemp "$TMP_ROOT/err.XXXXXX")
  FM_ALLOW_RAW_SEARCH=1 "$CHECK" --tool bash --command 'rg foo src/' --cwd "$INDEXED" \
    >"$out_file" 2>"$err_file"
  RC=$?
  OUT=$(cat "$out_file")
  ERR=$(cat "$err_file")
  expect_allow "allow with FM_ALLOW_RAW_SEARCH=1 in the environment"
}

test_allow_inline_escape_hatch() {
  check_cli "$INDEXED" bash 'FM_ALLOW_RAW_SEARCH=1 rg foo src/'
  expect_allow "allow with FM_ALLOW_RAW_SEARCH=1 as an inline prefix"
}

test_allow_target_outside_repo() {
  check_cli "$INDEXED" bash "rg foo $OUTSIDE"
  expect_allow "allow a target that resolves outside the repo root"
}

test_allow_unrelated_tool_name() {
  check_cli "$INDEXED" Read
  expect_allow "allow an unrelated (non-search) tool name"
}

test_allow_log_target() {
  check_cli "$INDEXED" bash 'rg foo app.log'
  expect_allow "allow a *.log target"
}

# --- additional coverage ----------------------------------------------------

test_allow_vendored_target() {
  check_cli "$INDEXED" bash 'rg foo node_modules/pkg'
  expect_allow "allow a target under a vendored directory"
}

test_deny_recursive_grep_over_repo() {
  check_cli "$INDEXED" bash 'grep -rn foo .'
  expect_deny "deny grep -rn foo . over the repo root"
}

test_allow_grep_reads_stdin() {
  check_cli "$INDEXED" bash 'grep foo'
  expect_allow "allow non-recursive grep with no path (reads stdin)"
}

test_allow_bare_dash_stdin() {
  check_cli "$INDEXED" bash 'grep foo -'
  expect_allow "allow grep foo - (reads stdin through a bare -)"
}

test_deny_find_over_repo() {
  check_cli "$INDEXED" bash 'find . -name main.rs'
  expect_deny "deny find . over the repo root"
}

test_allow_find_outside_repo() {
  check_cli "$INDEXED" bash 'find /var/log -name syslog'
  expect_allow "allow find rooted outside the repo"
}

test_deny_search_tool_name_via_stdin() {
  local json
  json=$(jq -cn --arg p createUser --arg path "$INDEXED/src" --arg cwd "$INDEXED" \
    '{tool_name:"Grep",tool_input:{pattern:$p,path:$path},cwd:$cwd}')
  check_stdin "$json"
  expect_deny "deny a Grep tool call whose path is repo code"
  case "$ERR" in
  *'codegraph explore "createUser"'*) ;;
  *) fail "Grep deny must echo the pattern as the codegraph query; got: $ERR" ;;
  esac
  pass "deny Grep tool call echoes the pattern in the codegraph query"
}

test_allow_search_tool_name_log_via_stdin() {
  local json
  json=$(jq -cn --arg p x --arg path "$INDEXED/app.log" --arg cwd "$INDEXED" \
    '{tool_name:"Grep",tool_input:{pattern:$p,path:$path},cwd:$cwd}')
  check_stdin "$json"
  expect_allow "allow a Grep tool call whose path is a *.log file"
}

test_deny_bash_via_stdin() {
  local json
  json=$(jq -cn --arg c 'rg foo src/' --arg cwd "$INDEXED" \
    '{tool_name:"Bash",tool_input:{command:$c},cwd:$cwd}')
  check_stdin "$json"
  expect_deny "deny a Bash tool call via the Claude stdin JSON form"
}

# --- fail-open transport behavior -------------------------------------------

test_fail_open_empty_stdin() {
  check_stdin ''
  expect_allow "fail open on empty stdin"
}

test_fail_open_malformed_json() {
  check_stdin 'not json {'
  expect_allow "fail open on unparseable stdin JSON"
}


# --- the repository boundary ------------------------------------------------

test_allow_nested_repo_without_own_index() {
  check_cli "$NESTED" bash 'rg foo src/'
  expect_allow "allow a search in a nested repo that carries no index of its own"
}

test_allow_repo_under_an_indexed_ancestor() {
  check_cli "$ANCESTOR/repo" bash 'rg foo src/'
  expect_allow "allow a search in a plain repo beneath an indexed non-repo ancestor"
}

# --- every command on the line, not only the first --------------------------

test_deny_search_after_cd_into_the_repo() {
  check_cli "$INDEXED" bash "cd $INDEXED && grep -rn foo ."
  expect_deny "deny cd <repo> && grep -rn foo . (the shape a live pi run used)"
}

test_deny_search_after_relative_cd() {
  check_cli "$INDEXED" bash 'cd src && rg foo deep'
  expect_deny "deny a search after a relative cd that stays inside the repo"
}

test_allow_search_after_cd_out_of_the_repo() {
  check_cli "$INDEXED" bash "cd $PLAIN && grep -rn foo src/"
  expect_allow "allow a search after cd into an unindexed repo"
}

test_allow_search_after_unresolvable_cd() {
  # shellcheck disable=SC2016 # the unexpanded $TARGET is the case under test
  check_cli "$INDEXED" bash 'cd $TARGET && grep -rn foo src/'
  expect_allow "allow a search after a cd whose destination needs expansion"
}

test_allow_search_after_a_directory_stack_move() {
  check_cli "$INDEXED" bash 'pushd src >/dev/null && rg foo .'
  expect_allow "allow a search after a directory-stack move this check does not resolve"
}

test_deny_search_in_a_command_sequence() {
  check_cli "$INDEXED" bash 'ls; rg foo src/'
  expect_deny "deny a search that is the second command in a sequence"
}

test_deny_search_after_an_unrelated_command() {
  check_cli "$INDEXED" bash 'git status && rg foo src/'
  expect_deny "deny a search chained after an unrelated command"
}

test_deny_search_behind_a_command_wrapper() {
  check_cli "$INDEXED" bash 'command grep -rn foo src/'
  expect_deny "deny a search behind a command wrapper"
}

test_deny_search_in_a_subshell() {
  check_cli "$INDEXED" bash '( rg foo src/ )'
  expect_deny "deny a search inside a subshell"
}

test_deny_search_on_a_later_line() {
  check_cli "$INDEXED" bash 'echo starting
rg foo src/'
  expect_deny "deny a search on a later line of a multi-line command"
}

test_deny_search_with_a_redirect() {
  check_cli "$INDEXED" bash 'grep -rn foo src/ 2>/dev/null'
  expect_deny "deny a search whose only extra operand is a redirect"
}

test_allow_stdin_grep_downstream_of_a_sequence() {
  check_cli "$INDEXED" bash 'ls src/ | grep foo'
  expect_allow "allow a grep that filters the output of an earlier command"
}

# --- bytes that only look like a search -------------------------------------

test_allow_search_words_inside_a_quoted_string() {
  check_cli "$INDEXED" bash 'echo "one; rg foo src/"'
  expect_allow "allow a search command that is only quoted text"
}

test_allow_search_words_inside_a_commit_message() {
  check_cli "$INDEXED" bash 'git commit -m "stop running rg foo src/ by hand"'
  expect_allow "allow a search phrase inside a quoted commit message"
}

test_allow_search_words_inside_a_heredoc_body() {
  check_cli "$INDEXED" bash "cat >script.sh <<'EOF'
rg foo src/
EOF"
  expect_allow "allow a search written into a heredoc body"
}

test_deny_quoted_separator_inside_a_pattern() {
  check_cli "$INDEXED" bash 'rg -n "a; b" src/'
  expect_deny "deny a real search whose pattern contains a quoted separator"
}

test_allow_unbalanced_quoting() {
  check_cli "$INDEXED" bash 'echo "never closed'
  expect_allow "allow command bytes that cannot be tokenized"
}

test_allow_oversized_command() {
  local padding
  padding=$(head -c 5000 /dev/zero | tr '\0' 'x')
  check_cli "$INDEXED" bash "rg foo src/ # $padding"
  expect_allow "allow a command line past the tokenizer size cap"
}

# --- the pi/omp structured tool transport -----------------------------------

test_deny_structured_tool_input_forwarded_as_json() {
  check_cli "$INDEXED" grep '{"pattern":"createUser","path":"src"}'
  expect_deny "deny a pi grep tool call forwarded as serialized JSON input"
  case "$ERR" in
  *'codegraph explore "createUser"'*) ;;
  *) fail "the serialized tool input must supply the codegraph query; got: $ERR" ;;
  esac
  pass "serialized tool input supplies the codegraph query"
}

test_allow_structured_tool_input_pointing_outside_the_repo() {
  check_cli "$INDEXED" grep '{"pattern":"x","path":"app.log"}'
  expect_allow "allow a pi grep tool call whose serialized path is a *.log file"
}

test_deny_pi_find_tool() {
  check_cli "$INDEXED" find '{"pattern":"*.rs"}'
  expect_deny "deny a pi find tool call with no path"
}

# --- the guard extension's cannot-run policy --------------------------------
#
# extensions/fm-codegraph-guard.ts is what actually stands between a pi or omp
# tool call and the checker. A checker that never starts cannot report anything,
# so the extension decides that case: it refuses search-shaped calls inside an
# indexed repository and leaves every other call alone, because this one handler
# sees EVERY tool call and a blanket refusal would wedge the session.

GUARD="$ROOT/extensions/fm-codegraph-guard.ts"
GUARD_DRIVER="$TMP_ROOT/drive-guard.mjs"
cat >"$GUARD_DRIVER" <<'MJS'
import { pathToFileURL } from "node:url";
const [guardPath, tool, command, cwd] = process.argv.slice(2);
const mod = await import(pathToFileURL(guardPath).href);
let handler = null;
mod.default({
  on: (event, fn) => {
    if (event === "tool_call") handler = fn;
  },
});
if (!handler) {
  process.stderr.write("guard registered no tool_call handler");
  process.exit(1);
}
const result = await handler(
  { type: "tool_call", toolName: tool, input: command ? { command } : {} },
  { cwd },
);
process.stdout.write(JSON.stringify(result ?? {}));
MJS

# drive_guard <home> <fm_home> <tool> <command> <cwd>: run the extension handler
# in a fresh process so its load-time path resolution sees this environment.
# Sets GUARD_RESULT.
drive_guard() {
  local home=$1 fm_home=$2 tool=$3 command=$4 cwd=$5
  GUARD_RESULT=$(HOME="$home" FM_HOME="$fm_home" node "$GUARD_DRIVER" "$GUARD" "$tool" "$command" "$cwd" 2>"$TMP_ROOT/guard.err") || {
    fail "guard driver failed: $(cat "$TMP_ROOT/guard.err")"
  }
}

expect_guard_block() {
  case "$GUARD_RESULT" in
  *'"block":true'*) ;;
  *) fail "$1: expected a block, got: $GUARD_RESULT" ;;
  esac
  pass "$1"
}

expect_guard_allow() {
  case "$GUARD_RESULT" in
  *'"block":true'*) fail "$1: expected the call to be allowed, got: $GUARD_RESULT" ;;
  esac
  pass "$1"
}

test_guard_extension_policy() {
  command -v node >/dev/null 2>&1 || {
    pass "node not installed, skipping the guard extension policy"
    return
  }
  printf 'export const ok = 1;\n' >"$TMP_ROOT/probe.ts"
  printf 'import { ok } from "./probe.ts";\nprocess.stdout.write(String(ok));\n' >"$TMP_ROOT/probe.mjs"
  node "$TMP_ROOT/probe.mjs" >/dev/null 2>&1 || {
    pass "this node cannot import TypeScript directly, skipping the guard extension policy"
    return
  }

  # A home and an FM_HOME that carry no checker at all.
  local bare="$TMP_ROOT/bare-home"
  mkdir -p "$bare"

  drive_guard "$bare" "$bare" bash 'rg foo src/' "$INDEXED"
  expect_guard_block "no checker: a search-shaped call in an indexed repo is refused, not waved through"
  case "$GUARD_RESULT" in
  *"could not run"*) ;;
  *) fail "the refusal must say the guard could not run; got: $GUARD_RESULT" ;;
  esac
  case "$GUARD_RESULT" in
  *"fm-codegraph-pretool-check.sh"*) ;;
  *) fail "the refusal must name the missing checker; got: $GUARD_RESULT" ;;
  esac
  pass "no checker: the refusal names the missing checker and how to restore it"

  drive_guard "$bare" "$bare" bash 'git status --short' "$INDEXED"
  expect_guard_allow "no checker: an ordinary non-search command still runs, so the session is not wedged"

  drive_guard "$bare" "$bare" write '' "$INDEXED"
  expect_guard_allow "no checker: a non-search tool still runs"

  drive_guard "$bare" "$bare" bash 'rg foo src/' "$PLAIN"
  expect_guard_allow "no checker: an unindexed repo has nothing to enforce"

  drive_guard "$bare" "$bare" grep '' "$INDEXED"
  expect_guard_block "no checker: a structured search tool is refused by name"

  drive_guard "$bare" "$bare" bash 'FM_ALLOW_RAW_SEARCH=1 rg foo src/' "$INDEXED"
  expect_guard_allow "no checker: the inline escape hatch still releases the call"

  # A checker that answers: exit 0 allows, exit 2 blocks with its own reason.
  local allowing="$TMP_ROOT/fm-allow"
  mkdir -p "$allowing/bin"
  printf '#!/bin/sh\nexit 0\n' >"$allowing/bin/fm-codegraph-pretool-check.sh"
  chmod +x "$allowing/bin/fm-codegraph-pretool-check.sh"
  drive_guard "$bare" "$allowing" bash 'rg foo src/' "$INDEXED"
  expect_guard_allow "a checker that allows is obeyed"

  local denying="$TMP_ROOT/fm-deny"
  mkdir -p "$denying/bin"
  printf '#!/bin/sh\necho "checker reason here" >&2\nexit 2\n' >"$denying/bin/fm-codegraph-pretool-check.sh"
  chmod +x "$denying/bin/fm-codegraph-pretool-check.sh"
  drive_guard "$bare" "$denying" bash 'rg foo src/' "$INDEXED"
  expect_guard_block "a checker that denies is obeyed"
  case "$GUARD_RESULT" in
  *"checker reason here"*) ;;
  *) fail "the checker's own reason must reach the agent; got: $GUARD_RESULT" ;;
  esac
  pass "the checker's own deny reason is forwarded verbatim"

  # A checker that answers with an exit code the contract does not define, and a
  # checker that cannot be executed at all, are both "could not run".
  local broken="$TMP_ROOT/fm-broken"
  mkdir -p "$broken/bin"
  printf '#!/bin/sh\nexit 7\n' >"$broken/bin/fm-codegraph-pretool-check.sh"
  chmod +x "$broken/bin/fm-codegraph-pretool-check.sh"
  drive_guard "$bare" "$broken" bash 'rg foo src/' "$INDEXED"
  expect_guard_block "an undefined checker exit code is refused, not read as approval"
  drive_guard "$bare" "$broken" bash 'git status --short' "$INDEXED"
  expect_guard_allow "an undefined checker exit code still leaves non-search calls alone"

  # An explicitly pinned checker wins over both resolved paths.
  drive_guard_pinned() {
    local pinned=$1 tool=$2 command=$3 cwd=$4
    GUARD_RESULT=$(HOME="$bare" FM_HOME="$allowing" FM_CODEGRAPH_CHECKER="$pinned" \
      node "$GUARD_DRIVER" "$GUARD" "$tool" "$command" "$cwd" 2>"$TMP_ROOT/guard.err") || {
      fail "guard driver failed: $(cat "$TMP_ROOT/guard.err")"
    }
  }
  drive_guard_pinned "$denying/bin/fm-codegraph-pretool-check.sh" bash 'rg foo src/' "$INDEXED"
  expect_guard_block "FM_CODEGRAPH_CHECKER pins a checker ahead of the installed and repo paths"

  local unexecutable="$TMP_ROOT/fm-unexecutable"
  mkdir -p "$unexecutable/bin"
  printf '#!/bin/sh\nexit 0\n' >"$unexecutable/bin/fm-codegraph-pretool-check.sh"
  chmod 0644 "$unexecutable/bin/fm-codegraph-pretool-check.sh"
  drive_guard "$bare" "$unexecutable" bash 'rg foo src/' "$INDEXED"
  expect_guard_block "a checker that cannot be executed is refused, not read as approval"
}

# --- lint -------------------------------------------------------------------

test_script_is_shellcheck_clean() {
  command -v shellcheck >/dev/null 2>&1 || {
    pass "shellcheck not installed, skipping"
    return
  }
  shellcheck "$CHECK" >/dev/null 2>&1 ||
    fail "bin/fm-codegraph-pretool-check.sh is not shellcheck-clean"
  pass "bin/fm-codegraph-pretool-check.sh is shellcheck-clean"
}

test_deny_raw_search_in_indexed_repo
test_allow_raw_search_without_index
test_allow_pipe_into_grep
test_allow_env_escape_hatch
test_allow_inline_escape_hatch
test_allow_target_outside_repo
test_allow_unrelated_tool_name
test_allow_log_target
test_allow_vendored_target
test_deny_recursive_grep_over_repo
test_allow_grep_reads_stdin
test_allow_bare_dash_stdin
test_deny_find_over_repo
test_allow_find_outside_repo
test_deny_search_tool_name_via_stdin
test_allow_search_tool_name_log_via_stdin
test_deny_bash_via_stdin
test_fail_open_empty_stdin
test_fail_open_malformed_json
test_allow_nested_repo_without_own_index
test_allow_repo_under_an_indexed_ancestor
test_deny_search_after_cd_into_the_repo
test_deny_search_after_relative_cd
test_allow_search_after_cd_out_of_the_repo
test_allow_search_after_unresolvable_cd
test_allow_search_after_a_directory_stack_move
test_deny_search_in_a_command_sequence
test_deny_search_after_an_unrelated_command
test_deny_search_behind_a_command_wrapper
test_deny_search_in_a_subshell
test_deny_search_on_a_later_line
test_deny_search_with_a_redirect
test_allow_stdin_grep_downstream_of_a_sequence
test_allow_search_words_inside_a_quoted_string
test_allow_search_words_inside_a_commit_message
test_allow_search_words_inside_a_heredoc_body
test_deny_quoted_separator_inside_a_pattern
test_allow_unbalanced_quoting
test_allow_oversized_command
test_deny_structured_tool_input_forwarded_as_json
test_allow_structured_tool_input_pointing_outside_the_repo
test_deny_pi_find_tool
test_guard_extension_policy
test_script_is_shellcheck_clean

pass "CodeGraph-first PreToolUse seatbelt: all cases correct"
