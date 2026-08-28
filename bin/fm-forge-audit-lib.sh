#!/usr/bin/env bash
# fm-forge-audit-lib.sh - the home's own append-only record of every outbound
# forge WRITE performed through this repo's bin/.
#
# Why it exists: many firstmate homes share one forge credential, and the forge
# reports the same provenance for a plain token and for a human at the web UI,
# so an outbound write is not attributable to a home after the fact. This record
# is written locally by the acting home, so it is independent of what the forge
# itself can distinguish, and answers "which home did this" from the log alone.
#
# Contract:
#   - One tab-separated line per write, appended BEFORE the call is attempted,
#     so a write that crashes mid-flight still leaves evidence it was tried.
#   - Reads are out of scope. Only writes are recorded.
#   - A line that cannot be appended refuses the write: fm_forge_audit returns
#     non-zero and the caller stops rather than act unlogged.
#   - Values are only identity firstmate itself constructed: the home, the task
#     id, the action, and an already-validated canonical target. Caller argv and
#     the environment are never passed in, which is what structurally keeps a
#     token, a header value, or any other secret out of the log.
#   - The log covers only writes made through this repo's bin/ tooling. A raw gh
#     invocation an agent types itself, and a browser action, leave no line here.
#     The first line of the log says so on creation, because a reader who takes
#     it for a complete record of outbound writes would read its silence as
#     proof that no write happened, which it is not.
#
# Log: $FM_STATE_OVERRIDE/forge-write-audit.log, else $FM_HOME/state/ - the same
# state resolution every entrypoint uses. It supersedes state/pr-merge-audit.log,
# which covered only pipeline-class merges; a home that has one keeps that older
# file untouched for its own history.

# Written once, as the log's first line, so the record carries its own limit.
FM_FORGE_AUDIT_HEADER='# forge writes made through firstmate bin/ tooling; a direct gh invocation or a browser action is NOT captured, so the absence of a line is not proof that no write occurred.'

# One field value with the separators removed, so no value can forge a second
# record out of an embedded tab or newline.
fm_forge_audit_scrub() { printf '%s' "${1-}" | tr -d '\t\n\r'; }

# fm_forge_audit <action> <task-id-or-dash> <target> [<extra-field> ...]
# Records one outbound forge write. Returns non-zero, after naming the reason,
# when the record could not be appended.
fm_forge_audit() {
  local action=$1 task=$2 target=$3
  shift 3
  local home state log line extra

  home=${FM_HOME:-}
  if [ -z "$home" ]; then
    echo "error: the forge write audit needs FM_HOME to name the acting home" >&2
    return 1
  fi
  state=${FM_STATE_OVERRIDE:-$home/state}
  log="$state/forge-write-audit.log"

  line=$(printf '%s\thome=%s\ttask=%s\taction=%s\ttarget=%s' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "$(fm_forge_audit_scrub "$home")" \
    "$(fm_forge_audit_scrub "$task")" \
    "$(fm_forge_audit_scrub "$action")" \
    "$(fm_forge_audit_scrub "$target")")
  for extra in "$@"; do
    line=$(printf '%s\t%s' "$line" "$(fm_forge_audit_scrub "$extra")")
  done

  mkdir -p "$state" 2>/dev/null
  [ -e "$log" ] || line=$FM_FORGE_AUDIT_HEADER$'\n'$line
  if ! printf '%s\n' "$line" >>"$log" 2>/dev/null; then
    echo "error: the forge write audit log could not be appended: $log" >&2
    return 1
  fi
}
