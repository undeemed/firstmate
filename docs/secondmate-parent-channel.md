# Secondmate parent channel

This note records why a secondmate home's captain-facing outcomes are delivered by scripts instead of by the mate model, and which script delivers each one.
`bin/fm-parent-channel-lib.sh` owns the channel contract: where the channel lives, how a line is appended, and the return codes every publisher shares.
[`remote-secondmates.md`](remote-secondmates.md) owns the transport that carries the remote form of the channel back to the parent.

## The problem

A secondmate is a firstmate in its own home, and nobody reads its chat: the captain and the main firstmate see only what is appended to the parent channel.
On 2026-09-02 four outcomes across two mate homes never reached the captain.
The watcher had delivered the parent's request within a minute each time, the mate did the work, and then the mate addressed "captain" in its own chat instead of appending to the channel.
The cause is structural rather than a one-off lapse: the mate can satisfy the [address rule in `AGENTS.md`](../AGENTS.md#firstmate) in local chat while missing the charter's later return-channel instruction.
The captain's framing of the requirement was: "the root problem is not specific to PRs, right? it looks like any message or outcomes from second mates can miss. we need to make sure our fixes are addressing this in a principled, fundamental way, not surgically treating the symptoms of just this PR update miss."
A PR-ready report was the observed symptom, but a finding, a decision, a blocker, and a failure all fail the same way, because every one of them depended on the mate model remembering to write one line.

The design goal is therefore: the parent channel must not depend on the model remembering to write to it.

A second constraint bounds that goal: the channel carries only what the captain needs, not every event in the mate home.
A secondmate owns its crews, so a child finishing or failing is the mate's own event to handle, prune, or decide on.
Republishing every child's terminal line upward woke the main home once per crew completion, which floods it when several secondmates run many crews in parallel.

## The design

The delivery rule has one sentence: the scripts report facts, the mate reports judgement.
Every outcome the captain must act on that leaves durable evidence in the mate home - a PR ready for review, a decision held for the captain, a merge, and a marked reply - is published on the channel by the script that records that evidence when it records it, and the charter reserves the mate's own appends for judgement.

| Outcome | Durable evidence in the mate home | Published by |
|---|---|---|
| Ship child PR ready | `pr=` in the child's record once registered | `bin/fm-pr-check.sh` at registration with the canonical URL |
| Child decision escalated to the captain | the task held for the captain in the mate backlog | `bin/fm-captain-hold.sh hold`, and its answer by `answer` |
| PR merged | the merge poll or the mate's own merge | `bin/fm-merge-outcome-lib.sh` |
| Answer to a marked request | a correlated line guarded by the pending-reply record | `bin/fm-secondmate-report.sh`, which resolves the parent channel from the mate home; the pending-reply guard repairs a line stranded in the local mate's same-basename status file before recovery or escalation |
| A child's routine outcome the captain should see (findings, a failure) | the child's ledger line, and `data/<child>/report.md` for a scout | the mate, as judgement, after its own watcher wakes it |
| An outcome that exists only in the mate's reasoning | none | the charter and the `AGENTS.md` carve-outs only |

A child's `done:` or `failed:` line wakes the mate through its own watcher exactly as a main home is woken, and a child that ends silently is found by the mate home's own inactive-outcome scan (`bin/fm-inactive-reconcile.sh`), which queues the finding in that home and never on the parent channel.
Teardown of a child in the mate home leaves any unhandled inactive-outcome finding queued there, because those wakes are not task-scoped and survive retirement (`bin/fm-retire-lib.sh`).
The main home's backstop for a mate that leaves its children's events unconsumed is its secondmate-unattended check (`bin/fm-watch.sh`), not a copy of every child event.
A duplicate line is harmless and a missed one is not, so the mate may still append its own judgement about a published outcome, and the parent reads the script's line as the fact and the mate's line as commentary.
For marked replies, the report helper accepts no caller-selected destination and uses the channel resolver for both local and remote homes; its script header owns the exact invocation contract.
The pending-reply guard may restate only the correlated line from a local mate's `state/<mate-id>.status` onto the parent channel, which repairs the common parent-home versus mate-home mixup without accepting arbitrary mate-home sightings as acknowledgement.
Other correlated mate-home status lines remain wrong-home evidence, while a remote home's routed `state/parent-replies.status` is already the parent channel and is not classified as wrong-home.
A missed-reply escalation includes the complete first sighting path and line number in readable shell-escaped form.

## What is deliberately not built

- No mirror of the mate's chat: chat can mix outcomes with other conversation, so choosing which sentence is an outcome would itself be model behavior, and every harness exposes turn text differently.
- No threshold escalation of a child's open decision or blocker: a decision the mate escalates is a captain hold, which is published; a decision the mate neither answers nor escalates is a supervision-quality question, separable from channel delivery.
- No republication of routine child outcomes: the mate owns its crew, and a parent-side filter over a flood of copies would only move the cost.

## Regression coverage

`tests/fm-inactive-reconcile.test.sh` covers a mate home queuing a silent child's terminal outcome in its own wake queue while writing nothing to the parent channel, and a child's terminal ledger line never being republished upstream.
`tests/fm-captain-hold-lifecycle.test.sh` covers a mate home publishing a hold, its answer, and a distinct occurrence on re-hold, and a main home publishing nothing.
`tests/fm-pr-merge.test.sh` covers the PR-ready line at registration and the merge outcome's upward report.
`tests/fm-teardown.test.sh` covers a child's teardown in a mate home writing nothing upward and leaving its unhandled finding queued in that home.
`tests/fm-brief.test.sh` pins the charter's channel rule.
`tests/fm-pending-reply.test.sh` covers helper-selected local routing, remote-channel classification, same-basename restatement before false escalation, readable wrong-home diagnostics, and the rule that arbitrary mate-home sightings never acknowledge a reply.

## Live verification

[`verification/secondmate-parent-channel.md`](verification/secondmate-parent-channel.md) records the dated live run: real tmux panes, both real watchers re-armed after each wake, and no model, with every delivered parent line and the parent wake it produced.
