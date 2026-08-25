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

## Refreshing this record

```
bash tests/fm-lint.test.sh
CI=true bin/fm-lint.sh --telemetry /tmp/fm-lint-telemetry.tsv
```

The first command is the enforced pin: it fails if a canonical root stops fitting the 6 GiB ceiling, and it fails if an oversized root is skipped instead of named.
