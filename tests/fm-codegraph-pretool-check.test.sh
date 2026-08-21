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
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-codegraph-pretool-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-codegraph-pretool-check)

# An indexed repository: a .codegraph/ directory plus ordinary code and the
# vendored/log paths the carve-outs recognize.
INDEXED="$TMP_ROOT/indexed"
mkdir -p "$INDEXED/src" "$INDEXED/.codegraph" "$INDEXED/node_modules/pkg"
printf 'fn main() {}\n' >"$INDEXED/src/main.rs"
printf 'log line\n' >"$INDEXED/app.log"

# A plain repository with no .codegraph/ index: the check must be inert here.
PLAIN="$TMP_ROOT/plain"
mkdir -p "$PLAIN/src"

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
test_script_is_shellcheck_clean

pass "CodeGraph-first PreToolUse seatbelt: all cases correct"
