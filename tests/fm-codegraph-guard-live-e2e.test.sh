#!/usr/bin/env bash
# Opt-in live enforcement guard for the CodeGraph-first search seatbelt
# (docs/codegraph-pretool-check.md). The portable regression in
# tests/fm-codegraph-pretool-check.test.sh proves the decision path with real
# processes but no harness; this guard proves the installed harnesses actually
# block at tool-execution time, which no stub or fake agent can confirm.
set -u

if [ "${FM_CODEGRAPH_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_CODEGRAPH_LIVE_E2E=1 to run the live CodeGraph seatbelt enforcement guard"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

unset FM_ALLOW_RAW_SEARCH FM_CODEGRAPH_CHECKER NO_MISTAKES_GATE

LAB="$ROOT/.codegraph-live-e2e.$$"
REPO="$LAB/indexed"
CHECKER="$ROOT/bin/fm-codegraph-pretool-check.sh"
GUARD="$ROOT/extensions/fm-codegraph-guard.ts"
SENTINEL="FM_CG_LIVE_SENTINEL_$$"

cleanup() {
  rm -rf "$LAB"
}
trap cleanup EXIT

# This header keeps the first output line of an opted-in run from being a
# per-harness skip line, which the runner would misread as a gate skip.
echo "# live CodeGraph seatbelt guard: checker under test $CHECKER"

mkdir -p "$REPO/src" "$REPO/.codegraph"
git init -q "$REPO"
printf 'fn createUser() {} // %s\n' "$SENTINEL" >"$REPO/src/user.rs"

SEARCH_PROMPT='Run exactly this bash command, once: grep -rn createUser src/ - do not retry it, do not modify it, and do not set any environment variables. Then report what happened, quoting any command output or refusal reason verbatim.'
CAT_PROMPT='Run exactly this bash command, once: cat src/user.rs - then reply with its exact output.'

# run_harness <harness> <prompt>: one real non-interactive session inside the
# indexed tree, loading only the tracked guard extension and pinning the repo
# checker so no shared installed copy is touched. Prints the session output.
run_harness() {
  local harness=$1 prompt=$2
  local -a extra=()
  if [ "$harness" = omp ]; then
    extra=(--auto-approve)
  fi
  (
    cd "$REPO" &&
      FM_CODEGRAPH_CHECKER="$CHECKER" "$harness" -ne -e "$GUARD" --no-session -nc -ns \
        "${extra[@]+"${extra[@]}"}" -p "$prompt" 2>&1
  )
}

exercised=0
for harness in pi omp; do
  if ! command -v "$harness" >/dev/null 2>&1; then
    echo "skip: $harness is not installed, so its live CodeGraph enforcement was not exercised"
    continue
  fi
  version=$("$harness" --version 2>&1 | head -1)

  out=$(run_harness "$harness" "$SEARCH_PROMPT") ||
    fail "$harness $version: the raw-search probe session itself failed: $out"
  case "$out" in
  *"src/user.rs:1:"*)
    fail "$harness $version ran the raw search inside the indexed tree instead of refusing it: $out"
    ;;
  esac
  printf '%s' "$out" | grep -Eiq 'codegraph|FM_ALLOW_RAW_SEARCH|blocked|refus' ||
    fail "$harness $version surfaced no refusal for the raw search: $out"

  out=$(run_harness "$harness" "$CAT_PROMPT") ||
    fail "$harness $version: the non-search probe session itself failed: $out"
  case "$out" in
  *"$SENTINEL"*) ;;
  *)
    fail "$harness $version blocked or dropped a plain non-search command: $out"
    ;;
  esac

  printf 'ok - %s %s refuses a raw search in an indexed tree and still runs non-search commands\n' \
    "$harness" "$version"
  exercised=$((exercised + 1))
done

[ "$exercised" -gt 0 ] ||
  fail "FM_CODEGRAPH_LIVE_E2E=1 but neither pi nor omp is installed, so nothing was exercised"

printf 'ok - live CodeGraph seatbelt enforcement exercised on %s harness(es)\n' "$exercised"
