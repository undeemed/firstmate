# Fleet tiers: hierarchy, sweep, and consult

Reference for the strict three-tier fleet model.
`AGENTS.md` section 1 ("Fleet hierarchy") owns the operating contract; this doc is the mechanism and policy reference it points to.
Mechanics (exact flags, paths) live in each script's own header; this doc does not restate them.

## The three tiers

```
firstmate  ->  one persistent secondmate per project repo  ->  disposable 3rd mates (crewmates)
```

- **firstmate** controls every repo but delegates all project work down.
  It spawns a crewmate directly for exactly one thing: work on the firstmate repo itself, its own control plane, which is not a project.
- **secondmate**: one persistent supervisor per project repo, created on demand the first time work is routed to that repo.
  A secondmate is a firstmate in its own isolated home; it spawns, supervises, and sweeps its own 3rd mates with the identical lifecycle.
  Secondmates never coordinate with one another - each is tied to its one repo and answers only to the main firstmate.
- **3rd mates** (crewmates) are disposable, one per task, and swept continuously (see Sweep below).
  Same-repo 3rd mates DO coordinate peer-to-peer through herdr (the peer-coordination note in every brief, `AGENTS.md` section 11).

The one delivery-mode exception is `local-only`: the main firstmate still handles it directly rather than routing it to a secondmate (`AGENTS.md` section 7 delivery modes).
This is a delivery-mode routing exception, orthogonal to the structural firstmate-repo carve-out; both are places firstmate acts without a secondmate.

## Per-tier model policy

The model each tier runs on, and the codex model it consults, are OWNED by their config and scripts - not by an authoritative table here, which would drift.
This section records the intended policy and names the owner of each value:

| Tier | Executing model | Owner | Consults codex |
| --- | --- | --- | --- |
| firstmate | fable | firstmate's own launch model (captain-side) | `gpt-5.6-sol` |
| secondmate | opus-4.8/xhigh fast (fable when the domain is complex) | `config/secondmate-harness` | `gpt-5.6-sol` (default), `gpt-5.6-terra` to escalate |
| 3rd mate | opus-4.8/xhigh fast (codex `gpt-5.6-luna` for the simplest tasks) | `config/crew-dispatch.json` | `gpt-5.6-terra` |

Conventions: "ultra" means maximum reasoning, i.e. `xhigh` effort; every executing (non-fable) Claude agent runs fast mode (a global harness setting).
The consult-model column is owned by `bin/fm-consult.sh` (its header is the single source of the tier -> codex-model map).
`config/crew-dispatch.json`, `config/secondmate-harness`, and `config/crew-harness` are the local, gitignored owners of the executing-model choices; `docs/configuration.md` owns their schemas.

## Sweep: `bin/fm-sweep.sh`

3rd mates are meant to be reaped continuously so a human never closes a finished pane by hand.
`bin/fm-sweep.sh` is the reaper. It runs from two places, per home (main firstmate and every secondmate sweep their own children):

- session start, when the session holds the fleet lock (`bin/fm-session-start.sh`, reported as `SWEEP:` lines);
- every supervision cycle on a bounded cadence (`bin/fm-watch.sh`, `FM_SWEEP_INTERVAL`, default 300s), launched detached so it never adds latency to wake handling.

Scope is this home's own children only: its `state/<id>.meta` tasks with `kind=ship`/`kind=scout`, and its `projects/*` pool worktrees.
`kind=secondmate` is never swept (secondmates are persistent by design).

Safety is delegated to the single owners; the sweep reimplements no landed-work check:

- Each meta-tracked reap candidate is torn down with `bin/fm-teardown.sh <id>` (never `--force`), which owns the full landed-work definition and REFUSES anything not landed - a refusal means "leave it, report why".
  Teardown also closes the backend endpoint, so a done+landed crew's bare-shell/agentless pane (e.g. a herdr pane left after the agent `/exit`ed, which otherwise keeps tripping the watcher's stale detection) is closed rather than left to churn.
- Orphaned pool worktrees are reclaimed with `treehouse prune --yes` per pool (scoped by working directory; never `--all`/`--global`).
  treehouse prune is the single owner of pool landed-safety: it removes a worktree only when treehouse manages it, no owner reservation or running process is using it, it has no uncommitted changes, and its HEAD is already merged into the default branch.
  That "no running process / no reservation" gate is what makes it safe against a just-spawned crew and a live crew's worktree.

Reap gate (cheap first; teardown is the final safety net either way):

1. `fm_backend_agent_alive` (`bin/fm-backend.sh`) reads the endpoint for a live harness-agent PROCESS - the same confident-dead bar the session-start secondmate liveness sweep requires, not the pane-presence-only `fm_backend_target_exists` (which reports a transient backend outage as gone).
   `dead` (confident: a bare shell, or a structurally-gone/no-agent pane) -> candidate, so a crashed/exited crew whose lease would otherwise leak is reaped.
2. `alive` (a real agent process): read `bin/fm-crew-state.sh`; `state == done` -> candidate (idle-done); any other alive state - working, parked, blocked, failed, or a just-spawned `unknown` - is LEFT.
3. `unknown` (ambiguous, unreadable, a transient backend outage, or a backend whose agent classifier is unverified - zellij, orca, cmux) -> ALWAYS LEFT, never a candidate: the classifier's contract forbids licensing an action from `unknown` alone, and a meta with no recorded target is treated the same way.

Leaving alive non-done crews is what guarantees a live working agent is never reaped and a just-spawned crew is never mistaken for an orphan.

A candidate that still has an armed `state/<id>.check.sh` (firstmate's merged-PR poll) is LEFT this sweep, whichever path made it a candidate: an armed check means the task deliberately awaits an external event - a PR-ready ship task awaiting the captain's merge - so the sweep preserves its meta (`pr=`, `pr_head=`, X-mode links), worktree, and poll, and the watcher's check pass fires the normal durable merge wake.
The poll has an arming window the check gate alone cannot see: in PR-based ship modes (`mode=no-mistakes` or `mode=direct-PR`) the crew reports done (checks green) before firstmate has handled that wake with `bin/fm-pr-check.sh`, which is what arms `check.sh` and records `pr=`.
So a PR-based-mode ship candidate with neither an armed `check.sh` nor a recorded `pr=` is LEFT too, on both candidate paths; once `pr=` is recorded, `fm-teardown`'s landed-work check owns the decision, and local-only ship tasks and scouts have no PR and are unaffected.
A swept teardown does none of the normal post-teardown bookkeeping; the `SWEEP:` digest lines are the cue to reconcile the backlog and relay a not-yet-relayed outcome (the `bootstrap-diagnostics` skill owns the per-line response).

The firstmate repo's OWN pool (where the primary and project-less firstmate-repo crews live) is deliberately out of scope for the automated orphan prune, so the sweep never prunes the pool the running primary lives in; meta-tracked firstmate-repo crews are still reaped by the teardown path, and firstmate-repo-pool orphans are left to manual `treehouse prune`.

Properties: lock-gated by its callers (session start runs it only when locked; the watcher is a per-home singleton), best-effort and non-fatal, idempotent, fast, quiet when there is nothing to reap, and guarded by its own lock so overlapping runs are a no-op.

## Consult: `bin/fm-consult.sh`

When a tier is stuck on a hard call, it may consult codex for a second opinion:

```
bin/fm-consult.sh [--terra] <firstmate|secondmate|crewmate> "<question>"
```

It maps the tier to its codex model (owned by the script header), runs `codex exec` non-interactively in a read-only sandbox at `xhigh` reasoning, and prints codex's answer to stdout.
`--terra` escalates the secondmate tier from `gpt-5.6-sol` to `gpt-5.6-terra`; it is ignored for the other tiers.

It is advisory and never blocks: if codex is missing, unauthenticated, or quota-exhausted, it prints one clear line and exits non-zero, and the caller proceeds on its own judgment.
It never sends codex's `/usage` command or otherwise triggers/redeems a usage reset (a paid captain resource); a consult uses ordinary quota.
