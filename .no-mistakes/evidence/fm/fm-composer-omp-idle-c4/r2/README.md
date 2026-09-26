# Round-2 live validation (target d55edd2), 2026-09-26

Product: omp 18.3.0 with the fleet plugins (ponytail, i-have-adhd, custom-banners session-info widget), running in an isolated Herdr 0.9.1 lab session (fm-lab-ompc4-3311741-18962). The session was provisioned, had a viewer attached, and was torn down through bin/fm-herdr-lab.sh. The fleet-state tripwire confirmed the default session was unchanged. A PATH shim routed every adapter Herdr call through the lab helper, using the same pattern as tests/fm-send-secondmate-marker-herdr-e2e.test.sh. A test guard extension recorded every omp before_agent_start prompt and aborted all of them except one explicit FMLIVE-RECAP turn, so no doorbell reached a model.

Each verdict comes from the real adapter, fm_backend_herdr_composer_state, sourced either from HEAD (d55edd2) or from the base tree (682a969). "plain" is the adapter's styled=0 fallback. It was forced by making the shim refuse `--format ansi`.

Files:
- live-verdict-matrix.txt: every live snapshot, with its label, the pane's rect width, and the HEAD/BASE styled/plain verdicts.
- *.ansi / *.txt: the exact 20-row pane tail each verdict was computed from.
- live-width-sweep.txt: the idle pane at every rect width from 54 to 85 (94 is in the matrix). HEAD reads empty at every width. BASE reads pending (styled) and unknown (plain).
- live-fm-send-transcripts.txt: at width 70, BASE skips the doorbell. HEAD delivers it at widths 70 and 54. The guard's abort puts the prompt back into the omp composer, so fm-send's submit retry sends the same doorbell a second time. That comes from the guard, not the classifier; the after-send snapshot then correctly reads pending.
- live-fm-control-exit-transcript.txt: BASE refuses to exit the idle pane; HEAD stops omp.
- live-tmux-omp-transcript.txt: omp on a private tmux server, read both cursored and cursorless, at 150 and 70 columns.
- regression-test-fail-before-pass-after.log: the new test fails against base and against cf92a20, and passes against d55edd2.

Observed behavior that follows from the user-prescribed end-anchored rule (not a new failure): take a draft whose first line is blank and whose next typed row ENDS in a badge after a spaced dot, such as `status · [PR 12]`. It reads empty on HEAD (probe-draft-ending-in-badge-one-row-width70). These stay pending:
- typed rows with text after the badge
- typed rows with a context-shaped `5%/1M` cell
- a soft-wrapped draft split inside a badge, sitting above the widget
