Captain, dispatch plan follows.

**Assumptions** (would verify from session start digest):
- Project: subliminal, registered, cloned under projects/
- Delivery mode: no-mistakes (default)
- Yolo: off (default)
- Branch prefix: fm/
- Crew harness/dispatch: From config/crew-harness or profiles if configured

**Task breakdown with dependencies:**

```
Task 1: Demo foundation (demo data + staffing workflows)
  ├── Task 2: Workflow map view
  ├── Task 3: /agents page  
  └── Task 4: /automations overview
      └── Task 5: Configure control
```

**Dispatch sequence:**

**Turn 1 (now):** Dispatch Task 1 only.

Task 1 blocks everything else - parts 2-5 cannot implement against non-existent data model. Spawning them now creates 4 idle workers.

**Turn 2 (after Task 1 lands):** Dispatch Tasks 2, 3, 4 in parallel.

These read the landed foundation, no mutual dependencies.

**Turn 3 (after Task 4 lands):** Dispatch Task 5.

Configure control lives on the automations page Task 4 builds.

**Exact invocations:**

**Task 1:**
```bash
bin/fm-tasks-axi.sh add "Build demo foundation: gated demo data and staffing workflows for subliminal automation demo"

bin/fm-brief.sh subliminal-demo-foundation \
  --mode no-mistakes \
  --task "Build gated demo data model and staffing workflow definitions. This is the foundation that workflow map, agents page, automations overview, and configure control will read from. Include sample agent definitions, workflow states, automation rules, and staffing triggers."

bin/fm-spawn.sh subliminal-demo-foundation \
  --project subliminal \
  --mode no-mistakes \
  --backend <resolved-from-config-or-auto> \
  --harness <resolved-from-dispatch-profile-or-config> \
  --effort medium
```

**Task 2 (after Task 1 lands):**
```bash
bin/fm-tasks-axi.sh add "Build workflow map view reading demo foundation"

bin/fm-brief.sh subliminal-workflow-map \
  --mode no-mistakes \
  --task "Build workflow map view component that visualizes workflows from the demo data foundation landed in Task 1. Read workflow definitions, states, and transitions from the established data model."

bin/fm-spawn.sh subliminal-workflow-map \
  --project subliminal \
  --mode no-mistakes \
  --backend <resolved> \
  --harness <resolved> \
  --effort low
```

**Task 3 (after Task 1 lands):**
```bash
bin/fm-tasks-axi.sh add "Build /agents page reading demo foundation"

bin/fm-brief.sh subliminal-agents-page \
  --mode no-mistakes \
  --task "Build /agents page showing agent roster from demo data foundation landed in Task 1. Display agent definitions, status, and assignments from the established data model."

bin/fm-spawn.sh subliminal-agents-page \
  --project subliminal \
  --mode no-mistakes \
  --backend <resolved> \
  --harness <resolved> \
  --effort low
```

**Task 4 (after Task 1 lands):**
```bash
bin/fm-tasks-axi.sh add "Build /automations overview page reading demo foundation"

bin/fm-brief.sh subliminal-automations-overview \
  --mode no-mistakes \
  --task "Build /automations overview page displaying automation rules and workflows from demo data foundation landed in Task 1. Read automation definitions and execution state from the established data model."

bin/fm-spawn.sh subliminal-automations-overview \
  --project subliminal \
  --mode no-mistakes \
  --backend <resolved> \
  --harness <resolved> \
  --effort medium
```

**Task 5 (after Task 4 lands):**
```bash
bin/fm-tasks-axi.sh add "Add Configure control to automations page"

bin/fm-brief.sh subliminal-configure-control \
  --mode no-mistakes \
  --task "Add Configure control component to the /automations page built in Task 4. Integrate with existing page layout and demo data model."

bin/fm-spawn.sh subliminal-configure-control \
  --project subliminal \
  --mode no-mistakes \
  --backend <resolved> \
  --harness <resolved> \
  --effort low
```

**Path to review:**

No-mistakes mode:
1. Each worker implements → commits → triggers pipeline
2. Pipeline pushes PR, runs CI
3. Worker reports `done [at=<epoch>]: PR <url> checks green`
4. Firstmate records PR with fm-pr-check.sh
5. Yolo off: firstmate reports PR URL, waits captain merge call
6. After captain approves: fm-pr-merge.sh, fleet-sync refresh
7. Next dependent task dispatches

**Parallelism:**
- Tasks 2, 3, 4 proceed concurrently after Task 1 lands
- Independent validation, independent PRs
- No file conflicts expected (separate UI surfaces)
- Sequential landing order doesn't matter for 2-4

Total: 5 tasks, 3 dispatch turns, 5 PRs.
