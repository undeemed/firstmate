#!/usr/bin/env bash
# fm-secondmate-rename.sh - rename an EXITED secondmate's id, and optionally the
# project label that mate owns, across every LIVE record - never across history.
#
# Usage:
#   fm-secondmate-rename.sh <old-id> <new-id> [--project <old> <new>] [--dry-run]
#
# Why this exists: a secondmate's id is written into records that each have a
# different owner - task metadata, watcher sidecars, the pending reread nudge,
# the charter directory, the home's own identity marker, the routing record, and
# the durable treehouse lease that keeps the pool slot from being recycled.
# Renaming by hand leaves some of them behind, and a half-renamed mate is worse
# than an unrenamed one: the routing record names an id whose lease, marker, and
# metadata still carry the old one.
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
# below is read by a running agent and by supervision. The rename refuses to
# WRITE unless the recorded endpoint's recovery-grade state is `dead` or
# `missing` and the mate's busy record does not read busy. The operator runs:
#
#   bin/fm-control.sh <old-id> exit
#   bin/fm-secondmate-rename.sh <old-id> <new-id> [--project <old> <new>]
#   bin/fm-spawn.sh <new-id> <home> --secondmate
#
# Both bracketing commands are printed by every run, dry or wet.
#
# --dry-run prints the same steps, writes nothing, and reports the exit gate's
# verdict instead of enforcing it, so the plan is readable before the mate stops.
#
# Ambiguity guard: state sidecars are matched by file name, so the rename refuses
# when any other task id in this home contains the old id as a substring - a
# name-matched rename there could rewrite a sibling's records.
#
# Failure model: everything is validated before anything is written, and every
# step prints itself as it runs. A failure stops at that step and names it, so
# the printed lines above it are exactly what was applied.
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

# --- validation ------------------------------------------------------------

META="$STATE/$OLD_ID.meta"
[ -f "$META" ] && [ ! -L "$META" ] || die "no secondmate record for $OLD_ID at $META"
[ "$(fm_meta_get "$META" kind)" = secondmate ] || die "$OLD_ID is not a secondmate (kind= in $META)"

MATE_HOME=$(fm_meta_get "$META" home)
[ -n "$MATE_HOME" ] || die "$META records no home= for $OLD_ID"
[ -d "$MATE_HOME" ] || die "recorded home for $OLD_ID is not a directory: $MATE_HOME"
[ -z "$(fm_meta_get "$META" remote_host)" ] || die "$OLD_ID is a remote secondmate; rename it from its own host"

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

BACKEND=$(fm_backend_of_meta "$META")
TARGET=$(fm_backend_target_of_meta "$META")
AGENT_STATE=unverified
if [ -n "$TARGET" ]; then
	AGENT_STATE=$(fm_backend_agent_state "$BACKEND" "$TARGET" 2>/dev/null || printf 'unreadable')
fi
EXIT_GATE=
case "$AGENT_STATE" in
dead | missing) ;;
*) EXIT_GATE="$OLD_ID is not proven exited (endpoint $BACKEND $TARGET reads '$AGENT_STATE')" ;;
esac
if [ -z "$EXIT_GATE" ] && grep -q ' state=busy ' "$STATE/$OLD_ID.busy-state" 2>/dev/null; then
	EXIT_GATE="$OLD_ID still records a busy turn in $STATE/$OLD_ID.busy-state"
fi
# The exit gate guards WRITES. A dry run writes nothing, so it reports the
# verdict and still prints the steps the operator applies after that exit.
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
	base=$(basename "$path")
	new_base=${base//"$OLD_ID"/"$NEW_ID"}
	[ "$new_base" != "$base" ] || continue
	plan_move "$path" "$(dirname "$path")/$new_base"
done
shopt -u dotglob nullglob
[ ! -d "$DATA/$OLD_ID" ] || plan_move "$DATA/$OLD_ID" "$DATA/$NEW_ID"

[ -z "$OLD_PROJECT" ] || [ ! -d "$MATE_HOME/projects/$OLD_PROJECT" ] \
	|| plan_move "$MATE_HOME/projects/$OLD_PROJECT" "$MATE_HOME/projects/$NEW_PROJECT"

# Treehouse lease: this mate's own slot only, and only while it still holds it.
POOL=$MATE_HOME
until [ -f "$POOL/treehouse-state.json" ]; do
	POOL=$(dirname "$POOL")
	[ "$POOL" != / ] || {
		POOL=
		break
	}
done
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

# Values read from the OLD records, so a dry run prints exactly what the wet run
# will rewrite.
OLD_ENDPOINT_ID=$(fm_meta_get "$META" endpoint_task_id)
OLD_TASKTMP=$(fm_meta_get "$META" tasktmp)
OLD_PROJECTS_FIELD=$(fm_meta_get "$META" projects)
NEW_META="$STATE/$NEW_ID.meta"
NUDGE="$STATE/.secondmate-nudge-pending/$NEW_ID.pending"
HAD_NUDGE=0
[ ! -f "$STATE/.secondmate-nudge-pending/$OLD_ID.pending" ] || HAD_NUDGE=1
MARKER="$MATE_HOME/.fm-secondmate-home"
HOME_CHARTER="$MATE_HOME/data/charter.md"
BRIEF="$DATA/$NEW_ID/brief.md"
HAD_BRIEF=0
[ ! -f "$DATA/$OLD_ID/brief.md" ] || HAD_BRIEF=1
MATE_BACKLOG="$MATE_HOME/data/backlog.md"

# --- steps -----------------------------------------------------------------
#
# Every step prints itself and then acts, unless this is a dry run. One walk, so
# the plan cannot drift from what is applied.

do_move() { # <src> <dst>
	printf '  move   %s -> %s\n' "$1" "$2"
	[ "$DRY_RUN" -eq 0 ] || return 0
	mv -- "$1" "$2" || die "stopped at move $1 -> $2"
}

# Replace occurrences of <search> with <replace> in <file>, atomically and with
# the file's own mode preserved. The match is LITERAL, never a regex, so an id's
# dots and dashes cannot widen it. Scope "prefix" replaces only at the start of a
# line, which is how a record's own key is rewritten without touching prose that
# happens to quote it.
do_sub() { # <file> <note> <search> <replace> [all|prefix]
	local file=$1 note=$2 search=$3 replace=$4 scope=${5:-all} tmp line
	printf '  edit   %s (%s)\n' "$file" "$note"
	[ "$DRY_RUN" -eq 0 ] || return 0
	tmp=$(mktemp "$file.rename.XXXXXX") || die "stopped at $file"
	cp -p -- "$file" "$tmp" || die "stopped at $file"
	while IFS= read -r line || [ -n "$line" ]; do
		if [ "$scope" = prefix ]; then
			case "$line" in "$search"*) line=$replace${line#"$search"} ;; esac
		else
			line=${line//"$search"/"$replace"}
		fi
		printf '%s\n' "$line"
	done <"$file" >"$tmp" || die "stopped at $file"
	mv -f -- "$tmp" "$file" || die "stopped at $file"
}

echo "rename $OLD_ID -> $NEW_ID (home $MATE_HOME)"
[ -z "$OLD_PROJECT" ] || echo "project $OLD_PROJECT -> $NEW_PROJECT"
echo "endpoint state: $AGENT_STATE"
[ -z "$EXIT_GATE" ] || echo "would refuse to write: $EXIT_GATE; run bin/fm-control.sh $OLD_ID exit first"
echo

for move in ${MOVES[@]+"${MOVES[@]}"}; do
	do_move "${move%%$'\t'*}" "${move#*$'\t'}"
done

[ -z "$OLD_ENDPOINT_ID" ] ||
	do_sub "$NEW_META" "endpoint task id" "endpoint_task_id=$OLD_ENDPOINT_ID" "endpoint_task_id=$NEW_ID" prefix
[ "$OLD_TASKTMP" != "/tmp/fm-$OLD_ID" ] ||
	do_sub "$NEW_META" "build cache path" "tasktmp=/tmp/fm-$OLD_ID" "tasktmp=/tmp/fm-$NEW_ID" prefix
if [ -n "$OLD_PROJECT" ] && [ -n "$OLD_PROJECTS_FIELD" ]; then
	new_projects=",$OLD_PROJECTS_FIELD,"
	new_projects=${new_projects//",$OLD_PROJECT,"/",$NEW_PROJECT,"}
	new_projects=${new_projects#,}
	new_projects=${new_projects%,}
	[ "$new_projects" = "$OLD_PROJECTS_FIELD" ] ||
		do_sub "$NEW_META" "project list" "projects=$OLD_PROJECTS_FIELD" "projects=$new_projects" prefix
fi
[ "$HAD_NUDGE" -eq 0 ] || do_sub "$NUDGE" "pending reread nudge" "$OLD_ID" "$NEW_ID"
[ ! -f "$MARKER" ] || [ -L "$MARKER" ] || do_sub "$MARKER" "home identity marker" "$OLD_ID" "$NEW_ID"
[ ! -f "$HOME_CHARTER" ] || do_sub "$HOME_CHARTER" "charter identity" "$OLD_ID" "$NEW_ID"
[ "$HAD_BRIEF" -eq 0 ] || do_sub "$BRIEF" "charter identity" "$OLD_ID" "$NEW_ID"
if [ -f "$REG" ]; then
	! grep -q "^- $OLD_ID " "$REG" || do_sub "$REG" "routing record id" "- $OLD_ID " "- $NEW_ID " prefix
	if [ -n "$OLD_PROJECT" ] && grep -q "projects: $OLD_PROJECT;" "$REG"; then
		do_sub "$REG" "routing record project" "projects: $OLD_PROJECT;" "projects: $NEW_PROJECT;"
	fi
fi

if [ -n "$OLD_PROJECT" ]; then
	if [ -f "$PROJECT_REGISTRY" ] && grep -q "^- $OLD_PROJECT \[" "$PROJECT_REGISTRY"; then
		do_sub "$PROJECT_REGISTRY" "project registry entry" "- $OLD_PROJECT [" "- $NEW_PROJECT [" prefix
	fi
	if [ -f "$LIVE_BOARD" ] && grep -q "\"$OLD_PROJECT\": Path(" "$LIVE_BOARD"; then
		do_sub "$LIVE_BOARD" "tracked home map - commit this change" \
			"\"$OLD_PROJECT\": Path(" "\"$NEW_PROJECT\": Path("
	fi
	if [ -f "$MATE_BACKLOG" ] && grep -q "(repo: $OLD_PROJECT)" "$MATE_BACKLOG"; then
		do_sub "$MATE_BACKLOG" "repo: fields on this home's own items" "(repo: $OLD_PROJECT)" "(repo: $NEW_PROJECT)"
	fi
fi

if [ "$LEASE_ACTION" = rekey ]; then
	printf '  edit   %s (lease holder for %s)\n' "$POOL/treehouse-state.json" "$MATE_HOME"
	if [ "$DRY_RUN" -eq 0 ]; then
		lease_tmp=$(mktemp "$POOL/.treehouse-state.rename.XXXXXX") || die "stopped at treehouse lease temp file"
		(
			exec 9>>"$POOL/treehouse-state.lock"
			flock -w 30 9 || exit 1
			jq --arg home "$MATE_HOME" --arg old "$OLD_ID" --arg new "$NEW_ID" \
				'.worktrees = [.worktrees[] | if .path == $home and .lease_holder == $old then .lease_holder = $new else . end]' \
				"$POOL/treehouse-state.json" >"$lease_tmp" || exit 1
			mv -f -- "$lease_tmp" "$POOL/treehouse-state.json" || exit 1
		) || {
			rm -f -- "$lease_tmp"
			die "stopped at treehouse lease re-key in $POOL/treehouse-state.json"
		}
	fi
elif [ -n "$POOL" ]; then
	printf '  skip   %s (no lease held for %s)\n' "$POOL/treehouse-state.json" "$MATE_HOME"
fi

printf '  append %s (rename record)\n' "$STATE/$NEW_ID.status"
if [ "$DRY_RUN" -eq 0 ]; then
	printf 'note: renamed from %s at %s; transcript history under the old id\n' \
		"$OLD_ID" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$STATE/$NEW_ID.status" ||
		die "stopped at rename record in $STATE/$NEW_ID.status"
fi

echo
echo "operator sequence:"
echo "  bin/fm-control.sh $OLD_ID exit"
echo "  bin/fm-spawn.sh $NEW_ID $MATE_HOME --secondmate"
[ "$DRY_RUN" -eq 0 ] || echo "dry run: nothing was written"
