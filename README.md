<h1 align="center">firstmate</h1>
<p align="center">
  <a
    href="https://img.shields.io/badge/platform-macOS%20%7C%20Linux-blue?style=flat-square"
    ><img
      alt="Platform"
      src="https://img.shields.io/badge/platform-macOS%20%7C%20Linux-blue?style=flat-square"
  /></a>
  <a href="https://x.com/kunchenguid"
    ><img
      alt="X"
      src="https://img.shields.io/badge/X-@kunchenguid-black?style=flat-square"
  /></a>
  <a href="https://discord.gg/Wsy2NpnZDu"
    ><img
      alt="Discord"
      src="https://img.shields.io/discord/1439901831038763092?style=flat-square&label=discord"
  /></a>
</p>

<h3 align="center">Talk to one agent. Ship with a crew.</h3>

<p align="center">
  <img alt="firstmate - talk to one agent, ship with a crew" src="assets/banner.png" width="100%" />
</p>

## What it is

You can run one coding agent easily.
But the moment you want three project tasks done in parallel - fixes, investigations, plans, audits - you become a tab-juggler: babysitting sessions, copy-pasting context between repos, forgetting which terminal had the failing test.

firstmate flips the model.
You talk to a single agent - the first mate - and it runs the crew for you: spawning autonomous agents in a visible session backend, giving each a clean git worktree, supervising them to completion, and handing you finished PRs, approved local merges, or standalone investigation reports.
Project work flows through a strict three-tier hierarchy: each project repo gets one persistent secondmate on demand - a domain supervisor that is still an ordinary direct report, but runs from its own isolated firstmate home - which spawns, supervises, and sweeps the disposable crewmates that do the work.
There is no app to install; the orchestrator is `AGENTS.md`, bundled firstmate skills, and helper scripts that any terminal coding agent can follow.

This is not an agent harness. This is not a single skill. This is not a CLI.
This is.. a directory that turns any agent into your firstmate, and you the captain.

## Features

- **One liaison** - you talk only to the first mate; it dispatches, supervises, escalates only real decisions, and reports plain outcomes.
- **A visible crew** - every crewmate works in its own herdr tab (this fork's configured backend), tmux window, zellij tab, cmux workspace, or Orca terminal you can watch or type into; the first mate reconciles.
- **Disposable worktrees** - each task runs in a clean [treehouse](https://github.com/kunchenguid/treehouse) git worktree, or an Orca-managed worktree when `backend=orca`, so parallel work on one repo never collides.
- **Two task shapes** - ship tasks deliver a change; scout tasks investigate, plan, reproduce, or audit and leave a report.
- **Explicit project modes** - each project ships via `no-mistakes`, `direct-PR`, or `local-only`, with an optional `+yolo` autonomy flag.
- **A three-tier fleet** - project work routes through one persistent secondmate per project repo, created on demand: domain supervisors that run from isolated firstmate homes with their own `FM_HOME`, state, projects, and session lock, supervising project clones or a project-less firstmate-repo domain, kept on the primary firstmate version by guarded local fast-forwards and checked for live agent processes at session start.
- **Event-driven, zero-token supervision** - a bash watcher sleeps on the fleet, wakes the first mate only when something needs you, and constantly sweeps landed or dead crewmates and orphaned worktrees in the background; verified primary harnesses also get a turn-end backstop that blocks or follows up on a blind stop when work is in flight and supervision is not live.
- **Optional X mode** - opt in with one local `.env` token so firstmate can answer your public `@myfirstmate` mentions, act on normal reversible mention requests through the same lifecycle as chat requests, acknowledge spawned work, and post up to three public-safe completion follow-ups within seven days for genuine milestones and the final outcome without changing non-X behavior; dry-run preview records would-be replies and dismissals locally before go-live.
- **Guarded by construction** - the first mate is read-only over your projects outside guarded clone refreshes, safe branch pruning, and approved `local-only` fast-forward merges; crewmates make every project change behind your merge approval.
- **Restart-proof** - all state lives on disk and in the active session backend (tmux by hard default, herdr or cmux when selected or auto-detected, zellij/orca when explicitly selected); kill the session anytime and the next one reconciles, including confirmed-dead secondmate agents, and carries on.

Full detail on every feature lives in [docs/architecture.md](docs/architecture.md).

## Quick Start

This fork runs its fleet on the [herdr](https://herdr.dev) backend, an agent-native terminal multiplexer with per-pane agent-state detection, verified end to end in [docs/herdr-backend.md](docs/herdr-backend.md).

### Requirements

- A verified agent harness: Claude Code, Grok, Pi, Codex, or OpenCode.
- Git and the GitHub CLI, authenticated through `gh auth login`.
- `herdr` (protocol 14 or newer) with `jq`, this fork's configured runtime backend.
- tmux, still required by the toolchain check and the code-level default backend.

The first mate detects and offers to install everything else.

### Recommended harnesses

**Claude Code, Grok, and Pi are equal co-primary recommendations** for running the primary firstmate session.
Claude Code and Grok use background-notify wake cycles; Pi uses its tracked primary watcher extension.
All three have verified turn-end guard paths when launched with their documented setup.
Pick whichever one matches your subscription and workflow.

Codex and OpenCode are also verified and supported as primary harnesses; Codex uses bounded foreground checkpoints, and OpenCode uses a TUI plugin, so both carry more harness-specific supervision tradeoffs than the three co-primaries.

### Install and launch

```sh
gh auth login
git clone https://github.com/undeemed/firstmate
cd firstmate
mkdir -p config && echo herdr > config/backend   # pin this fork's runtime backend (local, gitignored)
```

Then launch one of the co-primary harnesses; AGENTS.md takes over from there:

**Claude Code**

```sh
claude
```

**Grok**

```sh
grok --trust
```

**Pi**

```sh
pi
```

For Grok, `--trust` is needed once per clone so project hooks and the turn-end guard load; `/hooks-trust` inside Grok works too.
For Pi, approve the project trust prompt once per clone on first launch so both tracked `.pi/extensions/*.ts` files auto-load.

Session start is one command: the first mate opens every session by running `bin/fm-session-start.sh`, which locks the home, runs bootstrap diagnostics, drains queued wakes, and prints the full fleet digest.
Approve the tool installs bootstrap proposes on the first run; nothing is installed without your consent.

### Add a project

Just ask in chat - "add my github project xyz" - and the first mate clones it under `projects/`, registers it, and initializes its delivery gate.
Under the hood that is three steps you can also run yourself:

```sh
git clone <url> projects/<name>
mkdir -p data && echo '- <name> [no-mistakes] - <one line> (added <date>)' >> data/projects.md
cd projects/<name> && no-mistakes init && no-mistakes doctor
```

`no-mistakes init` applies only to the default `no-mistakes` delivery mode; `direct-PR` and `local-only` projects skip it.

### Talk to it

```sh
> ahoy! look at my github project xyz, then fix the flaky login test and add dark mode

# firstmate checks its toolchain (asking your consent before installing anything),
# clones the project under projects/, and spawns two crewmates in the active backend
# fm-fix-login-k3 and fm-dark-mode-p7.
# Minutes later:

  PR ready for review, captain: https://github.com/you/xyz/pull/42
  (fix flaky login test - risk: low - CI green)

> alright merge it
```

### Watch the crew

Each firstmate home gets its own herdr workspace (the primary uses `firstmate`) with one `fm-<id>` tab per task.
Attach to your herdr session and switch to that workspace to watch every task, or skip attaching: `bin/fm-peek.sh fm-<id>` reads a task's pane and `FM_HOME=<firstmate-home> bin/fm-send.sh fm-<id> "<text>"` steers it (`fm-send` refuses to guess a target without an explicit `FM_HOME`).

### Resume after a restart

Restart is a non-event.
Kill your harness session anytime; the next launch runs the same `bin/fm-session-start.sh` digest, which reconciles live tasks, queued wakes, and the backlog from disk, and the first mate carries on where it left off.
Stored herdr pane ids even survive a herdr server restart within the same named session and remain valid peek/send targets, though a restored task tab comes back agent-less - a subsequent respawn closes and replaces it automatically, with no manual cleanup needed.

### More backends

Setup guides for tmux (the code-level default) and the other backends (zellij, Orca, cmux) are linked in [Documentation](#documentation) below.

## How It Works

```
            you (the captain)
                  │  chat: requests, decisions, "merge it"
                  ▼
 ┌─────────────────────────────────────┐
 │ firstmate            (this repo)    │
 │ reads projects/ + firstmate routes  │
 │ writes guarded backlog/briefs/state │
 └──┬──────────────┬───────────────┬───┘
    │ backend sends / status files │
    ▼              ▼               ▼
 ┌────────┐   ┌────────┐      ┌────────┐
 │fm-task1│   │fm-task2│  ... │fm-taskN│   herdr tabs (this fork), tmux windows, zellij tabs, cmux workspaces, or Orca terminals
 │crewmate│   │crewmate│      │crewmate│   one autonomous agent each
 └───┬────┘   └───┬────┘      └───┬────┘
     ▼            ▼               ▼
  treehouse worktree, Orca worktree, or isolated secondmate home
     │
     ├─ ship: project mode ► PR/local merge ► teardown
     │
     └─ scout: report at data/<id>/report.md ► relay findings ► teardown
```

You chat with the first mate.
It routes each request down to a crewmate in its own session endpoint and git worktree, supervises the fleet with a zero-token event-driven watcher, and brings you finished PRs, approved local merges, or investigation reports.
Project work routes through one persistent secondmate per project repo in a strict three-tier hierarchy ([docs/fleet-tiers.md](docs/fleet-tiers.md)), dispatch profiles let you steer which harness handles which task, and an opt-in X mode lets the same fleet answer public mentions.
`codex-app` is not a runtime backend yet; [docs/codex-app-backend.md](docs/codex-app-backend.md) owns the Codex App boundary.

Full architecture - the supervision engine, worktree isolation, secondmates, dispatch profiles, project modes, optional X mode, fleet sync, and self-update - is in [docs/architecture.md](docs/architecture.md).

## Built-in skills

Firstmate ships these user-invocable built-in skills.
Claude and grok use the slash form shown here; codex uses the same names with `$`, such as `$afk`.

| Skill              | What it does                                                                                                                                  |
| ------------------ | -------------------------------------------------------------------------------------------------------------------------------------------- |
| `/afk`             | Enter away-mode supervision: the sub-supervisor self-handles routine wakes in bash, escalates captain-relevant events and bounded declared-external-wait rechecks as batched digests, and actively alerts if delivery wedges while you step away |
| `/bearings`        | Generate a "pick up where I left off" status report from the read-only fleet snapshot - backlog, per-task crew state, open PRs, scout reports, pending decisions, and date-gated queued work - written to a dated file in `data/` and surfaced concisely in chat; read-mostly, mutates no task state |
| `/updatefirstmate` | Self-update the running firstmate and its secondmates to the latest from origin with fast-forward-only pulls, then re-read instructions and nudge secondmates |
| `/stow`            | Sweep the session for uncaptured durable knowledge, route each finding to its disk home per AGENTS.md, file undone next steps to the backlog, and report what is now safe to reset |

Agent-only reference skills live under `.agents/skills/` and are loaded by firstmate at the trigger points named in [`AGENTS.md`](AGENTS.md).

### Two-tier skill layout

Firstmate's skills live in two separate places with different audiences:

- `.agents/skills/` - agent-loaded skills (this section's table, plus firstmate's agent-only reference skills). Every one of these assumes a live firstmate home and is meaningless, or actively misleading, installed anywhere else, so each carries `metadata.internal: true` in its frontmatter. That flag hides them from installer discovery (tools like the [skills.sh](https://skills.sh) `npx skills add` installer) without affecting how firstmate itself loads them - frontmatter metadata is inert to the agent's own skill loader.
- `skills/` - public, installer-facing skills meant to be installed standalone into any project, independent of firstmate.
  Each one is a self-contained skill with no dependency on firstmate's paths, tools, or vocabulary.
  Today that is `skills/stow`, a generic session-knowledge-sweep skill that routes findings by explicit instruction first, then existing local conventions, then a private `.stow-notes.md` fallback in the current directory, and closes with a resume pointer for the next session.
  It intentionally shares no code with the firstmate-internal `.agents/skills/stow` it is named after, so the two can evolve independently.

## Documentation

- [docs/architecture.md](docs/architecture.md) - how the crew, supervision, worktrees, secondmates, and project modes work.
- [docs/fleet-tiers.md](docs/fleet-tiers.md) - the strict three-tier fleet hierarchy, the constant 3rd-mate sweep, and the per-tier codex consult gate.
- [docs/configuration.md](docs/configuration.md) - environment variables, `FM_HOME`, runtime backend selection, optional X mode, the files you set, and harness support.
- [docs/herdr-backend.md](docs/herdr-backend.md) - setup guide for this fork's herdr backend, plus its verification notes and known gaps.
- [docs/tmux-backend.md](docs/tmux-backend.md) - setup guide for the tmux reference backend (the code-level default): prerequisites, attaching, and watching crew windows.
- [docs/wedge-alarm.md](docs/wedge-alarm.md) - configure the active alert for a wedged away-mode escalation delivery.
- [docs/zellij-backend.md](docs/zellij-backend.md) - setup guide for the experimental zellij backend, plus its verification notes and known gaps.
- [docs/orca-backend.md](docs/orca-backend.md) - setup guide for the experimental Orca backend, plus its lifecycle notes and known gaps.
- [docs/cmux-backend.md](docs/cmux-backend.md) - setup guide for the experimental cmux backend, plus its verification notes and known gaps.
- [docs/codex-app-backend.md](docs/codex-app-backend.md) - Codex App backend boundary, evidence, and rollout contract.
- [docs/turnend-guard.md](docs/turnend-guard.md) - the primary session's structural "no turn ends blind" backstop: verified per-harness hook mechanisms, scoping, loop safety, and fail-open tradeoffs.
- [docs/supervision-protocols/](docs/supervision-protocols/) - rendered primary-harness watcher protocols for Claude, Codex, OpenCode, Pi, Grok, and unknown harness fallback.
- [docs/scripts.md](docs/scripts.md) - the `bin/` toolbelt reference.
- [`AGENTS.md`](AGENTS.md) - firstmate's full operating manual for the orchestrator agent.
- [CONTRIBUTING.md](CONTRIBUTING.md) - how to contribute, including the dev/test commands.

## Contributing

Contributions are welcome - see [CONTRIBUTING.md](CONTRIBUTING.md) for the workflow, repo conventions, and how to run the tests.

## License

MIT - see [LICENSE](LICENSE).
