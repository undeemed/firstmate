Captain, dry-run dispatch plan:

## Project resolution
Resolve "subliminal" from `data/projects.md` registry. If absent/ambiguous, escalate which project before proceeding.

## Delivery mode resolution  
Run `bin/fm-project-mode.sh subliminal` to get registered mode and yolo posture. If unregistered, defaults: `no-mistakes`, yolo off, prefix `fm/`.

## Task decomposition

**Two independent tasks, one serialization:**

### THIS TURN - dispatch both:

**1. Latency diagnosis (scout)**
```bash
bin/fm-brief.sh scout subliminal latency-diagnosis
```

Captain's intent section:
```
Checkout p95 latency tripled since Tuesday - find out why.
```

Firstmate spec section:
```
- Check metrics/logs from Tuesday to now for checkout flow
- Identify p95 latency baseline vs current
- Find regression point (commit/deploy/config change)
- Isolate root cause (database, API, cache, network, etc)
- Document findings with evidence in report
- Out of scope: implementing fix (separate ship task after diagnosis)
```

Then:
```bash
bin/fm-spawn.sh scout subliminal latency-diagnosis --backend <validated> --profile <from dispatch rules or explicit>
```

**2. Dark mode toggle (ship)**
```bash
bin/fm-brief.sh ship subliminal dark-mode-toggle --mode <resolved>
```

Captain's intent section:
```
Add a dark-mode toggle to the settings page.
```

Firstmate spec section:
```
- Add toggle control to settings page UI
- Implement dark mode stylesheet/theme switching
- Persist user preference (localStorage or user settings)
- Ensure toggle reflects current mode on load
```

Then:
```bash
bin/fm-spawn.sh ship subliminal dark-mode-toggle --mode <resolved> --yolo <on|off> --branch-prefix <resolved> --backend <validated> --profile <from dispatch or explicit>
```

### LATER TURN - after scout report:

**3. Latency fix (ship)**  
Wait for scout report. After reading findings, dispatch ship with spec targeting identified root cause. Cannot specify now - fix depends entirely on diagnosis.

Serialization reason: "Latency fix cannot be specified until diagnostic findings exist." Per section 7, this exact case requires serialization.

## Both tasks hit review via:
- Scout: report in `data/<id>/report.md`, relay findings to captain
- Ship: selected delivery mode (no-mistakes or direct-PR), then configured merge authority (yolo or captain approval)

## Notes:
- Both concurrent (no file/scope overlap)
- Scout never opens PR
- Ship follows project's registered delivery path through to merge
- Would check existing monitoring/reports before spawning scout (dry run skips actual check)

Ready to execute on captain go.
