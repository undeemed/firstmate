# omp (Oh My Pi)

omp is a Pi fork distributed as the npm package `@oh-my-pi/pi-coding-agent` and executed by bun.
It is a CREWMATE, SCOUT, and SECONDMATE adapter.
Liveness was verified on 2026-08-15 with omp 17.3.4, and the half-open composer read plus Herdr send acknowledgement on 2026-08-21 with omp 17.3.5 and Herdr 0.8.0.
Every other fact below is STATIC EVIDENCE read from the installed binary's `--help`, its shipped TypeScript declarations, and its bundle, not from a live supervised session.
Treat the dialog row, and composer and submission behavior on any backend other than Herdr, as UNVERIFIED until a real omp crewmate has been supervised end to end.

## Operating facts

| Fact | Value |
|---|---|
| Binary | `omp` on `PATH`, a bun launcher for `@oh-my-pi/pi-coding-agent/dist/cli.js`. Measured live: the pane title reads `bun` and only the foreground `comm` reads `omp`, so supervision attributes an omp pane from the foreground name alone. |
| Launch | Positional prompt, the Pi shape, so the instructions ride the launch command. Keep them as ONE positional argument. |
| Autonomy | `--auto-approve`, with `--approval-mode yolo` as the equivalent long form. |
| Busy state | The Firstmate-owned extension's `agent_start` marks busy and `agent_end` marks idle. omp has NO `agent_settled`, so idle requires all three of its own settle signals to agree: `event.willContinue` false, `ctx.isIdle()` true, and `ctx.hasPendingMessages()` false. Known failure mode: if `ctx.isIdle()` is present but returns false inside `agent_end`, the handler returns early and no idle record is ever written, and because `../../../bin/fm-busy-lib.sh` has no age expiry the task keeps classifying `busy omp-ext` until control, recovery, or cleanup writes another record. Confirm that `agent_end` timing on the first supervised omp crewmate. |
| Turn-end | The same extension's `turn_end`, loaded with `-e` from `state/<id>.omp-ext.ts` outside the worktree. |
| Exit command | `/exit`, or `/quit` (alias `/q`); both resolve to the same handler. `Ctrl-D` is the `app.exit` keybind. |
| Interrupt | Single Escape (`app.interrupt`, default key `escape`). |
| Skill invocation | `/skill:<skill>`, for example `/skill:no-mistakes`. The `skill:` prefix is part of the registered command name, so the bare Claude form is not a registered omp command; use natural language when the exact form is uncertain. |
| Environment marker | `OMPCODE=1`, exported to children ALONGSIDE `CLAUDECODE=1`; the router's Detection section owns the precedence this forces. omp does NOT set `PI_CODING_AGENT`, so there is no collision with the Pi marker. |
| Model flag | `--model <model>`. |
| Effort flag | `--thinking <low\|medium\|high\|xhigh\|max>`, verified 2026-08-15 against installed omp 17.3.4 `--help`. The flag also accepts `off\|minimal\|auto`, which sit outside the shared vocabulary and stay unreachable rather than remapped. |
| Model discovery | Run `omp models`, or open the running session's `/model` picker. `--model` fuzzy-matches, so quote the listing's exact identifier rather than an abbreviation. |
| Resume | `-c` / `--continue` for the previous session, `-r` / `--resume <id-prefix\|path>` for a specific one; bare `-r` opens a picker. |
| Trust dialog | None found. omp 17.3.4 ships no `trust.json` store and none exists under `~/.omp/agent/`, unlike Pi. This is a bundle-level negative, not an observed first run, and the launch path does not depend on it because the extension is loaded from `state/` by absolute path. |

`--extension`/`-e` loads an extension by explicit path even when `--no-extensions` disables discovery, so the Firstmate extension survives a discovery-disabled profile.

## Primary integration

The Pi primary supervision pair is ported as the tracked `.omp/extensions/fm-primary-turnend-guard.ts` and `.omp/extensions/fm-primary-omp-watch.ts`.
Because omp emits no `agent_settled`, the ported guard fires on `agent_end` only when omp's settle triple agrees the run is idle, the same triple the busy-state row above uses.
The PreToolUse-equivalent watcher-arm seatbelt returns `{block: true}` from the guard extension's `tool_call` event.
The model arms through the `fm_watch_arm_omp` tool, and `../../../docs/supervision-protocols/omp.md` owns the tool result and clean-exit fallback.

`../../../bin/fm-spawn.sh --secondmate` on omp launches with both extensions via `-e`, `../../../bin/fm-supervision-instructions.sh` maps omp to that protocol, and `../../../bin/fm-session-start.sh` reports when a live omp primary has not loaded both.
`tests/fm-omp-turnend-guard.test.sh`, `tests/fm-omp-watch-extension.test.sh`, and `tests/fm-omp-harness.test.sh` cover the port, but no live supervised omp secondmate has run yet, so the supervision port remains STATIC EVIDENCE.
