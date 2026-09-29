# Secondmate parent channel: live verification

Maintainer-verification record for the guarantee in [`secondmate-parent-channel.md`](../secondmate-parent-channel.md): a secondmate's own watcher is woken by its child's terminal line while the parent channel receives no child-outcome line, and the PR-ready line, the captain hold, and its answer still reach the parent from the scripts that record them, each waking the parent watcher.
Refresh it by rerunning the fixture below after changing any publisher named in `bin/fm-parent-channel-lib.sh`.

## What was run

Date: 2026-09-29.
Tree: this change's branch on Linux 7.0.0-14-generic x86_64 with tmux 3.6, GNU bash 5.3.9, and the repo's own scripts.
Fixture: two isolated homes under a fresh `mktemp -d` scratch directory `$S`, `$P` (parent) and `$M` (mate), with `config/backend` set to `tmux` in both.
The mate home carries `.fm-secondmate-home` (`mate`) and a local `.fm-secondmate-parent` binding to `$P`; the parent home carries `state/mate.meta` (`kind=secondmate`, `home=$M`) and registers the mate in `data/secondmates.md`.
The mate's child task `child` is a real tmux pane (`fmpcv-fLcvhn:fm-child`) recorded in `$M/state/child.meta` with `kind=ship`, `mode=no-mistakes`, and `yolo=off`, and its worktree is a git copy whose HEAD is on its remote-tracking ref; the mate itself is a second real pane (`fmpcv-fLcvhn:fm-mate`).
Both panes live on an isolated tmux server: `TMUX_TMPDIR=$S/tmux` for every command, and `tmux ls` on the default server did not list the session.
Both homes run the real `bin/fm-watch.sh` (`FM_POLL=2`, `FM_SIGNAL_GRACE=2`), re-armed after every wake: when the watcher exits, a loop runs `bin/fm-wake-drain.sh`, reads its `WAKE_ACK_REQUIRED` line, runs `bin/fm-wake-drain.sh --ack-through <n> --recovery-generation <g>`, and starts the watcher again, exactly as fleet supervision re-arms a watcher after a handled turn.
`FM_CHECK_INTERVAL=999999` keeps the watchers from sweeping `*.check.sh`, so the merge poll that `bin/fm-pr-check.sh` arms never calls a forge during the run.
No agent harness and no model runs anywhere in the fixture.

The child's only action is the ordinary crewmate status append, typed into its own pane with `tmux send-keys`.
The mate's only actions are the scripts a firstmate runs when it registers a PR and when it holds a task for the captain and records the answer.
Forge access is a shim on `PATH`: `gh` logs every call and answers only the three reads `bin/fm-pr-check.sh` makes (draft state `false`, the child's HEAD as the PR head, and a plain body), while `gh-axi`, `glab`, and `curl` log and exit 97.

## Transcript

```text
$ # Setup: mate home $M is a secondmate of parent home $P (local route); child task 'child' lives in a real tmux pane; both watchers are live and have already seen the files' existing lines

$ cat $M/state/child.status
working: implementing the feature

$ cat $P/state/mate.status   (the parent channel)
working: delegated scope

$ # Step 1: the child appends its terminal line from inside its own real tmux pane

$ tmux send-keys -t fmpcv-fLcvhn:fm-child "echo 'done: PR https://github.com/kunchenguid/firstmate/pull/9999 checks green' >> $M/state/child.status" Enter

$ cat $M/state/child.status   (20 seconds later)
working: implementing the feature
done: PR https://github.com/kunchenguid/firstmate/pull/9999 checks green

$ cat $P/state/mate.status
working: delegated scope

$ ls -A $M/state/terminal-outcomes
(empty)

$ mate watcher log so far
signal: $M/state/child.status
--- re-armed after wake (ack-through 2)

$ mate drain presentation for that wake (excerpt)
1790651716	2	signal	child.status	signal: $M/state/child.status
wake annotation: latest wake-EVENT observed at drain, not current state: child.status: done: PR https://github.com/kunchenguid/firstmate/pull/9999 checks green
STATUS OUTCOME BACKSTOP (newest captain-facing task event has no covering branch outcome):
child done: PR https://github.com/kunchenguid/firstmate/pull/9999 checks green

$ parent watcher log so far
(empty)

$ # Step 2: the mate registers the PR with fm-pr-check; the ready line with the canonical URL reaches the parent from the script itself

$ FM_HOME=$M FM_STATE_OVERRIDE=$M/state FM_DATA_OVERRIDE=$M/data FM_CONFIG_OVERRIDE=$M/config bin/fm-pr-check.sh child https://github.com/kunchenguid/firstmate/pull/9999
armed: state/child.check.sh
(exit 0; stderr also carried the fm-guard worktree-tangle banner, because the tree under test is a feature-branch checkout)

$ cat $P/state/mate.status
working: delegated scope
done [key=child-pr-child] [at=1790651863]: child child PR ready: https://github.com/kunchenguid/firstmate/pull/9999 mode=no-mistakes yolo=off

$ parent watcher log so far
signal: $P/state/mate.status
--- re-armed after wake (ack-through 2)

$ # Step 3: the mate holds a task for the captain; the hold reaches the parent from fm-captain-hold itself

$ FM_HOME=$M FM_STATE_OVERRIDE=$M/state FM_DATA_OVERRIDE=$M/data FM_CONFIG_OVERRIDE=$M/config bin/fm-captain-hold.sh hold child-call --title 'Pick the rollout window' --reason 'rollout window choice pending' --repo alpha
child-call

$ cat $P/state/mate.status
working: delegated scope
done [key=child-pr-child] [at=1790651863]: child child PR ready: https://github.com/kunchenguid/firstmate/pull/9999 mode=no-mistakes yolo=off
needs-decision [key=captain-hold-child-call-1] [at=1790651946]: captain hold child-call: rollout window choice pending

$ # Step 4: the captain's answer is recorded in the mate home; the close reaches the parent from fm-captain-hold itself

$ printf 'roll out on Monday\n' > $S/decision.txt
$ FM_HOME=$M FM_STATE_OVERRIDE=$M/state FM_DATA_OVERRIDE=$M/data FM_CONFIG_OVERRIDE=$M/config bin/fm-captain-hold.sh answer child-call --decision-file $S/decision.txt
answered: child-call

$ cat $P/state/mate.status   (final parent channel)
working: delegated scope
done [key=child-pr-child] [at=1790651863]: child child PR ready: https://github.com/kunchenguid/firstmate/pull/9999 mode=no-mistakes yolo=off
needs-decision [key=captain-hold-child-call-1] [at=1790651946]: captain hold child-call: rollout window choice pending
resolved [key=captain-hold-child-call-1] [at=1790652033]: captain hold child-call: answered

$ grep -c child-outcome $P/state/mate.status
0

$ parent watcher log, one wake per delivered line (3 signals)
signal: $P/state/mate.status
--- re-armed after wake (ack-through 2)
signal: $P/state/mate.status
--- re-armed after wake (ack-through 4)
signal: $P/state/mate.status
--- re-armed after wake (ack-through 6)

$ mate watcher log
signal: $M/state/child.status
--- re-armed after wake (ack-through 2)
stale: fmpcv-fLcvhn:fm-child
--- re-armed after wake (ack-through 3)

$ cat $S/forge.log   (every forge call of the run)
gh pr view https://github.com/kunchenguid/firstmate/pull/9999 --json isDraft
gh api repos/kunchenguid/firstmate/pulls/9999 --jq .head.sha
gh api repos/kunchenguid/firstmate/pulls/9999 --jq .body // ""

$ # Every line on the parent channel after setup was written by a script, never by a model; each one woke the parent watcher, and the child's own terminal line woke only the mate.
```

## Why this proves the channel carries the captain's outcomes and not the mate's crew events

- The original defect was a mate model that handled a captain-facing outcome and then addressed the captain in its own chat instead of appending to the parent channel.
  In this run there is no model at all, and the three captain-facing lines still appeared on `$P/state/mate.status`: the PR-ready line at registration with the canonical PR, mode, and posture; the captain hold; and the hold's answer.
- Each of those lines was written by the script that recorded the underlying fact: `bin/fm-pr-check.sh` and `bin/fm-captain-hold.sh`.
- Each of those lines produced one `signal:` wake in the real parent watcher, three lines and three wakes, which is the event that starts the parent firstmate's turn and therefore the captain-facing report.
- The child's terminal `done:` line woke the mate's own watcher, and the mate's drain presented it as the newest captain-facing event of its own task, so the mate handles its crew's outcome on its own turn.
- The same line put nothing on the parent channel: the channel was unchanged after step 1, no `child-outcome-` line ever appeared on it, the parent watcher logged no wake until step 2, and `$M/state/terminal-outcomes` stayed empty.
- The only forge calls were the three reads `bin/fm-pr-check.sh` made at registration, all answered by the shim.
- The `stale:` line in the mate watcher log is the idle real child pane after its final line, ordinary liveness escalation unrelated to delivery.
