#!/usr/bin/env bash
# fm-desktop.sh - the desktop registry: the single source of truth for which
# X displays exist, who owns them, and where their RFB port is.
#
# WHY IT EXISTS
#   Display numbers and noVNC ports used to be hand-picked and remembered
#   nowhere, so ownership had to be recovered by reading process environments
#   and a display that died (":17", 2026-09-01) was noticed by nobody. Every
#   consumer - the wall page, the single token-routed noVNC listener, a future
#   session asking "who is on :14" - reads this registry instead of a hardcoded
#   table.
#
# REGISTRY
#   $FM_HOME/state/desktops.json, written atomically under a lock:
#     {"desktops":[{"name":"seer","display":14,
#       "group":"secondmates","owner":"seer-mate-e3","status_file":"..."}]}
#   "name" is also the websockify token and the snapshot filename, so it is
#   restricted to [a-z0-9][a-z0-9-]*.
#
# USAGE
#   fm-desktop.sh create   <name> [options]        allocate a display, start it, record it
#   fm-desktop.sh register <name> --display <N> [options]
#                                                  record a display that already exists
#   fm-desktop.sh list                             every desktop, with live/dead state
#   fm-desktop.sh retire   <name>                  drop the record (never kills anything)
#
#   Options for create/register:
#     --group <g>        wall grouping, e.g. secondmates | main-firstmate
#     --owner <id>       agent/home id that owns the desktop
#     --status-file <p>  file whose last line the wall shows on the tile
#     --display <N>      register only: the existing display number
#
# ENVIRONMENT
#   FM_HOME                  home whose state/ holds the registry (default: repo root)
#   FM_DESKTOP_GEOMETRY      geometry for create (default 1600x900)
#   FM_DESKTOP_FIRST/LAST    allocation window (default 11..64)
#   FM_DESKTOP_LEGACY_REGISTRY
#                            TSV registry of the per-agent helper ~/.local/bin/fm-desktop
#                            (default ~/.fm-desktops/registry). Allocation avoids every
#                            display it lists, and create upserts the owner's line there,
#                            so the two tools can never hand out the same display.
#
# SAFETY
#   `retire` removes a record and never signals a process: another home may be
#   working on that desktop right now. It prints the command to stop the display
#   for a human to run deliberately.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SELF_DIR/.." && pwd)"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
REGISTRY="$STATE/desktops.json"
LEGACY_REGISTRY="${FM_DESKTOP_LEGACY_REGISTRY:-$HOME/.fm-desktops/registry}"
GEOMETRY="${FM_DESKTOP_GEOMETRY:-1600x900}"
FIRST_DISPLAY="${FM_DESKTOP_FIRST:-11}"
LAST_DISPLAY="${FM_DESKTOP_LAST:-64}"
X_SOCKET_DIR="${FM_DESKTOP_X_SOCKET_DIR:-/tmp/.X11-unix}"

die() {
	printf 'fm-desktop: %s\n' "$*" >&2
	exit 1
}

usage() { sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'; }

command -v jq >/dev/null 2>&1 || die "jq is required"

ensure_registry() {
	mkdir -p "$STATE"
	[ -f "$REGISTRY" ] || printf '{"desktops":[]}\n' >"$REGISTRY"
}

# Serialize every read-modify-write so two callers cannot allocate one display.
with_lock() {
	ensure_registry
	exec 9>"$REGISTRY.lock"
	flock -w 30 9 || die "registry lock busy: another fm-desktop run holds $REGISTRY.lock"
}

write_registry() { # <json on stdin>
	local tmp="$REGISTRY.tmp.$$"
	jq -S . >"$tmp"
	mv "$tmp" "$REGISTRY"
}

display_live() { # <display-number>
	[ -e "$X_SOCKET_DIR/X$1" ]
}

registry_displays() {
	jq -r '.desktops[].display' "$REGISTRY" 2>/dev/null || true
}

legacy_displays() {
	[ -f "$LEGACY_REGISTRY" ] || return 0
	cut -f2 "$LEGACY_REGISTRY" 2>/dev/null || true
}

allocate_display() {
	local n taken
	taken=$(
		{
			registry_displays
			legacy_displays
		} | tr -d ' ' | grep -E '^[0-9]+$' || true
	)
	for ((n = FIRST_DISPLAY; n <= LAST_DISPLAY; n++)); do
		display_live "$n" && continue
		printf '%s\n' "$taken" | grep -qx "$n" && continue
		printf '%s' "$n"
		return 0
	done
	die "no free display between :$FIRST_DISPLAY and :$LAST_DISPLAY"
}

# The per-agent helper allocates from the same display space, so its record has
# to agree with ours or `fm-desktop chrome <owner>` lands on somebody else's screen.
mirror_legacy() { # <owner> <display>
	local owner="$1" n="$2" tmp
	[ -n "$owner" ] || return 0
	[ -d "$(dirname "$LEGACY_REGISTRY")" ] || return 0
	touch "$LEGACY_REGISTRY"
	tmp="$LEGACY_REGISTRY.tmp.$$"
	awk -F'\t' -v o="$owner" '$1!=o' "$LEGACY_REGISTRY" >"$tmp"
	printf '%s\t%s\n' "$owner" "$n" >>"$tmp"
	mv "$tmp" "$LEGACY_REGISTRY"
}

start_display() { # <display-number>
	local n="$1" waited=0
	if display_live "$n"; then
		printf 'display :%s already up\n' "$n"
		return 0
	fi
	command -v tigervncserver >/dev/null 2>&1 || die "tigervncserver not found"
	# Same shape as every desktop already on this box: localhost-only RFB, no VNC
	# auth on the wire, reached over the tailnet through the TLS noVNC listener.
	# 9>&- matters: the session started here outlives this script by days, and an
	# inherited lock fd would hold the registry lock for that whole time. Detached
	# from this terminal and time-boxed for the same reason - a desktop launch must
	# never be able to wedge a caller.
	timeout 60 tigervncserver ":$n" -localhost yes -geometry "$GEOMETRY" -depth 24 \
		-SecurityTypes None </dev/null >/dev/null 2>&1 9>&- || die "could not start display :$n"
	while [ "$waited" -lt 20 ]; do
		display_live "$n" && {
			printf 'display :%s up\n' "$n"
			return 0
		}
		sleep 0.5
		waited=$((waited + 1))
	done
	die "display :$n did not come up"
}

parse_options() {
	NAME=""
	DISPLAY_NUM=""
	GROUP=""
	OWNER=""
	STATUS_FILE=""
	[ $# -ge 1 ] || die "a desktop name is required"
	NAME="$1"
	shift
	[[ "$NAME" =~ ^[a-z0-9][a-z0-9-]*$ ]] ||
		die "name '$NAME' must match [a-z0-9][a-z0-9-]* (it is a token and a filename)"
	while [ $# -gt 0 ]; do
		case "$1" in
		--display)
			DISPLAY_NUM="${2:-}"
			shift 2
			;;
		--group)
			GROUP="${2:-}"
			shift 2
			;;
		--owner)
			OWNER="${2:-}"
			shift 2
			;;
		--status-file)
			STATUS_FILE="${2:-}"
			shift 2
			;;
		*) die "unknown option '$1'" ;;
		esac
	done
}

ensure_unclaimed() { # uses the parse_options globals; the caller holds the lock
	local existing holder
	existing=$(jq -r --arg n "$NAME" '[.desktops[] | select(.name==$n)] | length' "$REGISTRY")
	[ "$existing" = "0" ] || die "desktop '$NAME' is already registered (retire it first)"
	holder=$(jq -r --argjson d "$DISPLAY_NUM" \
		'first(.desktops[] | select(.display==$d) | .name) // ""' "$REGISTRY")
	[ -z "$holder" ] || die "display :$DISPLAY_NUM is already registered to '$holder'"
}

record() { # uses the parse_options globals
	ensure_unclaimed
	jq \
		--arg name "$NAME" --argjson display "$DISPLAY_NUM" \
		--arg group "$GROUP" --arg owner "$OWNER" --arg status "$STATUS_FILE" \
		'.desktops += [{name:$name, display:$display, group:$group,
                    owner:$owner, status_file:$status}]' \
		"$REGISTRY" | write_registry
	printf 'registered %s on :%s (rfb %s)\n' "$NAME" "$DISPLAY_NUM" "$((5900 + DISPLAY_NUM))"
}

cmd_register() {
	parse_options "$@"
	[ -n "$DISPLAY_NUM" ] || die "register needs --display <N>"
	[[ "$DISPLAY_NUM" =~ ^[0-9]+$ ]] || die "--display must be a number"
	with_lock
	record
}

cmd_create() {
	parse_options "$@"
	with_lock
	[ -n "$DISPLAY_NUM" ] || DISPLAY_NUM="$(allocate_display)"
	[[ "$DISPLAY_NUM" =~ ^[0-9]+$ ]] || die "--display must be a number"
	ensure_unclaimed
	start_display "$DISPLAY_NUM"
	mirror_legacy "$OWNER" "$DISPLAY_NUM"
	record
}

cmd_retire() {
	local name="${1:-}" n
	[ -n "$name" ] || die "usage: fm-desktop.sh retire <name>"
	with_lock
	n=$(jq -r --arg n "$name" '.desktops[] | select(.name==$n) | .display' "$REGISTRY")
	[ -n "$n" ] || die "no desktop named '$name'"
	jq --arg n "$name" '.desktops |= map(select(.name!=$n))' "$REGISTRY" | write_registry
	printf 'retired %s (record only)\n' "$name"
	printf 'display :%s was NOT touched. Another home may be working on it.\n' "$n"
	printf 'to stop it deliberately: tigervncserver -kill :%s\n' "$n"
}

cmd_list() {
	ensure_registry
	printf '%-14s %-8s %-7s %-16s %-18s %s\n' NAME DISPLAY RFB GROUP OWNER STATE
	local name n group owner
	while IFS=$'\t' read -r name n group owner; do
		[ -n "$name" ] || continue
		local state="down"
		display_live "$n" && state="up"
		printf '%-14s %-8s %-7s %-16s %-18s %s\n' \
			"$name" ":$n" "$((5900 + n))" "$group" "$owner" "$state"
	done < <(jq -r '.desktops | sort_by(.display)[] |
                  [.name, (.display|tostring),
                   (if .group == "" then "-" else .group end),
                   (if .owner == "" then "-" else .owner end)]
                  | @tsv' "$REGISTRY")
}

[ $# -ge 1 ] || {
	usage
	exit 1
}
action="$1"
shift
case "$action" in
create) cmd_create "$@" ;;
register) cmd_register "$@" ;;
list) cmd_list ;;
retire) cmd_retire "$@" ;;
-h | --help | help) usage ;;
*)
	usage
	exit 1
	;;
esac
