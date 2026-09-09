#!/usr/bin/env bash
# fm-secondmate-rename.sh - rename an EXITED secondmate's id, and optionally the
# project label that mate owns, across every LIVE record - never across history.
#
# Usage:
#   fm-secondmate-rename.sh <old-id> <new-id> [--project <old> <new>] [--dry-run]
#
# Why this exists: a secondmate's id is written into records that each have a
# different owner - task metadata, watcher sidecars, the pending reread nudge,
# the charter directory, the home's own identity marker, the routing registry,
# and the durable treehouse lease that keeps the pool slot from being recycled.
# Renaming by hand leaves some of them behind, and a half-renamed mate is worse
# than an unrenamed one: the registry routes to an id whose lease, marker, and
# metadata still name the old one.
#
# What it deliberately does NOT touch:
#   - History. Status-log lines, pending-reply records, and every other
#     append-only record keep the old id, because they say what happened under
#     that name. Only the status log's FILE NAME moves, so the new id inherits
#     its own transcript, and the one line appended at the end records where that
#     history came from.
#   - The runtime endpoint. Renaming is offline by contract (see the exit gate),
#     so there is no live pane or window to re-title: the operator's relaunch
#     creates and names its own endpoint. The metadata's recorded window and pane
#     fields are left exactly as the exited endpoint left them.
#   - Anything inside a project clone, and any prose that merely mentions the old
#     name. Only structured, machine-read fields are rewritten.
#
# Exit gate (fail-closed). The mate must already be stopped, because every record
# below is read by a running agent and by supervision. The rename refuses unless
# the recorded endpoint's recovery-grade state is `dead` or `missing` and the
# mate's busy record does not read busy. The operator therefore runs, in order:
#
#   bin/fm-control.sh <old-id> exit
#   bin/fm-secondmate-rename.sh <old-id> <new-id> [--project <old> <new>]
#   bin/fm-spawn.sh <new-id> <home> --secondmate
#
# Both bracketing commands are printed by every run, dry or wet.
#
# --dry-run prints the same validated plan and exits 0 having written nothing.
#
# Ambiguity guard: state sidecars are matched by file name, so the rename refuses
# when any other task id in this home contains the old id as a substring - a
# name-matched rename there could rewrite a sibling's records.
#
# Failure model: everything is validated before anything is written. A failure
# during application stops at that step and reports every step already applied,
# so the operator repairs forward from a named point rather than guessing.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
REG="$DATA/secondmates.md"
PROJECT_REGISTRY="$DATA/projects.md"
LIVE_BOARD="$FM_ROOT/bin/fm-live-board.py"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

usage() {
	echo "usage: fm-secondmate-rename.sh <old-id> <new-id> [--project <old> <new>] [--dry-run]" >&2
}

die() {
	echo "error: $*" >&2
	exit 1
}

OLD_PROJECT=
NEW_PROJECT=
DRY_RUN=0
POSITIONAL=()

while [ "$#" -gt 0 ]; do
	case "$1" in
	--dry-run)
		DRY_RUN=1
		shift
		;;
	--project)
		[ "$#" -gt 2 ] || die "--project requires <old> <new>"
		OLD_PROJECT=$2
		NEW_PROJECT=$3
		shift 3
		;;
	-h | --help)
		usage
		exit 0
		;;
	-*)
		usage
		die "unknown option: $1"
		;;
	*)
		POSITIONAL+=("$1")
		shift
		;;
	esac
done

[ "${#POSITIONAL[@]}" -eq 2 ] || {
	usage
	exit 1
}
OLD_ID=${POSITIONAL[0]}
NEW_ID=${POSITIONAL[1]}

valid_token() {
	case "${1:-}" in
	'' | *[!A-Za-z0-9._-]*) return 1 ;;
	. | ..) return 1 ;;
	esac
	return 0
}

valid_token "$OLD_ID" || die "invalid old id: $OLD_ID"
valid_token "$NEW_ID" || die "invalid new id: $NEW_ID"
[ "$OLD_ID" != "$NEW_ID" ] || die "old and new id are the same: $OLD_ID"
if [ -n "$OLD_PROJECT" ]; then
	valid_token "$OLD_PROJECT" || die "invalid old project: $OLD_PROJECT"
	valid_token "$NEW_PROJECT" || die "invalid new project: $NEW_PROJECT"
	[ "$OLD_PROJECT" != "$NEW_PROJECT" ] || die "old and new project are the same: $OLD_PROJECT"
fi

# --- reads -----------------------------------------------------------------

meta_field() { # <meta> <key>
	local meta=$1 key=$2 line
	[ -f "$meta" ] || return 1
	while IFS= read -r line || [ -n "$line" ]; do
		case "$line" in "$key="*)
			printf '%s\n' "${line#"$key"=}"
			return 0
			;;
		esac
	done <"$meta"
	return 1
}

# Print the busy record's own state token, or "none" when the mate has no record.
busy_state() { # <state-dir> <id>
	local record=$1/$2.busy-state line
	[ -f "$record" ] || {
		printf 'none\n'
		return 0
	}
	IFS= read -r line <"$record" || {
		printf 'unreadable\n'
		return 0
	}
	case " $line " in
	*' state=busy '*) printf 'busy\n' ;;
	*' state=idle '*) printf 'idle\n' ;;
	*) printf 'unreadable\n' ;;
	esac
}

# Print the pool directory holding <home>'s treehouse-state.json, or nothing.
treehouse_pool_for() { # <home>
	local probe=$1
	while [ "$probe" != "/" ] && [ -n "$probe" ]; do
		probe=$(dirname "$probe")
		if [ -f "$probe/treehouse-state.json" ]; then
			printf '%s\n' "$probe"
			return 0
		fi
	done
	return 0
}

# --- writes ----------------------------------------------------------------

# BSD and GNU stat disagree on the mode flag, exactly as bin/fm-busy-event.sh
# documents, so the platform is resolved once rather than per call.
if [ "$(uname -s 2>/dev/null || true)" = Darwin ]; then
	file_mode() { stat -f %Lp "$1" 2>/dev/null; }
else
	file_mode() { stat -c %a "$1" 2>/dev/null; }
fi

# Replace occurrences of <search> with <replace> in <file>, atomically and with
# the file's own mode preserved. The match is LITERAL, never a regex, so an id's
# dots and dashes cannot widen it. Scope "prefix" replaces only at the start of a
# line, which is how a record's own key is rewritten without touching prose that
# happens to quote it.
literal_sub() { # <file> <search> <replace> [all|prefix]
	local file=$1 search=$2 replace=$3 scope=${4:-all} tmp mode
	tmp=$(mktemp "$file.rename.XXXXXX") || return 1
	mode=$(file_mode "$file") || mode=
	awk -v s="$search" -v r="$replace" -v scope="$scope" '
    {
      line = $0; out = ""
      if (scope == "prefix") {
        if (index(line, s) == 1) { line = r substr(line, length(s) + 1) }
        print line
        next
      }
      while ((i = index(line, s)) > 0) {
        out = out substr(line, 1, i - 1) r
        line = substr(line, i + length(s))
      }
      print out line
    }
  ' "$file" >"$tmp" || {
		rm -f -- "$tmp"
		return 1
	}
	if [ -n "$mode" ]; then
		chmod "$mode" "$tmp" || {
			rm -f -- "$tmp"
			return 1
		}
	fi
	mv -f -- "$tmp" "$file" || {
		rm -f -- "$tmp"
		return 1
	}
}

# Rewrite one "key=value" metadata field, atomically. Adds nothing: a key the
# metadata never had stays absent.
meta_set() { # <meta> <key> <value>
	local meta=$1 key=$2 value=$3 tmp line mode
	tmp=$(mktemp "$meta.rename.XXXXXX") || return 1
	mode=$(file_mode "$meta") || mode=
	while IFS= read -r line || [ -n "$line" ]; do
		case "$line" in
		"$key="*) printf '%s=%s\n' "$key" "$value" >>"$tmp" ;;
		*) printf '%s\n' "$line" >>"$tmp" ;;
		esac
	done <"$meta"
	if [ -n "$mode" ]; then
		chmod "$mode" "$tmp" || {
			rm -f -- "$tmp"
			return 1
		}
	fi
	mv -f -- "$tmp" "$meta" || {
		rm -f -- "$tmp"
		return 1
	}
}

# Print a comma-separated project list with <old> replaced by <new>. Only a whole
# entry matches, so "swarm" never rewrites "swarms-platform".
project_list_sub() { # <list> <old> <new>
	printf '%s' "$1" | awk -v old="$2" -v new="$3" -F, '
    {
      out = ""
      for (i = 1; i <= NF; i++) {
        entry = $i
        head = entry; sub(/^[ \t]*/, "", head)
        lead = substr(entry, 1, length(entry) - length(head))
        token = head; sub(/[ \t]*$/, "", token)
        if (token == old) { entry = lead new }
        out = out (i > 1 ? "," : "") entry
      }
      printf "%s", out
    }
  '
}

# --- validation ------------------------------------------------------------

META="$STATE/$OLD_ID.meta"
[ -f "$META" ] && [ ! -L "$META" ] || die "no secondmate record for $OLD_ID at $META"
[ "$(meta_field "$META" kind || true)" = secondmate ] || die "$OLD_ID is not a secondmate (kind= in $META)"

MATE_HOME=$(meta_field "$META" home || true)
[ -n "$MATE_HOME" ] || die "$META records no home= for $OLD_ID"
[ -d "$MATE_HOME" ] || die "recorded home for $OLD_ID is not a directory: $MATE_HOME"
[ -z "$(meta_field "$META" remote_host || true)" ] || die "$OLD_ID is a remote secondmate; rename it from its own host"

# No other task id in this home may contain the old id, or a name-matched sidecar
# rename could rewrite that sibling's records.
for other_meta in "$STATE"/*.meta; do
	[ -f "$other_meta" ] || continue
	other_id=$(basename "$other_meta" .meta)
	[ "$other_id" != "$OLD_ID" ] || continue
	case "$other_id" in
	*"$OLD_ID"*) die "task id $other_id contains $OLD_ID; renaming would rewrite its records" ;;
	esac
done

[ ! -e "$STATE/$NEW_ID.meta" ] || die "$NEW_ID already has a task record at $STATE/$NEW_ID.meta"
[ ! -e "$DATA/$NEW_ID" ] || die "$NEW_ID already has a data directory at $DATA/$NEW_ID"

BACKEND=$(meta_field "$META" backend || true)
[ -n "$BACKEND" ] || BACKEND=tmux
TARGET=$(meta_field "$META" window || true)
AGENT_STATE=unverified
if [ -n "$TARGET" ]; then
	AGENT_STATE=$(fm_backend_agent_state "$BACKEND" "$TARGET" 2>/dev/null || printf 'unreadable')
fi
BUSY=$(busy_state "$STATE" "$OLD_ID")
EXIT_GATE=
case "$AGENT_STATE" in
dead | missing) ;;
*) EXIT_GATE="$OLD_ID is not proven exited (endpoint $BACKEND $TARGET reads '$AGENT_STATE')" ;;
esac
if [ -z "$EXIT_GATE" ] && [ "$BUSY" = busy ]; then
	EXIT_GATE="$OLD_ID still records a busy turn in $STATE/$OLD_ID.busy-state"
fi
# The exit gate guards WRITES. A dry run writes nothing, so it reports the gate's
# verdict and still prints the plan the operator applies after that exit.
if [ -n "$EXIT_GATE" ] && [ "$DRY_RUN" -eq 0 ]; then
	die "$EXIT_GATE; run bin/fm-control.sh $OLD_ID exit first"
fi

# Sidecar moves: every state path whose file name carries the id, at the two
# depths the fleet writes - state/<name> and state/<dir>/<name>. Dotfiles are the
# common case here, so the scan runs under dotglob.
MOVES=()
plan_move() { # <src> <dst>
	[ ! -e "$2" ] || die "rename target already exists: $2"
	MOVES+=("$1"$'\t'"$2")
}
shopt -s dotglob nullglob
for path in "$STATE"/*"$OLD_ID"* "$STATE"/*/*"$OLD_ID"*; do
	[ -e "$path" ] || continue
	dir=$(dirname "$path")
	base=$(basename "$path")
	new_base=${base//"$OLD_ID"/"$NEW_ID"}
	[ "$new_base" != "$base" ] || continue
	plan_move "$path" "$dir/$new_base"
done
shopt -u dotglob nullglob
[ ! -d "$DATA/$OLD_ID" ] || plan_move "$DATA/$OLD_ID" "$DATA/$NEW_ID"

PROJECT_DIR_MOVE=
if [ -n "$OLD_PROJECT" ] && [ -d "$MATE_HOME/projects/$OLD_PROJECT" ]; then
	[ ! -e "$MATE_HOME/projects/$NEW_PROJECT" ] || die "project clone already exists: $MATE_HOME/projects/$NEW_PROJECT"
	PROJECT_DIR_MOVE="$MATE_HOME/projects/$OLD_PROJECT"$'\t'"$MATE_HOME/projects/$NEW_PROJECT"
fi

# Treehouse lease: this mate's own slot only, and only while it still holds it.
POOL=$(treehouse_pool_for "$MATE_HOME")
LEASE_ACTION=none
if [ -n "$POOL" ]; then
	command -v jq >/dev/null 2>&1 || die "jq is required to read the treehouse lease at $POOL/treehouse-state.json"
	LEASE_HOLDER=$(jq -r --arg home "$MATE_HOME" \
		'first(.worktrees[]? | select(.path == $home) | .lease_holder // "") // "absent"' \
		"$POOL/treehouse-state.json") || die "could not read $POOL/treehouse-state.json"
	case "$LEASE_HOLDER" in
	absent | '') LEASE_ACTION=none ;;
	"$OLD_ID")
		command -v flock >/dev/null 2>&1 || die "flock is required to re-key the treehouse lease under $POOL/treehouse-state.lock"
		LEASE_ACTION=rekey
		;;
	*) die "the treehouse slot for $MATE_HOME is leased to '$LEASE_HOLDER', not $OLD_ID; refusing to re-key another mate's lease" ;;
	esac
fi

# --- plan ------------------------------------------------------------------

echo "rename $OLD_ID -> $NEW_ID (home $MATE_HOME)"
[ -z "$OLD_PROJECT" ] || echo "project $OLD_PROJECT -> $NEW_PROJECT"
echo "endpoint state: $AGENT_STATE; busy record: $BUSY"
[ -z "$EXIT_GATE" ] || echo "would refuse to write: $EXIT_GATE; run bin/fm-control.sh $OLD_ID exit first"
echo
echo "paths:"
for move in ${MOVES[@]+"${MOVES[@]}"}; do
	printf '  move   %s -> %s\n' "${move%%$'\t'*}" "${move#*$'\t'}"
done
[ -z "$PROJECT_DIR_MOVE" ] || printf '  move   %s -> %s\n' "${PROJECT_DIR_MOVE%%$'\t'*}" "${PROJECT_DIR_MOVE#*$'\t'}"
echo
echo "records:"
printf '  edit   %s (endpoint_task_id, tasktmp%s)\n' "$STATE/$NEW_ID.meta" "${OLD_PROJECT:+, projects}"
[ ! -f "$STATE/.secondmate-nudge-pending/$OLD_ID.pending" ] || printf '  edit   %s (pending reread nudge)\n' "$STATE/.secondmate-nudge-pending/$NEW_ID.pending"
printf '  edit   %s (identity marker)\n' "$MATE_HOME/.fm-secondmate-home"
[ ! -f "$REG" ] || printf '  edit   %s (routing record)\n' "$REG"
[ ! -f "$MATE_HOME/data/charter.md" ] || printf '  edit   %s (charter identity)\n' "$MATE_HOME/data/charter.md"
[ ! -f "$DATA/$OLD_ID/brief.md" ] || printf '  edit   %s (charter identity)\n' "$DATA/$NEW_ID/brief.md"
if [ -n "$OLD_PROJECT" ]; then
	[ ! -f "$PROJECT_REGISTRY" ] || printf '  edit   %s (project registry entry)\n' "$PROJECT_REGISTRY"
	[ ! -f "$LIVE_BOARD" ] || printf '  edit   %s (tracked home map - commit this change)\n' "$LIVE_BOARD"
	[ ! -f "$MATE_HOME/data/backlog.md" ] || printf '  edit   %s (repo: field on this home own items)\n' "$MATE_HOME/data/backlog.md"
fi
case "$LEASE_ACTION" in
rekey) printf '  edit   %s (lease holder for %s)\n' "$POOL/treehouse-state.json" "$MATE_HOME" ;;
none) [ -z "$POOL" ] || printf '  skip   %s (no lease held for %s)\n' "$POOL/treehouse-state.json" "$MATE_HOME" ;;
esac
printf '  append %s (rename record)\n' "$STATE/$NEW_ID.status"
echo
echo "operator sequence:"
echo "  bin/fm-control.sh $OLD_ID exit"
echo "  bin/fm-spawn.sh $NEW_ID $MATE_HOME --secondmate"

if [ "$DRY_RUN" -eq 1 ]; then
	echo
	echo "dry run: nothing was written"
	exit 0
fi

# --- apply -----------------------------------------------------------------

APPLIED=()
step_failed() { # <what>
	local done_step
	echo "error: rename stopped at: $1" >&2
	echo "applied before the failure:" >&2
	for done_step in ${APPLIED[@]+"${APPLIED[@]}"}; do
		echo "  $done_step" >&2
	done
	exit 1
}

echo
for move in ${MOVES[@]+"${MOVES[@]}"}; do
	src=${move%%$'\t'*}
	dst=${move#*$'\t'}
	mv -- "$src" "$dst" || step_failed "move $src -> $dst"
	APPLIED+=("moved $src -> $dst")
done

NEW_META="$STATE/$NEW_ID.meta"
if [ -f "$NEW_META" ]; then
	if [ -n "$(meta_field "$NEW_META" endpoint_task_id || true)" ]; then
		meta_set "$NEW_META" endpoint_task_id "$NEW_ID" || step_failed "endpoint_task_id in $NEW_META"
		APPLIED+=("set endpoint_task_id=$NEW_ID")
	fi
	TASKTMP=$(meta_field "$NEW_META" tasktmp || true)
	if [ "$TASKTMP" = "/tmp/fm-$OLD_ID" ]; then
		meta_set "$NEW_META" tasktmp "/tmp/fm-$NEW_ID" || step_failed "tasktmp in $NEW_META"
		APPLIED+=("set tasktmp=/tmp/fm-$NEW_ID")
	fi
	if [ -n "$OLD_PROJECT" ]; then
		PROJECTS_FIELD=$(meta_field "$NEW_META" projects || true)
		if [ -n "$PROJECTS_FIELD" ]; then
			meta_set "$NEW_META" projects "$(project_list_sub "$PROJECTS_FIELD" "$OLD_PROJECT" "$NEW_PROJECT")" ||
				step_failed "projects in $NEW_META"
			APPLIED+=("rewrote projects= in $NEW_META")
		fi
	fi
fi

NUDGE="$STATE/.secondmate-nudge-pending/$NEW_ID.pending"
if [ -f "$NUDGE" ]; then
	literal_sub "$NUDGE" "$OLD_ID" "$NEW_ID" || step_failed "$NUDGE"
	APPLIED+=("rewrote $NUDGE")
fi

MARKER="$MATE_HOME/.fm-secondmate-home"
if [ -f "$MARKER" ] && [ ! -L "$MARKER" ]; then
	printf '%s\n' "$NEW_ID" >"$MARKER" || step_failed "$MARKER"
	APPLIED+=("rewrote $MARKER")
fi

for charter in "$MATE_HOME/data/charter.md" "$DATA/$NEW_ID/brief.md"; do
	[ -f "$charter" ] || continue
	literal_sub "$charter" "$OLD_ID" "$NEW_ID" || step_failed "$charter"
	APPLIED+=("rewrote $charter")
done

if [ -f "$REG" ]; then
	if grep -q "^- $OLD_ID " "$REG"; then
		literal_sub "$REG" "- $OLD_ID " "- $NEW_ID " prefix || step_failed "$REG"
		APPLIED+=("rewrote the routing record id")
	fi
	if [ -n "$OLD_PROJECT" ] && grep -q "projects: $OLD_PROJECT;" "$REG"; then
		literal_sub "$REG" "projects: $OLD_PROJECT;" "projects: $NEW_PROJECT;" || step_failed "$REG"
		APPLIED+=("rewrote the routing record project field")
	fi
fi

if [ -n "$OLD_PROJECT" ]; then
	if [ -n "$PROJECT_DIR_MOVE" ]; then
		src=${PROJECT_DIR_MOVE%%$'\t'*}
		dst=${PROJECT_DIR_MOVE#*$'\t'}
		mv -- "$src" "$dst" || step_failed "move $src -> $dst"
		APPLIED+=("moved $src -> $dst")
	fi
	if [ -f "$PROJECT_REGISTRY" ] && grep -q "^- $OLD_PROJECT \[" "$PROJECT_REGISTRY"; then
		literal_sub "$PROJECT_REGISTRY" "- $OLD_PROJECT [" "- $NEW_PROJECT [" prefix || step_failed "$PROJECT_REGISTRY"
		APPLIED+=("rewrote the project registry entry")
	fi
	if [ -f "$LIVE_BOARD" ] && grep -q "\"$OLD_PROJECT\": Path(" "$LIVE_BOARD"; then
		literal_sub "$LIVE_BOARD" "\"$OLD_PROJECT\": Path(" "\"$NEW_PROJECT\": Path(" || step_failed "$LIVE_BOARD"
		APPLIED+=("rewrote the home map in $LIVE_BOARD - commit this tracked change")
	fi
	if [ -f "$MATE_HOME/data/backlog.md" ] && grep -q "(repo: $OLD_PROJECT)" "$MATE_HOME/data/backlog.md"; then
		literal_sub "$MATE_HOME/data/backlog.md" "(repo: $OLD_PROJECT)" "(repo: $NEW_PROJECT)" ||
			step_failed "$MATE_HOME/data/backlog.md"
		APPLIED+=("rewrote repo: fields in $MATE_HOME/data/backlog.md")
	fi
fi

if [ "$LEASE_ACTION" = rekey ]; then
	LEASE_TMP=$(mktemp "$POOL/.treehouse-state.rename.XXXXXX") || step_failed "treehouse lease temp file"
	(
		exec 9>>"$POOL/treehouse-state.lock"
		flock -w 30 9 || exit 1
		jq --arg home "$MATE_HOME" --arg old "$OLD_ID" --arg new "$NEW_ID" \
			'.worktrees = [.worktrees[] | if .path == $home and .lease_holder == $old then .lease_holder = $new else . end]' \
			"$POOL/treehouse-state.json" >"$LEASE_TMP" || exit 1
		mv -f -- "$LEASE_TMP" "$POOL/treehouse-state.json" || exit 1
	) || {
		rm -f -- "$LEASE_TMP"
		step_failed "treehouse lease re-key in $POOL/treehouse-state.json"
	}
	APPLIED+=("re-keyed the treehouse lease to $NEW_ID")
fi

printf 'note: renamed from %s at %s; transcript history under the old id\n' \
	"$OLD_ID" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$STATE/$NEW_ID.status" ||
	step_failed "rename record in $STATE/$NEW_ID.status"
APPLIED+=("recorded the rename in $STATE/$NEW_ID.status")

echo "renamed $OLD_ID -> $NEW_ID"
for applied_step in "${APPLIED[@]}"; do
	echo "  $applied_step"
done
echo
echo "now relaunch: bin/fm-spawn.sh $NEW_ID $MATE_HOME --secondmate"
