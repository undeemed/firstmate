#!/usr/bin/env bash
# The one owner of firstmate's outbound forge write audit record.
#
# Many firstmate homes share one forge credential, and the forge reports the
# same provenance for a plain token and for a human at the web UI, so an
# outbound write is not attributable to a home after the fact. Every write made
# through bin/ therefore appends one tab-separated line to the acting home's own
# state/forge-write-audit.log BEFORE it is attempted, so a write that crashes
# mid-flight still leaves evidence it was tried, and refuses rather than act
# unlogged. It supersedes the pipeline-only state/pr-merge-audit.log; a home
# that has one keeps that older file untouched for its own history.
#
# Only identity the calling script constructed is recorded - the home, the task
# id, the action, and an already-validated canonical target - which is what
# structurally keeps a token, a header value, or any other secret out of the
# log. Reads are never recorded.
#
# Record format, one line per attempted write:
#   <utc-timestamp> home=<path> task=<id-or-dash> action=<verb> target=<url> [<extra>...]
# with a single tab between fields.
#
# A sourcing script sets STATE (its home's state directory) and FM_HOME before
# the first forge_audit call.

# One field value with the separators removed, so no value can forge a second
# record out of an embedded tab or newline.
forge_audit_scrub() { printf '%s' "${1-}" | tr -d '\t\n\r'; }

# forge_audit <action> <task-id-or-dash> <target> [<extra-field> ...]
# Returns non-zero, after naming the reason, when the record cannot be appended.
forge_audit() {
  local action=$1 task=$2 target=$3
  shift 3
  local log line extra
  log="$STATE/forge-write-audit.log"

  line=$(printf '%s\thome=%s\ttask=%s\taction=%s\ttarget=%s' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "$(forge_audit_scrub "$FM_HOME")" \
    "$(forge_audit_scrub "$task")" \
    "$(forge_audit_scrub "$action")" \
    "$(forge_audit_scrub "$target")")
  for extra in "$@"; do
    line=$(printf '%s\t%s' "$line" "$(forge_audit_scrub "$extra")")
  done

  mkdir -p "$STATE" 2>/dev/null
  # The log states its own limit on creation, because a reader who takes it for
  # a complete record of outbound writes would read its silence as proof that
  # no write happened, which it is not.
  [ -e "$log" ] || line='# forge writes made through firstmate bin/ tooling; a direct gh invocation or a browser action is NOT captured, so the absence of a line is not proof that no write occurred.'$'\n'$line
  if ! printf '%s\n' "$line" >>"$log" 2>/dev/null; then
    echo "error: the forge write audit log could not be appended: $log" >&2
    return 1
  fi
}
