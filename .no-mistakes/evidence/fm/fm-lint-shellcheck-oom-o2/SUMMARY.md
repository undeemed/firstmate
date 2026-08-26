# Test-phase evidence: bounded ShellCheck memory in bin/fm-lint.sh

Branch fm/fm-lint-shellcheck-oom-o2, target commit 25be9f0, tested 2026-08-26 on Linux, ShellCheck 0.11.0 (= the pin), 8 CPU, RLIMIT_AS enforced (probed).
All runs used the shipped capped lint. No uncapped ShellCheck was ever run.

## Before -> after, measured with /usr/bin/time -v

| Root | Before (base source graph, 6 GiB ceiling) | After (target commit, 6 GiB ceiling) |
| --- | --- | --- |
| bin/fm-teardown.sh | OOM: killed at 4202336 KiB RSS, 2:40.65, exit 2, loud message naming the root and the 6291456 KiB ceiling | 3118292 KiB RSS, 38.20 s, exit 0 |
| bin/fm-send.sh | (fits before and after per intent) | 1537472 KiB RSS, 21.02 s, exit 0 |
| bin/fm-spawn.sh | (graph unchanged by design) | 2514336 KiB RSS, 20.72 s, exit 0 |
| tests/fm-pending-reply.test.sh | (fourth root found by the sweep) | 3331108 KiB RSS, 50.97 s, exit 0 |

RSS agrees with the intent's reported table within 2 percent on every root.
Wall times are on a loaded host and are upper bounds.

## The real gate run on this branch (no args)

Changed-file set: bin/fm-lint.sh, bin/fm-pending-reply-lib.sh, bin/fm-teardown.sh, tests/fm-lint.test.sh.
Completed exit 0 in 38.86 s at 3117928 KiB peak RSS, plus the workflow check (actionlint 1.7.12, 3 workflow files valid).
Before this change, this exact gate run could never finish: bin/fm-teardown.sh alone reached 14.4 GB RSS over 2h45m uncapped.

## Lint still catches real findings (nothing silently skipped)

A seeded SC1007 at line 2 of each of bin/fm-teardown.sh, bin/fm-send.sh, and bin/fm-spawn.sh was reported by one capped lint run, naming each file ("In bin/fm-teardown.sh line 2:", "In bin/fm-send.sh line 2:", "In bin/fm-spawn.sh line 2:"), exit 1.
All three seeds were then reverted; files verified byte-identical to the target commit.

## Regression pin

`bash tests/fm-lint.test.sh`: 26/26 cases pass in 2m11.9 s, exit 0, zero skips.
The four new cases all executed for real (RLIMIT_AS enforcement and the pinned ShellCheck were both probed present):
- fails closed on a malformed memory ceiling
- fails loudly and names the root it could not lint within the ceiling
- still reports findings for the roots that fit under the ceiling
- lints the heaviest canonical roots inside the 6 GiB memory ceiling

## Files

- step-a-before-repro.txt - the before failure, capped, loud, named
- step-b-after-measured.txt - per-root RSS and wall time after the fix
- step-c-seeded-findings.txt - seeded SC1007 caught in each named file
- step-d-gate-run.txt - the real changed-file gate run, measured
- step-e-test-suite.txt - full colocated test file output
- run-a.sh .. run-d.sh - the exact scripts that produced the transcripts
