# Verification: ShellCheck memory ceiling

Audience: maintainer-verification.
Owner of the mechanism: `bin/fm-lint.sh` (header and `--help`).
Owner of the regression pin: `tests/fm-lint.test.sh`.

## What this record supports

`bin/fm-lint.sh` runs every ShellCheck process under an address-space ceiling
(`FM_LINT_MEMORY_LIMIT_KIB`, default 6291456 KiB = 6 GiB) and every canonical root fits inside it.

ShellCheck's memory cost is roughly linear in the total number of lines it analyses, at about 130 KiB of resident memory per line on this build.
`--external-sources` inlines a module once per `# shellcheck source=` directive, so a root that imports the same module more than once pays for that module's entire graph every time.
`bin/fm-teardown.sh` imported `bin/fm-wake-lib.sh` three times and reached 28,132 analysed lines, which is why it could not be linted at all.

## Environment

- Date: 2026-08-24.
- Host: Linux x86_64, 8 CPU, 22 GiB RAM, other fleet work running concurrently (load average 9-19), so wall times are upper bounds.
- ShellCheck 0.11.0, the version `bin/fm-lint.sh --required-version` pins.
- Every measurement ran under `ulimit -v` with a wall-clock timeout. No unbounded run was repeated.

## Not a version regression

The same root exhausts the same memory on three ShellCheck releases, so the pin is not the cause and moving it is not the fix.

```
$ ( ulimit -v 6000000; /usr/bin/time -f 'wall=%es rss=%MKiB rc=%x' timeout 300 \
    shellcheck --norc --external-sources -- bin/fm-teardown.sh >/dev/null )
0.11.0   wall=57.56s rss=4009084KiB rc=251   shellcheck: out of memory
0.10.0   wall=63.16s rss=3997432KiB rc=251   shellcheck: out of memory
0.9.0    wall=65.66s rss=4002880KiB rc=251   shellcheck: out of memory
```

## Before and after

Peak RSS and wall time for one `bin/fm-lint.sh <root>` run per root, `FM_LINT_JOBS=1`, measured with `/usr/bin/time -f 'wall=%es peak_rss=%MKiB rc=%x'`.
The "before" column is the same measurement on the pre-fix tree under a 6 GiB ceiling.

| root | analysed lines before | before | analysed lines after | after |
|---|---:|---|---:|---|
| `bin/fm-teardown.sh` | 28132 | out of memory above 6 GiB (4009084 KiB when the ceiling stopped it) | 21708 | 3105464 KiB, 88.90 s, exit 0 |
| `tests/fm-pending-reply.test.sh` | 24138 | out of memory above 4 GiB (2676472 KiB when the ceiling stopped it) | 17450 | 3262496 KiB, 51.61 s, exit 0 |
| `bin/fm-send.sh` | 16544 | 1986000 KiB, 33.51 s (out of memory under a 3 GiB ceiling) | 13200 | 1523600 KiB, 23.50 s, exit 0 |
| `bin/fm-spawn.sh` | 10924 | 2510780 KiB, 20.14 s (out of memory under a 3 GiB ceiling) | 10924 | 2515156 KiB, 22.24 s, exit 0 |

`bin/fm-spawn.sh` imports no module twice, so its graph is unchanged; it now completes because the shipped ceiling is above what it needs, not because its graph shrank.

Reported uncapped by the worker this fix unblocked: 14.4 GB RSS over 2 h 45 min, all 51 GB of swap consumed, load average 34.

## Full canonical lint

```
$ CI=true FM_LINT_JOBS=1 bin/fm-lint.sh --telemetry <path>
root_count            323
max_worker_rss_kib    3144092
wall_seconds          1020
result_exit           0
```

Serial, on the loaded host above. Peak resident memory across the whole run is 3144092 KiB, well inside the 6 GiB ceiling.

## Findings parity

Linting each of the 323 canonical roots separately, before and after, produced the same diagnostics: none.
A seeded `SC1007` in each of `bin/fm-teardown.sh`, `bin/fm-send.sh`, and `bin/fm-spawn.sh` is reported and the run exits 1, so the shrunken source graph still analyses those roots rather than skipping them.

## Enforcement scope: Linux is the platform that enforces the ceiling

Decided 2026-08-26 during review, recorded here because it bounds what the ceiling promises.
The ceiling is real only where the kernel enforces RLIMIT_AS, and of this fleet's platforms only Linux does.
macOS accepts `setrlimit(RLIMIT_AS)` and then does not enforce it, so on Darwin the ceiling is set but bounds nothing.
Approving that silently was rejected on the accepted intent, not on taste: a cap that silently skips linting is not acceptable, and a ceiling that is set but not enforced is the same failure wearing a different hat.
Darwin is a real platform for this fleet, not hypothetical: the fleet runs three M4 Mac minis reachable on the tailnet, and `bin/fm-lint.sh` already carries explicit Darwin branches.
`bin/fm-lint.sh` therefore probes actual enforcement once per lint run, before the workers start: one process runs under a tiny `ulimit -v`, and the kernel either refuses its allocation or does not.
The probe never branches on `uname`, because the thing under test is the platform's behaviour, not its name.
When the platform refuses RLIMIT_AS, or accepts it without enforcing it, `bin/fm-lint.sh` warns in exactly one line on stderr that the configured ceiling is not bounding ShellCheck.
That single line is deliberately the whole mechanism: no capability-detection framework, no new configuration surface, no new guarantee.
The warning lands on the run's real stderr rather than inside a worker's captured shard streams, so it cannot be mistaken for a ShellCheck finding or truncated with a discarded shard batch.
The three ceiling tests in `tests/fm-lint.test.sh` - `test_heavy_roots_lint_within_the_memory_ceiling`, `test_memory_ceiling_names_the_root_it_could_not_lint`, and `test_memory_ceiling_still_reports_the_roots_that_fit` - skip when that same runtime probe finds RLIMIT_AS unenforced, and each skip message states that reason.
The heavy-roots case skips for the same reason as the two named failure cases: without enforcement it cannot prove the roots fit, and the honest warning line would trip its no-ceiling-message assertion.

## Refreshing this record

```
bash tests/fm-lint.test.sh
CI=true bin/fm-lint.sh --telemetry /tmp/fm-lint-telemetry.tsv
```

The first command is the enforced pin: it fails if a canonical root stops fitting the 6 GiB ceiling, and it fails if an oversized root is skipped instead of named.
