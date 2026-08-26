#!/usr/bin/env bash
set -u
cd "$1"
EV=/tmp/no-mistakes-evidence/01M0XCV4GFJTFH9F2WVWP7D6PK
{
  echo "== STEP A: BEFORE repro - base-commit source graph, NEW capped lint =="
  echo "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)  host shellcheck: $(shellcheck --version | awk '/^version:/{print $2}')"
  echo "cmd: git checkout 0981b6ec -- bin/fm-teardown.sh bin/fm-pending-reply-lib.sh"
  git checkout 0981b6ec -- bin/fm-teardown.sh bin/fm-pending-reply-lib.sh
  echo "cmd: FM_LINT_JOBS=1 /usr/bin/time -v bin/fm-lint.sh bin/fm-teardown.sh  (default 6 GiB ceiling)"
  timeout 540 env FM_LINT_JOBS=1 /usr/bin/time -v bin/fm-lint.sh bin/fm-teardown.sh
  rc=$?
  echo "EXIT CODE: $rc"
  echo "cmd: git checkout 25be9f0a -- bin/fm-teardown.sh bin/fm-pending-reply-lib.sh (restore)"
  git checkout 25be9f0a -- bin/fm-teardown.sh bin/fm-pending-reply-lib.sh
  git diff --stat 25be9f0a -- bin/fm-teardown.sh bin/fm-pending-reply-lib.sh && echo "restore verified: no diff vs target commit"
} > "$EV/step-a-before-repro.txt" 2>&1
grep -E "EXIT CODE|memory ceiling|Maximum resident|Elapsed" "$EV/step-a-before-repro.txt" | head -8
