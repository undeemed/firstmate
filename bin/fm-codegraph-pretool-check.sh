#!/usr/bin/env bash
# Stable PreToolUse transport and decision owner for the CodeGraph-first search
# policy.
#
# In a repository that carries a .codegraph/ index, a raw text search (a grep,
# glob, find, or ast_grep tool call, or a shell rg/grep/find/... command) throws
# away the pre-built structure the agent should be querying. This seatbelt denies
# a repository code search in that situation and points the agent at the
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
# CLI mode is used by the Pi and omp guards (which forward the tool name and
# either the command or the serialized tool input) and by the test suite.
#
# Exit/output contract:
#   ALLOW - exit 0 and no output.
#   DENY  - exit 2 with a short plain-text reason on stderr and an EMPTY stdout,
#           the shape Claude Code honors and the Pi/omp guards forward verbatim.
#   FAIL OPEN - anything unevaluable (no CodeGraph-indexed repo around the cwd,
#           empty or malformed stdin, missing jq on the stdin path, an
#           unresolvable cwd, command bytes this tokenizer cannot resolve, or a
#           call that is not a repository code search) allows with exit 0.
#           A guard that cannot RUN AT ALL is a different case that this script
#           cannot observe; extensions/fm-codegraph-guard.ts owns it.
#
# FM_ALLOW_RAW_SEARCH=1 in the environment, or as an inline prefix on the search
# command itself, allows unconditionally.
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
REPO=""

# Longest command line this check will tokenize. A PreToolUse hook sits in front
# of every tool call, so its cost is paid on every call; a 4000-byte line
# tokenizes in about 0.2s and anything longer fails open rather than stalling the
# agent. Real search commands are two orders of magnitude shorter than this, and
# the long ones agents do write - a file written through a heredoc - stop at the
# heredoc operator long before the cap.
MAX_COMMAND_BYTES=4000

# The length of $1 in bytes. The cap above is a byte budget, and a plain
# ${#...} counts locale characters, which undercounts multibyte text.
byte_length() {
  local LC_ALL=C
  printf '%s' "${#1}"
}

TAB=$'\t'
NL=$'\n'
BACKSLASH=$'\134'
DOLLAR_PAREN=$'\44('

usage() {
  cat <<'EOF'
Usage: fm-codegraph-pretool-check.sh --tool <name> [--command <cmd>] [--cwd <dir>]

With no arguments, reads a PreToolUse-style JSON payload on stdin (Claude
tool_name/tool_input, or the Grok toolName/toolInput fallbacks).
Denies a raw repository code search when the surrounding Git repository carries
a .codegraph/ index, and allows everything else.
Exits 0 to allow and 2 to deny; the deny reason is written to stderr.
FM_ALLOW_RAW_SEARCH=1 (environment, or an inline prefix on the search command)
allows always. Unevaluable input fails open with exit 0.
EOF
}

# The lowercased tool name of a structured code-search tool call. Claude names
# these Grep/Glob, pi names them grep/find, and other harnesses use the
# ast_grep/ripgrep/search spellings.
is_search_tool() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
  grep | glob | find | search | ast_grep | ast-grep | astgrep | ripgrep) return 0 ;;
  *) return 1 ;;
  esac
}

# The basename of a command word, when it is a raw search binary.
is_search_binary() {
  case "$1" in
  rg | grep | egrep | fgrep | ag | ack | fd | find | ast-grep) return 0 ;;
  *) return 1 ;;
  esac
}

# Words that only wrap the command that follows them, so the real command word
# is the next one. `bash -c "<string>"` is deliberately NOT in this set: its
# payload is a nested command string, which docs/codegraph-pretool-check.md
# records as an accepted non-goal.
is_command_wrapper() {
  case "$1" in
  command | builtin | exec | time | nohup | nice | env) return 0 ;;
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

# Resolve the repository around a directory and report its root only when that
# root carries a .codegraph/ index.
#
# The walk stops at the first Git working tree (a directory holding a .git
# directory, or a .git file for a linked worktree or submodule). CodeGraph
# writes .codegraph/ at the root of the repository it indexed, so a .codegraph/
# further up the filesystem belongs to some OTHER project and must not activate
# the guard here. Without that boundary, one indexed ancestor - an indexed
# $HOME, say - makes every unindexed directory beneath it look indexed and
# denies searches the agent has no CodeGraph index to replace.
find_repo_root() {
  local dir=$1
  while :; do
    if [ -e "$dir/.git" ]; then
      [ -d "$dir/.codegraph" ] && {
        printf '%s' "$dir"
        return 0
      }
      return 1
    fi
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

# --- tokenizer --------------------------------------------------------------
#
# TOKENS holds the command words and shell control operators in order, and
# TOKKIND holds "w" or "o" for each so a quoted literal ";" is never confused
# with the separator ";". Quoting, backslash escapes, $( ) and backticks are all
# honored, which is what stops a ";" or "&&" inside a quoted string from being
# read as a command boundary.
#
# This is byte inspection only. Nothing here executes, sources, evaluates, or
# expands any part of the submitted command.
TOKENS=()
TOKKIND=()
TOK_CUR=""
TOK_HAVE=0

tok_flush() {
  if [ "$TOK_HAVE" -eq 1 ]; then
    TOKENS[${#TOKENS[@]}]=$TOK_CUR
    TOKKIND[${#TOKKIND[@]}]=w
    TOK_CUR=""
    TOK_HAVE=0
  fi
}

tok_op() {
  tok_flush
  TOKENS[${#TOKENS[@]}]=$1
  TOKKIND[${#TOKKIND[@]}]=o
}

# tokenize <command>: fill TOKENS/TOKKIND. Returns 1 when the bytes cannot be
# resolved (unbalanced quoting or substitution), which the caller fails open on.
#
# The walk is a flat state machine fed 256-byte slices taken from the FRONT of a
# shrinking copy. Indexing a long bash string by absolute offset costs time
# proportional to that offset, so a naive per-character walk is quadratic and a
# few thousand bytes of command already cost seconds inside a hook that runs
# before every tool call. Slicing from the front keeps every offset small.
tokenize() {
  local rest=$1
  local chunk clen limit j ch nxt heredoc=0
  local state=n depth=0
  TOKENS=()
  TOKKIND=()
  TOK_CUR=""
  TOK_HAVE=0
  while [ -n "$rest" ]; do
    # One byte of overlap so a two-byte operator is never split by the slice.
    chunk=${rest:0:257}
    clen=${#chunk}
    if [ "$clen" -gt 256 ]; then limit=256; else limit=$clen; fi
    j=0
    while [ "$j" -lt "$limit" ]; do
      ch=${chunk:$j:1}
      case "$state" in
      e)
        TOK_CUR=$TOK_CUR$ch
        TOK_HAVE=1
        state=n
        j=$((j + 1))
        continue
        ;;
      E)
        TOK_CUR=$TOK_CUR$ch
        state=d
        j=$((j + 1))
        continue
        ;;
      s)
        if [ "$ch" = "'" ]; then state=n; else TOK_CUR=$TOK_CUR$ch; fi
        j=$((j + 1))
        continue
        ;;
      d)
        if [ "$ch" = '"' ]; then
          state=n
        elif [ "$ch" = "$BACKSLASH" ]; then
          state=E
        else
          TOK_CUR=$TOK_CUR$ch
        fi
        j=$((j + 1))
        continue
        ;;
      b)
        TOK_CUR=$TOK_CUR$ch
        [ "$ch" = '`' ] && state=n
        j=$((j + 1))
        continue
        ;;
      p)
        TOK_CUR=$TOK_CUR$ch
        case "$ch" in
        '(') depth=$((depth + 1)) ;;
        ')')
          depth=$((depth - 1))
          [ "$depth" -eq 0 ] && state=n
          ;;
        esac
        j=$((j + 1))
        continue
        ;;
      esac
      case "$ch" in
      "$BACKSLASH")
        # A backslash escapes exactly one byte; that byte is ordinary text.
        state=e
        j=$((j + 1))
        continue
        ;;
      "'")
        state=s
        TOK_HAVE=1
        j=$((j + 1))
        continue
        ;;
      '"')
        state=d
        TOK_HAVE=1
        j=$((j + 1))
        continue
        ;;
      '`')
        # An opaque substitution. Its bytes stay inside the surrounding word so
        # a path operand built around one still reads as a path operand.
        TOK_CUR=$TOK_CUR$ch
        TOK_HAVE=1
        state=b
        j=$((j + 1))
        continue
        ;;
      esac
      nxt=${chunk:$j:2}
      if [ "$nxt" = "$DOLLAR_PAREN" ]; then
        TOK_CUR=$TOK_CUR$nxt
        TOK_HAVE=1
        depth=1
        state=p
        j=$((j + 2))
        continue
      fi
      case "$nxt" in
      '<<')
        # A heredoc body is text, not commands. Stop here so a script written
        # into a heredoc is never classified as a search.
        heredoc=1
        break
        ;;
      '&&' | '||' | '|&' | '>>' | '>&' | '<&')
        tok_op "$nxt"
        j=$((j + 2))
        continue
        ;;
      esac
      case "$ch" in
      ';' | '|' | '&' | '<' | '>')
        tok_op "$ch"
        j=$((j + 1))
        continue
        ;;
      ' ' | "$TAB")
        tok_flush
        j=$((j + 1))
        continue
        ;;
      "$NL")
        tok_op ';'
        j=$((j + 1))
        continue
        ;;
      esac
      TOK_CUR=$TOK_CUR$ch
      TOK_HAVE=1
      j=$((j + 1))
    done
    [ "$heredoc" -eq 1 ] && break
    rest=${rest:$j}
  done
  # A trailing backslash (state e) is a line continuation; anything else still
  # open means unbalanced quoting or substitution the caller must fail open on.
  case "$state" in
  n | e) ;;
  *) return 1 ;;
  esac
  tok_flush
  return 0
}

is_separator() {
  case "$1" in
  ';' | '&&' | '||' | '|' | '|&' | '&') return 0 ;;
  *) return 1 ;;
  esac
}

# --- per-command classification ---------------------------------------------

# Effective working directory while walking a command line. A leading `cd` moves
# it, so `cd <dir> && grep ...` is judged against the directory the search
# actually runs in.
EFFCWD=""
# Set once the effective working directory stops being knowable, after which the
# rest of the line fails open.
TAINTED=0

# apply_cd <start> <end>: resolve a `cd` segment's destination, or taint the
# rest of the line. Only a single literal operand is resolved; anything that
# would need expansion is unknowable by byte inspection.
apply_cd() {
  local s=$1 e=$2 tok dest="" count=0 resolved
  local idx=$s
  idx=$((idx + 1))
  while [ "$idx" -lt "$e" ]; do
    [ "${TOKKIND[$idx]}" = w ] || break
    if is_fd_before_redirect "$idx" "$e"; then
      idx=$((idx + 1))
      continue
    fi
    tok=${TOKENS[$idx]}
    case "$tok" in
    -[LP] | --) ;;
    *)
      dest=$tok
      count=$((count + 1))
      ;;
    esac
    idx=$((idx + 1))
  done
  if [ "$count" -ne 1 ] || [ -z "$dest" ]; then
    TAINTED=1
    return 0
  fi
  case "$dest" in
  *'$'* | *'*'* | *'?'* | '~'*)
    TAINTED=1
    return 0
    ;;
  esac
  case "$dest" in
  /*) resolved=$dest ;;
  *) resolved=$EFFCWD/$dest ;;
  esac
  resolved=$(CDPATH='' cd -- "$resolved" 2>/dev/null && pwd -P) || {
    TAINTED=1
    return 0
  }
  EFFCWD=$resolved
}

# classify_segment <start> <end>: deny (exit 2) when this one command is a raw
# repository code search; return 0 otherwise.
classify_segment() {
  local s=$1 e=$2 idx tok base i n seen_pattern first_pattern endopts recursive
  local -a targets=()
  idx=$s
  # Leading environment assignments and pure command wrappers.
  while [ "$idx" -lt "$e" ]; do
    [ "${TOKKIND[$idx]}" = w ] || return 0
    tok=${TOKENS[$idx]}
    case "$tok" in
    FM_ALLOW_RAW_SEARCH=1) return 0 ;;
    [A-Za-z_]*=*)
      idx=$((idx + 1))
      continue
      ;;
    '(' | '{' | '!')
      idx=$((idx + 1))
      continue
      ;;
    esac
    base=${tok##*/}
    if is_command_wrapper "$base"; then
      idx=$((idx + 1))
      continue
    fi
    break
  done
  [ "$idx" -lt "$e" ] || return 0
  [ "${TOKKIND[$idx]}" = w ] || return 0

  tok=${TOKENS[$idx]}
  base=${tok##*/}

  if [ "$base" = cd ]; then
    apply_cd "$idx" "$e"
    return 0
  fi
  # A directory-stack move is not resolved here, so the rest of the line runs
  # somewhere unknown and must not be judged against the old directory.
  if [ "$base" = pushd ] || [ "$base" = popd ]; then
    TAINTED=1
    return 0
  fi

  is_search_binary "$base" || return 0

  # The search runs in EFFCWD, so the repo boundary is resolved from there.
  REPO=$(find_repo_root "$EFFCWD") || return 0
  CWD=$EFFCWD

  i=$((idx + 1))
  n=$e
  recursive=0
  if [ "$base" = find ]; then
    # find PATH... EXPRESSION: the leading operands before the first primary or
    # flag are the search roots; a missing root means the working directory.
    while [ "$i" -lt "$n" ]; do
      [ "${TOKKIND[$i]}" = w ] || break
      tok=${TOKENS[$i]}
      [ "$tok" = "-" ] && return 0
      case "$tok" in
      -* | '(' | '!') break ;;
      esac
      if ! is_fd_before_redirect "$i" "$n"; then
        targets[${#targets[@]}]=$tok
      fi
      i=$((i + 1))
    done
    [ "${#targets[@]}" -gt 0 ] || targets[0]="."
  else
    # rg/grep/ag/ack/fd/ast-grep PATTERN [PATH...]: the first non-flag operand
    # is the pattern (the query), the rest are targets.
    seen_pattern=0
    first_pattern=""
    endopts=0
    while [ "$i" -lt "$n" ]; do
      [ "${TOKKIND[$i]}" = w ] || break
      tok=${TOKENS[$i]}
      if [ "$endopts" -eq 0 ]; then
        [ "$tok" = "-" ] && return 0
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
      if is_fd_before_redirect "$i" "$n"; then
        i=$((i + 1))
        continue
      fi
      if [ "$seen_pattern" -eq 0 ]; then
        first_pattern=$tok
        seen_pattern=1
      else
        targets[${#targets[@]}]=$tok
      fi
      i=$((i + 1))
    done
    QUERY=$first_pattern
    if [ "${#targets[@]}" -eq 0 ]; then
      case "$base" in
      grep | egrep | fgrep)
        # No path and no recursion means grep reads stdin: an output filter.
        [ "$recursive" -eq 1 ] || return 0
        targets[0]="."
        ;;
      *)
        # rg/ag/ack/fd/ast-grep default to searching the working directory.
        targets[0]="."
        ;;
      esac
    fi
  fi

  for tok in "${targets[@]}"; do
    if target_is_code "$tok"; then
      emit_deny "the search command: $CMD"
    fi
  done
  return 0
}

# A lone file-descriptor number immediately before a redirection operator is
# part of that redirection (`2>/dev/null`), never a search target.
is_fd_before_redirect() {
  local i=$1 n=$2 next=$((1 + $1))
  case "${TOKENS[$i]}" in
  '' | *[!0-9]*) return 1 ;;
  esac
  [ "$next" -lt "$n" ] || return 1
  [ "${TOKKIND[$next]}" = o ] || return 1
  case "${TOKENS[$next]}" in
  '>' | '>>' | '<' | '>&' | '<&') return 0 ;;
  esac
  return 1
}

# classify_command_line: split the command into the individual commands it runs
# and classify each one. The leading command word alone is not enough: `cd repo
# && grep -rn foo .` and `ls; rg foo src/` are ordinary agent habits that a
# first-word test reads as `cd` and `ls` and lets straight through.
classify_command_line() {
  local n i seg_start sep piped=0
  n=${#TOKENS[@]}
  i=0
  EFFCWD=$CWD
  TAINTED=0
  while [ "$i" -lt "$n" ]; do
    seg_start=$i
    while [ "$i" -lt "$n" ]; do
      if [ "${TOKKIND[$i]}" = o ] && is_separator "${TOKENS[$i]}"; then
        break
      fi
      i=$((i + 1))
    done
    sep=""
    if [ "$i" -lt "$n" ]; then
      sep=${TOKENS[$i]}
    fi
    # A command downstream of a pipe filters another command's output rather
    # than searching the repository, so it is never classified.
    if [ "$TAINTED" -eq 0 ] && [ "$piped" -eq 0 ] && [ "$i" -gt "$seg_start" ]; then
      classify_segment "$seg_start" "$i"
    fi
    case "$sep" in
    '|' | '|&') piped=1 ;;
    *) piped=0 ;;
    esac
    i=$((i + 1))
  done
}

# --- entry ------------------------------------------------------------------

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

# Branch 1: a structured code-search tool call (Claude Grep/Glob, pi grep/find,
# ast_grep, ...). It carries no pipe and no stdin, so only the target-is-code
# test can allow it. The Pi and omp guards forward the tool's input serialized
# as a JSON object in --command because a structured call carries no command
# string; recover the path and pattern from it when they did not arrive as
# dedicated fields.
if is_search_tool "$TOOL"; then
  REPO=$(find_repo_root "$CWD") || exit 0
  if { [ -z "$TOOL_PATH" ] || [ -z "$STDIN_PATTERN" ]; } && command -v jq >/dev/null 2>&1; then
    case "$CMD" in
    '{'*'}')
      [ -n "$TOOL_PATH" ] || TOOL_PATH=$(printf '%s' "$CMD" | jq -r '(.path // .dir // .directory // empty)' 2>/dev/null) || TOOL_PATH=""
      [ -n "$STDIN_PATTERN" ] || STDIN_PATTERN=$(printf '%s' "$CMD" | jq -r '(.pattern // .pat // .query // .regex // .glob // empty)' 2>/dev/null) || STDIN_PATTERN=""
      ;;
    esac
  fi
  QUERY=$(strip_quotes "$STDIN_PATTERN")
  [ -n "$QUERY" ] || QUERY=$(strip_quotes "$TOOL_PATH")
  if [ -n "$TOOL_PATH" ]; then
    target_is_code "$TOOL_PATH" || exit 0
  fi
  emit_deny "the $TOOL tool"
fi

# Branch 2: a shell command line. Every command it runs is classified, not only
# the leading one.
[ -n "$CMD" ] || exit 0
[ "$(byte_length "$CMD")" -le "$MAX_COMMAND_BYTES" ] || exit 0
tokenize "$CMD" || exit 0
[ "${#TOKENS[@]}" -gt 0 ] || exit 0
classify_command_line
exit 0
