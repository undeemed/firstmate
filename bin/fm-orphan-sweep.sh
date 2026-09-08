#!/usr/bin/env bash
# fm-orphan-sweep.sh - reclaim the per-task litter no owner is left to clean.
#
# WHY IT EXISTS
#   bin/fm-teardown.sh removes what a task's own records name. Litter that
#   outlives its records has no owner at all: a desktop whose task meta was
#   already deleted, a treehouse pool whose source repository is gone, a
#   disowned browser reparented to init, a scratch directory in /tmp older than
#   the session that made it. Measured on 2026-09-05: four dead per-task
#   desktops (~560 MB), 1533 leaked test-fixture worktrees under ~/.treehouse
#   (~700 MB), a ten-day headless chromium at ppid 1, and 3.5 GB of /tmp older
#   than two days.
#
# USAGE
#   fm-orphan-sweep.sh [--dry-run]
#
#   Prints one line per removal and a closing summary. Prints NOTHING when
#   there is nothing to reclaim, so bin/fm-wake-drain.sh can call it on a
#   schedule without adding noise to a quiet turn.
#   --dry-run reports exactly what would be removed and removes nothing.
#
# WHAT IS SWEPT, AND THE PROOF EACH CATEGORY NEEDS
#   Every category refuses on missing evidence rather than guessing, and every
#   one of them additionally refuses anything a live mate owns.
#
#   desktops     $FM_DESKTOP_ROOT/<name> plus its registry line, when no live
#                mate records <name> as a task, its display is down, no live
#                process runs in it, and nothing under it changed in three
#                days. A registry line whose directory is already gone is
#                dropped on the same proof, which is what returns its display
#                number to the allocator.
#   treehouse    a pool directory under $HOME/.treehouse whose worktrees all
#                point (through their `gitdir:` file) at a source repository
#                that no longer exists, when no live mate records a path inside
#                it, treehouse itself records no lease in it, no live process
#                runs in it, and nothing under it changed in a day. A pool
#                whose source repo still exists is a real pool, never touched.
#   processes    a process of this user at ppid 1 whose name is one of the
#                disown-survivors measured on 2026-09-05 (a ten-day headless
#                chromium, and the 66 ssh-agents and 44 caddy processes one
#                mate left behind) plus the websockify bridge a dead desktop
#                strands, AND whose working directory has been deleted or whose
#                --user-data-dir no longer exists. Signalled one pid at a time
#                and never by name pattern alone: a name match reaches another
#                home's process, which is how sessions get killed.
#   tmp          a top-level entry in /tmp owned by this user, not matching the
#                allowlist in tmp_kept_by_allowlist, with nothing under it
#                changed in two days, and no live process holding it.
#
#   No category ever changes a mode to make a removal possible: a directory
#   this user owns but cannot write to is left exactly as its owner set it.
#
# LIVE OWNERSHIP
#   A "live mate" is this home plus every firstmate home running a watcher
#   right now, discovered from the process table rather than from a hardcoded
#   layout. A name with a state/<name>.meta in any of those homes is owned and
#   is never swept, whatever its age.
#
# HOLDERS
#   Two bounded lsof scans answer "is anything using this": every process's
#   working directory, and every file open directly in /tmp. A full lsof scan
#   would answer more but costs ~31s on a busy box against ~6s for these two,
#   which is why the deep-file gap is closed by the age gate instead: an entry
#   is a candidate only when NOTHING under it has been modified inside the age
#   window, not merely when its own mtime is old. If lsof is missing or a scan
#   fails, the sweep removes nothing and says so - it never guesses that an
#   unscannable path is idle.
#
# ENVIRONMENT
#   FM_HOME                          this home (default: repo root)
#   FM_DESKTOP_ROOT                  desktop root (default ~/.fm-desktops)
#   FM_DESKTOP_LEGACY_REGISTRY       TSV registry (default <root>/registry)
#   FM_ORPHAN_SWEEP_TREEHOUSE_ROOT   pool root (default $HOME/.treehouse)
#   FM_ORPHAN_SWEEP_TMP_DIR          scratch root (default /tmp)
#   FM_ORPHAN_SWEEP_PROC_ROOT        process table (default /proc). Any other
#                                    root is a fixture: candidates are read
#                                    from its <pid>/comm, ppid, cmdline and
#                                    cwd entries and stopped by removing the
#                                    entry, so a run against a fixture root
#                                    never signals a real pid.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"

DESKTOP_ROOT="${FM_DESKTOP_ROOT:-$HOME/.fm-desktops}"
DESKTOP_REGISTRY="${FM_DESKTOP_LEGACY_REGISTRY:-$DESKTOP_ROOT/registry}"
X_SOCKET_DIR="${FM_DESKTOP_X_SOCKET_DIR:-/tmp/.X11-unix}"
TREEHOUSE_ROOT="${FM_ORPHAN_SWEEP_TREEHOUSE_ROOT:-$HOME/.treehouse}"
TMP_DIR="${FM_ORPHAN_SWEEP_TMP_DIR:-/tmp}"
PROC_ROOT="${FM_ORPHAN_SWEEP_PROC_ROOT:-/proc}"
DESKTOP_AGE_DAYS=3
TREEHOUSE_AGE_DAYS=1
TMP_AGE_DAYS=2
ORPHAN_PROCESS_NAMES='chrome|chromium|caddy|ssh-agent|websockify'

DRY_RUN=false
REMOVED=0
HOLDERS=
LIVE_HOMES=

usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; }

die() {
	printf 'fm-orphan-sweep: %s\n' "$*" >&2
	exit 1
}

case "${1:-}" in
'') ;;
--dry-run) DRY_RUN=true ;;
-h | --help | help)
	usage
	exit 0
	;;
*) die "unknown argument '$1' (see --help)" ;;
esac
[ "$#" -le 1 ] || die "unexpected arguments after '${1:-}'"

HOLDERS=$(mktemp "${TMPDIR:-/tmp}/fm-orphan-sweep.XXXXXX") || die "could not create a work file"
trap 'rm -f -- "$HOLDERS"' EXIT

# --- evidence ---------------------------------------------------------------

# Every home a live mate is working in. The watcher process is the one durable
# per-home artifact in the process table, so a home that is genuinely running
# is discovered even when this sweep has never heard of it.
collect_live_homes() {
	{
		printf '%s\n' "$FM_HOME"
		pgrep -a -u "$(id -u)" -f 'bin/fm-watch\.sh' 2>/dev/null |
			sed -n 's#.*[[:space:]]\(/[^[:space:]]*\)/bin/fm-watch\.sh.*#\1#p'
	} | sort -u
}

# Both bounded scans, one file of paths. Fails when lsof cannot answer, which
# stops every destructive category rather than treating silence as proof.
collect_holders() {
	command -v lsof >/dev/null 2>&1 || return 1
	{
		lsof -Fn -w -n -P -d cwd 2>/dev/null || true
		[ -d "$TMP_DIR" ] && { lsof -Fn -w -n -P +d "$TMP_DIR" 2>/dev/null || true; }
	} | sed -n 's/^n//p' >"$HOLDERS"
	[ -s "$HOLDERS" ]
}

# A live mate records this name as a task.
owned_by_live_mate() { # <name>
	local home
	while IFS= read -r home; do
		[ -n "$home" ] || continue
		[ -f "$home/state/$1.meta" ] && return 0
	done <<<"$LIVE_HOMES"
	return 1
}

# Something is running in <dir> (its own path or anything below it).
path_held() { # <dir>
	awk -v dir="$1" 'index($0, dir "/") == 1 || $0 == dir { found = 1; exit } END { exit !found }' \
		"$HOLDERS"
}

# Anything under <dir> - including <dir> itself - changed inside the window.
# `-quit` stops at the first hit, so a live tree costs one stat, not a walk.
recently_touched() { # <dir> <days>
	local hit
	hit=$(find "$1" -newermt "-$2 days" -print -quit 2>/dev/null) || return 0
	[ -n "$hit" ]
}

# One line per action, and the one place --dry-run changes what happens.
report() { # <what was done>
	if [ "$DRY_RUN" = true ]; then
		printf 'orphan sweep: would have %s\n' "$1"
	else
		printf 'orphan sweep: %s\n' "$1"
	fi
	REMOVED=$((REMOVED + 1))
}

remove_path() { # <label> <path> <reason>
	local size
	# A directory whose owner deliberately made it unwritable cannot be emptied
	# without changing its mode, and a sweep that escalates permissions to
	# delete is not a sweep anyone should trust. Left alone, silently, because
	# the condition never clears on its own and an hourly warning about it is
	# noise rather than news.
	[ ! -d "$2" ] || [ -w "$2" ] || return 1
	size=$(du -sh "$2" 2>/dev/null | cut -f1)
	if [ "$DRY_RUN" = true ] || rm -rf -- "$2" 2>/dev/null; then
		report "removed $1 $2 (${size:-unknown}, $3)"
		return 0
	fi
	printf 'orphan sweep: could not remove %s %s\n' "$1" "$2" >&2
	return 1
}

# --- desktops ---------------------------------------------------------------

desktop_display() { # <name>
	[ -f "$DESKTOP_REGISTRY" ] || return 0
	awk -F'\t' -v a="$1" '$1 == a { print $2; exit }' "$DESKTOP_REGISTRY"
}

desktop_names() {
	local dir
	{
		[ -f "$DESKTOP_REGISTRY" ] && cut -f1 "$DESKTOP_REGISTRY"
		for dir in "$DESKTOP_ROOT"/*/; do
			[ -d "$dir" ] || continue
			dir=${dir%/}
			printf '%s\n' "${dir##*/}"
		done
	} 2>/dev/null | sort -u
}

# A desktop no live mate owns, whose display is down and whose profile nothing
# is using. Its registry line goes either way, so a display number is not held
# hostage by a directory that is already gone.
sweep_desktops() {
	local dir name display
	[ -d "$DESKTOP_ROOT" ] || return 0
	while IFS= read -r name; do
		[ -n "$name" ] || continue
		owned_by_live_mate "$name" && continue
		display=$(desktop_display "$name")
		[ -n "$display" ] && [ -e "$X_SOCKET_DIR/X$display" ] && continue
		dir="$DESKTOP_ROOT/$name"
		if [ -d "$dir" ]; then
			path_held "$dir" && continue
			recently_touched "$dir" "$DESKTOP_AGE_DAYS" && continue
			remove_path desktop "$dir" "no live mate records it, display down" || continue
		fi
		[ -n "$display" ] || continue
		if [ "$DRY_RUN" != true ] &&
			! FM_DESKTOP_LEGACY_REGISTRY="$DESKTOP_REGISTRY" \
				"$SCRIPT_DIR/fm-desktop.sh" retire "$name" >/dev/null; then
			printf 'orphan sweep: could not drop the desktop registry line for %s\n' "$name" >&2
			continue
		fi
		report "dropped the desktop registry line for $name (display :$display returned to the allocator)"
	done < <(desktop_names)
}

# --- treehouse pools --------------------------------------------------------

# A pool is orphaned when every worktree in it points (through its own
# `gitdir:` file) at a source repository that is gone. A pool with a worktree
# whose pointer cannot be read is left alone: unreadable is not proof.
pool_is_orphaned() { # <pool>
	local pointer gitdir found=1
	for pointer in "$1"/*/*/.git; do
		[ -f "$pointer" ] || continue
		gitdir=$(sed -n 's/^gitdir: //p' "$pointer" 2>/dev/null) || return 1
		[ -n "$gitdir" ] || return 1
		case "$gitdir" in
		/*) ;;
		*) gitdir="$(dirname "$pointer")/$gitdir" ;;
		esac
		found=0
		[ -e "$gitdir" ] && return 1
	done
	return "$found"
}

pool_has_lease() { # <pool>
	local state="$1/treehouse-state.json"
	[ -f "$state" ] || return 1
	grep -q '"leased": *true' "$state"
}

pool_recorded_by_live_mate() { # <pool>
	local home
	while IFS= read -r home; do
		[ -n "$home" ] || continue
		[ -d "$home/state" ] || continue
		grep -rlqF -- "$1/" "$home/state" --include='*.meta' 2>/dev/null && return 0
	done <<<"$LIVE_HOMES"
	return 1
}

sweep_treehouse_pools() {
	local pool
	[ -d "$TREEHOUSE_ROOT" ] || return 0
	for pool in "$TREEHOUSE_ROOT"/*/; do
		pool=${pool%/}
		[ -d "$pool" ] || continue
		pool_is_orphaned "$pool" || continue
		pool_has_lease "$pool" && continue
		pool_recorded_by_live_mate "$pool" && continue
		path_held "$pool" && continue
		recently_touched "$pool" "$TREEHOUSE_AGE_DAYS" && continue
		remove_path "treehouse pool" "$pool" "no worktree of it has a source repository left" || true
	done
}

# --- disowned processes -----------------------------------------------------

process_data_dir_missing() { # <pid>
	local dir
	dir=$(tr '\0' '\n' <"$PROC_ROOT/$1/cmdline" 2>/dev/null | sed -n 's/^--user-data-dir=//p' | head -1)
	[ -n "$dir" ] && [ ! -e "$dir" ]
}

process_cwd_deleted() { # <pid>
	local cwd
	cwd=$(readlink "$PROC_ROOT/$1/cwd" 2>/dev/null) || return 1
	case "$cwd" in
	*' (deleted)') return 0 ;;
	esac
	return 1
}

# Signal one proven pid at a time, on evidence read from that pid's own /proc
# entry rather than from its name.
orphan_process_candidates() {
	local entry pid name ppid
	if [ "$PROC_ROOT" = /proc ]; then
		pgrep -l -u "$(id -u)" -P 1 -x "$ORPHAN_PROCESS_NAMES" 2>/dev/null
		return 0
	fi
	for entry in "$PROC_ROOT"/[0-9]*; do
		[ -d "$entry" ] || continue
		pid=${entry##*/}
		name=$(cat "$entry/comm" 2>/dev/null) || continue
		ppid=$(cat "$entry/ppid" 2>/dev/null) || continue
		[ "$ppid" = 1 ] || continue
		printf '%s\n' "$name" | grep -qEx "$ORPHAN_PROCESS_NAMES" || continue
		printf '%s %s\n' "$pid" "$name"
	done
}

stop_orphan_process() { # <pid>
	if [ "$PROC_ROOT" = /proc ]; then
		kill -TERM "$1" 2>/dev/null
	else
		rm -rf -- "${PROC_ROOT:?}/$1"
	fi
}

sweep_orphan_processes() {
	local pid name
	[ -d "$PROC_ROOT" ] || return 0
	while read -r pid name; do
		[ -n "$pid" ] || continue
		process_cwd_deleted "$pid" || process_data_dir_missing "$pid" || continue
		if [ "$DRY_RUN" != true ]; then
			stop_orphan_process "$pid" || continue
		fi
		report "stopped disowned $name (pid $pid, its working directory or profile is gone)"
	done < <(orphan_process_candidates)
}

# --- /tmp -------------------------------------------------------------------

# The shared machinery a sweep must never break: every dot-entry (X sockets and
# locks, ICE, font), and the well-known sockets and scratch roots of tools that
# hold them open far longer than the age window.
tmp_kept_by_allowlist() { # <name>
	case "$1" in
	.* | dbus-* | systemd-* | snap* | ssh-* | tmux-* | dotnet-diagnostic-* | nix-shell-*) return 0 ;;
	esac
	return 1
}

sweep_tmp_entries() {
	local entry name
	[ -d "$TMP_DIR" ] || return 0
	while IFS= read -r entry; do
		[ -n "$entry" ] || continue
		name=${entry##*/}
		tmp_kept_by_allowlist "$name" && continue
		path_held "$entry" && continue
		recently_touched "$entry" "$TMP_AGE_DAYS" && continue
		remove_path "tmp entry" "$entry" "older than $TMP_AGE_DAYS days, nothing is using it" || true
	done < <(find "$TMP_DIR" -mindepth 1 -maxdepth 1 -user "$(id -u)" 2>/dev/null)
}

# --- run --------------------------------------------------------------------

LIVE_HOMES=$(collect_live_homes)
if ! collect_holders; then
	printf 'orphan sweep: refusing to remove anything - the process scan could not run, so no path could be proven idle\n' >&2
	exit 1
fi

sweep_desktops
sweep_treehouse_pools
sweep_orphan_processes
sweep_tmp_entries

[ "$REMOVED" -eq 0 ] || printf 'orphan sweep: %s orphan(s) in total\n' "$REMOVED"
exit 0
