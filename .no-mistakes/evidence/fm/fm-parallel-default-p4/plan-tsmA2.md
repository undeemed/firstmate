Captain, here's the exact dispatch plan:

**Project resolution**: subliminal (would verify via `bin/fm-project-mode.sh subliminal`)

**Delivery mode check**: Would run `bin/fm-project-mode.sh --mode subliminal` and `--yolo subliminal` to resolve standing posture. Assuming `no-mistakes` / yolo off for this plan.

**Task decomposition**: 6 tasks total - 5 concurrent slices (local-only) + 1 integration owner (no-mistakes)

**Shared contract** (stated in all 5 slice briefs):
```typescript
// Demo data model
interface WorkflowDefinition {
  id: string
  name: string
  trigger: { type: string, config: any }
  actions: Array<{ type: string, config: any }>
  enabled: boolean
  staffingImpact: { roles: string[], allocation: number }
}

interface AgentDefinition {
  id: string
  name: string
  capabilities: string[]
  status: 'active' | 'idle' | 'busy'
  currentWorkflow?: string
}

// Access pattern: import from '@/demo/workflows'
```

**Dispatch commands** (all in this turn):

```bash
# Slice 1: Demo data foundation
bin/fm-brief.sh add ship subliminal \
  --mode local-only \
  "Build gated demo data and staffing workflow model. Export WorkflowDefinition[], AgentDefinition[] from @/demo/workflows. Include 3-4 sample workflows showing triggers->actions->staffing. Use contract above."

bin/fm-spawn.sh <id1> --mode local-only --profile <resolved> --backend <current>

# Slice 2: Workflow map view  
bin/fm-brief.sh add ship subliminal \
  --mode local-only \
  "Build workflow map view component. Reads demo workflows, renders visual graph of trigger->action flow. Use contract above, stub demo data import if not merged yet."

bin/fm-spawn.sh <id2> --mode local-only --profile <resolved> --backend <current>

# Slice 3: /agents page
bin/fm-brief.sh add ship subliminal \
  --mode local-only \
  "Build /agents page. Lists agents from demo data, shows status/capabilities/current workflow. Use contract above, stub demo data if needed."

bin/fm-spawn.sh <id3> --mode local-only --profile <resolved> --backend <current>

# Slice 4: /automations overview  
bin/fm-brief.sh add ship subliminal \
  --mode local-only \
  "Build /automations overview page. Lists workflows from demo data, shows enabled/disabled state, staffing impact summary. Use contract above, stub demo data if needed."

bin/fm-spawn.sh <id4> --mode local-only --profile <resolved> --backend <current>

# Slice 5: Configure control
bin/fm-brief.sh add ship subliminal \
  --mode local-only \
  "Build Configure control for automations page. Toggle workflow enabled state, edit basic config. Reads/writes demo workflow state. Use contract above, stub demo data if needed."

bin/fm-spawn.sh <id5> --mode local-only --profile <resolved> --backend <current>

# Integration owner (waits for slice branches)
bin/fm-brief.sh add ship subliminal \
  --mode no-mistakes \
  "Integration owner: merge branches from <id1-id5>, remove all demo data stubs (slices 2-5 use real imports from slice 1), validate integrated demo works end-to-end, ship through no-mistakes."

bin/fm-spawn.sh <id6> --mode no-mistakes --profile <resolved> --backend <current>
```

**Timing**: Tasks id1-id5 spawn immediately, all in this turn. Task id6 spawns immediately but briefs state "wait for sibling branches <id1-id5> ready" in Firstmate spec.

**Dependencies**: No blocking waits. Slices 2-5 build against contract using local stand-ins. Integration owner merges all 5 branches when ready, removes stand-ins, validates integrated result.

**Review path**: Integration owner lands one PR through no-mistakes pipeline. Slices never open PRs (local-only, branches handed to id6). 

**Why concurrent**: Shared data model interface specified up front. Each slice independently testable against contract. Integration reconciles at merge, not build time.

Ready to execute when tools enabled, captain.
