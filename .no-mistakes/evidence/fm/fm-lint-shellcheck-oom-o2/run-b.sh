#!/usr/bin/env bash
set -u
cd "$1"
EV=/tmp/no-mistakes-evidence/01M0XCV4GFJTFH9F2WVWP7D6PK
{
  echo "== STEP B: AFTER - each heavy root linted under the default 6 GiB ceiling =="
  echo "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)  commit: $(git rev-parse --short HEAD)  shellcheck: $(shellcheck --version | awk '/^version:/{print $2}')"
  for root in bin/fm-teardown.sh bin/fm-send.sh bin/fm-spawn.sh tests/fm-pending-reply.test.sh; do
    echo ""
    echo "--- cmd: FM_LINT_JOBS=1 /usr/bin/time -v bin/fm-lint.sh $root ---"
    timeout 540 env FM_LINT_JOBS=1 /usr/bin/time -v bin/fm-lint.sh "$root" 2>&1 \
      | grep -E "^fm-lint|Command being timed|Elapsed \(wall|Maximum resident|Exit status" 
    echo "EXIT CODE for $root: ${PIPESTATUS[0]}"
  done
} > "$EV/step-b-after-measured.txt" 2>&1
cat "$EV/step-b-after-measured.txt"
