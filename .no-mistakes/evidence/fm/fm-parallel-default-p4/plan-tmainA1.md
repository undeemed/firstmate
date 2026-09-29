Captain, dispatch plan follows.

## Task breakdown

6 ship tasks total:
- 5 concurrent slices (parts 1-5), each `local-only`
- 1 integration owner at subliminal's resolved delivery mode

## Interface contract (enables concurrency)

State in every brief:

**Demo data model interface:**
- Workflow schema: fields for workflow ID, name, trigger conditions, action sequence, state tracking
- Staffing workflow contract: what triggers fire, what actions execute, state transitions
- Query API: how pages read workflow definitions and current state (in-memory model, JSON file, or module export)

**Stand-in rule for slices 2-5:** Use local mock data matching this schema. Integration owner removes all stand-ins.

## Dispatch sequence (all this turn)

1. Resolve project mode: `bin/fm-project-mode.sh subliminal` → capture `mode` and `yolo`
2. Resolve branch prefix: `bin/fm-project-mode.sh --branch-prefix subliminal` → default `fm/`
3. Resolve dispatch profiles if configured
4. Spawn slices 1-5 concurrently:

```bash
# Part 1: Demo data + staffing workflows
bin/fm-brief.sh ship subliminal --mode local-only \
  "Build gated demo data model and staffing workflows. Interface: [state the schema/API contract]. This is the foundation - workflow map, agents page, automations page, and configure control will read this model. Use demo data only, no real staffing. Passes local validation against its own fixtures." \
  > data/demo-data/brief.md

bin/fm-spawn.sh demo-data --mode local-only --project subliminal

# Part 2: Workflow map view
bin/fm-brief.sh ship subliminal --mode local-only \
  "Build workflow map view that visualizes workflow definitions and relationships. Reads demo data model via [interface]. Use local stand-in matching schema until integration. Passes local validation with stand-in data." \
  > data/workflow-map/brief.md

bin/fm-spawn.sh workflow-map --mode local-only --project subliminal

# Part 3: /agents page
bin/fm-brief.sh ship subliminal --mode local-only \
  "Build /agents page showing agent roster driven by staffing workflows. Reads demo data model via [interface]. Use local stand-in until integration. Passes local validation with stand-in data." \
  > data/agents-page/brief.md

bin/fm-spawn.sh agents-page --mode local-only --project subliminal

# Part 4: /automations overview page
bin/fm-brief.sh ship subliminal --mode local-only \
  "Build /automations overview page listing available workflows. Reads demo data model via [interface]. Use local stand-in until integration. Passes local validation with stand-in data." \
  > data/automations-page/brief.md

bin/fm-spawn.sh automations-page --mode local-only --project subliminal

# Part 5: Configure control on automations page
bin/fm-brief.sh ship subliminal --mode local-only \
  "Build Configure control for automations page (workflow enable/disable, parameter tuning). Reads/writes demo data model via [interface]. Use local stand-in until integration. Passes local validation with stand-in data." \
  > data/configure-control/brief.md

bin/fm-spawn.sh configure-control --mode local-only --project subliminal
```

5. Capture branch names from spawn output: `fm/demo-data`, `fm/workflow-map`, `fm/agents-page`, `fm/automations-page`, `fm/configure-control`

6. Spawn integration owner:

```bash
bin/fm-brief.sh ship subliminal --mode <resolved-mode> \
  "Integrate automation demo. Merge branches: fm/demo-data, fm/workflow-map, fm/agents-page, fm/automations-page, fm/configure-control. Remove all stand-ins from parts 2-5. Verify integrated result: all pages read real demo data, workflows drive staffing correctly, configure control works end-to-end. Validate once against final integrated head." \
  > data/integration/brief.md

bin/fm-spawn.sh integration --mode <resolved-mode> --project subliminal [--profile <resolved-if-configured>]
```

## Dependencies

None. All 6 spawn this turn. Interface contract fixed up front enables concurrent build. No slice waits on another.

## Reaching review

1. Slices 1-5 each reach clean ready branch, report done
2. Integration owner receives branch names via steer, merges all 5, removes stand-ins, validates integrated result
3. Integration owner follows resolved delivery mode:
   - `no-mistakes`: pipeline → PR → green checks → merge authority
   - `direct-PR`: push → PR → merge authority  
   - `local-only`: clean branch → merge authority
4. After merge authority (captain approval or yolo), land via `fm-pr-merge.sh` or `fm-merge-local.sh`
5. Captain sees one PR URL with full integrated automation demo

Captain, ready execute this plan?
