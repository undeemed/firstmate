---
name: gnhf
description: >-
  Enter overnight autonomous-work mode when the captain invokes /gnhf, says "good night", says they are going to sleep and wants the fleet to keep working, or asks firstmate to run bounded overnight coding.
  It enters the existing away-mode lifecycle through the /afk scripts, records a durable captain-consented overnight-work authorization, lets firstmate drive bounded `gnhf` orchestrator runs against allowlisted repos overnight under unchanged approval authority, and leaves a morning catch-up through the existing return gate.
user-invocable: true
metadata:
  internal: true
---

# gnhf

Overnight autonomous work. The captain invokes `/gnhf [optional focus]` before sleeping.
This skill composes the existing away-mode lifecycle; it never reimplements it.
It adds exactly one thing on top of away mode: an explicit, durable, captain-consented authorization to process backlog work overnight through the `gnhf` loop orchestrator.

## What it does

1. **Acknowledge in one line.**
   Example: "Good night, Captain; away mode on, overnight gnhf work authorized against allowlisted repos, review-ready branches waiting in the morning."

2. **Enter away mode strictly through the existing /afk lifecycle.**
   Follow [`../afk/SKILL.md`](../afk/SKILL.md) exactly for entry: it owns `bin/fm-afk-launch.sh` (durable `state/.afk`, terminal record, rollback), the daemon path per harness, and the acknowledgement contract.
   Do not duplicate or reorder its steps here.

3. **Write the durable overnight authorization marker.**
   After away mode is active, write `state/.gnhf-overnight` with a timestamp and the captain's focus line (or `general backlog` when no focus was given).
   This marker is the authorization `bin/fm-gnhf-run.sh` requires; without it every run refuses.
   It is session-scoped like the other away-mode artifacts and is cleared on a clean morning return.

4. **Overnight: pick bounded work and drive gnhf through the single owner.**
   While away, firstmate runs only **explicitly chosen** backlog work - repos and objectives the captain named or firstmate selects deliberately - each as a bounded `gnhf` loop through `bin/fm-gnhf-run.sh` only.
   There is no automatic `state/.wake-queue` replay (see Settled decisions).
   Launch it through the harness's tracked-background mechanism (claude background bash, a herdr pane, a detached tmux session) - the same primitives away mode uses.
   Never launch `gnhf` directly and never with `nohup ... &`.
   Each run lands work as a git branch inside an isolated worktree (`<repo>-gnhf-worktrees/`); the captain's checkout is never touched.

## Approval authority is unchanged

`/gnhf` authorizes overnight *processing* of already-in-scope work; it never widens who approves what.
All gnhf output stays as unmerged branches/worktrees under the exact configured approval authority and exceptions from `AGENTS.md` section 7.
Nothing is merged, pushed, or captain-decided autonomously.
`bin/fm-gnhf-run.sh` refuses `--push` in code, so overnight work cannot leave the machine.

## The single owner: bin/fm-gnhf-run.sh

`bin/fm-gnhf-run.sh --repo <path> [options] "<objective>"` is the only supported way to invoke gnhf.
It enforces the whole safety envelope in code, not prose:

- always exports `GNHF_TELEMETRY=0`;
- rejects `--push` and `--current-branch`; always adds `--worktree`;
- always caps the run: `--max-iterations` (default 10) and `--max-tokens` (default 2000000);
- refuses any repo outside the allowlisted root (`FM_GNHF_REPOS_ROOT`, default `$HOME/Dev`), and always refuses `~/oss-fleet` and firstmate's own home;
- refuses a dirty target working tree;
- requires `state/.gnhf-overnight` to exist (the step-3 authorization);
- captures output to a size-bounded, rotating log under `state/gnhf/` and appends a bounded outcome block to `state/gnhf-overnight-report.md`.

Use `bin/fm-gnhf-run.sh --repo <path> --dry-run "<objective>"` to validate the gates and print the resolved command without running anything.

## INTEGRATION-POINT: gnhf (kunchenguid/gnhf) v0.1.44

The external tool is `gnhf` v0.1.44 (npm, MIT, Node>=20): a Ralph-style loop that validates clean git, creates/resumes a worktree, drives a coding agent per iteration, commits successes, `git reset --hard`s failures, and aborts after 3 consecutive failures or a configured cap.

- **SETUP / verify (once per host):** `npm install -g gnhf@0.1.44` (pinned).
  Confirm `node --version` is >= 20 and `gnhf --version` prints `0.1.44`.
  `bin/fm-gnhf-run.sh` re-checks Node>=20 and the pinned version at launch and refuses on mismatch (override only with `FM_GNHF_ALLOW_VERSION_MISMATCH=1`).
- **RUN (overnight):** `bin/fm-gnhf-run.sh --repo <allowlisted-repo> --max-iterations <n> --max-tokens <n> "<bounded objective>"`, launched as a tracked background job (never `nohup &`).
  Default agent is `claude`; pass `--agent <name>` for another native gnhf agent.
- **TEARDOWN / report:** each run appends its outcome to `state/gnhf-overnight-report.md`; gnhf preserves worktrees that have commits and prints their paths.

## How to exit: morning catch-up through the existing return gate

No `/back`. The first genuine (unprefixed, non-`/gnhf`) captain message on waking is the return signal, exactly as in [`../afk/SKILL.md`](../afk/SKILL.md).

1. Run `bin/fm-afk-return.sh` before acting on that message.
   It owns correct-ordered daemon shutdown, durable wake draining, escalation/wedge evidence, and the fail-closed catch-up gate; remediate or durably reclassify any reported `blocked:` event, then run `bin/fm-afk-return.sh check`.
2. As part of the same catch-up, read `state/gnhf-overnight-report.md` and summarize each overnight gnhf run for the captain: repo, branch/worktree, outcome, and the review command, so the morning surface carries the night's results alongside the gate output.
3. On a clean `check`, clear `state/.gnhf-overnight`.
4. Do not answer a Bearings request or perform any other ordinary captain work until `bin/fm-afk-return.sh check` exits successfully.

## Defaults (all overridable)

These are the shipped defaults; override per run via flags, or per host via env.

- `--max-tokens` cap: `2000000`.
  Override with `--max-tokens <n>` or the `FM_GNHF_MAX_TOKENS` env.
- `--max-iterations` cap: `10`.
  Override with `--max-iterations <n>`.
- `--prevent-sleep`: `off` (this is a headless host; system-sleep inhibition is not needed).
  Override with `--prevent-sleep on`.
- Allowlist root: `$HOME/Dev`, via the `FM_GNHF_REPOS_ROOT` env.
  A target repo must resolve under this root; `~/oss-fleet` and firstmate's own home are always refused regardless.
- `--agent`: `claude`.
  Override with `--agent <name>`.

## Settled decisions

These design points are decided, not open:

1. **Overnight queue source is explicit backlog only.**
   `/gnhf` processes only repos and objectives passed explicitly to `bin/fm-gnhf-run.sh`.
   There is deliberately no automatic `state/.wake-queue` replay: replaying the durable wake queue risks re-executing superseded or already-handled items overnight.
   Any future replay support must be an explicit, clearly-dangerous opt-in flag that stays off by default.
2. **`bin/fm-afk-return.sh` stays untouched.**
   The overnight report is surfaced at skill level: the morning return step reads `state/gnhf-overnight-report.md` alongside the gate output.
   *Deferred: native afk gate-level surfacing* - teaching `bin/fm-afk-return.sh` to emit the report itself is intentionally not done here, to keep that critical script's contract unchanged.
3. **Caps ship with defaults and are overridable** - see Defaults above.
4. **Allowlist root defaults to `$HOME/Dev`** via `FM_GNHF_REPOS_ROOT` - see Defaults above.
