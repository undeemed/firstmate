# Evidence: ponytail lean gate in freshly generated crewmate briefs

Generated with `bin/fm-brief.sh` at adfd18e, one brief per variant, into a clean FM_HOME.
Full generated briefs are in `generated-briefs/`.
Briefs under `generated-briefs/` were produced at adfd18e and supersede the earlier top-level `brief-*.md` copies from round 1, which predate the bare-uncommitted-work-form fix.
 Excerpts below are the Definition-of-done sections verbatim.

## no-mistakes ship brief (gate before the pipeline opens the PR, verdict carried into the PR body)
```
# Definition of done
Delivery contract: mode=no-mistakes
The task is complete only when committed on your branch.
Before the PR is opened, run `ponytail-review <base>` against the branch base you started from (for example `ponytail-review main`; bare `ponytail-review` reviews uncommitted work, and `git diff <base>... | ponytail-review --stdin` also works), cut everything it names, and re-run it until it passes - size alone is never the test.
Exit 0 is `Lean already. Ship.` and the gate passes; exit 2 means findings remain, so cut them and run it again; exit 1 means the gate COULD NOT RUN (missing plugin, missing agent, or empty diff), which you report with `blocked:` and never as a pass.
Carry that verdict into the PR body, and name any finding you deliberately did not cut with the reason it earns its place.
When you believe it is complete, append `done: {summary}` to the status file and stop.
Firstmate will then instruct you to run /no-mistakes to validate and ship a PR.
```

## direct-PR ship brief (gate before the worker opens the PR, verdict reported in the PR body)
```
# Definition of done
Delivery contract: mode=direct-PR
This task ships **direct-PR**: you raise the PR yourself, without the no-mistakes pipeline.
The task is complete only when committed on your branch.
Before you open the PR, run `ponytail-review <base>` against the branch base you started from (for example `ponytail-review main`; bare `ponytail-review` reviews uncommitted work, and `git diff <base>... | ponytail-review --stdin` also works), cut everything it names, and re-run it until it passes - size alone is never the test.
Exit 0 is `Lean already. Ship.` and the gate passes; exit 2 means findings remain, so cut them and run it again; exit 1 means the gate COULD NOT RUN (missing plugin, missing agent, or empty diff), which you report with `blocked:` and never as a pass.
Report that verdict in the PR body, and name any finding you deliberately did not cut with the reason it earns its place.
When it is implemented and committed, push your branch and open a PR with `gh-axi`, then append `done: PR {url}` to the status file and stop.
Do NOT run /no-mistakes. The configured merge authority decides whether to merge the PR; firstmate relays the outcome.
```

## local-only ship brief (gate on the branch handoff; no PR wording)
```
# Definition of done
Delivery contract: mode=local-only
This task ships **local-only**: no remote, no PR, no pipeline.
The task is complete only when committed on your branch `fm/ev-ship-local`. Do NOT push, do NOT open a PR, do NOT merge.
Keep your branch a clean fast-forward onto the current default branch - if `main` has advanced, rebase onto it so the eventual merge stays a fast-forward.
Before you hand the branch off, run `ponytail-review <base>` against the branch base you started from (for example `ponytail-review main`; bare `ponytail-review` reviews uncommitted work, and `git diff <base>... | ponytail-review --stdin` also works), cut everything it names, and re-run it until it passes - size alone is never the test.
Exit 0 is `Lean already. Ship.` and the gate passes; exit 2 means findings remain, so cut them and run it again; exit 1 means the gate COULD NOT RUN (missing plugin, missing agent, or empty diff), which you report with `blocked:` and never as a pass.
Record that verdict in your handoff, and name any finding you deliberately did not cut with the reason it earns its place.
When it is implemented and committed, append `done: ready in branch fm/ev-ship-local` to the status file and stop.
The configured merge authority approves the ready branch, then firstmate merges it into local `main` through the guarded fast-forward path.
```

## Negative constraints, verified on the generated files
```
$ grep -c ponytail <each brief>   |   grep -c /ponytail-review <each brief>
ev-ship-nm     ponytail-lines:1   slash-command:/ponytail-review:0
ev-ship-dpr    ponytail-lines:1   slash-command:/ponytail-review:0
ev-ship-local  ponytail-lines:1   slash-command:/ponytail-review:0
ev-scout       ponytail-lines:0   slash-command:/ponytail-review:0
ev-charter     ponytail-lines:0   slash-command:/ponytail-review:0

$ numeric size-threshold scan across all five briefs
no numeric size threshold found in any generated brief
```

## The instruction is runnable: real wrapper on PATH, contract matches the brief text
```
$ command -v ponytail-review
/home/ubuntu/.local/bin/ponytail-review
# USAGE
#   ponytail-review                 review uncommitted work (git diff HEAD)
#   ponytail-review <base>          review this branch against <base>, e.g. origin/main
#   ponytail-review --stdin         review a diff piped in
#   git diff main... | ponytail-review --stdin
#
# EXIT CODES
#   0  "Lean already. Ship." - the gate passes
#   1  usage, missing plugin, missing agent, or empty diff - NEVER a pass
#   2  findings remain: cut them and run again
```
