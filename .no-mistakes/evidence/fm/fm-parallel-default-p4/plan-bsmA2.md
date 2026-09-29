Captain, here's exact dispatch plan:

## Turn 1 - Foundation

**Task: subliminal-demo-data**

```bash
bin/fm-project-mode.sh --mode subliminal  # Resolve delivery mode
# Assuming no-mistakes mode (or use resolved value)

bin/fm-brief.sh ship --project subliminal --mode no-mistakes >data/subliminal-demo-data/brief.md
```

**Intent**: Build gated demo data model plus staffing workflows it drives. Foundation that pages 2-5 read from.

**Spec**: 
- Gated demo data structure
- Staffing workflow models driven by that data
- Data access layer pages can consume
- Keep out of scope: any UI pages (those are tasks 2-5)

```bash
bin/fm-spawn.sh subliminal-demo-data --mode no-mistakes
```

**Wait for subliminal-demo-data to land before Turn 2.**

## Turn 2 - Parallel page builds (after foundation lands)

**Task: subliminal-workflow-map**
```bash
bin/fm-brief.sh ship --project subliminal --mode no-mistakes >data/subliminal-workflow-map/brief.md
```
Intent: Workflow map view reading demo data from task 1.

```bash
bin/fm-spawn.sh subliminal-workflow-map --mode no-mistakes
```

**Task: subliminal-agents-page**
```bash
bin/fm-brief.sh ship --project subliminal --mode no-mistakes >data/subliminal-agents-page/brief.md
```
Intent: `/agents` page reading demo data from task 1.

```bash
bin/fm-spawn.sh subliminal-agents-page --mode no-mistakes
```

**Task: subliminal-automations-page**
```bash
bin/fm-brief.sh ship --project subliminal --mode no-mistakes >data/subliminal-automations-page/brief.md
```
Intent: `/automations` overview page reading demo data from task 1.

```bash
bin/fm-spawn.sh subliminal-automations-page --mode no-mistakes
```

**All three dispatch same turn, run parallel. Wait for subliminal-automations-page to land before Turn 3.**

## Turn 3 - Configure control (after automations page lands)

**Task: subliminal-configure-control**
```bash
bin/fm-brief.sh ship --project subliminal --mode no-mistakes >data/subliminal-configure-control/brief.md
```
Intent: Configure control on the automations page (integrates with landed page from task 4).

```bash
bin/fm-spawn.sh subliminal-configure-control --mode no-mistakes
```

## Dependencies

- **Turn 1 blocks Turn 2**: Parts 2-5 read foundation data model. Can't build pages before foundation exists.
- **Turn 2 → Turn 3**: Configure control lives "on the automations page". Building it before that page lands risks interface conflicts. Tasks 2, 3 independent of each other and task 4, so parallel dispatch safe.
- **Tasks 2, 3 don't block anything**: Workflow map and agents page fully independent.

## Review path

Each task ships no-mistakes (assuming project registry confirms):
1. Worker implements + commits
2. Worker triggers validation with /no-mistakes
3. Pipeline runs review, tests, fixes
4. Green PR reported to firstmate
5. Firstmate runs fm-pr-check.sh, tells captain PR URL
6. Captain approves or yolo merges
7. Teardown after confirmed landing

Five serial landing checkpoints total: foundation → (3 parallel pages) → configure control.

Human wall-clock: One foundation wait, one automations-page wait. Three-stage pipeline, five total landings.
