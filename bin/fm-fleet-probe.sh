#!/usr/bin/env bash
# fm-fleet-probe.sh - cheap, read-only, per-home probe for the fleet read layer.
#
# Why this exists: bin/fm-fleet-snapshot.sh is the DEEP reader - it reconciles
# every task through bin/fm-crew-state.sh, which asks no-mistakes about each
# branch and takes tens of seconds on a busy home. A screen that refreshes on a
# timer needs the CHEAP half of that read instead: who exists, whether its
# endpoint is still there, whether its harness is mid-turn, and the last line it
# wrote. This script answers only that, from the same owners the deep reader
# uses - bin/fm-backend.sh for endpoint presence, bin/fm-busy-lib.sh for the
# busy verdict, bin/fm-classify-lib.sh for the status-event split - so no
# renderer re-derives fleet state on its own.
#
# It never reconciles current state. A task's busy verdict and its `event` row
# are separate facts: the event row is wake-EVENT history, and a renderer must
# label it that way. Use bin/fm-crew-state.sh when current state matters.
# The per-home record emission itself lives in bin/fm-fleet-probe-home-lib.sh;
# this script owns discovery, the backlog read, and the record formats below.
#
# Usage:
#   fm-fleet-probe.sh --homes          list every discovered fleet home
#   fm-fleet-probe.sh --home           probe the home named by FM_HOME
#   fm-fleet-probe.sh --help
#
# Environment:
#   FM_HOME                     the home to probe, and the home whose
#                               data/secondmates.md drives discovery
#                               (default: this checkout's root)
#   FM_FLEET_TREEHOUSE_ROOT     the one pool root scanned for home markers. When
#                               set it REPLACES the roots this script would
#                               otherwise derive from the registry and from this
#                               checkout's own pool position.
#
# Output is tab-separated records, one per line, consumed by bin/fm_fleet_read.py.
# A field that cannot be read is `-`, and a note is the last field on its line
# with its tabs squeezed to spaces.
#
# --homes records:
#   home    <label>  <path>  <source>
#     source: main | registry | marker | remote:<host>
#     A `remote:` home is listed and never probed from here: its endpoint and
#     records live on that host (docs/remote-secondmates.md).
#
# --home records, in order:
#   home     <path>          <label>
#   sup      <wake-depth>    <oldest-wake-age-secs>  <watcher-beat-age-secs>  <session-lock>
#   backlog  <in-flight>     <queued>                <held>
#   hold     <task-id>       <hold-kind>
#   task     <id>  <kind>  <mode>  <harness>  <backend>  <endpoint>  <busy>  <busy-source>  <pr>
#     endpoint: alive | dead | unknown (nothing recorded, or a remote endpoint)
#     busy:     busy | idle | unknown
#   event    <id>  <age-secs>  <verb>  <note>
#   error    <reason>
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

usage() {
  sed -n '2,/^set -u$/p' "$SCRIPT_DIR/fm-fleet-probe.sh" | sed 's/^# \{0,1\}//; /^set -u$/d'
}

emit() {  # <field...> - one tab-separated record
  local IFS=$'\t'
  printf '%s\n' "$*"
}

clean() {  # <text> - squeeze tabs and newlines so a field cannot break a record
  printf '%s' "${1-}" | tr '\t\n' '  '
}


# --- discovery --------------------------------------------------------------
#
# Homes are never hardcoded. Three sources, in order of authority:
#   1. FM_HOME itself, the home this probe was pointed at.
#   2. data/secondmates.md, parsed by its own owner
#      (bin/fm-secondmate-registry-lib.sh), which is the fleet's routing record.
#   3. a scan of the pool root for firstmate's own home marker
#      (.fm-secondmate-home), so a home that exists but was never registered, or
#      whose registry label went stale, is still on the screen rather than
#      silently missing from it.

home_label() {  # <path>
  local marker="$1/.fm-secondmate-home" label
  if [ -f "$marker" ] && [ ! -L "$marker" ]; then
    label=$(head -1 "$marker" 2>/dev/null)
    if [ -n "$label" ]; then
      printf '%s' "$label"
      return 0
    fi
  fi
  printf '%s/%s' "$(basename "$(dirname "$1")")" "$(basename "$1")"
}

# Registry homes come from data/secondmates.md, parsed by its own owner. The
# three discovery functions share two globals: SEEN, the home paths already
# emitted, and ROOTS, the pool roots the marker scan will walk.
list_registry_homes() {  # <registry-file>
  local reg=$1 line

  # shellcheck source=bin/fm-secondmate-registry-lib.sh
  # shellcheck disable=SC1091
  . "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"

  [ -f "$reg" ] && [ ! -L "$reg" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in "- "*) ;; *) continue ;; esac
    secondmate_registry_parse_line "$line" || continue
    list_registry_entry
  done < "$reg"
}

list_registry_entry() {  # one parsed SECONDMATE_REGISTRY_* entry to its home row
  local path=$SECONDMATE_REGISTRY_HOME root
  if [ "$SECONDMATE_REGISTRY_REMOTE" -eq 1 ]; then
    emit home "$SECONDMATE_REGISTRY_ID" "$path" "remote:$SECONDMATE_REGISTRY_HOST"
    return 0
  fi
  case " ${SEEN[*]} " in *" $path "*) return 0 ;; esac
  SEEN+=("$path")
  emit home "$SECONDMATE_REGISTRY_ID" "$path" registry
  root=$(dirname "$(dirname "$path")")
  case " ${ROOTS[*]:-} " in *" $root "*) ;; *) ROOTS+=("$root") ;; esac
}

list_marker_homes() {  # walk ROOTS for .fm-secondmate-home markers
  local root marker path
  for root in "${ROOTS[@]:-}"; do
    [ -n "$root" ] && [ -d "$root" ] || continue
    for marker in "$root"/*/*/.fm-secondmate-home; do
      [ -f "$marker" ] && [ ! -L "$marker" ] || continue
      path=$(dirname "$marker")
      case " ${SEEN[*]} " in *" $path "*) continue ;; esac
      SEEN+=("$path")
      emit home "$(home_label "$path")" "$path" marker
    done
  done
}

list_homes() {
  local root
  SEEN=()
  ROOTS=()
  emit home main "$FM_HOME" main
  SEEN+=("$FM_HOME")
  list_registry_homes "$FM_HOME/data/secondmates.md"
  if [ -n "${FM_FLEET_TREEHOUSE_ROOT:-}" ]; then
    ROOTS=("$FM_FLEET_TREEHOUSE_ROOT")
  elif [ "$FM_ROOT" != "$FM_HOME" ]; then
    # This checkout's own pool position, which is how a probe that runs from a
    # pool worktree finds the pool even when the registry is empty.
    root=$(dirname "$(dirname "$FM_ROOT")")
    case " ${ROOTS[*]:-} " in *" $root "*) ;; *) ROOTS+=("$root") ;; esac
  fi
  list_marker_homes
}

# --- one home ---------------------------------------------------------------

probe_home() {
  local state="$FM_HOME/state"

  emit home "$FM_HOME" "$(home_label "$FM_HOME")"
  if [ ! -d "$state" ]; then
    emit error "no state directory at $state"
    return 0
  fi

  # Sourced only after the state directory is confirmed present: the wake
  # library materializes its own state directory at source time, and a probe
  # must not create records in a home it is merely reading.
  # shellcheck source=bin/fm-wake-lib.sh
  # shellcheck disable=SC1091
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  # shellcheck source=bin/fm-fleet-probe-home-lib.sh
  # shellcheck disable=SC1091
  . "$SCRIPT_DIR/fm-fleet-probe-home-lib.sh"

  fleet_probe_sup "$state"
  probe_backlog
  fleet_probe_tasks "$state"
}

probe_backlog() {
  local in_flight queued held
  # shellcheck source=bin/fm-tasks-axi-lib.sh
  # shellcheck disable=SC1091
  . "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
  if ! command -v tasks-axi > /dev/null 2>&1 ||
    fm_backlog_backend_manual "${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"; then
    # No tool, or this home configured the manual backlog path, so there is no
    # backend to ask. The counts stay unread rather than guessed from the file.
    emit backlog - - -
    return 0
  fi
  in_flight=$(backlog_count in_flight)
  queued=$(backlog_count queued)
  held=$(backlog_count held)
  emit backlog "${in_flight:--}" "${queued:--}" "${held:--}"
  probe_holds
}

# Held tasks are the captain's queue after the decision collapse: one row per
# held task, carrying the hold kind that says whether it waits on the captain.
# A row's id is everything before its first comma and its hold kind everything
# after its last, so a quoted title between them cannot be misread.
probe_holds() {
  local line id hold_kind
  while IFS= read -r line; do
    case "$line" in "  "*) ;; *) continue ;; esac
    line=${line#  }
    id=${line%%,*}
    hold_kind=${line##*,}
    case "$id" in '' | *[!A-Za-z0-9._-]*) continue ;; esac
    emit hold "$id" "$(clean "$hold_kind")"
  done <<EOF
$(cd "$FM_HOME" && tasks-axi list --state held --fields hold_kind 2>/dev/null)
EOF
}

backlog_count() {  # <state> - the `count: N` line tasks-axi prints first
  local out
  out=$(cd "$FM_HOME" && tasks-axi list --state "$1" 2>/dev/null | sed -n 's/^count: //p' | head -1)
  case "$out" in '' | *[!0-9]*) printf '' ;; *) printf '%s' "$out" ;; esac
}

case "${1:---home}" in
  --homes) list_homes ;;
  --home) probe_home ;;
  -h | --help) usage ;;
  *) usage >&2; exit 2 ;;
esac
