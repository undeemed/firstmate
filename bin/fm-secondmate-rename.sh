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
# `missing` and the semantic busy contract does not classify the mate busy. Both
# reads come from their owners - fm_backend_agent_state and fm_busy_classify_meta
# - so a stale record from a dead incarnation reads unknown rather than blocking
# the rename forever. The operator runs:
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

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$SCRIPT_DIR/fm-busy-lib.sh"

usage() {
	echo "usage: fm-secondmate-rename.sh <old-id> <new-id> [--project <old> <new>] [--dry-run]" >&2
}

die() {
	echo "error: $*" >&2
	exit 1
}

# --- arguments -------------------------------------------------------------

OLD_PROJECT=
NEW_PROJECT=
DRY_RUN=0

parse_args() {
	local positional=()
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
			positional+=("$1")
			shift
			;;
		esac
	done
	[ "${#positional[@]}" -eq 2 ] || {
		usage
		exit 1
	}
	OLD_ID=${positional[0]}
	NEW_ID=${positional[1]}
}

# An id and a project label both become path components here, so the charset
# check is the shared one and `.`/`..` are refused on top of it.
valid_token() {
	fm_busy_token_valid "${1:-}" || return 1
	case "$1" in . | ..) return 1 ;; esac
}

check_names() {
	valid_token "$OLD_ID" || die "invalid old id: $OLD_ID"
	valid_token "$NEW_ID" || die "invalid new id: $NEW_ID"
	[ "$OLD_ID" != "$NEW_ID" ] || die "old and new id are the same: $OLD_ID"
	[ -n "$OLD_PROJECT" ] || return 0
	valid_token "$OLD_PROJECT" || die "invalid old project: $OLD_PROJECT"
	valid_token "$NEW_PROJECT" || die "invalid new project: $NEW_PROJECT"
	[ "$OLD_PROJECT" != "$NEW_PROJECT" ] || die "old and new project are the same: $OLD_PROJECT"
}

# --- validation ------------------------------------------------------------

# Sets META and MATE_HOME from the mate's own task record.
read_mate_record() {
	META="$STATE/$OLD_ID.meta"
	[ -f "$META" ] && [ ! -L "$META" ] || die "no secondmate record for $OLD_ID at $META"
	[ "$(fm_meta_get "$META" kind)" = secondmate ] || die "$OLD_ID is not a secondmate (kind= in $META)"
	MATE_HOME=$(fm_meta_get "$META" home)
	[ -n "$MATE_HOME" ] || die "$META records no home= for $OLD_ID"
	[ -d "$MATE_HOME" ] || die "recorded home for $OLD_ID is not a directory: $MATE_HOME"
	[ -z "$(fm_meta_get "$META" remote_host)" ] || die "$OLD_ID is a remote secondmate; rename it from its own host"
}

# No other task id in this home may contain the old id, or a name-matched sidecar
# rename could rewrite that sibling's records. The new id must be unclaimed.
check_no_collision() {
	local other_meta other_id
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
}

# Sets AGENT_STATE and EXIT_GATE, the refusal reason when the mate is not proven
# stopped. Both reads come from the owners of those contracts.
read_exit_gate() {
	local backend target verdict
	backend=$(fm_backend_of_meta "$META")
	target=$(fm_backend_target_of_meta "$META")
	AGENT_STATE=unverified
	EXIT_GATE=
	if [ -n "$target" ]; then
		AGENT_STATE=$(fm_backend_agent_state "$backend" "$target" 2>/dev/null || printf 'unreadable')
	fi
	case "$AGENT_STATE" in
	dead | missing) ;;
	*)
		EXIT_GATE="$OLD_ID is not proven exited (endpoint $backend $target reads '$AGENT_STATE')"
		return 0
		;;
	esac
	verdict=$(fm_busy_classify_meta "$META" "$OLD_ID" "$STATE")
	[ "${verdict%% *}" = busy ] || return 0
	EXIT_GATE="$OLD_ID still records a busy turn ($verdict)"
}

# --- move plan -------------------------------------------------------------

MOVES=()

plan_move() { # <src> <dst>
	[ ! -e "$2" ] || die "rename target already exists: $2"
	MOVES+=("$1"$'\t'"$2")
}

# Every state path whose file name carries the id, at the two depths the fleet
# writes - state/<name> and state/<dir>/<name> - plus the charter directory and
# the project clone. Dotfiles are the common case here, so the scan runs under
# dotglob.
plan_moves() {
	local path base new_base
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
	[ -n "$OLD_PROJECT" ] && [ -d "$MATE_HOME/projects/$OLD_PROJECT" ] || return 0
	plan_move "$MATE_HOME/projects/$OLD_PROJECT" "$MATE_HOME/projects/$NEW_PROJECT"
}

# Sets POOL and LEASE_ACTION: this mate's own treehouse slot only, and only while
# it still holds the lease.
read_lease() {
	POOL=$MATE_HOME
	LEASE_ACTION=none
	until [ -f "$POOL/treehouse-state.json" ]; do
		POOL=$(dirname "$POOL")
		[ "$POOL" != / ] || {
			POOL=
			return 0
		}
	done
	command -v jq >/dev/null 2>&1 || die "jq is required to read the treehouse lease at $POOL/treehouse-state.json"
	local holder
	holder=$(jq -r --arg home "$MATE_HOME" \
		'first(.worktrees[]? | select(.path == $home) | .lease_holder // "") // "absent"' \
		"$POOL/treehouse-state.json") || die "could not read $POOL/treehouse-state.json"
	case "$holder" in
	absent | '') ;;
	"$OLD_ID")
		command -v flock >/dev/null 2>&1 || die "flock is required to re-key the treehouse lease under $POOL/treehouse-state.lock"
		LEASE_ACTION=rekey
		;;
	*) die "the treehouse slot for $MATE_HOME is leased to '$holder', not $OLD_ID; refusing to re-key another mate's lease" ;;
	esac
}

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

# Facts that only the OLD records can answer, read before anything moves - so a
# dry run prints exactly what the wet run will rewrite, and the wet run still
# knows which optional records existed once their paths have moved.
read_old_records() {
	OLD_ENDPOINT_ID=$(fm_meta_get "$META" endpoint_task_id)
	OLD_TASKTMP=$(fm_meta_get "$META" tasktmp)
	OLD_PROJECTS_FIELD=$(fm_meta_get "$META" projects)
	HAD_NUDGE=0
	HAD_BRIEF=0
	[ ! -f "$STATE/.secondmate-nudge-pending/$OLD_ID.pending" ] || HAD_NUDGE=1
	[ ! -f "$DATA/$OLD_ID/brief.md" ] || HAD_BRIEF=1
}

apply_meta_fields() {
	local new_meta="$STATE/$NEW_ID.meta" renamed
	[ -z "$OLD_ENDPOINT_ID" ] ||
		do_sub "$new_meta" "endpoint task id" "endpoint_task_id=$OLD_ENDPOINT_ID" "endpoint_task_id=$NEW_ID" prefix
	[ "$OLD_TASKTMP" != "/tmp/fm-$OLD_ID" ] ||
		do_sub "$new_meta" "build cache path" "tasktmp=/tmp/fm-$OLD_ID" "tasktmp=/tmp/fm-$NEW_ID" prefix
	[ -n "$OLD_PROJECT" ] && [ -n "$OLD_PROJECTS_FIELD" ] || return 0
	renamed=",$OLD_PROJECTS_FIELD,"
	renamed=${renamed//",$OLD_PROJECT,"/",$NEW_PROJECT,"}
	renamed=${renamed#,}
	renamed=${renamed%,}
	[ "$renamed" != "$OLD_PROJECTS_FIELD" ] || return 0
	do_sub "$new_meta" "project list" "projects=$OLD_PROJECTS_FIELD" "projects=$renamed" prefix
}

# The records that carry the id as an identity: the reread nudge, the home's own
# marker, both charters, and the parent's routing record.
apply_identity_records() {
	local marker="$MATE_HOME/.fm-secondmate-home"
	[ "$HAD_NUDGE" -eq 0 ] ||
		do_sub "$STATE/.secondmate-nudge-pending/$NEW_ID.pending" "pending reread nudge" "$OLD_ID" "$NEW_ID"
	[ ! -f "$marker" ] || [ -L "$marker" ] || do_sub "$marker" "home identity marker" "$OLD_ID" "$NEW_ID"
	[ ! -f "$MATE_HOME/data/charter.md" ] || do_sub "$MATE_HOME/data/charter.md" "charter identity" "$OLD_ID" "$NEW_ID"
	[ "$HAD_BRIEF" -eq 0 ] || do_sub "$DATA/$NEW_ID/brief.md" "charter identity" "$OLD_ID" "$NEW_ID"
	[ -f "$REG" ] || return 0
	! grep -q "^- $OLD_ID " "$REG" || do_sub "$REG" "routing record id" "- $OLD_ID " "- $NEW_ID " prefix
	[ -n "$OLD_PROJECT" ] && grep -q "projects: $OLD_PROJECT;" "$REG" || return 0
	do_sub "$REG" "routing record project" "projects: $OLD_PROJECT;" "projects: $NEW_PROJECT;"
}

# The records that carry the project label: the project registry and the mate's
# own backlog items. No tracked code names a project's home any more - the fleet
# read layer discovers homes from the registry (bin/fm_fleet_read.py) - so there
# is no source file to rewrite here.
apply_project_records() {
	local backlog="$MATE_HOME/data/backlog.md"
	[ -n "$OLD_PROJECT" ] || return 0
	if [ -f "$PROJECT_REGISTRY" ] && grep -q "^- $OLD_PROJECT \[" "$PROJECT_REGISTRY"; then
		do_sub "$PROJECT_REGISTRY" "project registry entry" "- $OLD_PROJECT [" "- $NEW_PROJECT [" prefix
	fi
	[ -f "$backlog" ] && grep -q "(repo: $OLD_PROJECT)" "$backlog" || return 0
	do_sub "$backlog" "repo: fields on this home's own items" "(repo: $OLD_PROJECT)" "(repo: $NEW_PROJECT)"
}

apply_lease() {
	local lease="$POOL/treehouse-state.json" tmp
	if [ "$LEASE_ACTION" != rekey ]; then
		[ -z "$POOL" ] || printf '  skip   %s (no lease held for %s)\n' "$lease" "$MATE_HOME"
		return 0
	fi
	printf '  edit   %s (lease holder for %s)\n' "$lease" "$MATE_HOME"
	[ "$DRY_RUN" -eq 0 ] || return 0
	tmp=$(mktemp "$POOL/.treehouse-state.rename.XXXXXX") || die "stopped at treehouse lease temp file"
	(
		exec 9>>"$POOL/treehouse-state.lock"
		flock -w 30 9 || exit 1
		jq --arg home "$MATE_HOME" --arg old "$OLD_ID" --arg new "$NEW_ID" \
			'.worktrees = [.worktrees[] | if .path == $home and .lease_holder == $old then .lease_holder = $new else . end]' \
			"$lease" >"$tmp" || exit 1
		mv -f -- "$tmp" "$lease" || exit 1
	) || {
		rm -f -- "$tmp"
		die "stopped at treehouse lease re-key in $lease"
	}
}

# The one line that tells the new mate where its own past lives.
append_rename_record() {
	local log="$STATE/$NEW_ID.status"
	printf '  append %s (rename record)\n' "$log"
	[ "$DRY_RUN" -eq 0 ] || return 0
	printf 'note: renamed from %s at %s; transcript history under the old id\n' \
		"$OLD_ID" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$log" ||
		die "stopped at rename record in $log"
}

main() {
	parse_args "$@"
	check_names
	read_mate_record
	check_no_collision
	read_exit_gate
	read_old_records
	plan_moves
	read_lease
	# The exit gate guards WRITES. A dry run writes nothing, so it reports the
	# verdict and still prints the steps the operator applies after that exit.
	[ -z "$EXIT_GATE" ] || [ "$DRY_RUN" -eq 1 ] ||
		die "$EXIT_GATE; run bin/fm-control.sh $OLD_ID exit first"

	echo "rename $OLD_ID -> $NEW_ID (home $MATE_HOME)"
	[ -z "$OLD_PROJECT" ] || echo "project $OLD_PROJECT -> $NEW_PROJECT"
	echo "endpoint state: $AGENT_STATE"
	[ -z "$EXIT_GATE" ] || echo "would refuse to write: $EXIT_GATE; run bin/fm-control.sh $OLD_ID exit first"
	echo

	local move
	for move in ${MOVES[@]+"${MOVES[@]}"}; do
		do_move "${move%%$'\t'*}" "${move#*$'\t'}"
	done
	apply_meta_fields
	apply_identity_records
	apply_project_records
	apply_lease
	append_rename_record

	echo
	echo "operator sequence:"
	echo "  bin/fm-control.sh $OLD_ID exit"
	echo "  bin/fm-spawn.sh $NEW_ID $MATE_HOME --secondmate"
	[ "$DRY_RUN" -eq 0 ] || echo "dry run: nothing was written"
}

main "$@"
