#!/usr/bin/env bash
# fm-fleet-probe-home-lib.sh - one home's record probe for bin/fm-fleet-probe.sh.
#
# Emits the `sup`, `task`, and `event` records of the probe's --home read, each
# fact delegated to its owner rather than re-derived: the wake queue through
# bin/fm-secondmate-home-lib.sh, task records through bin/fm-backend.sh, the
# busy verdict and endpoint presence through bin/fm-busy-lib.sh, and the
# status-event split through bin/fm-classify-lib.sh. The record formats these
# functions emit are owned by bin/fm-fleet-probe.sh's header.
#
# Sourcing contract, stated because a probe must never create records in a home
# it is only reading:
#   - Source this library only after the home's state directory is confirmed
#     present; bin/fm-fleet-probe.sh does that inside probe_home.
#   - The caller sources bin/fm-wake-lib.sh first (these functions call its
#     fm_path_age) and provides emit/clean, the probe's record shapers. That is
#     the pattern bin/fm-busy-lib.sh already uses for the fm_backend_* functions
#     it never sources itself.
#
# set -u safe. No side effects on source beyond sourcing the owners below.

_FM_FLEET_PROBE_HOME_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-backend.sh
# shellcheck disable=SC1091
. "$_FM_FLEET_PROBE_HOME_LIB_DIR/fm-backend.sh"
# shellcheck source=bin/fm-busy-lib.sh
# shellcheck disable=SC1091
. "$_FM_FLEET_PROBE_HOME_LIB_DIR/fm-busy-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
# shellcheck disable=SC1091
. "$_FM_FLEET_PROBE_HOME_LIB_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-secondmate-home-lib.sh
# shellcheck disable=SC1091
. "$_FM_FLEET_PROBE_HOME_LIB_DIR/fm-secondmate-home-lib.sh"

fleet_probe_sup() {  # <state-dir> - the home's supervision header, one `sup` record
  local state=$1 depth oldest _seq oldest_age beat lock
  IFS=$'\t' read -r depth oldest _seq <<< "$(fm_secondmate_home_queue_scan "$FM_HOME")"
  oldest_age=-
  [ -n "$oldest" ] && oldest_age=$(($(date +%s) - oldest))
  beat=-
  [ -f "$state/.last-watcher-beat" ] && beat=$(fm_path_age "$state/.last-watcher-beat")
  lock=$(FM_HOME="$FM_HOME" "$_FM_FLEET_PROBE_HOME_LIB_DIR/fm-lock.sh" status 2>/dev/null | head -1)
  lock=${lock#lock: }
  emit sup "${depth:-0}" "$oldest_age" "$beat" "$(clean "${lock:--}")"
}

fleet_probe_task() {  # <meta> <id> <state-dir> - one task's cheap facts, one `task` record
  local meta=$1 id=$2 state=$3
  local kind mode harness backend target endpoint busy_verdict busy busy_source pr
  kind=$(fm_meta_get "$meta" kind)
  mode=$(fm_meta_get "$meta" mode)
  harness=$(fm_meta_get "$meta" harness)
  pr=$(fm_meta_get "$meta" pr)
  backend=$(fm_backend_of_meta "$meta")
  target=$(fm_backend_target_of_meta "$meta")
  if [ -n "$(fm_meta_get "$meta" remote_host)" ]; then
    # A remote secondmate's endpoint lives on its own host, so the local
    # adapters are never asked about it. That is not evidence of death.
    endpoint=unknown
    busy=unknown
    busy_source=not-probed
  else
    # One call answers both halves: fm_busy_classify_live checks the endpoint
    # before it classifies, so the endpoint state falls out of its verdict
    # rather than being read a second time here.
    busy_verdict=$(fm_busy_classify_live "$backend" "$target" "$harness" "$id" "$state" "fm-$id")
    busy=${busy_verdict%% *}
    busy_source=${busy_verdict#* }
    [ "$busy_source" = "$busy_verdict" ] && busy_source=-
    case "$busy_verdict" in
      "dead endpoint-gone") endpoint=dead ;;
      "unknown no-target") endpoint=unknown ;;
      *) endpoint=alive ;;
    esac
  fi
  if [ -z "$pr" ] && [ -f "$state/$id.status" ]; then
    # The same pull-request shape fm-fleet-snapshot.sh recovers from a status
    # log, for a task that reported its PR before the merge poll recorded `pr=`.
    pr=$(grep -Eo 'https?://[^[:space:])"]+/pull/[0-9]+' "$state/$id.status" 2>/dev/null | head -1)
  fi
  emit task "$id" "${kind:-ship}" "${mode:--}" "${harness:--}" \
    "$backend" "$endpoint" "${busy:--}" "${busy_source:--}" "${pr:--}"
}

fleet_probe_event() {  # <id> <status-file> - the task's last wake EVENT, never current truth
  local id=$1 status=$2 line age verb note
  line=$(last_status_line "$status")
  [ -n "$line" ] || return 0
  age=$(fm_path_age "$status")
  verb=$(status_line_verb "$line")
  note=$(status_line_note "$line")
  emit event "$id" "$age" "${verb:--}" "$(clean "${note:--}")"
}

fleet_probe_tasks() {  # <state-dir> - every task record, each with its last event
  local state=$1 meta id
  for meta in "$state"/*.meta; do
    [ -f "$meta" ] || continue
    id=$(basename "$meta" .meta)
    fleet_probe_task "$meta" "$id" "$state"
    if [ -f "$state/$id.status" ]; then
      fleet_probe_event "$id" "$state/$id.status"
    fi
  done
}
