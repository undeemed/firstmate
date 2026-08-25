# Substance comparison: new AGENTS.md rule vs captain's global ~/.claude/CLAUDE.md "Pull request size"

Both texts were read from disk on 2026-08-25 (worktree at 6d321de; global CLAUDE.md live copy).

| Constraint | AGENTS.md (lines 365-367, one sentence per line) | Global CLAUDE.md "Pull request size" |
|---|---|---|
| No numeric cap | "There is no line cap: ..." | "There is no line cap. A number was the wrong gate ..." |
| Ponytail gate loop | "... run `/ponytail-review` on the diff, cut everything it names, and re-run it until it answers `Lean already. Ship.`" | "run `/ponytail-review` on the diff ... Cut everything it names, then re-run it. When it answers `Lean already. Ship.` ... Open the PR." |
| Green PR never held on size | "Never hold or reject an otherwise green PR on size alone." (pre-existing sentence, deliberately kept) | Consistent with "A large lean diff is fine." |
| Split rule | "Split only on genuinely independent seams, never because a total looked big, and a split that leaves an intermediate PR broken is not a split." | "Split when the change has genuinely independent seams, not because a total looked big. ... A split that leaves an intermediate PR broken or untested is not a split ..." |

Verdict: same rule in substance, no second wording that could diverge; a reader following either lands in the same place.
No numeral appears in any added line (checked: `git diff 0981b6ec..6d321de | grep '^+' | grep -oE '[0-9]+'` returns nothing).
