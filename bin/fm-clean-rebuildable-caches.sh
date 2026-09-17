#!/usr/bin/env bash
# Remove only rebuildable Bun/build caches and known stale Tetanus targets.
# Dry-run is the default. Use --apply only after reviewing the listed paths.
# Use --prune to delete Bun caches only when they exceed the configured limit.
set -euo pipefail

DRY_RUN=1
PRUNE=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) ;;
    --apply) DRY_RUN=0 ;;
    --prune) PRUNE=1 ;;
    *) printf 'usage: %s [--dry-run|--apply] [--prune]\n' "$0" >&2; exit 2 ;;
  esac
done

BUN_CACHE_MAX_BYTES="${FM_BUN_CACHE_MAX_BYTES:-4294967296}"

if pgrep -f '(^|/)(bun|node|cargo|rustc)(.*(install|build|test|typecheck|lint))' >/dev/null 2>&1; then
  if (( DRY_RUN )); then
    echo 'active build or package process found; listing only'
  else
    echo 'active build or package process found; refusing cleanup' >&2
    exit 1
  fi
fi

TARGETS=(
  "$HOME/.bun/install/cache"
  "$HOME/.bun/build-cache"
  "$HOME/.cache/bun/transpiler"
  "$HOME/.cache/tetanus-target"
  "/var/tmp/tetanus-target"
  "/var/tmp/tetanus-uiwatch-target"
)

for target in "${TARGETS[@]}"; do
  [[ -e "$target" ]] || continue
  size=$(du -sh "$target" 2>/dev/null | cut -f1 || true)
  case "$target" in
    "$HOME/.bun/install/cache"|"$HOME/.bun/build-cache"|"$HOME/.cache/bun/transpiler")
      if (( PRUNE )); then
        size_bytes=$(( $(du -sk "$target" 2>/dev/null | cut -f1 || echo 0) * 1024 ))
        if (( size_bytes <= BUN_CACHE_MAX_BYTES )); then
          printf 'keep %s (%s, limit %s bytes)\n' "$target" "${size:-unknown}" "$BUN_CACHE_MAX_BYTES"
          continue
        fi
      fi
      ;;
  esac
  if (( DRY_RUN )); then
    printf 'would-delete %s (%s)\n' "$target" "${size:-unknown}"
  else
    printf 'deleting %s (%s)\n' "$target" "${size:-unknown}"
    rm -rf -- "$target"
  fi
done

if (( DRY_RUN )); then
  echo 'dry-run only; pass --apply to delete listed targets'
else
  df -h / | tail -1
fi
