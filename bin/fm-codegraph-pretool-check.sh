#!/usr/bin/env bash
# Stable PreToolUse transport and decision owner for the CodeGraph-first search
# policy.
#
# In a repository that carries a .codegraph/ index, a raw text search (a Grep,
# Glob, or ast_grep tool call, or a shell rg/grep/find/... command) throws away
# the pre-built structure the agent should be querying. This seatbelt denies a
# repository code search in that situation and points the agent at the
# `codegraph explore` alternative instead.
# Unlike the sibling arm and cd seatbelts (docs/arm-pretool-check.md,
# docs/cd-guard.md), which delegate to a shared Node classifier, this check owns
# its whole decision here: the classification is a small, self-contained set of
# byte tests with no shared shell lexing to reuse.
# It never executes, sources, evaluates, or expands the submitted command; it
# only tokenizes the bytes and inspects command words and path operands.
# See docs/codegraph-pretool-check.md for the complete allow/deny matrix.
#
# Usage:
#   <PreToolUse JSON on stdin> | bin/fm-codegraph-pretool-check.sh
#   bin/fm-codegraph-pretool-check.sh --tool <name> [--command <cmd>] [--cwd <dir>]
#
# Stdin mode extracts .tool_name, .tool_input.command, .tool_input.path, and
# .tool_input.pattern (with the Grok .toolName / .toolInput fallbacks) plus .cwd,
# and is what Claude Code pipes in.
# CLI mode is used by the Pi and omp primary guards (which forward the tool name
# and the command) and by the test suite.
#
# Exit/output contract:
#   ALLOW - exit 0 and no output.
#   DENY  - exit 2 with a short plain-text reason on stderr and an EMPTY stdout,
#           the shape Claude Code honors and the Pi/omp guards forward verbatim.
#   FAIL OPEN - anything unevaluable (no .codegraph/ repo above the cwd, empty or
#           malformed stdin, missing jq on the stdin path, an unresolvable cwd, or
#           a call that is not a repository code search) allows with exit 0 so a
#           broken hook never denies a tool call.
#
# FM_ALLOW_RAW_SEARCH=1 in the environment or as an inline command prefix allows
# unconditionally.
set -u

TOOL=""
TOOL_SET=0
CMD=""
CMD_SET=0
CWD=""
CWD_SET=0
TOOL_PATH=""
STDIN_PATTERN=""
QUERY=""

usage() {
  cat <<'EOF'
Usage: fm-codegraph-pretool-check.sh --tool <name> [--command <cmd>] [--cwd <dir>]

With no arguments, reads a PreToolUse-style JSON payload on stdin (Claude
tool_name/tool_input, or the Grok toolName/toolInput fallbacks).
Denies a raw repository code search when the resolved repo root carries a
.codegraph/ index, and allows everything else.
Exits 0 to allow and 2 to deny; the deny reason is written to stderr.
FM_ALLOW_RAW_SEARCH=1 (environment or inline command prefix) allows always.
Unevaluable input fails open with exit 0.
EOF
}

# The lowercased tool name of a structured code-search tool call.
is_search_tool() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
  grep | glob | ast_grep | ast-grep | astgrep | ripgrep) return 0 ;;
  *) return 1 ;;
  esac
}

# The basename of a shell command's first word, when it is a raw search binary.
is_search_binary() {
  case "$1" in
  rg | grep | egrep | fgrep | ag | ack | fd | find | ast-grep) return 0 ;;
  *) return 1 ;;
  esac
}

# Strip one layer of matched surrounding single or double quotes.
strip_quotes() {
  local s=$1
  case "$s" in
  \"*\")
    s=${s#\"}
    s=${s%\"}
    ;;
  \'*\')
    s=${s#\'}
    s=${s%\'}
    ;;
  esac
  printf '%s' "$s"
}

# Lexically normalize an absolute path (collapse . and .. and empty segments)
# without touching the filesystem, so a nonexistent target still resolves.
normalize_path() {
  local input=$1 part rest result=""
  local -a out=()
  rest=$input
  while [ -n "$rest" ]; do
    part=${rest%%/*}
    if [ "$part" = "$rest" ]; then
      rest=""
    else
      rest=${rest#*/}
    fi
    case "$part" in
    '' | .) ;;
    ..) [ "${#out[@]}" -gt 0 ] && unset 'out[$(( ${#out[@]} - 1 ))]' ;;
    *) out+=("$part") ;;
    esac
  done
  if [ "${#out[@]}" -gt 0 ]; then
    for part in "${out[@]}"; do
      result="$result/$part"
    done
  fi
  printf '%s' "${result:-/}"
}

# Walk up from a directory to the nearest ancestor holding a .codegraph/ index.
find_repo_root() {
  local dir=$1
  while :; do
    [ -d "$dir/.codegraph" ] && {
      printf '%s' "$dir"
      return 0
    }
    [ "$dir" = "/" ] && return 1
    dir=$(dirname -- "$dir")
  done
}

# Is a search target plausibly repository code? A target that resolves outside
# the repo root, sits under a vendored/build directory, or is a *.log file is
# not code, so searching it is allowed.
target_is_code() {
  local p abs rel
  p=$(strip_quotes "$1")
  [ -n "$p" ] || return 1
  case "$p" in
  *.log) return 1 ;;
  esac
  case "$p" in
  /*) abs=$p ;;
  *) abs=$CWD/$p ;;
  esac
  abs=$(normalize_path "$abs")
  case "$abs/" in
  "$REPO/"*) ;;
  *) return 1 ;;
  esac
  rel=${abs#"$REPO"}
  rel=${rel#/}
  case "/$rel/" in
  *"/.git/"* | *"/node_modules/"* | *"/dist/"* | *"/build/"* | *"/target/"*) return 1 ;;
  esac
  return 0
}

emit_deny() {
  local what=$1 query=${QUERY:-}
  [ -n "$query" ] || query="<what you are looking for>"
  {
    printf 'Blocked %s.\n' "$what"
    printf 'This repository is CodeGraph-indexed (.codegraph/ at %s); prefer CodeGraph over raw search:\n' "$REPO"
    printf '  codegraph explore "%s"\n' "$query"
    printf 'It returns the matching code and its call paths in one step. To run the raw search anyway, set FM_ALLOW_RAW_SEARCH=1 (environment or inline prefix).\n'
  } >&2
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
  --tool)
    [ "$#" -gt 1 ] || {
      echo "error: --tool requires a value" >&2
      exit 2
    }
    TOOL=$2
    TOOL_SET=1
    shift 2
    ;;
  --tool=*)
    TOOL=${1#--tool=}
    TOOL_SET=1
    shift
    ;;
  --command)
    [ "$#" -gt 1 ] || {
      echo "error: --command requires a value" >&2
      exit 2
    }
    CMD=$2
    CMD_SET=1
    shift 2
    ;;
  --command=*)
    CMD=${1#--command=}
    CMD_SET=1
    shift
    ;;
  --cwd)
    [ "$#" -gt 1 ] || {
      echo "error: --cwd requires a value" >&2
      exit 2
    }
    CWD=$2
    CWD_SET=1
    shift 2
    ;;
  --cwd=*)
    CWD=${1#--cwd=}
    CWD_SET=1
    shift
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    echo "error: unknown argument: $1" >&2
    usage >&2
    exit 2
    ;;
  esac
done

# Stdin JSON transport (Claude and the Grok fallbacks) only when no CLI input was
# supplied. Any transport failure leaves the fields empty and falls through to a
# fail-open exit 0 below.
if [ "$TOOL_SET" -eq 0 ] && [ "$CMD_SET" -eq 0 ] && [ "$CWD_SET" -eq 0 ]; then
  PAYLOAD=$(cat 2>/dev/null || true)
  if [ -n "$PAYLOAD" ] && command -v jq >/dev/null 2>&1; then
    TOOL=$(printf '%s' "$PAYLOAD" | jq -r '(.tool_name // .toolName // empty)' 2>/dev/null) || TOOL=""
    CMD=$(printf '%s' "$PAYLOAD" | jq -r '(.tool_input.command // .toolInput.command // empty)' 2>/dev/null) || CMD=""
    TOOL_PATH=$(printf '%s' "$PAYLOAD" | jq -r '(.tool_input.path // .toolInput.path // empty)' 2>/dev/null) || TOOL_PATH=""
    STDIN_PATTERN=$(printf '%s' "$PAYLOAD" | jq -r '(.tool_input.pattern // .toolInput.pattern // empty)' 2>/dev/null) || STDIN_PATTERN=""
    CWD=$(printf '%s' "$PAYLOAD" | jq -r '(.cwd // empty)' 2>/dev/null) || CWD=""
  fi
fi

# Escape hatch: unconditional allow.
[ "${FM_ALLOW_RAW_SEARCH:-}" = "1" ] && exit 0

# Resolve the working directory to a physical path; an unusable cwd fails open.
[ -n "$CWD" ] || CWD=$PWD
CWD=$(CDPATH='' cd -- "$CWD" 2>/dev/null && pwd -P) || exit 0

# The repo is CodeGraph-indexed only if some ancestor holds a .codegraph/ dir.
REPO=$(find_repo_root "$CWD") || exit 0

# Branch 1: a structured search tool call (Claude Grep/Glob/ast_grep, etc.). It
# carries no pipe or stdin, so only the target-is-code test can allow it.
if is_search_tool "$TOOL"; then
  QUERY=$(strip_quotes "$STDIN_PATTERN")
  if [ -n "$TOOL_PATH" ]; then
    target_is_code "$TOOL_PATH" || exit 0
  fi
  emit_deny "the $TOOL tool"
fi

# Branch 2: a shell command whose first word is a raw search binary.
[ -n "$CMD" ] || exit 0

read -r -a TOKENS <<<"$CMD" || exit 0
[ "${#TOKENS[@]}" -gt 0 ] || exit 0

# Strip leading VAR=value assignments; honor the inline escape-hatch prefix.
idx=0
while [ "$idx" -lt "${#TOKENS[@]}" ]; do
  case "${TOKENS[$idx]}" in
  FM_ALLOW_RAW_SEARCH=1) exit 0 ;;
  [A-Za-z_][A-Za-z0-9_]*=*) idx=$((idx + 1)) ;;
  *) break ;;
  esac
done
[ "$idx" -lt "${#TOKENS[@]}" ] || exit 0

W1=${TOKENS[$idx]}
W1BASE=${W1##*/}
is_search_binary "$W1BASE" || exit 0

# Collect the path operands (the search targets) that decide condition 4. Any
# shell operator ends this command; a downstream pipeline stage is a separate
# command that the first-word test on its own turn already covers.
TARGETS=()
recursive=0
i=$((idx + 1))
n=${#TOKENS[@]}

if [ "$W1BASE" = find ]; then
  # find PATH... EXPRESSION: the leading operands before the first primary or
  # flag are the search roots; a missing root means the cwd.
  while [ "$i" -lt "$n" ]; do
    tok=${TOKENS[$i]}
    case "$tok" in
    '|' | '||' | '&&' | ';' | '&' | '<' | '>' | '>>' | '|&') break ;;
    esac
    [ "$tok" = "-" ] && exit 0
    case "$tok" in
    -* | '(' | '!') break ;;
    esac
    TARGETS+=("$tok")
    i=$((i + 1))
  done
  [ "${#TARGETS[@]}" -gt 0 ] || TARGETS+=(".")
else
  # rg/grep/ag/ack/fd/ast-grep PATTERN [PATH...]: the first non-flag operand is
  # the pattern (the query), the rest are targets.
  seen_pattern=0
  first_pattern=""
  endopts=0
  while [ "$i" -lt "$n" ]; do
    tok=${TOKENS[$i]}
    if [ "$endopts" -eq 0 ]; then
      case "$tok" in
      '|' | '||' | '&&' | ';' | '&' | '<' | '>' | '>>' | '|&') break ;;
      esac
      [ "$tok" = "-" ] && exit 0
      if [ "$tok" = "--" ]; then
        endopts=1
        i=$((i + 1))
        continue
      fi
      case "$tok" in
      --recursive)
        recursive=1
        i=$((i + 1))
        continue
        ;;
      --*)
        i=$((i + 1))
        continue
        ;;
      -*[rR]*)
        recursive=1
        i=$((i + 1))
        continue
        ;;
      -*)
        i=$((i + 1))
        continue
        ;;
      esac
    fi
    if [ "$seen_pattern" -eq 0 ]; then
      first_pattern=$tok
      seen_pattern=1
    else
      TARGETS+=("$tok")
    fi
    i=$((i + 1))
  done
  QUERY=$(strip_quotes "$first_pattern")
  if [ "${#TARGETS[@]}" -eq 0 ]; then
    case "$W1BASE" in
    grep | egrep | fgrep)
      # No path and no recursion means grep reads stdin: an output filter.
      [ "$recursive" -eq 1 ] || exit 0
      TARGETS+=(".")
      ;;
    *)
      # rg/ag/ack/fd/ast-grep default to searching the current directory.
      TARGETS+=(".")
      ;;
    esac
  fi
fi

# Deny only when at least one target is plausibly repository code.
code=0
for t in "${TARGETS[@]}"; do
  if target_is_code "$t"; then
    code=1
    break
  fi
done
[ "$code" -eq 1 ] || exit 0

emit_deny "the search command: $CMD"
