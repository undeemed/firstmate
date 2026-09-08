#!/usr/bin/env bash
# Scaffold a crewmate brief or persistent secondmate charter at
# data/<task-id>/brief.md under the active firstmate home.
# For ordinary tasks, the standard Setup/Rules/Definition-of-done contract is
# filled in. Firstmate then replaces the {TASK} placeholder with the task
# description, acceptance criteria, and context, and may adjust other sections
# when the task genuinely deviates (e.g. working an existing external PR instead
# of shipping a new one).
# Usage: fm-brief.sh <task-id> <repo-name> --mode <no-mistakes|direct-PR|local-only>
#          [--herdr-lab] [--pr-body-required <file>]
#        fm-brief.sh <task-id> <repo-name> --scout [--herdr-lab]
#        fm-brief.sh <task-id> --secondmate {<project>...|--no-projects}
#   --scout writes the scout contract instead: the deliverable is a report at
#   data/<task-id>/report.md (no branch, no push, no PR) and the worktree is scratch.
#   --secondmate writes a persistent secondmate charter. The project list
#   is cloned into the secondmate home, while the natural-language scope
#   tells the main firstmate when to route work there; routine churn stays in its own home;
#   captain-relevant escalations and marked from-firstmate replies append to this
#   home's status file.
#   --no-projects writes a project-less charter for a domain whose subject is the
#   firstmate repo itself (its home is a firstmate worktree, its crews take pooled
#   worktrees of the same repo). It is mutually exclusive with a project list, and
#   omitting both still fails loudly so an accidental omission is never silent.
#   Set FM_SECONDMATE_CHARTER='<charter>' to fill the charter text.
#   Set FM_SECONDMATE_SCOPE='<scope>' to write a routing scope distinct from the charter text.
#   --herdr-lab is mandatory when the task will issue Herdr lifecycle commands.
#   It adds the hard isolation contract backed by bin/fm-herdr-lab.sh.
#   The flag must be explicit because {TASK} is filled after scaffolding and the
#   caller-supplied repo string cannot reliably identify this repo. Briefs made
#   without it carry a loud declaration so an omitted contract cannot be silent.
# For ship tasks, --mode is REQUIRED and shapes the definition of done. Firstmate
# resolves it per task at intake (AGENTS.md section 7); data/projects.md holds the
# captain's standing posture as context, and this script never reads it:
#   no-mistakes  implement -> /no-mistakes pipeline -> PR -> configured merge authority
#   direct-PR    implement -> push + open PR via gh-axi (no pipeline) -> configured merge authority
#   local-only   implement on branch, stop and report "ready in branch" (no push/PR);
#                the configured merge authority approves, firstmate merges to local main
# no-mistakes-prod-only is a registry policy, not a task mode; resolve it to one of
# the three concrete modes at intake before calling this script.
# The generated ship brief records the chosen mode as a fixed machine-readable
# "Delivery contract: mode=<mode>" line. bin/fm-spawn.sh reads that line and refuses
# to launch a ship task whose explicit --mode disagrees, so an adjusted brief and the
# recorded task metadata cannot drift apart.
# Ship briefs begin with a worktree-isolation assertion before the branch step.
# Every ship mode also carries AGENTS.md's ponytail lean gate, worded for that
# mode's own delivery point (the PR body for the PR modes, the branch handoff for
# local-only), and no scaffold states a size number because the gate replaced the
# line cap. Scouts and charters never carry it.
# LEAN_GATE below owns the invocation, the exit codes, and the three-round bound
# for all three modes.
# --mode is refused on scout and secondmate scaffolds: a scout's deliverable is a
# report rather than a merge, and a charter is not a delivery contract.
# There is no --yolo flag here. The worker never owns merge decisions, so yolo is
# a spawn-time and firstmate-side input only (AGENTS.md section 7).
# --pr-body-required <file> declares content the PUBLISHED pull request body must
# end with, for a repository whose own policy requires it (an AI-assistance
# disclosure, for example). It applies only to the two PR-publishing ship modes,
# because local-only publishes nothing. The file's content is stored at
# data/<task-id>/pr-body-required.md, and bin/fm-pr-check.sh carries it into the
# published body and verifies it there over REST; that script's header owns the
# publication contract. The brief tells the worker the content is declared and
# that it must not hand-write it, because the pipeline composes the body itself
# and a hand-written copy would be dropped or duplicated. Without this flag a
# generated brief is unchanged and no body is ever read or written.
# Every scaffold's status protocol distinguishes the configured
# declared-external-wait verb (FM_CLASSIFY_PAUSED_VERB, default "paused") from
# "blocked:": pause for a known external wait expected to clear on its own,
# blocked when firstmate must act.
# Ship and scout status protocols also require the worker to DECLARE that it is
# stopping - pause or blocked, including a finished block with nothing queued -
# before it goes quiet, because a still pane with no declared state costs
# supervision a deep inspection to tell apart from a wedge.
# Every scaffold also carries the same status-honesty contract: `done:` is a
# claim that the deliverable its definition of done names exists, so it must
# name that evidence, and work that is only intended, committed locally, or
# analyzed stays `working:` or `blocked:`.
# Every scaffold also carries the same progress-visibility contract: stacked
# ASCII progress bars in the worker's OWN output, every percentage derived from
# a real done/total count it can name, and no bar at all when there is no
# countable denominator. It does not loosen the status protocol: a status append
# stays one sparse supervisor-actionable line, a bar is never a reason to
# append, and a stacked bar block must never be appended to a status file,
# because every supervisor reads that file's LAST line
# (bin/fm-classify-lib.sh last_status_line) and trailing bar lines would hide
# the done:/blocked:/needs-decision: verb the append exists to deliver.
# Every scaffold's status protocol also teaches the stated decision-key position
# (needs-decision [key=<slug>]: <summary>), because a key written later in the
# line folds under the shared "default" bucket and cannot be answered by its own
# key; bin/fm-classify-lib.sh owns that grammar and the drain warning that
# catches a misplaced one.
# Every worker scaffold's rules also forbid waiting on a forge by polling it in a
# shell loop and point at firstmate's armed merge poll (bin/fm-pr-check.sh)
# instead; FORGE_POLL_RULE below owns that text and the measured reason for it.
# Ship tasks include a project-memory section so durable project-intrinsic
# learnings can be committed to AGENTS.md through the project's delivery path;
# it carries the AGENTS.md authoring bar (widely useful knowledge only, pointers
# over copied detail) and has the crewmate add the fm-ensure-agents-md.sh
# self-governance section when a touched project AGENTS.md lacks it.
# Refuses to overwrite an existing brief.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

# shellcheck source=bin/fm-marker-lib.sh
. "$SCRIPT_DIR/fm-marker-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
PAUSED_VERB=${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}

resolve_directory_input() {
  local name=$1 path=$2 resolved
  case "$path" in
    /*) printf '%s\n' "$path"; return 0 ;;
  esac
  resolved=$(CDPATH='' cd -- "$path" 2>/dev/null && pwd -P) || {
    echo "error: $name directory cannot be resolved: $path" >&2
    return 1
  }
  printf '%s\n' "$resolved"
}

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME=$(resolve_directory_input FM_HOME "${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}") || exit 1
if [ -n "${FM_DATA_OVERRIDE:-}" ]; then
  DATA=$(resolve_directory_input FM_DATA_OVERRIDE "$FM_DATA_OVERRIDE") || exit 1
else
  DATA="$FM_HOME/data"
fi
if [ -n "${FM_STATE_OVERRIDE:-}" ]; then
  STATE=$(resolve_directory_input FM_STATE_OVERRIDE "$FM_STATE_OVERRIDE") || exit 1
else
  STATE="$FM_HOME/state"
fi
KIND=ship
HERDR_LAB=0
NO_PROJECTS=0
PR_BODY_REQUIRED=
MODE=
MODE_SET=0
POS=()
want_value=
for a in "$@"; do
  if [ -n "$want_value" ]; then
    case "$a" in
      --*) echo "error: --$want_value requires a value" >&2; exit 1 ;;
    esac
    case "$want_value" in
      mode) MODE=$a; MODE_SET=1 ;;
      pr_body_required)
        [ -n "$a" ] || { echo "error: --pr-body-required requires a value" >&2; exit 1; }
        PR_BODY_REQUIRED=$a ;;
      *) echo "error: internal parser state for --$want_value" >&2; exit 1 ;;
    esac
    want_value=
    continue
  fi
  case "$a" in
    --scout) KIND=scout ;;
    --secondmate) KIND=secondmate ;;
    --herdr-lab) HERDR_LAB=1 ;;
    --no-projects) NO_PROJECTS=1 ;;
    --mode) want_value=mode ;;
    --mode=*) MODE=${a#--mode=}; MODE_SET=1 ;;
    --pr-body-required) want_value=pr_body_required ;;
    --pr-body-required=*)
      PR_BODY_REQUIRED=${a#--pr-body-required=}
      [ -n "$PR_BODY_REQUIRED" ] || { echo "error: --pr-body-required requires a value" >&2; exit 1; }
      ;;
    # yolo never reaches the worker: it is firstmate's merge authority, not a
    # brief input. Refuse it loudly so it is never silently dropped here and then
    # believed to have been recorded.
    --yolo|--yolo=*) echo "error: --yolo is not a brief input; pass it to bin/fm-spawn.sh, which records the task's merge posture" >&2; exit 1 ;;
    *) POS+=("$a") ;;
  esac
done
[ -z "$want_value" ] || { echo "error: --$want_value requires a value" >&2; exit 1; }

# Ship delivery mode is an explicit per-task decision (AGENTS.md section 7). A
# missing or invalid value stops the scaffold rather than silently defaulting.
if [ "$KIND" = ship ]; then
  [ "$MODE_SET" -eq 1 ] || {
    echo "error: ship briefs require --mode <no-mistakes|direct-PR|local-only>; resolve it at intake from the captain's instruction and the project's registered posture in data/projects.md" >&2
    exit 1
  }
  case "$MODE" in
    no-mistakes|direct-PR|local-only) ;;
    no-mistakes-prod-only)
      echo "error: no-mistakes-prod-only is a registry policy, not a task mode; classify this task's surface and resolve it to no-mistakes or direct-PR at intake" >&2
      exit 1 ;;
    *) echo "error: --mode must be one of no-mistakes, direct-PR, local-only (got '$MODE')" >&2; exit 1 ;;
  esac
elif [ "$MODE_SET" -eq 1 ]; then
  echo "error: --mode applies only to ship briefs; a scout delivers a report and a secondmate charter is not a delivery contract" >&2
  exit 1
fi
ID=${POS[0]}

if [ "$KIND" = secondmate ] && [ "$HERDR_LAB" -eq 1 ]; then
  echo "error: --herdr-lab applies only to crewmate ship or scout briefs" >&2
  exit 1
fi

if [ "$NO_PROJECTS" -eq 1 ] && [ "$KIND" != secondmate ]; then
  echo "error: --no-projects applies only to --secondmate charters" >&2
  exit 1
fi

# Declared body content is only meaningful where a body is published, and a
# blank file is refused here rather than becoming a declaration the publication
# gate later refuses.
if [ -n "$PR_BODY_REQUIRED" ]; then
  case "$KIND:$MODE" in
    ship:no-mistakes|ship:direct-PR) ;;
    *) echo "error: --pr-body-required applies only to a ship brief in a mode that publishes a PR (no-mistakes, direct-PR)" >&2; exit 1 ;;
  esac
  [ -f "$PR_BODY_REQUIRED" ] || { echo "error: --pr-body-required file not found: $PR_BODY_REQUIRED" >&2; exit 1; }
  grep -q '[^[:space:]]' "$PR_BODY_REQUIRED" \
    || { echo "error: --pr-body-required file is blank: $PR_BODY_REQUIRED" >&2; exit 1; }
fi

BRIEF="$DATA/$ID/brief.md"
[ -e "$BRIEF" ] && { echo "error: $BRIEF already exists" >&2; exit 1; }
mkdir -p "$DATA/$ID"

PR_BODY_FILE="$DATA/$ID/pr-body-required.md"
[ -z "$PR_BODY_REQUIRED" ] || cp -- "$PR_BODY_REQUIRED" "$PR_BODY_FILE" || exit 1

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

STATUS_FILE=$(shell_quote "$STATE/$ID.status")

# Progress-visibility contract, byte-identical in every scaffold so a worker's
# progress reporting never depends on which kind of brief it received. Built
# with a QUOTED heredoc so its backticks, braces, and box-drawing cells reach
# the reading agent verbatim; the interpolating brief heredocs below expand
# "$PROGRESS_SECTION" once and never rescan its bytes.
IFS= read -r -d '' PROGRESS_SECTION <<'EOF' || true
# Progress - do not be a black box
The status protocol above owns WHEN you append a status line.
This owns what your own working output shows in between, so a supervisor can see where the work actually is without asking.

While working on anything with more than a couple of steps, print ASCII progress bars in your own output.
Exact format, fixed width so stacked lines read as a table:

```
Agent repair   [██░░░░░░░░░░░░]  10%
Batch 7        [████████████░░]  88%
Whole build    [████░░░░░░░░░░]  34%
```

- Label left-aligned and padded to the widest label in the group.
- Bar is exactly 14 cells between `[` and `]`, `█` filled and `░` empty, filled cells = `round(percent * 14 / 100)`.
- Percent right-aligned in 3 characters, then `%`, separated from the bar by two spaces.
- Show the tracks that exist, innermost first: the unit of work in hand, its parent batch, then the whole job. One track is fine; never invent a hierarchy to fill lines.

Print a group when progress genuinely moves - a step completing, a batch finishing - not on every line, and not on a timer.
Re-print the whole group each time rather than a single changed line, so the latest block always shows the full picture.
A bar never replaces the substance: it sits with the sentence that says what happened and what is next.

**Every percentage must come from a real count you can name**: tests passed over total, files migrated over total, steps done over planned, subtasks merged over opened.
Derive it as `done / total`, and be ready to say what the two numbers were.

**Never invent a number to look busy.** A fabricated 34% is worse than no bar, because it reads as measurement and a supervisor will act on it.
When there is no countable denominator, print the honest shape instead and omit the bar entirely:

```
Root cause     step 3, total unknown - still narrowing
```

Bars never change WHEN you append status, and a bar is never a reason to append one: status stays sparse supervisor-actionable events.
Keep the append itself ONE line, and never append a stacked bar block to the status file: supervision reads the LAST line of that file, so trailing bar lines would hide the `done:`, `blocked:`, or `needs-decision:` verb the append exists to deliver.
A status line you were already going to append may end with one compact inline bar built from the same real count, for example:
`working: fix implemented, tests 34/40 [████████████░░]  85%`
EOF
PROGRESS_SECTION=${PROGRESS_SECTION%$'\n'}

# Status-honesty contract, byte-identical in every scaffold so no delivery mode
# can be the one variant a worker reads as permission to report an intention.
# Quoted heredoc for the same reason as PROGRESS_SECTION above: its backticks
# must reach the reading agent verbatim.
IFS= read -r -d '' STATUS_HONESTY <<'EOF' || true
# Status honesty
Append `done:` ONLY when the deliverable your definition of done names provably exists, and name that evidence in the line: the pull request URL, the report path, the merged commit, or the committed branch it requires.
Reporting `done:` for work you have not finished - no PR where your definition of done requires one, no report written, an unpushed commit, or an analysis you are about to turn into the deliverable - is a false report, not a status update.
If you intend to finish but have not finished, the line is `working:`, or `blocked:` when you need help - never `done:`.
EOF
STATUS_HONESTY=${STATUS_HONESTY%$'\n'}

# Forge-poll prohibition, byte-identical in every worker scaffold, quoted for the
# same backtick reason as the two blocks above. A hand-written wait loop re-reads
# the PR through GraphQL on every iteration: `gh-axi pr view` costs 2 points, so a
# 45-second loop spends 160 of the fleet's shared 5,000 points per hour per PR
# waited on. The armed merge poll bin/fm-pr-check.sh spends none of that budget.
IFS= read -r -d '' FORGE_POLL_RULE <<'EOF' || true
   Never wait on a forge by polling it in a shell loop - no `while ...; do gh pr view ...; sleep ...; done`
   and no `gh pr checks` variant of it. Every iteration spends the fleet's shared GraphQL budget, and one
   hour of waiting can empty it for every other task. Report the PR URL and stop instead: firstmate arms
   the merge poll (`bin/fm-pr-check.sh`), which watches the PR on the supervision sweep at no GraphQL cost.
EOF
FORGE_POLL_RULE=${FORGE_POLL_RULE%$'\n'}

if [ "$KIND" = secondmate ]; then
SECONDMATE_PROJECTS=""
idx=1
while [ "$idx" -lt "${#POS[@]}" ]; do
  SECONDMATE_PROJECTS="${SECONDMATE_PROJECTS}${SECONDMATE_PROJECTS:+ }${POS[$idx]}"
  idx=$((idx + 1))
done
if [ "$NO_PROJECTS" -eq 1 ]; then
  [ -z "$SECONDMATE_PROJECTS" ] || { echo "error: --no-projects cannot be combined with a project list" >&2; exit 1; }
else
  [ -n "$SECONDMATE_PROJECTS" ] || { echo "error: --secondmate requires at least one project, or --no-projects for a project-less home" >&2; exit 1; }
fi
SECONDMATE_CHARTER=${FM_SECONDMATE_CHARTER:-"{TASK}"}
SECONDMATE_SCOPE=${FM_SECONDMATE_SCOPE:-${FM_SECONDMATE_CHARTER:-"{TASK}"}}
if [ "$NO_PROJECTS" -eq 1 ]; then
  PROJECT_CLONES_BODY="None. This is a project-less domain: its subject is the firstmate repo this home lives in, so it needs no separate clones under \`projects/\`; its crews take pooled worktrees of that firstmate repo."
  PROJECT_CLONES_NOTE="This domain has no separate project clones: its subject is the firstmate repo this home lives in, and its crews take pooled worktrees of that repo."
else
  PROJECT_CLONES_BODY=$(printf '%s\n' "$SECONDMATE_PROJECTS" | tr ' ' '\n' | sed 's/^/- /')
  PROJECT_CLONES_NOTE="The projects above are local clones for work you supervise; they are not an exclusive ownership claim."
fi
cat > "$BRIEF" <<EOF
You are a persistent second mate managed by the main firstmate. Work on your own; do not wait for a human.

# Charter
$SECONDMATE_CHARTER

# Routing scope
$SECONDMATE_SCOPE

# Project clones
$PROJECT_CLONES_BODY

# Operating model
You are in an isolated firstmate home. The local \`AGENTS.md\` is your job description, and your local \`data/\`, \`state/\`, \`config/\`, and \`projects/\` dirs are yours to operate.
$PROJECT_CLONES_NOTE
Delegate project work to your own crewmates with the normal firstmate lifecycle: brief, spawn, status, watcher, steer, teardown, and recovery.
Do not invent a second delegation system.
You do not generate your own work.
Act only on tasks the main firstmate routes to you.
Never start a survey, audit, or "find improvements" sweep on your own initiative; that is not your job and it is unwanted.

# Requests from the main firstmate
You are a firstmate in your own home, so an incoming message reaches you in your own chat.
You must distinguish who it is from, because the answer goes to a different place.
A request relayed to you by the main firstmate is tagged with a leading \`$FM_FROMFIRST_LABEL\` marker followed by an invisible system separator; this marker is untypable, so a human never produces it.
When a message carries that marker, do the work, then respond via the STATUS/ESCALATION path below, never only in this chat: the main firstmate does not read your chat, so a chat-only reply is lost.
Marked requests also carry a privacy-safe \`corr=<id>\` token after the marker; include that exact token in your parent status reply (or in the status pointer to a detailed doc) so the parent can correlate the answer.
Optional helper: \`bin/fm-secondmate-report.sh\` can append a correlated status line for you, but a plain \`echo\` that includes the same \`corr=<id>\` is equally valid - do not depend on the helper being present.
For a terse result, a status line is the whole answer.
For a detailed answer (an investigation, a plan, an audit), write it to a doc under your home's \`data/\` and append a status line that points to that doc - the scout-report pattern - so the main firstmate is woken and can read it.
Before treating an investigation or visual review as complete, load \`captain-hold-lifecycle\` from this home's \`.agents/skills/\` and pass its shared completion gate.
A message with NO marker is the captain typing directly into your pane: treat it as authoritative captain intervention and stay conversational exactly as you would for any captain message; do not force it onto the status path.

# Escalation to main firstmate
Handle routine work yourself.
Report only true captain-relevant outcomes or a declared external wait by appending one line:
   \`echo "{state}: {one short line}" >> $STATUS_FILE\`
States: working, needs-decision, blocked, $PAUSED_VERB, done, failed.
Use \`$PAUSED_VERB: {why}\` (distinct from \`blocked:\`) only when your domain is deliberately idling on a known external wait you expect to clear on its own; use \`blocked:\` when you are stuck and need firstmate to act.
Use this only for material phase changes, a captain decision, a real blocker, a failure, or work ready for review.
This is also how you return the answer to a marked from-firstmate request above.
A marked request requires one correlated answer after the work; it does not require a separate receipt or start acknowledgement.
Never append \`working:\` merely to acknowledge receipt or announce that a marked request has started.
When a routed-work phase has a supervisor-actionable material change worth reporting under the rule above, give that reported phase a stable key.
If its first reportable event is \`working [key=<work-slug>]: {material phase}\`, use the same key on its later \`$PAUSED_VERB\`, \`done\`, \`failed\`, \`needs-decision\`, or \`blocked\` event so the earlier working phase is superseded.
When a keyed phase ends without another reportable state, append \`resolved [key=<work-slug>]: {why it is no longer active}\`.
An escalation is keyed the same way: \`needs-decision [key=<slug>]: {summary}\` and \`blocked [key=<slug>]: {why}\`.
Every \`[key=...]\` token must sit BEFORE the colon; written later in the line it is read as message text, so the event files under the shared \`default\` key and cannot be answered by its own key.
\`resolved\` separately closes an escalated decision or blocker, and only a \`resolved\` line carrying that decision's exact key closes it: a later \`done\` or \`working\` event never does, even when the answer is what started that work.
The main firstmate's answer normally writes that closing line at answer time; when a blocker or wait clears WITHOUT an answer from the main firstmate, append \`resolved [key=<slug>]: {how it cleared}\` yourself (the same key you opened it with, or a bare \`resolved: {how it cleared}\` when you opened it unkeyed) as your domain resumes.
Routine internal supervision, heartbeats, retries, and crewmate churn stay inside your own home and must not touch that status file.

$STATUS_HONESTY

$PROGRESS_SECTION

# Definition of done
You are persistent by default. Do not exit just because your queue is empty.
On startup and restart, run normal firstmate bootstrap and recovery through \`bin/fm-session-start.sh\` for your own home, but only to RECONCILE work that is already yours: in-flight crewmates, tracked backlog items, and durable watches recorded in this home.
When you have no assigned or in-flight work after that reconciliation, go idle and wait silently for the main firstmate to route you a task.
An empty queue is a healthy resting state, not a cue to invent work: never spawn a survey, audit, or any self-directed "find work" task on your own initiative.
If this charter cannot be carried out, append \`blocked: {why}\` or \`failed: {why}\` to the main status file and stop.
EOF
if [ "$SECONDMATE_CHARTER" = "{TASK}" ]; then
  echo "scaffolded: $BRIEF (secondmate charter; replace {TASK})"
else
  echo "scaffolded: $BRIEF (secondmate charter)"
fi
exit 0
fi

REPO=${POS[1]}

if [ "$HERDR_LAB" -eq 1 ]; then
HERDR_LAB_HELPER=$(shell_quote "$FM_ROOT/bin/fm-herdr-lab.sh")
# shellcheck disable=SC2016  # single quotes are deliberate: these lines are literal brief text whose backtick-wrapped $(...) and "$HERDR_LAB_SESSION" snippets must reach the reading agent verbatim, not expand at scaffold time; only the '"$VAR"' break-outs interpolate.
HERDR_SECTION=$(printf '%s\n' \
'# Herdr isolation - HARD SAFETY CONTRACT' \
'This brief was explicitly scaffolded with `--herdr-lab` because the task will drive Herdr lifecycle behavior.' \
'On Herdr 0.7.3 the API socket is not relocatable by `HERDR_CONFIG_PATH`, `XDG_CONFIG_HOME`, or `HOME`.' \
'A named non-`default` session plus a trailing `--session <name>` on every call is the only viable local isolation.' \
'' \
'1. Set `HERDR_LAB_HELPER='"$HERDR_LAB_HELPER"'` and generate the session name with `HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name '"$ID"')`.' \
'   Install `trap '\''"$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION"'\'' EXIT` before provisioning, then provision only with `"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"`.' \
'2. Run every task-specific non-lifecycle Herdr command through `"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" <arguments...>`.' \
'   The helper appends the required trailing `--session "$HERDR_LAB_SESSION"`; `HERDR_SESSION` alone is never accepted as isolation.' \
'3. Teardown only through `"$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION"`.' \
'   It re-checks refuse-default immediately before stop and again immediately before delete, and fails closed on ambiguity.' \
'4. If an experiment requires a deliberate mid-run session stop, use only `"$HERDR_LAB_HELPER" stop "$HERDR_LAB_SESSION"`; it performs the same immediate refuse-default check.' \
'5. Forbidden commands: direct `herdr server stop`, every other server-global operation such as `herdr server live-handoff` or reload/update operations, direct `herdr session stop`, direct `herdr session delete`, and any Herdr call scoped only by ambient or inline `HERDR_SESSION`.' \
'6. The helper records the live default session before provisioning and verifies the identical fleet state after teardown.' \
'   A missing, stopped, or changed default session is a hard tripwire failure, never a cleanup warning to ignore.' \
'' \
'Never bypass the helper, even for a read-only lifecycle probe or cleanup after failure.' \
'The captain fleet uses the running `default` session.')
else
IFS= read -r -d '' HERDR_SECTION <<'EOF' || true
# Herdr lifecycle declaration - NOT ENABLED
**HARD SAFETY GATE:** this scaffold cannot inspect the task text filled in above.
If the task will start, stop, delete, restart, profile, or otherwise drive Herdr lifecycle behavior, stop and regenerate the brief with `--herdr-lab` before dispatch.
Do not add Herdr lifecycle commands to this unguarded brief by hand.
EOF
HERDR_SECTION=${HERDR_SECTION%$'\n'}
fi

if [ "$KIND" = scout ]; then
cat > "$BRIEF" <<EOF
You are a crewmate: an autonomous worker agent managed by firstmate. Work on your own; do not wait for a human.

# Task
{TASK}

$HERDR_SECTION

# Setup
You are in a disposable git worktree of $REPO, at a detached HEAD on a clean default branch.
This is a SCOUT task: the deliverable is a written report, not a PR.
The worktree is your laboratory - install, run, edit, and make scratch commits freely; all of it is discarded at teardown.
The report is the only thing that survives, so anything worth keeping must be in it.

# Rules
1. Never push to any remote and never open a PR.
2. Stay inside this worktree; the only files you may write outside it are the report and the status file below.
3. Use gh-axi for GitHub operations and chrome-devtools-axi for browser operations.
$FORGE_POLL_RULE
4. Report status by appending one line:
   \`echo "{state}: {one short line}" >> $STATUS_FILE\`
   States: working, needs-decision, blocked, $PAUSED_VERB, done, failed.
   Each append wakes firstmate, so report sparingly: only phase changes a supervisor
   would act on and the needs-decision/blocked/paused/done/failed states. No step-by-step
   FYI progress lines; firstmate reads your pane for that.
   Use \`$PAUSED_VERB: {why}\` - distinct from \`blocked:\` - ONLY when you are deliberately idling on a
   known external wait you expect to clear on its own (an upstream release, a rate-limit reset):
   firstmate then leaves your idle pane alone and rechecks it on a long cadence instead of
   treating it as a possible wedge. Use \`blocked:\` when you are stuck and need help.
   Declare every stop before you go quiet: whenever you stop making progress, append
   \`$PAUSED_VERB: {why}\` or \`blocked: {why}\` first. Finishing a block with nothing queued
   counts as stopping - say what is ready and where it sits rather than idling silently.
   A still pane with no declared state is indistinguishable from a wedge, and supervision
   must spend a deep inspection to tell them apart.
5. If you hit the same obstacle twice, append \`blocked: {why}\` and stop; firstmate will help.
6. If a decision belongs to a human (product choices, destructive actions),
   append \`needs-decision [key=<slug>]: {summary of options}\` and stop. Firstmate will reply with the decision.
   The \`[key=<slug>]\` token names that decision and must sit BEFORE the colon; \`blocked [key=<slug>]: {why}\` names a blocker the same way.
   A token written later in the line is read as message text, so the decision files under the shared \`default\` key, cannot be answered by its own key, and shares that key with every other unkeyed decision on this task.
   A decision or blocker you opened stays open until a \`resolved\` line carrying its exact key lands; a later \`done:\` or \`working:\` line never closes it, even when the answer is what started that work.
   Firstmate's reply normally writes that closing line at answer time; when a blocker or wait clears WITHOUT a firstmate reply, append \`resolved [key=<slug>]: {how it cleared}\` yourself (the same key you opened it with) as you resume.
7. Never stop, restart, or update the shared \`no-mistakes\` daemon - it is one instance serving
   every lane/home, so restarting it kills other lanes' in-flight pipeline runs. On ANY no-mistakes
   daemon error, append \`blocked: {the daemon error}\` and stop; only firstmate manages the daemon.

$STATUS_HONESTY

$PROGRESS_SECTION

# Definition of done
Write your findings to \`$DATA/$ID/report.md\`.
The report must stand alone: what you did, what you found, the evidence (commands run, output, file:line references), and what you recommend.
If your deliverable is a visual artifact the captain will review and iterate on, you may host the Lavish review loop yourself (poll, revise, re-serve, staying alive) instead of handing it back to firstmate.
Before reporting done, read and follow \`$FM_ROOT/.agents/skills/captain-hold-lifecycle/SKILL.md\` and pass its shared completion gate for the report and any visual review.
When the report is complete, append \`done: {one-line conclusion}\` to the status file and stop.
If your findings reveal work that should ship (e.g. you reproduced a bug and the fix is clear), say so in the report; firstmate may promote this task in place, and you would then receive mode-specific ship instructions as a follow-up message.
EOF
echo "scaffolded: $BRIEF (scout; replace {TASK})"
exit 0
fi

# Ponytail lean gate, identical for every ship mode so the invocation and the
# exit-code meanings have one owner. Single-quoted so its backticks reach the
# reading agent verbatim; the interpolating DOD heredocs below expand
# "$LEAN_GATE" once and never rescan its bytes.
# It teaches only the diff-against-base forms: on committed work, which is what
# every ship delivery point has, the bare form reviews an empty diff and exits 1.
# shellcheck disable=SC2016  # single quotes are deliberate: these backticks are literal brief text
LEAN_GATE='run `ponytail-review <base>` against the branch base you started from (for example `ponytail-review main`; `git diff <base>... | ponytail-review --stdin` also works), cut everything it names, and re-run it until it passes - size alone is never the test.
Exit 0 is `Lean already. Ship.` and the gate passes; exit 2 means findings remain, so cut them and run it again; exit 1 means the gate COULD NOT RUN (missing plugin, missing agent, or empty diff), which you report with `blocked:` and never as a pass.
The loop is bounded at THREE rounds because the gate does not always converge, so never run a fourth round, and never obey a finding that reverses what an earlier round ruled on the same code - record that contradiction and leave the earlier ruling standing.
When the third round still exits 2, its remaining findings and every contradiction you recorded belong in the verdict you report below as named keeps, not in another round of cutting.'

# Ship task: shape Setup / Rule 1 / Definition of done by this task's explicit
# delivery mode, validated above. The generated DOD opens with the fixed
# "Delivery contract: mode=<mode>" line that bin/fm-spawn.sh checks against its own
# explicit --mode before launching.
case "$MODE" in
  direct-PR)
    SETUP2=""
    RULE1='1. Never push to the default branch (push only your `fm/'"$ID"'` branch). Never merge a PR.'
    IFS= read -r -d '' DOD <<EOF || true
# Definition of done
Delivery contract: mode=direct-PR
This task ships **direct-PR**: you raise the PR yourself, without the no-mistakes pipeline.
The task is complete only when committed on your branch.
Before you open the PR, $LEAN_GATE
Report that verdict in the PR body, and name any finding you deliberately did not cut with the reason it earns its place.
When it is implemented and committed, push your branch and open a PR with \`gh-axi\`, then append \`done: PR {url}\` to the status file and stop.
Do NOT run /no-mistakes. The configured merge authority decides whether to merge the PR; firstmate relays the outcome.
EOF
    ;;
  local-only)
    SETUP2=""
    RULE1="1. Never push to any remote and never open a PR. Work only on your \`fm/$ID\` branch; firstmate handles the merge into local \`main\`."
    IFS= read -r -d '' DOD <<EOF || true
# Definition of done
Delivery contract: mode=local-only
This task ships **local-only**: no remote, no PR, no pipeline.
The task is complete only when committed on your branch \`fm/$ID\`. Do NOT push, do NOT open a PR, do NOT merge.
Keep your branch a clean fast-forward onto the current default branch - if \`main\` has advanced, rebase onto it so the eventual merge stays a fast-forward.
Before you hand the branch off, $LEAN_GATE
Record that verdict in your handoff, and name any finding you deliberately did not cut with the reason it earns its place.
When it is implemented and committed, append \`done: ready in branch fm/$ID\` to the status file and stop.
The configured merge authority approves the ready branch, then firstmate merges it into local \`main\` through the guarded fast-forward path.
EOF
    ;;
  *)  # no-mistakes
    SETUP2="
2. Run \`no-mistakes doctor\`; if it reports the repo is not initialized here, run \`no-mistakes init\`."
    RULE1='1. Never push to the default branch. Never merge a PR.'
    IFS= read -r -d '' DOD <<EOF || true
# Definition of done
Delivery contract: mode=no-mistakes
The task is complete only when committed on your branch.
Before the PR is opened, $LEAN_GATE
Carry that verdict into the PR body, and name any finding you deliberately did not cut with the reason it earns its place.
When you believe it is complete, append \`done: {summary}\` to the status file and stop.
Firstmate will then instruct you to run /no-mistakes to validate and ship a PR.

You drive no-mistakes by responding to its gates, not by implementing fixes.
Follow the guidance no-mistakes itself provides for the mechanics: it loads when you invoke /no-mistakes, and \`no-mistakes axi run --help\` plus the \`help\` lines in each \`axi\` response are authoritative and version-matched to the installed binary.
When starting no-mistakes, make \`--intent\` preserve all relevant content from this brief's \`# Task\` section plus every later accepted Firstmate requirement, clarification, constraint, exclusion, and supersession, carrying only each requirement's current accepted form; retain direct requirements instead of substituting a diff summary, and exclude generic operational, status, delivery, and other scaffold boilerplate unless it is task-specific.
The pipeline publishes that \`--intent\` text verbatim as the published pull request body's \`## Intent\` section, so write it for the repository's own public audience: put every requirement in the project's vocabulary, and never carry fleet-internal vocabulary (firstmate, crewmate, secondmate, captain, ponytail, treehouse, \`fm-*.sh\` script names) or any path from this worktree into it.
Firstmate reads the published body back and refuses to record a pull request whose body carries that vocabulary, so a body written for the fleet stops the task instead of shipping.
Do not hand-edit, commit, or fix findings yourself while a run is active - the pipeline applies every fix.

Two firstmate-specific rules layer on top of that guidance:
- ask-user findings are never yours to answer: escalate to firstmate (rule 6) and stop.
  Firstmate applies \`ask-user-authority\` and obtains any required captain decision.
  When the decision comes back, feed it to the gate with \`no-mistakes axi respond\` and let the pipeline apply it - do not route the question to "the user" or implement the fix yourself.
- Avoid \`--yes\`: it would silently bypass firstmate's authority check and any required captain escalation.

After /no-mistakes reports CI green (the CI-ready return point - do not wait for it to keep monitoring in the background until merge), append \`done: PR {url} checks green\` and stop. You are finished.
EOF
    ;;
esac

# read -r -d '' preserves the heredoc's trailing newline that the removed
# $(...) command substitution used to strip. Drop that one newline so generated
# briefs stay byte-identical to the historical Bash 5 output.
DOD=${DOD%$'\n'}

# Declared body content is prepended to the delivery contract rather than
# emitted as its own template line, so a brief that declares nothing stays
# byte-identical to a brief scaffolded before the flag existed.
if [ -n "$PR_BODY_REQUIRED" ]; then
  DOD="# Required pull-request body content
This task declares content the PUBLISHED pull request body must END with. It is stored at \`$PR_BODY_FILE\`.
Do not write it into the body, a commit message, or the pipeline intent yourself: in no-mistakes mode the pipeline composes the body and drops a hand-written copy, and in direct-PR mode you open the PR yourself and a hand-written copy risks being duplicated.
Firstmate carries the declared content into the published body when it records your PR, reads the body back from the forge to confirm it, and refuses loudly if the forge does not publish it.

$DOD"
fi

cat > "$BRIEF" <<EOF
You are a crewmate: an autonomous worker agent managed by firstmate. Work on your own; do not wait for a human.

# Task
{TASK}

$HERDR_SECTION

# Setup
You are in a disposable git worktree of $REPO, at a detached HEAD on a clean default branch.

**Verify isolation before anything else.** Run \`pwd -P\` and \`git rev-parse --show-toplevel\`; both must resolve to the disposable task worktree you were launched in, such as a treehouse pool path or an Orca-managed worktree, not the primary checkout firstmate operates from.
The path check is authoritative: \`git rev-parse --git-dir\` and \`git rev-parse --git-common-dir\` can help inspect the repo, but they do not prove you are outside the primary checkout.
If the top-level path is the primary checkout or not the worktree you were launched in, STOP - do not branch or commit here - append \`blocked: launched in primary checkout, not an isolated worktree\` to the status file and stop.

1. First action: create your branch: \`git checkout -b fm/$ID\`$SETUP2

# Rules
$RULE1
2. Stay inside this worktree; modify nothing outside it.
3. Use gh-axi for GitHub operations and chrome-devtools-axi for browser operations.
$FORGE_POLL_RULE
4. Report status by appending one line:
   \`echo "{state}: {one short line}" >> $STATUS_FILE\`
   States: working, needs-decision, blocked, $PAUSED_VERB, done, failed.
   Each append wakes firstmate, so report sparingly: only phase changes a supervisor
   would act on (setup done, bug reproduced, fix implemented, validation passed) and the
   needs-decision/blocked/paused/done/failed states. No step-by-step FYI progress lines;
   firstmate reads your pane for that.
   A mid-task \`working:\` line (including setup complete) is nonterminal: do not end the
   turn after it; continue the same stage until a defined \`done:\` gate under Definition of done.
   Use \`$PAUSED_VERB: {why}\` - distinct from \`blocked:\` - ONLY when you are deliberately idling on a
   known external wait you expect to clear on its own (an upstream release, a rate-limit reset,
   a scheduled window): firstmate then leaves your idle pane alone and rechecks it on a long
   cadence instead of treating it as a possible wedge. Use \`blocked:\` when you are stuck and need help.
   Declare every stop before you go quiet: whenever you stop making progress, append
   \`$PAUSED_VERB: {why}\` or \`blocked: {why}\` first. Finishing a block with nothing queued
   counts as stopping - say what is ready and where it sits rather than idling silently.
   A still pane with no declared state is indistinguishable from a wedge, and supervision
   must spend a deep inspection to tell them apart.
5. If you hit the same obstacle twice, append \`blocked: {why}\` and stop; firstmate will help.
6. If a decision belongs above the implementation worker (product choices, destructive actions, ask-user findings),
   append \`needs-decision [key=<slug>]: {summary of options}\` and stop. Firstmate will reply with the decision.
   The \`[key=<slug>]\` token names that decision and must sit BEFORE the colon; \`blocked [key=<slug>]: {why}\` names a blocker the same way.
   A token written later in the line is read as message text, so the decision files under the shared \`default\` key, cannot be answered by its own key, and shares that key with every other unkeyed decision on this task.
   A decision or blocker you opened stays open until a \`resolved\` line carrying its exact key lands; a later \`done:\` or \`working:\` line never closes it, even when the answer is what started that work.
   Firstmate's reply normally writes that closing line at answer time; when a blocker or wait clears WITHOUT a firstmate reply, append \`resolved [key=<slug>]: {how it cleared}\` yourself (the same key you opened it with) as you resume.
7. Never stop, restart, or update the shared \`no-mistakes\` daemon - it is one instance serving
   every lane/home, so restarting it kills other lanes' in-flight pipeline runs. On ANY no-mistakes
   daemon error, append \`blocked: {the daemon error}\` and stop; only firstmate manages the daemon.

$STATUS_HONESTY

$PROGRESS_SECTION

# Project memory
If \`AGENTS.md\` or \`CLAUDE.md\` already exists, or if this task produced durable project-intrinsic knowledge, run \`$FM_ROOT/bin/fm-ensure-agents-md.sh .\` in the worktree.
Record only project knowledge useful to almost every future session.
For anything the codebase already shows, prefer a pointer to the authoritative file, command, or doc over copying the detail.
If you touch a project \`AGENTS.md\` that lacks \`## Maintaining this file\`, add that short self-governance section from \`$FM_ROOT/bin/fm-ensure-agents-md.sh\` in the same pass.
Keep it proportionate: skip \`AGENTS.md\` edits for trivial tasks that produced no durable project knowledge.

$DOD
EOF
echo "scaffolded: $BRIEF (ship, mode=$MODE; replace {TASK})"
