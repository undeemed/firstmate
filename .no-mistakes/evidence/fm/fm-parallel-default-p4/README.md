# Live A/B: firstmate dispatch planning under base vs target AGENTS.md

Homes: throwaway `git archive` exports of base dcef8c59 and target 49dbfb04 under /tmp,
with a `subliminal [no-mistakes]` registry line; "sm" homes carry a `.fm-secondmate-home`
marker + charter (the Subliminal secondmate case), "main" is a plain main home.
Driver: `claude -p "$(cat prompt)" --allowedTools Read Glob Grep --disallowedTools Bash Edit Write ...`
from the home root (CLAUDE.md -> @AGENTS.md), i.e. the real firstmate agent loading the real instructions.

| run | home | AGENTS.md | prompt | outcome |
|---|---|---|---|---|
| plan-bsmA1 | secondmate | base | Subliminal demo | SERIAL: foundation -> 3 pages -> Configure (3 turns) |
| plan-bsmA2 | secondmate | base | Subliminal demo | SERIAL: foundation -> 3 pages -> Configure (3 turns) |
| plan-tsmA1 | secondmate | target | Subliminal demo | PARALLEL: 5 local-only slices now against stated contract + 1 integration owner (no-mistakes) |
| plan-tsmA2 | secondmate | target | Subliminal demo | PARALLEL: 5 local-only slices now + integration owner, "No blocking waits" |
| plan-tmainA1 | main | target | Subliminal demo | PARALLEL: all 6 spawn this turn, one integrated PR |
| plan-tsmB1 | secondmate | target | investigate-then-fix + unrelated toggle | scout + toggle dispatched now; fix serialized with stated reason "cannot be specified until diagnostic findings exist" |
