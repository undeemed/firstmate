# CodeGraph-first PreToolUse seatbelt

This document is the authoritative human-readable contract for the CodeGraph-first PreToolUse seatbelt.
`bin/fm-codegraph-pretool-check.sh` is both the harness transport and the single decision owner.
Unlike the sibling watcher-arm and cd-guard seatbelts (`docs/arm-pretool-check.md`, `docs/cd-guard.md`), which delegate their verdict to a shared Node classifier, this check owns its whole decision in the script, because its classification is a small self-contained set of byte tests with no shared shell lexer to reuse.

It is the fourth member of the family of PreToolUse seatbelts that share the same cross-harness hook machinery: the watcher-arm seatbelt, the cd-guard seatbelt, and the turn-end supervision guard (`bin/fm-turnend-guard.sh`, `docs/turnend-guard.md`).

## Purpose and boundary

A repository that carries a `.codegraph/` index has a pre-built graph of every symbol, edge, and file.
A raw text search in that repository (a `Grep`, `Glob`, or `ast_grep` tool call, or a shell `rg`/`grep`/`find`/... command) discards that structure and returns less accurate context in more round-trips than one `codegraph explore` call.
This seatbelt denies a raw repository code search in that situation and points the agent at the `codegraph explore` alternative instead.

The check never executes, sources, evaluates, or expands any byte of the submitted command.
It tokenizes the bytes and inspects the command words and path operands only.
Its threat model is agent mistakes, the same as the sibling seatbelts: an ordinary `rg foo src/` reached for out of habit, not a deliberately obfuscated bypass.

This is a preference nudge, not a sandbox.
It never blocks anything outside a CodeGraph-indexed repository, and the escape hatch always allows the raw search when the agent genuinely needs it.

## Scope: CodeGraph-indexed repositories only

The check resolves the repo root by walking up from the working directory (`--cwd`, or the process `$PWD`, or the stdin payload `.cwd`) to the nearest ancestor that contains a `.codegraph/` directory.
If no ancestor contains one, the repository is not indexed and the check is a silent no-op (exit 0).
Indexing is the user's decision, so a repository without `.codegraph/` is never touched.

The same walk yields the repo root that the target-is-code test below measures against.

## The rule

The check denies only when all of the following hold.
Any one of them not holding allows the call.

1. The resolved repo root contains a `.codegraph/` directory.
2. The call is code-search shaped: either a search tool name (`Grep`, `Glob`, `ast_grep`, or an obvious equivalent such as `ripgrep`), or a shell command whose first word is `rg`, `grep`, `egrep`, `fgrep`, `ag`, `ack`, `fd`, `find`, or `ast-grep`.
3. It is a repository search, not output filtering: a command whose search word is preceded by a pipe, or that reads stdin through a bare `-`, is allowed.
4. The target is plausibly code: a target that resolves outside the repo root, sits under `.git/`, `node_modules/`, `dist/`, `build/`, or `target/`, or matches `*.log` is allowed.
5. No escape hatch is active: `FM_ALLOW_RAW_SEARCH=1` in the environment or as an inline command prefix allows unconditionally.

The first word is matched by its basename, so `/usr/bin/rg` is recognized as `rg`.
A command with no path operand takes the tool's own default: `rg`, `ag`, `ack`, `fd`, `ast-grep`, and `find` search the current directory and are denied, while a non-recursive `grep`/`egrep`/`fgrep` reads stdin and is allowed.
A structured search tool call carries no pipe or stdin, so only the target-is-code test (its `path` input, defaulting to the repo root) can allow it.

## Allow and deny matrix

The matrix below assumes the working directory is inside a repository that carries a `.codegraph/` index, unless the row states otherwise.

| Call | Verdict | Reason |
| --- | --- | --- |
| `rg foo src/` | deny | first word is a search binary, target is repo code |
| `grep -rn foo .` | deny | recursive grep over the repo root |
| `grep -e createUser lib/` | deny | first word is a search binary, target is repo code |
| `ast-grep -p '$X()' src/` | deny | first word is a search binary, target is repo code |
| `find . -name '*.rs'` | deny | find over the repo root |
| `rg foo` | deny | ripgrep defaults to searching the current directory |
| `Grep` tool call (path in repo) | deny | search tool name, target is repo code |
| `Glob` tool call (no path) | deny | search tool name, defaults to the repo root |
| `rg foo src/` in a repo with no `.codegraph/` | allow | repository is not indexed |
| `cat file \| grep foo` | allow | first word is `cat`; the search word is preceded by a pipe |
| `grep foo` | allow | non-recursive grep with no path reads stdin |
| `grep foo -` | allow | reads stdin through a bare `-` |
| `rg foo app.log` | allow | target matches `*.log` |
| `rg foo node_modules/pkg` | allow | target is under a vendored directory |
| `rg foo /etc/hosts` | allow | target resolves outside the repo root |
| `find /var/log -name '*.log'` | allow | target resolves outside the repo root |
| `FM_ALLOW_RAW_SEARCH=1 rg foo src/` | allow | inline escape-hatch prefix |
| `cat foo.rs` | allow | first word is not a search binary |
| `Read` tool call | allow | tool name is not a search tool |

### Accepted non-goals

Consistent with the agent-mistake threat model, the check does not chase every obfuscated or compound shape.

- A search that is not the first command on its line (a chained `echo hi; rg foo src/`, or a later line of a multi-line command) is not classified, because the first-word test only inspects the leading command.
- A target path that contains spaces and is split by simple whitespace tokenization may be misread; the verdict then leans toward deny, and the escape hatch remains available.
- A search reconstructed by a command substitution or an expanded variable (`$SEARCH foo`) is opaque to a byte tokenizer and is allowed.

Any unresolved shape allows rather than blocks, so the check never wrongly denies a non-search command.

## The escape hatch

`FM_ALLOW_RAW_SEARCH=1` allows the raw search unconditionally.
It is honored both as an environment variable and as an inline leading assignment in the command (`FM_ALLOW_RAW_SEARCH=1 rg foo src/`).
The deny reason always names it, so an agent that genuinely needs the raw search can retry in one step.

## Transport and fail-open behavior

`bin/fm-codegraph-pretool-check.sh` supports two entry forms.

- Stdin JSON, read when no CLI arguments are supplied: `.tool_name`, `.tool_input.command`, `.tool_input.path`, and `.tool_input.pattern`, with the Grok `.toolName` / `.toolInput` fallbacks, plus `.cwd`. This is what Claude Code pipes in.
- CLI flags `--tool <name> [--command <cmd>] [--cwd <dir>]`, used by the Pi and omp primary guards (which forward the tool name and command) and by the test suite.

Anything unevaluable fails open with exit 0 and no output: no `.codegraph/` repo above the working directory, empty or malformed stdin, a missing `jq` on the stdin path, an unresolvable working directory, or a call that is not a repository code search.
A broken hook must never deny a tool call.

## Output contract

- Allow returns exit 0 with both streams empty.
- Deny returns exit 2 with a short plain-text reason on stderr and an empty stdout.

The empty stdout on deny is deliberate: Claude Code honors a PreToolUse deny only when the hook's stdout is empty and it exits 2 with the reason on stderr, and the Pi and omp guards forward the stderr text as the block reason verbatim.
The reason text is read by an LLM, so it stays to a few concrete lines: what was blocked, that the repository is CodeGraph-indexed, the exact `codegraph explore "<query>"` alternative, and the escape hatch.
It carries no Firstmate-internal jargon.

## Wiring

The check runs everywhere a Firstmate-launched agent can run a search.

| Harness | Entry | Behavior on checker exit 2 |
| --- | --- | --- |
| Pi primary | `.pi/extensions/fm-primary-turnend-guard.ts` `tool_call` handler chains this check after the cd-guard and watcher-arm checks, forwarding the tool name. | Returns `{ block: true, reason }` so the bash command does not run. |
| omp primary | `.omp/extensions/fm-primary-turnend-guard.ts` runs the identical chain. | Returns `{ block: true, reason }`. |
| Claude Code | `~/.claude/settings.json` `PreToolUse` entry matching `Bash|Grep|Glob` pipes the tool payload to the checker on stdin. | Claude blocks the tool call and feeds the stderr reason back to the model. |

The two TypeScript guards only fire for the primary's `bash` tool, so they forward `--tool bash` and rely on the command-shaped detection.
The Claude entry covers the structured `Grep` and `Glob` tools as well as `Bash`, using the tool-name detection for the former.
Each entry is independent: this check runs alongside the cd-guard and watcher-arm seatbelts, and any one deny blocks the command.

## Automated validation

`tests/fm-codegraph-pretool-check.test.sh` owns the acceptance matrix.
It proves the deny and allow verdicts through both the CLI and the Claude stdin JSON entry forms, the indexed-versus-unindexed scoping, the pipe and stdin carve-outs, the outside-repo, vendored, and `*.log` target carve-outs, the environment and inline escape hatches, the structured search-tool path, the fail-open transport behavior, the empty-stdout-on-deny output contract, and that the script is shellcheck-clean.

Run:

```sh
bash tests/fm-codegraph-pretool-check.test.sh
```

## User-level guard extension and the installed checker

`extensions/fm-codegraph-guard.ts` is the canonical source of the user-level guard that gives every raw pi and omp session the same check the primary guards already run.
It is one portable file: omp discovers it from `~/.omp/agent/extensions/`, and pi loads it as an installed package pointing at that same path, so the two runtimes never drift into separate copies.

Install it by copying this file to `~/.omp/agent/extensions/fm-codegraph-guard.ts` and registering that path with `pi install`.

The guard resolves the checker from `~/.local/bin/fm-codegraph-pretool-check.sh` first and falls back to `$FM_HOME/bin/fm-codegraph-pretool-check.sh`.
That order exists because of a real failure: an earlier version resolved only the repository path, so checking out a branch without the script made the spawn fail, and the guard's deliberate fail-open behavior then allowed every raw search with nothing logged.
Install the checker to the stable path with `install -m 0755 bin/fm-codegraph-pretool-check.sh ~/.local/bin/fm-codegraph-pretool-check.sh`, and re-run that command whenever this repository's copy changes.
