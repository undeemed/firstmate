# Pilot

Pilot is a third-party Go daemon from [qf-studio/pilot](https://github.com/qf-studio/pilot) that turns a labelled GitHub issue into a pull request.
It polls each configured repository for issues carrying the `pilot` label, plans and writes the change with Claude Code, runs the repository's own build and test commands, and opens a pull request linked to the issue.
It is optional and entirely separate from this repository's own agent supervision: nothing here starts, stops, or reads Pilot, and a machine without it behaves exactly as before.

This page covers the operating facts an owner of a running instance needs.
Pilot's own README and `--help` output own its full configuration reference and command surface.

## Triggering work

Label a GitHub issue `pilot` in any repository listed in the local Pilot configuration.
The daemon claims the issue with `pilot-in-progress`, branches as `pilot/GH-<number>`, implements, validates, opens the pull request, and marks the issue `pilot-done`.
Nothing starts without that label, so an unlabelled issue is never touched.

Write the issue body as a task: what to do, the acceptance criteria, and any constraint that matters.
Pilot suits bug fixes, small features, refactors, tests, documentation, and dependency updates.
It does not suit large architectural changes, security-critical code, or work needing human judgement.

The label names come from Pilot's own constants (`pilot`, `pilot-in-progress`, `pilot-done`, and further `pilot-*` state labels), not from the slash-separated names its README shows.
Pilot creates any missing state label on demand, so only `pilot` has to exist before the first run.

## Merging stays manual

The recommended posture is the `prod` autopilot environment with `require_approval: true` and no approval channel wired.
Pilot then waits for CI, parks the pull request, and never merges anything: a human reviews and merges by hand.

Pilot's startup banner reports that posture as an `approval-misconfig` problem and warns that "all PRs will deadlock".
That warning is expected here and is not a failure - it is Pilot describing the deliberate absence of an automated approval path.
Pilot also posts one explanatory comment on a parked pull request, which can be ignored or deleted.

## Running it

The daemon runs as a `systemd --user` unit:

```sh
systemctl --user status pilot        # is it running
systemctl --user stop pilot          # stop until the next login or start
systemctl --user disable --now pilot # stop and keep it stopped across reboots
journalctl --user-unit pilot -f      # follow what it is doing
```

`sequential` execution with `wait_for_merge: true` keeps it to one task at a time, which matters on a shared box: a parallel Pilot plus the fleet's own workers can exhaust the CPU.
A `MemoryMax` on the unit bounds the daemon and everything it spawns.
An idle daemon watching nine repositories holds roughly 75 MB of resident memory.

In this mode Pilot waits up to one hour for a human merge before moving to the next labelled issue.
That wait is fixed inside the poller in release 2.273.1, so `orchestrator.execution.pr_timeout` does not change it.

## Configuration

The daemon reads `~/.pilot/config.yaml`; `pilot config validate` checks it and `pilot config path` prints the resolved location.
[`../configs/pilot/config.example.yaml`](../configs/pilot/config.example.yaml) is a copyable starting point that matches the posture described here.

Two structural points are worth stating, because the README's single-repository example hides them:

- One daemon serves many repositories.
  `adapters.github.repo` is the default repository and must exist for polling to start at all, and every entry under `projects:` with an `owner`/`repo` pair gets its own poller and autopilot controller.
- Each project needs its own checkout under a Pilot-owned directory such as `~/.pilot/projects/<name>`.
  Never point a project at a working copy something else is using: Pilot switches branches and creates worktrees in it.

Set `default_branch` per project where it is not `main`.
Leave the global `quality:` block out unless every repository shares one toolchain, because Pilot otherwise auto-detects a build and test gate per project instead of forcing one repository's commands onto another.

The GitHub credential is supplied to the process, never written into the configuration file: the unit exports `GITHUB_TOKEN` from `gh auth token` at start, and the file only refers to `${GITHUB_TOKEN}`.
A repository the credential cannot push to cannot be driven by Pilot, since it has to push a branch there; leave such a repository out of `projects:`.

## Cost

Pilot bills to its own Claude Code account, which is not the account backing this repository's agent runtimes.
A typical task costs roughly $0.50 to $2.00 of model usage, and a labelled issue is the only thing that spends anything.
`pilot metrics summary` and `pilot usage summary` report actual spend, and `budget:` in the configuration can cap it.
