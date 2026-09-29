Captain, executing approved automation demo plan. Here dispatch strategy:

## Dispatch Plan

### Project Resolution
Would run: `bin/fm-project-mode.sh subliminal` to get delivery mode and yolo posture
Would run: `bin/fm-project-mode.sh --branch-prefix subliminal` to get branch prefix
Assuming: `no-mistakes` mode, yolo off, prefix `fm/` (state if different)

### Decomposition Strategy
5 concurrent slice tasks + 1 integration owner, following section 7 concurrent-slice pattern:
- Part 1's data model interface defined upfront in every brief
- Parts 1-5 all spawn `local-only` NOW, build concurrently against stated contract
- Integration owner spawns LATER after slices complete
- Integration owner ships through actual delivery mode (no-mistakes assumed)

### This Turn - Spawn All 5 Slices

**Slice 1: Foundation data model**
```bash
bin/fm-tasks-axi.sh add "subliminal demo: gated data model and staffing workflows"
bin/fm-brief.sh <id1> ship subliminal --mode local-only --branch-prefix fm/
```
Brief fills:
- **Captain's intent**: Build gated demo data plus staffing workflows it drives. Foundation that pages read from.
- **Firstmate spec**: Define WorkflowDefinition, AgentConfig, AutomationRule data structures. Implement workflow engine that processes staffing rules. Create demo dataset (3-5 realistic workflows). Export typed API for UI consumption. Include unit tests.

```bash
bin/fm-dispatch-resolve.sh <id1>
bin/fm-spawn.sh <id1> --profile <resolved-from-dispatch> --mode local-only --branch-prefix fm/
```

**Slice 2: Workflow map view**
```bash
bin/fm-tasks-axi.sh add "subliminal demo: workflow map view"
bin/fm-brief.sh <id2> ship subliminal --mode local-only --branch-prefix fm/
```
Brief fills:
- **Captain's intent**: Build workflow map view page reading demo data from part 1.
- **Firstmate spec**: Create visual workflow map component. Read from WorkflowDefinition API (contract: see task <id1> brief). Use stand-in mock data if foundation not integrated yet. Show workflow nodes, connections, agent assignments. Include component tests.
- **Data contract**: [paste WorkflowDefinition interface from id1 brief]

```bash
bin/fm-dispatch-resolve.sh <id2>
bin/fm-spawn.sh <id2> --profile <resolved> --mode local-only --branch-prefix fm/
```

**Slice 3: /agents page**
```bash
bin/fm-tasks-axi.sh add "subliminal demo: /agents page"
bin/fm-brief.sh <id3> ship subliminal --mode local-only --branch-prefix fm/
```
Brief fills:
- **Captain's intent**: Build /agents page reading demo data from part 1.
- **Firstmate spec**: Create /agents route and page. Read from AgentConfig API (contract: see task <id1> brief). Use stand-in mock if needed. Display agent roster, assignments, status. Include route tests.
- **Data contract**: [paste AgentConfig interface from id1 brief]

```bash
bin/fm-dispatch-resolve.sh <id3>
bin/fm-spawn.sh <id3> --profile <resolved> --mode local-only --branch-prefix fm/
```

**Slice 4: /automations overview**
```bash
bin/fm-tasks-axi.sh add "subliminal demo: /automations overview page"
bin/fm-brief.sh <id4> ship subliminal --mode local-only --branch-prefix fm/
```
Brief fills:
- **Captain's intent**: Build /automations overview page reading demo data from part 1.
- **Firstmate spec**: Create /automations route and overview. Read from AutomationRule API (contract: see task <id1> brief). Use stand-in mock if needed. Display automation list, status, triggers. Include route tests.
- **Data contract**: [paste AutomationRule interface from id1 brief]

```bash
bin/fm-dispatch-resolve.sh <id4>
bin/fm-spawn.sh <id4> --profile <resolved> --mode local-only --branch-prefix fm/
```

**Slice 5: Configure control**
```bash
bin/fm-tasks-axi.sh add "subliminal demo: Configure control on automations page"
bin/fm-brief.sh <id5> ship subliminal --mode local-only --branch-prefix fm/
```
Brief fills:
- **Captain's intent**: Build Configure control on automations page.
- **Firstmate spec**: Add Configure button/modal to automations page from task <id4>. Edit AutomationRule settings (contract: see task <id1> brief). Demo mode = local state only, no persistence. Include interaction tests.
- **Data contract**: [paste AutomationRule interface from id1 brief]

```bash
bin/fm-dispatch-resolve.sh <id5>
bin/fm-spawn.sh <id5> --profile <resolved> --mode local-only --branch-prefix fm/
```

### Next Turn - After Slices Complete

**Integration owner** (spawns when tasks id1-id5 all done):
```bash
bin/fm-tasks-axi.sh add "subliminal demo: integration"
bin/fm-brief.sh <id6> ship subliminal --mode no-mistakes --branch-prefix fm/
```
Brief fills:
- **Captain's intent**: Integrate 5 demo component branches into unified feature.
- **Firstmate spec**: Merge branches from tasks <id1-id5>. Remove all stand-in mocks. Verify data flows end-to-end (foundation → all 4 pages). Run full test suite. Validate workflow map, /agents, /automations, Configure all work together. Required for no-mistakes validation.
- **Input branches**: fm/<id1>, fm/<id2>, fm/<id3>, fm/<id4>, fm/<id5>

```bash
bin/fm-dispatch-resolve.sh <id6>
bin/fm-spawn.sh <id6> --profile <resolved> --mode no-mistakes --branch-prefix fm/
```

### Reasoning

**Why concurrent not serial**: Part 1's interface can be fixed upfront. Parts 2-5 build against stated contract using stand-ins. No slice blocks another. Integration reconciles at end.

**Why local-only for slices**: Per section 7, slices hand branches to integration owner without opening PRs. Only integrated result goes to review.

**Why no-mistakes for integration**: Product-facing work (assumed). Integration owner validates combined result through full pipeline.

**What goes out this turn**: All 5 slice tasks spawn NOW. Zero waiting.

**What waits**: Integration task waits until slice branches ready. Then spawns, merges, validates integrated result.

**How reaches review**: Integration owner pushes through no-mistakes pipeline, opens one PR with full combined work, waits for green checks, reports PR URL for captain review.

Ready execute if project mode confirmed. Captain, what subliminal project actual delivery mode?
