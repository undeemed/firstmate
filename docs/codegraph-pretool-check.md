# CodeGraph-first PreToolUse seatbelt

This document is the authoritative human-readable contract for the CodeGraph-first PreToolUse seatbelt.
`bin/fm-codegraph-pretool-check.sh` is both the harness transport and the single decision owner for whether a call is a raw repository search.
`extensions/fm-codegraph-guard.ts` is the pi and omp transport in front of it, and owns the one decision the checker cannot make: what happens when the checker cannot run at all.
Unlike the sibling watcher-arm and cd-guard seatbelts (`docs/arm-pretool-check.md`, `docs/cd-guard.md`), which delegate their verdict to a shared Node classifier, this check owns its whole decision in the script, because its classification is a small self-contained set of byte tests with no shared shell lexer to reuse.

It is the fourth member of the family of PreToolUse seatbelts that share the same cross-harness hook machinery: the watcher-arm seatbelt, the cd-guard seatbelt, and the turn-end supervision guard (`bin/fm-turnend-guard.sh`, `docs/turnend-guard.md`).

## Purpose and boundary

A repository that carries a `.codegraph/` index has a pre-built graph of every symbol, edge, and file.
A raw text search in that repository (a `grep`, `glob`, `find`, or `ast_grep` tool call, or a shell `rg`/`grep`/`find`/... command) discards that structure and returns less accurate context in more round-trips than one `codegraph explore` call.
This seatbelt denies a raw repository code search in that situation and points the agent at the `codegraph explore` alternative instead.

The check never executes, sources, evaluates, or expands any byte of the submitted command.
It tokenizes the bytes and inspects the command words and path operands only.
Its threat model is agent mistakes, the same as the sibling seatbelts: an ordinary `rg foo src/` reached for out of habit, not a deliberately obfuscated bypass.

This is a preference nudge, not a sandbox.
It never blocks anything outside a CodeGraph-indexed repository, and the escape hatch always allows the raw search when the agent genuinely needs it.

## Scope: CodeGraph-indexed repositories only

The check resolves the repository around the working directory (`--cwd`, or the process `$PWD`, or the stdin payload `.cwd`) by walking up to the nearest ancestor that is a Git working tree: a directory holding a `.git` directory, or a `.git` file for a linked worktree or submodule.
The repository is indexed only when that exact root carries a `.codegraph/` directory.
If it does not, or if no Git working tree is found, the check is a silent no-op (exit 0).
Indexing is the user's decision, so a repository without `.codegraph/` is never touched.

The Git boundary is load-bearing, not incidental.
CodeGraph writes `.codegraph/` at the root of the repository it indexed, so a `.codegraph/` further up the filesystem belongs to some other project.
Without the boundary, one indexed ancestor - an indexed home directory, say - makes every unindexed directory beneath it look indexed, and the check denies searches that have no CodeGraph index to replace them.

The same walk yields the repo root that the target-is-code test below measures against.

## The rule

For each command on the submitted line, the check denies only when all of the following hold.
Any one of them not holding allows that command.

1. The repository resolved around the command's working directory carries a `.codegraph/` directory.
2. The command is code-search shaped: either a search tool name (`grep`, `glob`, `find`, `search`, `ast_grep`, or an obvious equivalent such as `ripgrep`), or a shell command whose command word is `rg`, `grep`, `egrep`, `fgrep`, `ag`, `ack`, `fd`, `find`, or `ast-grep`.
3. It is a repository search, not output filtering: a command that sits downstream of a pipe, or that reads stdin through a bare `-`, is allowed.
4. The target is plausibly code: a target that resolves outside the repo root, sits under `.git/`, `node_modules/`, `dist/`, `build/`, or `target/`, or matches `*.log` is allowed.
5. No escape hatch is active: `FM_ALLOW_RAW_SEARCH=1` in the environment or as an inline prefix on the search command allows unconditionally.

The command word is matched by its basename, so `/usr/bin/rg` is recognized as `rg`.
A command with no path operand takes the tool's own default: `rg`, `ag`, `ack`, `fd`, `ast-grep`, and `find` search the current directory and are denied, while a non-recursive `grep`/`egrep`/`fgrep` reads stdin and is allowed.
A structured search tool call carries no pipe or stdin, so only the target-is-code test (its `path` input, defaulting to the repo root) can allow it.

### Every command on the line, not only the first

A shell tool call is a command *line*, and a first-word test reads only its leading command.
That is the gap this check was first shipped with: `cd repo && grep -rn foo .` reads as `cd`, `ls; rg foo src/` reads as `ls`, and both went straight through inside an indexed repository while a bare `grep -rn foo .` in the same session was refused.
`cd <dir> && <search>` in particular is an ordinary agent habit, so the leading-word gap left the common case unguarded.

The check therefore splits the line into the individual commands it runs and classifies each one:

- The line is split on `;`, `&&`, `||`, `|`, `|&`, `&`, and newlines.
- A command downstream of a pipe is never classified; it filters another command's output rather than searching the repository.
- Leading environment assignments and pure wrappers (`command`, `builtin`, `exec`, `time`, `nohup`, `nice`, `env`) and a leading `(`, `{`, or `!` are stripped before the command word is read.
- A redirection (`<`, `>`, `>>`, `<&`, `>&`) ends a command's operands, and a lone file-descriptor number in front of one (`2>/dev/null`) is part of the redirection rather than an operand, so it is neither a search target nor a `cd` destination.

A leading `cd` moves the working directory the following commands are judged against, so `cd <indexed repo> && grep -rn foo .` is denied and `cd /tmp && grep -rn foo .` is allowed.
Only a single literal destination is resolved, and it must exist.
A `cd` whose destination would need expansion (`cd $DIR`), or that cannot be resolved, makes the rest of the line unknowable, and every remaining command on it is allowed.
A directory-stack move (`pushd`, `popd`) is not resolved either, so it likewise makes the rest of the line unknowable, and every remaining command on it is allowed.

### Tokenization

The tokenizer honors single quotes, double quotes, backslash escapes, `$( )`, and backticks, so a `;` or `&&` inside a quoted string is never read as a command boundary.
`echo "one; rg foo src/"` and `git commit -m "stop running rg foo src/ by hand"` are therefore allowed, and a real `rg -n "a; b" src/` is still denied.
Command-substitution and backtick bytes stay inside the surrounding word, so a path operand built around one still reads as a path operand.
A `<<` heredoc operator ends tokenization: a heredoc body is text, not commands, so a script written into a heredoc is never classified as a search.

## Allow and deny matrix

The matrix below assumes the working directory is inside a repository that carries a `.codegraph/` index, unless the row states otherwise.

| Call | Verdict | Reason |
| --- | --- | --- |
| `rg foo src/` | deny | command word is a search binary, target is repo code |
| `grep -rn foo .` | deny | recursive grep over the repo root |
| `grep -e createUser lib/` | deny | command word is a search binary, target is repo code |
| `ast-grep -p '$X()' src/` | deny | command word is a search binary, target is repo code |
| `find . -name '*.rs'` | deny | find over the repo root |
| `rg foo` | deny | ripgrep defaults to searching the current directory |
| `cd <this repo> && grep -rn foo .` | deny | the search runs in the indexed repository |
| `ls; rg foo src/` | deny | the second command is a repository search |
| `git status && rg foo src/` | deny | the chained command is a repository search |
| `( rg foo src/ )` | deny | the subshell's command is a repository search |
| `command grep -rn foo src/` | deny | a pure wrapper does not change the command |
| `grep -rn foo src/ 2>/dev/null` | deny | the redirect is not a search target |
| `rg -n "a; b" src/` | deny | the `;` is inside the pattern, not a command boundary |
| `grep` tool call (path in repo) | deny | search tool name, target is repo code |
| `glob` tool call (no path) | deny | search tool name, defaults to the repo root |
| `rg foo src/` in a repo with no `.codegraph/` | allow | repository is not indexed |
| `rg foo src/` in a nested repo with no index of its own | allow | the index above belongs to another project |
| `cat file \| grep foo` | allow | the grep is downstream of a pipe |
| `ls src/ \| grep foo` | allow | the grep filters another command's output |
| `grep foo` | allow | non-recursive grep with no path reads stdin |
| `grep foo -` | allow | reads stdin through a bare `-` |
| `rg foo app.log` | allow | target matches `*.log` |
| `rg foo node_modules/pkg` | allow | target is under a vendored directory |
| `rg foo /etc/hosts` | allow | target resolves outside the repo root |
| `find /var/log -name '*.log'` | allow | target resolves outside the repo root |
| `cd /tmp && grep -rn foo .` | allow | the search runs outside the indexed repository |
| `cd $DIR && grep -rn foo src/` | allow | the working directory is unknowable |
| `echo "one; rg foo src/"` | allow | the search words are quoted text |
| `cat >x.sh <<'EOF'` ... `rg foo src/` ... `EOF` | allow | a heredoc body is text, not commands |
| `FM_ALLOW_RAW_SEARCH=1 rg foo src/` | allow | inline escape-hatch prefix |
| `cat foo.rs` | allow | command word is not a search binary |
| `read` tool call | allow | tool name is not a search tool |

### Accepted non-goals

Consistent with the agent-mistake threat model, the check does not chase every obfuscated or compound shape.

- A nested command string (`bash -c "rg foo src/"`, `sh -c ...`) is not classified. Its payload is a command inside a single word, which would need a second tokenizer pass; the wrapper set deliberately excludes shells for that reason.
- A search whose command word is reconstructed by a command substitution or an expanded variable (`$SEARCH foo`) is opaque to a byte tokenizer and is allowed. A substitution used as a path operand (`rg foo $(pwd)/src`) still reads as a path operand and is classified.
- A search invoked as a `git` subcommand - `git grep`, and the `git log -S` and `git log -G` pickaxe searches - classifies by its command word as `git` and is allowed. Classifying git subcommands would add parsing surface that can itself fail open, and this shape errs toward letting a search through rather than refusing legitimate work.
- A target path that contains spaces and is split by tokenization may be misread; the verdict then leans toward deny, and the escape hatch remains available.
- A command line longer than 4000 bytes is allowed without classification. Tokenizing is paid on every tool call, and a 4000-byte line already costs about 0.2s; real search commands are two orders of magnitude shorter, and the long lines agents do write - a file written through a heredoc - stop at the heredoc operator well before the cap.
- Command bytes that cannot be tokenized at all (unbalanced quoting or substitution) are allowed.
- A trailing comment is not stripped, so `grep foo app.log # check the log` is read as a search with extra targets and denied even though the allow matrix permits `grep foo app.log` alone.
- A separated option argument such as `-A 5`, `-B 5`, `-C 5`, or `-m 5` is read as the pattern and shifts the real pattern into the targets, so `rg foo -A 5 app.log` and `grep -m 5 foo /var/log/syslog` are denied even though the attached `rg foo -A5 app.log` form is allowed.
- An unexpanded `~` target is resolved as a relative path under the repository, so `grep foo ~/.bashrc` is denied even though the shell would expand it outside the repository.

The last three shapes stay deny-leaning on purpose: each carve-out would add parsing surface that can itself fail open, over-denying only refuses a raw search, and the `FM_ALLOW_RAW_SEARCH=1` escape hatch named in every deny reason recovers in one step.
Any unresolved shape allows rather than blocks, so the check never wrongly denies a non-search command.

## The escape hatch

`FM_ALLOW_RAW_SEARCH=1` allows the raw search unconditionally.
It is honored both as an environment variable and as an inline leading assignment on the search command itself (`rg foo src/` or `cd src && FM_ALLOW_RAW_SEARCH=1 rg foo deep`).
The deny reason always names it, so an agent that genuinely needs the raw search can retry in one step.

## Transport and fail-open behavior

`bin/fm-codegraph-pretool-check.sh` supports two entry forms.

- Stdin JSON, read when no CLI arguments are supplied: `.tool_name`, `.tool_input.command`, `.tool_input.path`, and `.tool_input.pattern`, with the Grok `.toolName` / `.toolInput` fallbacks, plus `.cwd`. This is what Claude Code pipes in.
- CLI flags `--tool <name> [--command <cmd>] [--cwd <dir>]`, used by the Pi and omp guards and by the test suite.

A structured tool call carries no command string, so the Pi and omp guards forward the tool's input serialized as a JSON object in `--command`.
The check recovers the search path and pattern from that object when they did not arrive as dedicated fields, so a `grep` tool call pointed at a `*.log` file is still allowed and a denied one still names the pattern in its `codegraph explore` suggestion.

Anything unevaluable fails open with exit 0 and no output: no indexed repository around the working directory, empty or malformed stdin, a missing `jq` on the stdin path, an unresolvable working directory, command bytes the tokenizer cannot resolve, or a call that is not a repository code search.
A check that reaches a verdict of "I cannot tell" must not deny a tool call.

That is a different case from the guard not running at all, which the next section owns.

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
| pi and omp, every session | `extensions/fm-codegraph-guard.ts`, installed as a user-level extension. | Returns `{ block: true, reason }` so the tool call does not run. |
| Pi primary | `.pi/extensions/fm-primary-turnend-guard.ts` `tool_call` handler chains this check after the cd-guard and watcher-arm checks. | Returns `{ block: true, reason }`. |
| omp primary | `.omp/extensions/fm-primary-turnend-guard.ts` runs the identical chain. | Returns `{ block: true, reason }`. |
| Claude Code | `~/.claude/settings.json` `PreToolUse` entry matching `Bash|Grep|Glob` pipes the tool payload to the checker on stdin. | Claude blocks the tool call and feeds the stderr reason back to the model. |

The user-level guard is the enforcement owner for pi and omp: it is loaded by every session of both runtimes, including crewmate sessions in a task worktree and the primary session itself.
The two primary turn-end guards resolve the checker from their own checkout and chain it for the primary's `bash` tool only.
They are a zero-install convenience that duplicates coverage the user-level guard already provides in the same session, and they fail open on a missing or failing checker; the cannot-run policy below lives in the user-level guard alone.
Each entry is independent: this check runs alongside the cd-guard and watcher-arm seatbelts, and any one deny blocks the command.

## When the guard cannot run

A guard that quietly allows everything is indistinguishable from a guard that approved the call.
`extensions/fm-codegraph-guard.ts` therefore treats "the checker did not answer" as its own case, separately from the checker's own fail-open verdicts.
It applies when no checker exists at either resolved path, when the spawn fails, or when the checker exits with a code the contract does not define.

The refusal is scoped rather than blanket, because this one handler sees every tool call:

- A search-shaped call inside a CodeGraph-indexed repository is refused, and the reason names what could not run and the recovery that matches the cause: the `install` command when the shared checker paths are what failed, or fixing or unsetting `FM_CODEGRAPH_CHECKER` when an explicit pin was in play.
- Everything else proceeds. A blanket refusal would block reading, writing, editing, and running commands, including the commands needed to reinstall the missing checker, and wedge the session with no way out.
- Outside an indexed repository the guard has nothing to enforce, so its absence changes nothing.
- The escape hatch still releases the call, so a genuinely needed raw search is never trapped.

The search-shaped test on this path is deliberately broader than the checker's rule: it matches the search tool names, and any search binary appearing as a word in a real command string.
It only has to decide which calls are unsafe to wave through while the real rule is unavailable.
A structured tool call is judged by its tool name alone, never by its serialized input.
The bytes of the Edit or Write that would repair a broken checker always contain search words, so scanning serialized input would refuse the guard's own repair - a trap that outweighs the marginal coverage - and the tool-name test mirrors the checker's rule, which likewise classifies only command strings and search tool names.

## Automated validation

`tests/fm-codegraph-pretool-check.test.sh` owns the acceptance matrix.
It proves the deny and allow verdicts through both the CLI and the Claude stdin JSON entry forms, the indexed-versus-unindexed scoping, the Git repository boundary including a nested repo and an indexed non-repo ancestor, per-command classification across `cd`, sequences, chains, subshells, wrappers, later lines, and redirects, the pipe and stdin carve-outs, quoted bytes that only look like a search, the outside-repo, vendored, and `*.log` target carve-outs, the environment and inline escape hatches, the structured search-tool path including serialized tool input, the fail-open transport behavior, the size cap, the empty-stdout-on-deny output contract, the guard extension's cannot-run policy, and that the script is shellcheck-clean.

`tests/fm-pi-primary-types.test.sh` typechecks `extensions/fm-codegraph-guard.ts` with the other tracked pi and omp extensions.

Run:

```sh
bash tests/fm-codegraph-pretool-check.test.sh
bash tests/fm-pi-primary-types.test.sh
FM_CODEGRAPH_LIVE_E2E=1 bash tests/fm-codegraph-guard-live-e2e.test.sh
```

The last one is the opt-in live guard: it drives each installed harness (pi, omp) for real against a throwaway indexed tree, because only a live run can prove the harness enforces the block at tool-execution time.
Its dated per-harness evidence lives in [`verification/runtime-backends.md`](verification/runtime-backends.md#codegraph-search-seatbelt).

## User-level guard extension and the installed checker

`extensions/fm-codegraph-guard.ts` is the canonical source of the user-level guard that gives every pi and omp session the same check the primary guards already run.
It is one portable file: omp discovers it from `~/.omp/agent/extensions/`, and pi loads it as an installed package pointing at that same path, so the two runtimes never drift into separate copies.

Install it by copying this file to `~/.omp/agent/extensions/fm-codegraph-guard.ts` and registering that path with `pi install`.

The guard resolves the checker from `~/.local/bin/fm-codegraph-pretool-check.sh` first and falls back to `$FM_HOME/bin/fm-codegraph-pretool-check.sh`, per call rather than once at load, so installing or removing the checker mid-session takes effect immediately.
`FM_CODEGRAPH_CHECKER` pins an explicit checker ahead of both, so one session can exercise a candidate script without rewriting the shared installed copy that every other agent on the machine is already running.
When `FM_CODEGRAPH_CHECKER` is set but nothing exists at that path, the guard treats the checker as unable to run and refuses search-shaped calls inside an indexed repository with a reason naming the missing pinned path, rather than silently falling back to the shared copies.
When it is unset or empty, resolution is unchanged: the installed path first, then the repository path.
That order exists because of a real failure: an earlier version resolved only the repository path, so checking out a branch without the script made the spawn fail, and the guard then allowed every raw search with nothing logged.
Install the checker to the stable path with `install -m 0755 bin/fm-codegraph-pretool-check.sh ~/.local/bin/fm-codegraph-pretool-check.sh`, and re-run that command whenever this repository's copy changes.
The installed copy is an unversioned artifact: nothing detects it drifting behind the repository copy, so treat the re-install as part of changing the script rather than a later step.
