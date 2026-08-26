#!/usr/bin/env bash
set -u
cd "$1"
EV=/tmp/no-mistakes-evidence/01M0XCV4GFJTFH9F2WVWP7D6PK
FILES=(bin/fm-teardown.sh bin/fm-send.sh bin/fm-spawn.sh)
{
  echo "== STEP C: lint still catches a real finding in each named file =="
  echo "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)  commit: $(git rev-parse --short HEAD)"
  echo "seed: insert '_fm_lint_seed_probe= true' (SC1007) at line 2 of each file"
  for f in "${FILES[@]}"; do sed -i '2i _fm_lint_seed_probe= true' "$f"; done
  echo ""
  echo "--- cmd: FM_LINT_JOBS=1 bin/fm-lint.sh ${FILES[*]} ---"
  timeout 540 env FM_LINT_JOBS=1 bin/fm-lint.sh "${FILES[@]}" > /tmp/step-c-full.txt 2>&1
  echo "EXIT CODE: $?"
  echo "findings, with the file each one names:"
  grep -E "^In bin/.* line 2:|SC1007" /tmp/step-c-full.txt
  echo ""
  echo "revert: git checkout 25be9f0a -- ${FILES[*]}"
  git checkout 25be9f0a -- "${FILES[@]}"
  git diff --quiet 25be9f0a -- "${FILES[@]}" && echo "revert verified: files identical to target commit"
  rm -f /tmp/step-c-full.txt
} > "$EV/step-c-seeded-findings.txt" 2>&1
cat "$EV/step-c-seeded-findings.txt"
