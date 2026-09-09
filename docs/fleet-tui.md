# Fleet TUI

One always-on terminal screen for every task in flight across the whole fleet, refreshed on a timer.

- Status: current, first shipped 2026-09-09.
- Components: `bin/fm-fleet-tui.py` (the screen), `bin/fm_fleet_read.py` (the one fleet read layer), `bin/fm-fleet-probe.sh` (the cheap per-home probe).
- Authoritative copy: this file in `undeemed/firstmate`.
- Exact flags, defaults, and record formats live in each file's header and `--help`; this document owns the design and the operating story.

## Who this is for, and what they ask

| Reader | Question this answers |
|---|---|
| The captain, watching the fleet | What is running right now, everywhere, and what did each worker last say. |
| An operator diagnosing a quiet fleet | Which home has queued notifications nobody consumed, a stopped monitor, or an endpoint that has gone. |
| A maintainer changing a board | Why both boards read through one module, and what that module deliberately does not answer. |

## Context view

```
bin/fm-fleet-tui.py      bin/fm-live-board.py
        \                        /
         \                      /
          bin/fm_fleet_read.py            <- discovery + concurrency, one read layer
                   |
          bin/fm-fleet-probe.sh           <- one cheap read per home
                   |
   fm-backend.sh · fm-busy-lib.sh · fm-classify-lib.sh · fm-lock.sh · tasks-axi
```

Both screens render the same read.
A renderer never parses a state file, and neither renderer holds its own idea of what the fleet is.

## Composition view

`bin/fm-fleet-probe.sh` answers two questions for one home: which homes exist, and what does this home hold.
Homes are discovered, never hardcoded: the home it was pointed at, every entry in that home's `data/secondmates.md`, and every pool directory carrying firstmate's own `.fm-secondmate-home` marker.
The marker scan is what keeps a home visible after it is created, renamed, or dropped from the registry - the previous web board carried a hardcoded four-home map, so a real home was simply absent from it and a renamed one was mislabelled.

`bin/fm_fleet_read.py` discovers the homes, runs those probes concurrently, and shapes the records.
It is the module both renderers import, and it is the only place fleet discovery lives.

## What the screen shows

Per task: its id, its home, its kind and delivery mode, whether its endpoint is still there, whether its harness is mid-turn, the last line it wrote, and its pull request when one is known.
Per home: how many notifications are queued and how old the oldest is, how long ago the monitor last recorded a beat, who holds the session lock, the in-flight, queued, and held counts from that home's configured backlog backend, and every task held for the captain.

A task's last status line is labelled `EVENT` on screen because that is what it is: the last thing a worker chose to announce, not its current state.
A worker that resolved a decision and carried on writes nothing new, so its last event can be hours stale while the worker is busy - the busy column, read from the harness, is the live half of that pair.

## Design rationale

`bin/fm-fleet-snapshot.sh` already reads the fleet deeply: it reconciles every task through `bin/fm-crew-state.sh`, which asks no-mistakes about each branch.
Measured on the fleet box on 2026-09-09, that read took 76 seconds for one home holding 13 tasks, so it cannot sit behind a refresh timer.
The probe therefore takes the cheap half of the same read - endpoint presence, the busy verdict, the status tail - from the same owners the deep reader uses, and skips reconciliation entirely.
A whole-fleet read of 9 homes measured 5.5 to 8.4 seconds at 21 tasks and 11 to 15 seconds at 25 tasks on the same box, dominated by one endpoint query per task.
That is why the screen reads off the drawing thread, never starts a second read while one is in flight, and prints how old the read it is showing is.

Read-only was chosen deliberately for this version.
Steering a worker means interrupting, exiting, relaunching, or sending it text, and those mechanics already have owners in `bin/fm-control.sh` and `bin/fm-send.sh`; a screen that reimplemented them would be a second lifecycle path.

## Limits

- It never answers "what state is this task really in": ask `bin/fm-crew-state.sh <id>`, which costs seconds per task.
- A remote secondmate's home is listed and never read from here, because its records and endpoint live on its own host ([remote-secondmates.md](remote-secondmates.md)).
- A home that configured the manual backlog path, or a box without `tasks-axi`, shows its backlog counts as unread rather than guessing them from the file.
- The screen is as fresh as its last read, and it says how old that read is; a home that times out is named rather than dropped.

## Verification

`tests/fm-fleet-read.test.sh` drives discovery, the probe, the read layer, and both renderers against a fixture home tree, including the proof that probing a home with no records writes nothing into it.
Run it with `bin/fm-test-run.sh tests/fm-fleet-read.test.sh`.
