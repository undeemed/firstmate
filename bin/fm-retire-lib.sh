#!/usr/bin/env bash
# Single owner of "retirement is final" for supervision wakes.
#
# A task's identity records (state/<id>.meta, state/<id>.status) are the only
# proof that a worker is in service. Everything else the supervision chain
# writes about that worker is derived bookkeeping:
#
#   state/.wake-queue              durable wake records naming its pane or status
#   state/.hash-<key> .count-<key> the watcher's per-pane staleness counters
#   state/.stale-<key> .stale-since-<key> .wedge-escalations-<key>
#                                  the watcher's per-pane wedge escalation state
#   state/.paused-<key> .paused-rechecked-<key> .paused-resurfaced-<key>
#                                  the watcher's per-pane declared-pause cadence
#   state/.seen-<id>_status .seen-<id>_turn-ended
#                                  the watcher's per-file signal suppressors
#   state/.hb-surfaced-<id>        the heartbeat backstop's surfaced marker
#   state/.subsuper-stale-<id> .subsuper-paused-<id> .subsuper-seen-status-<id>
#                                  the away-mode daemon's per-task bookkeeping
#   state/.watch-deliveries.log    the arm layer's identity-bound record of the
#                                  reason a watcher cycle already delivered,
#                                  which bin/fm-watch-arm.sh reprints when it
#                                  cannot observe that cycle's own output
#
# Retiring a worker used to remove only the identity records, so a wake already
# queued for it was still delivered, its delivered reason could still be
# reprinted, and its pane counters and daemon markers survived with nothing left
# that could ever clear them. The receiving home could only re-report an alarm
# for a pane no worker owns any more, and a backend that later reused that pane
# target inherited the retired worker's escalation count and pause cadence.
#
# This library ends that in two steps:
#   1. bin/fm-teardown.sh calls fm_retire_task_wake_state at the moment a task's
#      identity records are removed. It purges every record above and writes one
#      retirement tombstone.
#   2. bin/fm-wake-drain.sh calls fm_retire_wake_record_is_retired at delivery
#      time, so the one record an in-flight watcher cycle can still append while
#      teardown runs is dropped instead of alarming a home that has nothing left
#      to clear.
#
# The one hazard of both steps is silencing a LIVE worker, so suppression needs
# POSITIVE proof of retirement and never merely missing evidence of liveness:
#   - only this home's own tombstone ledger (state/.retired-tasks, written by
#     teardown) makes a wake droppable at all, so a wake for a task this home
#     never retired is always delivered, and
#   - a tombstoned pane or task that is live again - some meta records that pane,
#     or the task id has a meta or status file again - is delivered unchanged.
# Check and heartbeat wakes are never task-scoped and are never dropped.

FM_RETIRE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$FM_RETIRE_LIB_DIR/fm-wake-lib.sh"

# Tombstone ledger: "<epoch>\t<id>\t<window>", one line per retired pane target
# (one line with an empty window when a task had none). Bounded on every write by
# both age and line count, so it stays a small volatile record even in a home
# that retires tasks for years.
FM_RETIRE_LEDGER_MAX_AGE=${FM_RETIRE_LEDGER_MAX_AGE:-604800}
FM_RETIRE_LEDGER_MAX_LINES=${FM_RETIRE_LEDGER_MAX_LINES:-200}
case "$FM_RETIRE_LEDGER_MAX_AGE" in ''|*[!0-9]*|0) FM_RETIRE_LEDGER_MAX_AGE=604800 ;; esac
case "$FM_RETIRE_LEDGER_MAX_LINES" in ''|*[!0-9]*|0) FM_RETIRE_LEDGER_MAX_LINES=200 ;; esac

# Every entry point resolves file and lock paths under <state-dir>, so an empty
# or missing one would compose paths at the filesystem root and hand an
# unwritable lock path to the shared lock helper. Refuse instead: a retirement
# with no readable state directory has nothing to purge, and the caller reports
# the failure rather than acting on a path nobody meant.
fm_retire_state_dir_valid() {  # <state-dir>
  local state=${1:-}
  [ -n "$state" ] || return 1
  [ -d "$state" ] || return 1
  [ ! -L "$state" ] || return 1
}

fm_retire_ledger_path() {  # <state-dir>
  printf '%s/.retired-tasks' "$1"
}

fm_retire_ledger_lock() {  # <state-dir>
  printf '%s/.retired-tasks.lock' "$1"
}

# Note one dropped or purged record in the watcher's absorbed-wake debug log,
# under the same size knob its own writer uses (bin/fm-push-transition-lib.sh's
# triage_log). Debug evidence only: never relied on, safe to delete, and never a
# reason a retirement or a drain can fail.
fm_retire_log() {  # <state-dir> <line>
  local state=$1 line=$2 log size cap
  log="$state/.watch-triage.log"
  cap=${FM_WATCH_TRIAGE_LOG_MAX_BYTES:-262144}
  case "$cap" in ''|*[!0-9]*|0) cap=262144 ;; esac
  printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$line" >> "$log" 2>/dev/null || return 0
  size=$(wc -c < "$log" 2>/dev/null | tr -d '[:space:]')
  case "$size" in ''|*[!0-9]*) return 0 ;; esac
  if [ "$size" -ge "$cap" ]; then
    tail -n 2000 "$log" > "$log.tmp" 2>/dev/null && mv -f "$log.tmp" "$log" 2>/dev/null
    rm -f "$log.tmp" 2>/dev/null || true
  fi
  return 0
}

# Marker key for a pane target or task id, mirroring the transform the watcher
# uses when it names its own per-pane and per-task markers (bin/fm-watch.sh).
fm_retire_state_key() {  # <window-or-id>
  printf '%s' "$1" | tr ':/.' '___'
}

# Task ids are file-name components in every record this library touches, so a
# key that could not have been written by a real task never selects a path.
fm_retire_task_id_valid() {  # <id>
  local id=$1
  case "$id" in
    ''|.|..|.*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  [ "${#id}" -le 64 ]
}

# 0 when some task meta in <state> still records <window> as its endpoint.
fm_retire_window_is_recorded() {  # <state-dir> <window>
  local state=$1 window=$2 meta line
  [ -n "$window" ] || return 1
  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    while IFS= read -r line; do
      case "$line" in
        "window=$window"|"terminal=$window") return 0 ;;
      esac
    done < "$meta"
  done
  return 1
}

# 0 when <state> holds no identity record for task <id>.
fm_retire_task_records_gone() {  # <state-dir> <id>
  local state=$1 id=$2
  fm_retire_task_id_valid "$id" || return 1
  [ -e "$state/$id.meta" ] && return 1
  [ -e "$state/$id.status" ] && return 1
  return 0
}

# Record the retirement so a record appended after the purge is still provably
# retired at delivery time. Bounded, best-effort, and never a reason teardown
# fails: without it, the purge above has already removed everything queued.
fm_retire_ledger_record() {  # <state-dir> <id> [window...]
  local state=$1 id=$2 ledger lock tmp now cutoff win status=0 i=0
  local -a windows=()
  shift 2
  fm_retire_state_dir_valid "$state" || return 1
  fm_retire_task_id_valid "$id" || return 1
  for win in "$@"; do
    [ -n "$win" ] || continue
    windows+=("$win")
  done
  ledger=$(fm_retire_ledger_path "$state")
  lock=$(fm_retire_ledger_lock "$state")
  now=$(date +%s)
  cutoff=$((now - FM_RETIRE_LEDGER_MAX_AGE))
  while ! fm_lock_try_acquire "$lock"; do
    [ "$i" -lt 50 ] || return 1
    sleep 0.02
    i=$((i + 1))
  done
  tmp="$ledger.tmp.$(fm_current_pid)"
  {
    if [ -f "$ledger" ]; then
      awk -F '\t' -v cutoff="$cutoff" 'NF >= 2 && $1 ~ /^[0-9]+$/ && $1 >= cutoff' "$ledger"
    fi
    if [ "${#windows[@]}" -eq 0 ]; then
      printf '%s\t%s\t\n' "$now" "$id"
    else
      for win in "${windows[@]}"; do
        printf '%s\t%s\t%s\n' "$now" "$id" "$win"
      done
    fi
  } > "$tmp" 2>/dev/null || status=1
  if [ "$status" -eq 0 ]; then
    tail -n "$FM_RETIRE_LEDGER_MAX_LINES" "$tmp" > "$tmp.capped" 2>/dev/null \
      && mv -f "$tmp.capped" "$ledger" 2>/dev/null || status=1
  fi
  rm -f "$tmp" "$tmp.capped" 2>/dev/null || true
  fm_lock_release "$lock"
  return "$status"
}

# Print the tombstoned task id matching a pane target or task id, if any.
fm_retire_ledger_lookup() {  # <state-dir> <window> <id>
  local state=$1 window=$2 id=$3 ledger
  ledger=$(fm_retire_ledger_path "$state")
  [ -f "$ledger" ] || return 1
  awk -F '\t' -v window="$window" -v id="$id" '
    NF >= 2 {
      if (id != "" && $2 == id) { print $2; found = 1; exit }
      if (window != "" && NF >= 3 && $3 == window) { print $2; found = 1; exit }
    }
    END { exit(found ? 0 : 1) }
  ' "$ledger" 2>/dev/null
}

# 0 when a queued wake record names a worker this home retired and has not
# brought back. Only pane (stale) and status/turn-end (signal) wakes are
# task-scoped; every other kind is delivered unchanged.
fm_retire_wake_record_is_retired() {  # <state-dir> <kind> <key>
  local state=$1 kind=$2 key=$3 id='' window='' tombstoned
  # An unreadable state directory proves nothing, so the record is delivered.
  fm_retire_state_dir_valid "$state" || return 1
  case "$kind" in
    stale)
      [ -n "$key" ] || return 1
      # A pane some task still records is live by definition.
      fm_retire_window_is_recorded "$state" "$key" && return 1
      window=$key
      case "$key" in
        *:fm-?*)
          id=${key##*:}
          case "$id" in
            fm-?*)
              id=${id#fm-}
              fm_retire_task_id_valid "$id" || id=''
              ;;
            *) id='' ;;
          esac
          ;;
      esac
      ;;
    signal)
      case "$key" in
        *.status) id=${key%.status} ;;
        *.turn-ended) id=${key%.turn-ended} ;;
        *) return 1 ;;
      esac
      fm_retire_task_id_valid "$id" || return 1
      ;;
    *) return 1 ;;
  esac
  tombstoned=$(fm_retire_ledger_lookup "$state" "$window" "$id") || return 1
  [ -n "$tombstoned" ] || return 1
  # Re-spawned under the same id: its records are back, so its wakes are live.
  fm_retire_task_records_gone "$state" "$tombstoned"
}

# Join the caller's window list for awk, on the one separator the durable queue
# and delivery ledger already strip from every field they store.
fm_retire_join_windows() {  # [window...]
  local out='' win
  for win in "$@"; do
    [ -n "$win" ] || continue
    if [ -z "$out" ]; then out=$win; else out="$out"$'\t'"$win"; fi
  done
  printf '%s' "$out"
}

# Drop every queued wake record naming this task's panes, status file, or
# turn-end marker. Runs under the queue's own append lock, so a concurrent
# watcher append is never observed half-written or lost.
fm_retire_wake_queue_purge() {  # <state-dir> <id> [window...]
  local state=$1 id=$2 queue lock tmp wins status=0
  shift 2
  fm_retire_state_dir_valid "$state" || return 1
  queue="$state/.wake-queue"
  lock="$state/.wake-queue.lock"
  [ -f "$queue" ] || return 0
  wins=$(fm_retire_join_windows "$@")
  fm_lock_acquire_wait "$lock"
  if [ -s "$queue" ]; then
    tmp="$queue.retire.$(fm_current_pid)"
    if awk -F '\t' -v id="$id" -v wins="$wins" '
      BEGIN {
        n = split(wins, w, "\t")
        for (i = 1; i <= n; i++) if (w[i] != "") pane[w[i]] = 1
        suffix = ":fm-" id
      }
      NF >= 5 && $3 == "stale" && ($4 in pane) { next }
      NF >= 5 && $3 == "stale" \
        && length($4) > length(suffix) \
        && substr($4, length($4) - length(suffix) + 1) == suffix { next }
      NF >= 5 && $3 == "signal" && ($4 == id ".status" || $4 == id ".turn-ended") { next }
      { print }
    ' "$queue" > "$tmp" 2>/dev/null; then
      mv -f "$tmp" "$queue" || status=1
    else
      status=1
    fi
    rm -f "$tmp" 2>/dev/null || true
  fi
  fm_lock_release "$lock"
  return "$status"
}

# Remove the watcher's and the away-mode daemon's per-pane and per-task
# bookkeeping for a retired task. Leaving it behind both rots and, once a
# backend reuses the pane target, mis-keys the NEXT task's escalation count and
# declared-pause cadence.
fm_retire_watch_markers_purge() {  # <state-dir> <id> [window...]
  local state=$1 id=$2 win key tkey seen_status seen_turn status=0
  shift 2
  fm_retire_state_dir_valid "$state" || return 1
  fm_retire_task_id_valid "$id" || return 1
  tkey=$(fm_retire_state_key "$id")
  seen_status=$(printf '%s' "$id.status" | tr '.' '_')
  seen_turn=$(printf '%s' "$id.turn-ended" | tr '.' '_')
  rm -f -- \
    "$state/.seen-$seen_status" \
    "$state/.seen-$seen_turn" \
    "$state/.hb-surfaced-$tkey" \
    "$state/.subsuper-stale-$tkey" \
    "$state/.subsuper-paused-$tkey" \
    "$state/.subsuper-seen-status-$tkey" \
    2>/dev/null || status=1
  for win in "$@"; do
    [ -n "$win" ] || continue
    key=$(fm_retire_state_key "$win")
    rm -f -- \
      "$state/.hash-$key" \
      "$state/.count-$key" \
      "$state/.stale-$key" \
      "$state/.stale-since-$key" \
      "$state/.wedge-escalations-$key" \
      "$state/.paused-$key" \
      "$state/.paused-rechecked-$key" \
      "$state/.paused-resurfaced-$key" \
      2>/dev/null || status=1
  done
  return "$status"
}

# Drop this task's reasons from the arm layer's delivery ledger, so a cycle the
# arm could not observe can never reprint a retired worker's alarm. Bounded
# acquisition matches the ledger's writer: the ledger is diagnostic evidence and
# must never stall a retirement.
fm_retire_delivery_log_purge() {  # <state-dir> <id> [window...]
  local state=$1 id=$2 log lock tmp wins i=0 status=0
  shift 2
  fm_retire_state_dir_valid "$state" || return 1
  log="$state/.watch-deliveries.log"
  lock="$state/.watch-deliveries.lock"
  [ -f "$log" ] || return 0
  wins=$(fm_retire_join_windows "$@")
  while ! fm_lock_try_acquire "$lock"; do
    [ "$i" -lt 50 ] || return 1
    sleep 0.02
    i=$((i + 1))
  done
  if [ -s "$log" ]; then
    tmp="$log.retire.$(fm_current_pid)"
    if awk -F '\t' -v id="$id" -v wins="$wins" '
      BEGIN {
        panes = split(wins, pane, "\t")
        suffix = ":fm-" id
        sig_status = id ".status"
        sig_turn = id ".turn-ended"
      }
      {
        n = split($3, tok, " ")
        for (t = 1; t <= n; t++) {
          for (i = 1; i <= panes; i++) if (pane[i] != "" && tok[t] == pane[i]) next
          if (length(tok[t]) > length(suffix) \
            && substr(tok[t], length(tok[t]) - length(suffix) + 1) == suffix) next
          if (tok[t] == sig_status || tok[t] == sig_turn) next
          if (length(tok[t]) > length(sig_status) \
            && substr(tok[t], length(tok[t]) - length(sig_status)) == "/" sig_status) next
          if (length(tok[t]) > length(sig_turn) \
            && substr(tok[t], length(tok[t]) - length(sig_turn)) == "/" sig_turn) next
        }
        print
      }
    ' "$log" > "$tmp" 2>/dev/null; then
      mv -f "$tmp" "$log" || status=1
    else
      status=1
    fi
    rm -f "$tmp" 2>/dev/null || true
  fi
  fm_lock_release "$lock"
  return "$status"
}

# Reap pane-keyed and task-keyed bookkeeping left by RETIREMENTS THAT RAN BEFORE
# this sweep existed. Observed in a live main home: 145 of 158 pane-keyed
# watcher markers and 59 of 65 heartbeat markers belonged to panes and tasks no
# meta had recorded for weeks, because a marker is keyed by pane, not by task,
# and nothing ever removed it.
#
# Two independent conditions gate every removal, so a live worker can never lose
# the counters its next alarm depends on: the key must match no live pane and no
# live task, AND the marker must be older than FM_RETIRE_ORPHAN_MARKER_MAX_AGE.
# Every marker here is rewritten on the poll that observes its pane, so a live
# task's marker is always minutes old, never days. Losing one would at worst
# restart that pane's staleness count, never suppress an alarm.
FM_RETIRE_ORPHAN_MARKER_MAX_AGE=${FM_RETIRE_ORPHAN_MARKER_MAX_AGE:-604800}
case "$FM_RETIRE_ORPHAN_MARKER_MAX_AGE" in ''|*[!0-9]*) FM_RETIRE_ORPHAN_MARKER_MAX_AGE=604800 ;; esac

fm_retire_orphan_markers_sweep() {  # <state-dir>
  local state=$1 meta f base key line id
  local pane_keys=$'\n' task_keys=$'\n' seen_keys=$'\n'
  local prefixes_pane=(.hash- .count- .stale- .stale-since- .wedge-escalations- \
    .paused- .paused-rechecked- .paused-resurfaced- .herdr-escalated-)
  local prefixes_task=(.hb-surfaced- .subsuper-stale- .subsuper-paused- .subsuper-seen-status-)
  local prefix matched best
  fm_retire_state_dir_valid "$state" || return 1

  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    id=$(basename "$meta" .meta)
    task_keys="$task_keys$(fm_retire_state_key "$id")"$'\n'
    seen_keys="$seen_keys$(printf '%s' "$id.status" | tr '.' '_')"$'\n'
    seen_keys="$seen_keys$(printf '%s' "$id.turn-ended" | tr '.' '_')"$'\n'
    while IFS= read -r line; do
      case "$line" in
        window=*|terminal=*)
          key=${line#*=}
          [ -n "$key" ] || continue
          pane_keys="$pane_keys$(fm_retire_state_key "$key")"$'\n'
          ;;
      esac
    done < "$meta"
  done
  # A status file with no meta is still a live identity record, so anything it
  # names stays untouched.
  for f in "$state"/*.status; do
    [ -e "$f" ] || continue
    id=$(basename "$f" .status)
    task_keys="$task_keys$(fm_retire_state_key "$id")"$'\n'
    seen_keys="$seen_keys$(printf '%s' "$id.status" | tr '.' '_')"$'\n'
    seen_keys="$seen_keys$(printf '%s' "$id.turn-ended" | tr '.' '_')"$'\n'
  done

  for f in "$state"/.*; do
    [ -f "$f" ] || continue
    base=$(basename "$f")
    key=''
    matched=''
    best=''
    for prefix in "${prefixes_pane[@]}"; do
      case "$base" in
        "$prefix"*) [ "${#prefix}" -gt "${#best}" ] && best=$prefix ;;
      esac
    done
    if [ -n "$best" ]; then
      key=${base#"$best"}
      matched=pane
    fi
    if [ -z "$matched" ]; then
      for prefix in "${prefixes_task[@]}"; do
        case "$base" in
          "$prefix"*) key=${base#"$prefix"}; matched=task; break ;;
        esac
      done
    fi
    if [ -z "$matched" ]; then
      case "$base" in
        .seen-*) key=${base#.seen-}; matched=seen ;;
        *) continue ;;
      esac
    fi
    [ -n "$key" ] || continue
    case "$matched" in
      pane) case "$pane_keys" in *$'\n'"$key"$'\n'*) continue ;; esac ;;
      task) case "$task_keys" in *$'\n'"$key"$'\n'*) continue ;; esac ;;
      seen) case "$seen_keys" in *$'\n'"$key"$'\n'*) continue ;; esac ;;
    esac
    [ "$(fm_path_age "$f")" -ge "$FM_RETIRE_ORPHAN_MARKER_MAX_AGE" ] || continue
    rm -f -- "$f" 2>/dev/null || true
  done
  return 0
}

# The whole retirement sweep, called once at the moment a task's identity
# records are removed. Its callers remove the meta FIRST, so no watcher can
# still produce a record for this task by the time the sweep runs.
fm_retire_task_wake_state() {  # <state-dir> <id> [window...]
  local status=0
  fm_retire_wake_queue_purge "$@" || status=1
  fm_retire_watch_markers_purge "$@" || status=1
  fm_retire_delivery_log_purge "$@" || status=1
  fm_retire_ledger_record "$@" || status=1
  fm_retire_orphan_markers_sweep "$1" || status=1
  return "$status"
}
