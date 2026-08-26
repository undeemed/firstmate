#!/usr/bin/env bash
set -u
cd "$1"
EV=/tmp/no-mistakes-evidence/01M0XCV4GFJTFH9F2WVWP7D6PK
{
  echo "== STEP D: the real changed-file gate run on this branch (no args) =="
  echo "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)  commit: $(git rev-parse --short HEAD)"
  echo "file set:"
  bin/fm-lint.sh --list-files
  echo ""
  echo "--- cmd: /usr/bin/time -v bin/fm-lint.sh ---"
  timeout 540 /usr/bin/time -v bin/fm-lint.sh
  echo "EXIT CODE: $?"
} > "$EV/step-d-gate-run.txt" 2>&1
grep -E "^==|^file set:|^bin/|^tests/|^fm-lint|Elapsed \(wall|Maximum resident|EXIT CODE" "$EV/step-d-gate-run.txt"
