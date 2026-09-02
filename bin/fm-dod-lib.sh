#!/usr/bin/env bash
# Single owner of a ship task's mode-specific "Definition of done" block.
# Sourced by bin/fm-brief.sh, which renders it into a generated ship brief, and by
# bin/fm-promote.sh, which renders it into the ship instructions a promoted scout
# receives. Both paths must hand the worker the same contract: a promoted
# no-mistakes worker that never received the ask-user escalation rule or the
# `--yes` ban is the exact delivery hole this single owner exists to close.
# fm_dod_block <no-mistakes|direct-PR|local-only> <task-id> prints the block on
# stdout with no trailing blank line. The caller validates the mode; an unknown
# mode is refused rather than silently rendered as the pipeline contract.
# The block opens with the fixed machine-readable "Delivery contract: mode=<mode>"
# line that bin/fm-spawn.sh checks a ship brief against.
# Every heredoc here stays outside a command substitution: `VAR=$(cat <<EOF ...)`
# breaks parsing of the whole file on Bash 3.2 (tests/fm-brief.test.sh).
# The ponytail lean gate is identical for every mode, so the invocation and the
# exit-code meanings have one owner here. It is single-quoted so its backticks
# reach the reading agent verbatim; the interpolating heredocs below expand
# "$FM_DOD_LEAN_GATE" once and never rescan its bytes.
# It teaches only the diff-against-base forms: on committed work, which is what
# every ship delivery point has, the bare form reviews an empty diff and exits 1.
# shellcheck disable=SC2016  # single quotes are deliberate: these backticks are literal brief text
FM_DOD_LEAN_GATE='run `ponytail-review <base>` against the branch base you started from (for example `ponytail-review main`; `git diff <base>... | ponytail-review --stdin` also works), cut everything it names, and re-run it until it passes - size alone is never the test.
Exit 0 is `Lean already. Ship.` and the gate passes; exit 2 means findings remain, so cut them and run it again; exit 1 means the gate COULD NOT RUN (missing plugin, missing agent, or empty diff), which you report with `blocked:` and never as a pass.'

fm_dod_block() { # <mode> <task-id>
	local mode=$1 id=$2
	case "$mode" in
	direct-PR)
		cat <<EOF
# Definition of done
Delivery contract: mode=direct-PR
This task ships **direct-PR**: you raise the PR yourself, without the no-mistakes pipeline.
The task is complete only when committed on your branch.
Before you open the PR, $FM_DOD_LEAN_GATE
Report that verdict in the PR body, and name any finding you deliberately did not cut with the reason it earns its place.
When it is implemented and committed, push your branch and open a PR with \`gh-axi\`, then append \`done: PR {url}\` to the status file and stop.
Do NOT run /no-mistakes. The configured merge authority decides whether to merge the PR; firstmate relays the outcome.
EOF
		;;
	local-only)
		cat <<EOF
# Definition of done
Delivery contract: mode=local-only
This task ships **local-only**: no remote, no PR, no pipeline.
The task is complete only when committed on your branch \`fm/$id\`. Do NOT push, do NOT open a PR, do NOT merge.
Keep your branch a clean fast-forward onto the current default branch - if \`main\` has advanced, rebase onto it so the eventual merge stays a fast-forward.
Before you hand the branch off, $FM_DOD_LEAN_GATE
Record that verdict in your handoff, and name any finding you deliberately did not cut with the reason it earns its place.
When it is implemented and committed, append \`done: ready in branch fm/$id\` to the status file and stop.
The configured merge authority approves the ready branch, then firstmate merges it into local \`main\` through the guarded fast-forward path.
EOF
		;;
	no-mistakes)
		cat <<EOF
# Definition of done
Delivery contract: mode=no-mistakes
The task is complete only when committed on your branch.
Before the PR is opened, $FM_DOD_LEAN_GATE
Carry that verdict into the PR body, and name any finding you deliberately did not cut with the reason it earns its place.
When you believe it is complete, append \`done: {summary}\` to the status file and stop.
Firstmate will then instruct you to run /no-mistakes to validate and ship a PR.

You drive no-mistakes by responding to its gates, not by implementing fixes.
Follow the guidance no-mistakes itself provides for the mechanics: it loads when you invoke /no-mistakes, and \`no-mistakes axi run --help\` plus the \`help\` lines in each \`axi\` response are authoritative and version-matched to the installed binary.
When starting no-mistakes, make \`--intent\` preserve all relevant content from this brief's \`# Task\` section plus every later accepted Firstmate requirement, clarification, constraint, exclusion, and supersession, carrying only each requirement's current accepted form; retain direct requirements instead of substituting a diff summary, and exclude generic operational, status, delivery, and other scaffold boilerplate unless it is task-specific.
Do not hand-edit, commit, or fix findings yourself while a run is active - the pipeline applies every fix.

Two firstmate-specific rules layer on top of that guidance:
- ask-user findings are never yours to answer: escalate to firstmate (rule 6) and stop.
  Firstmate applies \`ask-user-authority\` and obtains any required captain decision.
  When the decision comes back, feed it to the gate with \`no-mistakes axi respond\` and let the pipeline apply it - do not route the question to "the user" or implement the fix yourself.
- NEVER pass \`--yes\` (or \`-y\`) to \`no-mistakes axi run\` or \`no-mistakes axi respond\`. It is banned fleet-wide.
  It auto-resolves every gate including ask-user findings with no escalation, and answering your own ask-user finding is a hard rule violation.

After /no-mistakes reports CI green (the CI-ready return point - do not wait for it to keep monitoring in the background until merge), append \`done: PR {url} checks green\` and stop. You are finished.
EOF
		;;
	*)
		echo "error: fm_dod_block: unknown delivery mode '$mode'" >&2
		return 1
		;;
	esac
}
