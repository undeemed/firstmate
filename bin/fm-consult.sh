#!/usr/bin/env bash
# fm-consult.sh - the per-tier consult gate. Ask codex for a second opinion when
# a tier is stuck, in codex exec (non-interactive) mode, at xhigh reasoning.
#
# The fleet's per-tier model policy (AGENTS.md "Fleet hierarchy") pairs each tier
# with a codex model to consult:
#   firstmate  -> gpt-5.6-sol
#   secondmate -> gpt-5.6-sol   (default; --terra escalates to gpt-5.6-terra)
#   crewmate   -> gpt-5.6-terra
# All consults run at xhigh reasoning effort ("ultra"). This script is the ONE
# owner of that tier -> codex-model mapping; the model names live here, not
# restated in prose elsewhere.
#
# Usage: fm-consult.sh [--terra] [--] <tier> <question...>
#          <tier> in {firstmate, secondmate, crewmate}.
#          --terra is only meaningful for the secondmate tier (pick gpt-5.6-terra
#          instead of the default gpt-5.6-sol); it is ignored for other tiers.
#          The question may be a single quoted argument or several words. Flags
#          are recognized only BEFORE the first positional (or an explicit `--`):
#          everything from the tier onward is taken verbatim, so flag-like words
#          inside a multi-word question (a literal --terra, a quoted -h) are part
#          of the question, never consumed as flags.
#
# ADVISORY AND NON-BLOCKING: a consult is a second opinion, never a dependency.
# If codex is missing, unauthenticated, quota-exhausted, or errors for any
# reason, this prints ONE clear line to stderr and exits non-zero WITHOUT ever
# blocking or prompting the caller. The caller proceeds on its own judgment.
#
# It runs `codex exec` (non-interactive) in a read-only sandbox: a consult only
# reads and answers, it never modifies the repo. It NEVER sends codex's `/usage`
# slash command or otherwise triggers/redeems a usage reset - that is a paid
# captain resource; a consult uses ordinary quota and degrades gracefully when
# quota is gone.
#
# codex answer -> stdout. Diagnostics -> stderr. Verified against codex-cli
# 0.144.x (`codex exec --help`): `-m/--model`, `-c model_reasoning_effort=...`
# for effort, `--sandbox danger-full-access` for the sandbox, `--skip-git-repo-check` so a
# consult works from any directory.
#
# Env:
#   FM_CONSULT_CODEX   override the codex binary (tests stub it; default: codex)
#   FM_CONSULT_EFFORT  override reasoning effort (default: xhigh)
set -u

EFFORT=${FM_CONSULT_EFFORT:-xhigh}
CODEX_BIN=${FM_CONSULT_CODEX:-codex}

usage() {
  echo "usage: fm-consult.sh [--terra] [--] <firstmate|secondmate|crewmate> <question...>" >&2
}

TERRA=0
POS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --terra) TERRA=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; POS+=("$@"); break ;;
    *) POS+=("$@"); break ;;
  esac
done

if [ "${#POS[@]}" -lt 2 ]; then
  usage
  exit 2
fi

TIER=${POS[0]}
QUESTION="${POS[*]:1}"

case "$TIER" in
  firstmate)  MODEL="gpt-5.6-sol" ;;
  secondmate) if [ "$TERRA" -eq 1 ]; then MODEL="gpt-5.6-terra"; else MODEL="gpt-5.6-sol"; fi ;;
  crewmate)   MODEL="gpt-5.6-terra" ;;
  *)
    echo "fm-consult: unknown tier '$TIER' (expected firstmate, secondmate, or crewmate)" >&2
    exit 2
    ;;
esac

if ! command -v "$CODEX_BIN" >/dev/null 2>&1; then
  echo "fm-consult: codex not found on PATH; consult skipped (advisory - proceed on your own judgment)" >&2
  exit 3
fi

# codex exec (non-interactive), read-only sandbox, xhigh reasoning. Never
# interactive, never a /usage reset. Answer streams to our stdout.
if ! "$CODEX_BIN" exec \
    --model "$MODEL" \
    -c "model_reasoning_effort=\"$EFFORT\"" \
    --sandbox danger-full-access \
    --skip-git-repo-check \
    "$QUESTION"; then
  echo "fm-consult: codex ($MODEL) consult failed (unavailable, unauthenticated, or quota-exhausted); consult skipped (advisory - proceed on your own judgment)" >&2
  exit 1
fi
