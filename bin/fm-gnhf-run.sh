#!/usr/bin/env bash
# fm-gnhf-run.sh - single owner of overnight `gnhf` orchestrator invocations.
#
# gnhf (npm, MIT, Node>=20) is a Ralph-style loop: it validates a clean git
# tree, creates/resumes a branch or worktree, and repeatedly drives a coding
# agent, committing successes and `git reset --hard`-ing failures until a cap or
# stop condition is reached (it aborts after 3 consecutive failures). Upstream
# defaults are permissive (agents run with --dangerously-skip-permissions and it
# can push), so this wrapper is the ONLY supported way firstmate launches gnhf.
# It hard-enforces the overnight safety envelope in code, not prose:
#   - GNHF_TELEMETRY=0 is always exported.
#   - --push is rejected; gnhf never pushes from here.
#   - --worktree is always added; the captain's checkout is never touched.
#   - a total-iteration cap (default 10) and a total-token cap (default
#     2000000) are always present.
#   - the target repo must be a clean git tree under the allowlisted repos root
#     (FM_GNHF_REPOS_ROOT, default $HOME/Dev); ~/oss-fleet and firstmate's own
#     home are always refused.
#   - overnight work must be captain-authorized: state/.gnhf-overnight must
#     exist (written by the /gnhf skill after entering away mode).
#   - gnhf output is captured to a size-bounded, rotating log under state/gnhf/.
#
# This script runs gnhf in the FOREGROUND and blocks until it exits. It is meant
# to be the body of a harness-tracked background terminal (claude background
# bash, a herdr pane, a detached tmux session - the same tracked-background
# primitives away mode uses). It NEVER self-backgrounds with `nohup ... &`,
# which Codex/herdr can reap after a tool call returns. It records a durable run
# entry under state/gnhf/ so an in-flight run stays discoverable, and appends a
# bounded outcome block to state/gnhf-overnight-report.md so the morning
# bin/fm-afk-return.sh catch-up can surface it.
#
# Usage:
#   fm-gnhf-run.sh --repo <path> [options] "<objective>"
#   fm-gnhf-run.sh --repo <path> --dry-run "<objective>"   # validate only
#
# Options:
#   --repo <path>            Target git repo (required; must pass the gates).
#   --agent <name>           gnhf native agent (default: claude).
#   --max-iterations <n>     Total-iteration cap (default: 10).
#   --max-tokens <n>         Total input+output token cap (default: 2000000).
#   --stop-when <cond>       Natural-language stop condition (optional).
#   --prevent-sleep <on|off> System sleep prevention (default: off).
#   --dry-run                Validate the gates and print the resolved command;
#                            do not launch gnhf or require overnight authorization.
#   -h, --help               This help.
#
# Rejected flags (hard): --push, --current-branch.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

export GNHF_TELEMETRY=0

GNHF_PINNED_VERSION="0.1.44"
GNHF_LOG_DIR="$STATE/gnhf"
GNHF_REPORT="$STATE/gnhf-overnight-report.md"
GNHF_AUTH_MARKER="$STATE/.gnhf-overnight"
REPOS_ROOT="${FM_GNHF_REPOS_ROOT:-$HOME/Dev}"
LOG_MAX_BYTES="${FM_GNHF_LOG_MAX_BYTES:-5242880}" # 5 MiB per file, rotated once
case "$LOG_MAX_BYTES" in '' | *[!0-9]*) LOG_MAX_BYTES=5242880 ;; esac

log() { printf 'fm-gnhf-run: %s\n' "$*" >&2; }
fail() {
  log "$*"
  exit 1
}

usage() {
  awk 'NR==1{next} /^#/{sub(/^# ?/,"");print;next} {exit}' "$0"
}

resolve_path() { CDPATH='' cd -- "$1" 2>/dev/null && pwd -P; }

path_under() { # <child> <parent> -> 0 when child == parent or under it
  case "$1/" in "$2"/*) return 0 ;; esac
  return 1
}

REPO=""
AGENT="claude"
MAX_ITER="10"
MAX_TOKENS="${FM_GNHF_MAX_TOKENS:-2000000}"
STOP_WHEN=""
PREVENT_SLEEP="off"
DRY_RUN=0
OBJECTIVE=""

while [ $# -gt 0 ]; do
  case "$1" in
  --repo)
    REPO="${2:-}"
    [ -n "$REPO" ] || fail "--repo needs a value"
    shift 2
    ;;
  --agent)
    AGENT="${2:-}"
    [ -n "$AGENT" ] || fail "--agent needs a value"
    shift 2
    ;;
  --max-iterations)
    MAX_ITER="${2:-}"
    [ -n "$MAX_ITER" ] || fail "--max-iterations needs a value"
    shift 2
    ;;
  --max-tokens)
    MAX_TOKENS="${2:-}"
    [ -n "$MAX_TOKENS" ] || fail "--max-tokens needs a value"
    shift 2
    ;;
  --stop-when)
    STOP_WHEN="${2:-}"
    [ -n "$STOP_WHEN" ] || fail "--stop-when needs a value"
    shift 2
    ;;
  --prevent-sleep)
    PREVENT_SLEEP="${2:-}"
    [ -n "$PREVENT_SLEEP" ] || fail "--prevent-sleep needs a value"
    shift 2
    ;;
  --dry-run)
    DRY_RUN=1
    shift
    ;;
  --worktree) shift ;; # always applied; tolerate an explicit one
  --push) fail "--push is refused: gnhf must never push from firstmate" ;;
  --current-branch) fail "--current-branch is refused: overnight runs are worktree-only" ;;
  -h | --help | help)
    usage
    exit 0
    ;;
  --)
    shift
    if [ -n "$OBJECTIVE" ]; then
      [ $# -eq 0 ] || fail "unexpected extra argument: $1"
    else
      OBJECTIVE="${1:-}"
      [ $# -le 1 ] || fail "unexpected extra argument: $2"
    fi
    break
    ;;
  -*) fail "unknown or unsupported flag: $1" ;;
  *)
    [ -z "$OBJECTIVE" ] || fail "unexpected extra argument: $1"
    OBJECTIVE="$1"
    shift
    ;;
  esac
done

[ -n "$OBJECTIVE" ] || fail "an objective is required"
[ -n "$REPO" ] || fail "--repo <path> is required"
case "$MAX_ITER" in '' | *[!0-9]*) fail "--max-iterations must be a positive integer" ;; esac
[ "$MAX_ITER" -ge 1 ] || fail "--max-iterations must be >= 1"
case "$MAX_TOKENS" in '' | *[!0-9]*) fail "--max-tokens must be a positive integer" ;; esac
[ "$MAX_TOKENS" -ge 1 ] || fail "--max-tokens must be >= 1"
case "$PREVENT_SLEEP" in on | off) ;; *) fail "--prevent-sleep must be on or off" ;; esac

# Repo allowlist and blocklist gates.
[ -d "$REPO" ] || fail "target repo does not exist: $REPO"
REPO_REAL="$(resolve_path "$REPO")" || true
[ -n "$REPO_REAL" ] || fail "cannot resolve target repo: $REPO"
ROOT_REAL="$(resolve_path "$REPOS_ROOT")" || true
[ -n "$ROOT_REAL" ] || fail "allowlisted repos root does not exist: $REPOS_ROOT"
FM_HOME_REAL="$(resolve_path "$FM_HOME")" || true
[ -n "$FM_HOME_REAL" ] || FM_HOME_REAL="$FM_HOME"
if path_under "$REPO_REAL" "$HOME/oss-fleet"; then
  fail "refusing to run against $HOME/oss-fleet (blocklisted)"
fi
if [ "$REPO_REAL" = "$FM_HOME_REAL" ] || path_under "$FM_HOME_REAL" "$REPO_REAL"; then
  fail "refusing to run gnhf against firstmate's own home: $REPO_REAL"
fi
path_under "$REPO_REAL" "$ROOT_REAL" || fail "target repo is outside the allowlisted root $ROOT_REAL: $REPO_REAL"
[ -e "$REPO_REAL/.git" ] || fail "target is not a git repo: $REPO_REAL"
if [ -n "$(git -C "$REPO_REAL" status --porcelain 2>/dev/null)" ]; then
  fail "target repo working tree is dirty; commit or stash before an overnight run: $REPO_REAL"
fi

# Toolchain preflight: gnhf present, pinned, on Node >= 20.
command -v gnhf >/dev/null 2>&1 || fail "gnhf is not installed; run: npm install -g gnhf@$GNHF_PINNED_VERSION"
command -v node >/dev/null 2>&1 || fail "node is not installed (gnhf requires Node >= 20)"
NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
case "$NODE_MAJOR" in '' | *[!0-9]*) NODE_MAJOR=0 ;; esac
[ "$NODE_MAJOR" -ge 20 ] || fail "gnhf requires Node >= 20 (found major $NODE_MAJOR)"
GNHF_VERSION="$(gnhf --version 2>/dev/null | sed -n 's/.*\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' | sed -n 1p || true)"
if [ "$GNHF_VERSION" != "$GNHF_PINNED_VERSION" ] && [ "${FM_GNHF_ALLOW_VERSION_MISMATCH:-0}" != "1" ]; then
  fail "gnhf version '${GNHF_VERSION:-unknown}' != pinned $GNHF_PINNED_VERSION (set FM_GNHF_ALLOW_VERSION_MISMATCH=1 to override)"
fi

# Overnight work must be captain-authorized (dry-run only reports the state).
if [ "$DRY_RUN" -ne 1 ] && [ ! -e "$GNHF_AUTH_MARKER" ]; then
  fail "overnight work is not authorized: $GNHF_AUTH_MARKER is absent (invoke /gnhf first)"
fi

GNHF_ARGS=(--worktree --agent "$AGENT" --max-iterations "$MAX_ITER" --max-tokens "$MAX_TOKENS" --prevent-sleep "$PREVENT_SLEEP")
[ -n "$STOP_WHEN" ] && GNHF_ARGS+=(--stop-when "$STOP_WHEN")
GNHF_ARGS+=("$OBJECTIVE")

SLUG="$(printf '%s' "$OBJECTIVE" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-' | sed 's/-\{2,\}/-/g; s/^-//; s/-$//' | cut -c1-40)"
[ -n "$SLUG" ] || SLUG="run"
RUN_ID="$SLUG-$(date '+%Y%m%d-%H%M%S')"
mkdir -p "$GNHF_LOG_DIR" || fail "cannot create log dir $GNHF_LOG_DIR"
LOG_FILE="$GNHF_LOG_DIR/$RUN_ID.log"
RUN_FILE="$GNHF_LOG_DIR/$RUN_ID.run"

if [ "$DRY_RUN" -eq 1 ]; then
  printf 'fm-gnhf-run: validation OK\n'
  printf '  repo:       %s\n' "$REPO_REAL"
  printf '  authorized: %s\n' "$([ -e "$GNHF_AUTH_MARKER" ] && echo yes || echo 'no (/gnhf not invoked)')"
  printf '  command:    GNHF_TELEMETRY=0 gnhf %s\n' "$(printf '%q ' "${GNHF_ARGS[@]}")"
  printf '  log:        %s\n' "$LOG_FILE"
  exit 0
fi

# Bounded, rotating capture: keep the most recent LOG_MAX_BYTES in LOG_FILE plus
# one prior rotation, draining all further output so gnhf is never SIGPIPE-killed.
bounded_log() {
  awk -v cap="$LOG_MAX_BYTES" -v f="$LOG_FILE" -v f1="$LOG_FILE.1" '
    { print >> f; fflush(f); n += length($0) + 1;
      if (n >= cap) { close(f); if (system("mv -f -- \"" f "\" \"" f1 "\"") != 0) exit 1; n = 0 } }
  '
}

started="$(date '+%s')"
{
  printf 'run_id\t%s\n' "$RUN_ID"
  printf 'repo\t%s\n' "$REPO_REAL"
  printf 'agent\t%s\n' "$AGENT"
  printf 'max_iterations\t%s\n' "$MAX_ITER"
  printf 'max_tokens\t%s\n' "$MAX_TOKENS"
  printf 'started\t%s\n' "$started"
  printf 'status\trunning\n'
  printf 'log\t%s\n' "$LOG_FILE"
} >"$RUN_FILE"

log "starting gnhf run $RUN_ID in $REPO_REAL (agent=$AGENT, max-iterations=$MAX_ITER, max-tokens=$MAX_TOKENS)"

set +e
(cd "$REPO_REAL" && exec gnhf "${GNHF_ARGS[@]}") </dev/null 2>&1 | bounded_log
rc=${PIPESTATUS[0]}
set -e

# Fixed strings, not the `done` keyword; keep the .run status literal.
run_status='failed'
outcome='stopped/failed'
if [ "$rc" -eq 0 ]; then
  run_status='done'
  outcome='completed'
fi

finished="$(date '+%s')"
{
  printf 'run_id\t%s\n' "$RUN_ID"
  printf 'repo\t%s\n' "$REPO_REAL"
  printf 'agent\t%s\n' "$AGENT"
  printf 'max_iterations\t%s\n' "$MAX_ITER"
  printf 'max_tokens\t%s\n' "$MAX_TOKENS"
  printf 'started\t%s\n' "$started"
  printf 'finished\t%s\n' "$finished"
  printf 'exit_code\t%s\n' "$rc"
  printf 'status\t%s\n' "$run_status"
  printf 'log\t%s\n' "$LOG_FILE"
} >"$RUN_FILE"

objective_flat="$(printf '%s' "$OBJECTIVE" | tr '\n\t' '  ')"
# Literal backticks below are intentional Markdown code spans, not command subs.
# shellcheck disable=SC2016
{
  printf '## gnhf run %s\n\n' "$RUN_ID"
  printf -- '- repo: `%s`\n' "$REPO_REAL"
  printf -- '- agent: %s | max-iterations: %s | max-tokens: %s\n' "$AGENT" "$MAX_ITER" "$MAX_TOKENS"
  printf -- '- objective: %s\n' "$objective_flat"
  printf -- '- outcome: %s (exit %s)\n' "$outcome" "$rc"
  printf -- '- worktree: `%s-gnhf-worktrees/` (preserved when it has commits)\n' "$REPO_REAL"
  printf -- '- log: `%s`\n\n' "$LOG_FILE"
} >>"$GNHF_REPORT"

if [ "$rc" -eq 0 ]; then
  log "gnhf run $RUN_ID completed (exit 0); see $LOG_FILE and $GNHF_REPORT"
else
  log "gnhf run $RUN_ID ended with exit $rc; see $LOG_FILE and $GNHF_REPORT"
fi
exit "$rc"
