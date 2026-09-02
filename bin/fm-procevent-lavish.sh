#!/usr/bin/env bash
# Lavish adapter for the generic process-to-event runner.
#
# Usage:
#   fm-procevent-lavish.sh arm <artifact.html>
#   fm-procevent-lavish.sh listening <artifact.html>
#   fm-procevent-lavish.sh classify <result-file>
#   fm-procevent-lavish.sh terminal <result-file>
#   fm-procevent-lavish.sh answers <result-file>
#   fm-procevent-lavish.sh autohandle <source-id> <sequence> <result-file>
#   fm-procevent-lavish.sh self-announcing
#   fm-procevent-lavish.sh source-id <artifact.html>
#   fm-procevent-lavish.sh retire <artifact.html>
#   fm-procevent-lavish.sh poll <artifact.html>
#
# classify   Print the lifecycle state a handler should act on: feedback, ended,
#            waiting, missing, poll-error, or unknown. `poll-error` is a poll
#            that failed rather than a captain who said something, so a caller
#            can tell a broken channel from real feedback without reading the
#            payload; `unknown` stays for output this adapter cannot read at all.
# listening  Prove this exact board is being polled RIGHT NOW, before telling the
#            captain it is ready for answers. Exit 0 only when the source is
#            armed, owned by a live runner, and that runner still has its poll
#            process; exit 3 when the listener is alive between bounded retries;
#            exit 1 for everything else. Armed is not listening, which is why
#            `bin/fm-procevent.sh list` alone cannot answer this.
# poll       The registered listener command `arm` publishes, not a command to
#            run in a conversational turn. It runs the published blocking poll
#            and prints its response verbatim, absorbing only the transient
#            interruption described below.
# terminal   Exit 0 when the captured result means this Lavish source will never
#            produce another result, so the runner may retire it; any other exit
#            keeps it armed. This is the generic adapter contract bin/fm-procevent.sh
#            calls, and the only place Lavish's notion of "ended" is decided.
#
# This adapter is deliberately thin. It owns only what is specific to Lavish:
# canonical source identity, the argv for the currently published poll command,
# and how to read a completed result. Ownership, durable capture, publication,
# and restart recovery all belong to bin/fm-procevent.sh.
#
# `answers` is this adapter's half of the generic keyed-answer contract in
# bin/fm-procevent.sh. It reports what the captain actually chose, as
# `<task-id>\t<answer>\t<label>` lines, and stops there. It maps nothing to a
# task, records no decision, and closes nothing: a captain answer is not special
# to Lavish, so every rule about what a keyed answer DOES belongs to the one
# intake in bin/fm-captain-hold.sh, which the runner feeds. A Lavish review is
# just an ephemeral discussion format that happens to carry answers.
#
# Only rows tagged `choice` are read. A freeform captain message is prose that may
# contain anything, and must never be able to forge a decision key.
#
# It wraps ONLY the currently published interface, verified against 0.1.45:
#   Usage: lavish-axi poll <html-file> [--agent-reply "..."]
# and that command "long-polls indefinitely" server-side. The adapter therefore
# runs the plain blocking form with no timeout flag, so results arrive as real
# server-side events. It adds no periodic discovery, no timer fallback, and no
# dependency on any unreleased capability.
#
# BOUNDED QUIET RETRY, owned here and nowhere else. A live listener is cut short
# whenever the one shared Lavish server on its fixed port goes away under it: any
# `lavish-axi` invocation whose own version differs from the running server's
# shuts that server down and starts its own, and `lavish-axi stop` and the idle
# self-stop do the same. Every poll in flight then loses its response stream and
# reports:
#
#   error: Lavish Editor poll response was interrupted
#   code: SERVER_ERROR
#   help[2]: ...                                # diagnostics, build-dependent
#
# Concurrent boards are NOT the cause: the server keys sessions and active polls
# per file, so opening a second board never displaces the first, and session
# state survives a server restart (docs/verification/process-event-sources.md).
# Polling again is therefore the correct recovery.
#
# That is an internal retry, not news, so registering the raw poll made the
# generic runner capture it and wake the whole fleet. `poll` therefore re-runs
# the published poll up to POLL_RETRY_LIMIT times for that response, with
# POLL_RETRY_DELAY_DEFAULT seconds between attempts. The match stays deliberately
# narrow: those two exact leading lines, followed only by the vendor's own
# `help[...]` diagnostic lines. Real feedback, ended and missing sessions, and
# any other SERVER_ERROR are printed straight through and captured normally.
# Matching that shape rather than a pinned byte count is what stops a later build
# adding a diagnostics line from silently disabling the whole retry. The retry is
# a Lavish fact, so the generic runner in bin/fm-procevent.sh stays
# adapter-agnostic and learns nothing about it.
#
# BROKEN CHANNEL. When the bound is spent, the board really has stopped
# listening, and that must never read as an ordinary result. `poll` then emits a
# POLL_UNRECOVERABLE report naming the board and quoting the exact last server
# response, `classify` reads it as `poll-error`, and this adapter's own
# `autohandle` announces it as a broken channel naming that board instead of the
# generic captured-result wake. The source stays armed, so ordinary supervision
# starts a fresh listener on its next reconcile, and `listening` is how a caller
# proves that actually happened.
#
# LOSS LIMITATION, stated plainly. The published poll destructively clears
# feedback before returning it. A result lost after that clearing and before the
# runner reads the process output is unrecoverable, and no Firstmate wrapper can
# close that source-side handoff window. Never describe this path as
# at-least-once, no-loss, or lossless. The only durability this proves is the
# runner's own: output that reached the runner is stored before it is announced.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-procevent-lib.sh
. "$SCRIPT_DIR/fm-procevent-lib.sh"
# shellcheck source=bin/fm-lavish-lib.sh
. "$SCRIPT_DIR/fm-lavish-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,101p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2; }

# Canonical identity is physical, not the path string: Lavish itself keys a
# session on the realpath of the artifact, so two names for one file are one
# source and must never become two owners.
cmd_source_id() {
  local artifact=${1-} real
  [ -n "$artifact" ] || usage
  case "$artifact" in *$'\n'*) die "artifact paths cannot contain newlines" ;; esac
  real=$(perl -MCwd=realpath -e '$p = realpath($ARGV[0]); defined($p) or exit 1; print "$p\n"' "$artifact" 2>/dev/null) \
    || die "cannot resolve the artifact path: $artifact"
  [ -f "$real" ] || die "artifact does not exist: $artifact"
  if command -v shasum >/dev/null 2>&1; then
    printf 'lavish-%s\n' "$(printf '%s' "$real" | shasum -a 256 | awk '{print substr($1,1,16)}')"
  else
    printf 'lavish-%s\n' "$(printf '%s' "$real" | sha256sum | awk '{print substr($1,1,16)}')"
  fi
}

cmd_arm() {
  local artifact=${1-} id real
  [ -n "$artifact" ] || usage
  [ "$#" -eq 1 ] || usage
  command -v lavish-axi >/dev/null 2>&1 || die "lavish-axi is not installed"
  poll_retry_delay >/dev/null
  id=$(cmd_source_id "$artifact") || exit 1
  real=$(perl -MCwd=realpath -e '$p = realpath($ARGV[0]); defined($p) or exit 1; print "$p\n"' "$artifact" 2>/dev/null) \
    || die "cannot resolve the artifact path: $artifact"
  # This adapter's own listener command, which runs the plain blocking form with
  # no --timeout-ms so completion is a server event, and absorbs only the
  # transient interruption. Registering raw poll output is what let that
  # interruption reach the runner as a captured result.
  "$SCRIPT_DIR/fm-procevent.sh" register lavish "$id" \
    -- "$SCRIPT_DIR/fm-procevent-lavish.sh" poll "$real" || exit 1
  printf 'armed: %s\n' "$id"
  printf 'artifact: %s\n' "$real"
}

cmd_retire() {
  local artifact=${1-} id
  [ -n "$artifact" ] || usage
  id=$(cmd_source_id "$artifact") || exit 1
  "$SCRIPT_DIR/fm-procevent.sh" retire "$id"
}

# The bounded quiet retry described in the header. The bound is a constant
# because it is a property of the transient response, not an operator choice;
# only the delay takes an override, so a test can exercise the real bound
# without waiting it out.
POLL_RETRY_LIMIT=12
POLL_RETRY_DELAY_DEFAULT=5
POLL_RETRY_DELAY_MAX=60

# Exit 10 only for the interruption, and nothing else. The response must open
# with those two exact lines and may then carry only the vendor's own `help[...]`
# diagnostic lines: a whitespace variant of either required line, any other
# SERVER_ERROR, and any response that adds real content are genuine errors this
# adapter must never swallow. Buffering is bounded, and a response that stops
# matching is streamed on from the byte it diverged, so nothing is held back,
# nothing is printed twice, and no unrelated response is buffered.
poll_response_filter() {  # <response-file>
  perl -e '
    use strict;
    use warnings;
    my ($stage) = @ARGV;
    my $head = "error: Lavish Editor poll response was interrupted\ncode: SERVER_ERROR\n";
    my $max = 8192;
    open my $staged, ">", $stage or exit 2;
    binmode STDIN;
    binmode STDOUT;
    binmode $staged;
    my ($candidate, $streaming) = ("", 0);
    sub write_all {
      my ($handle, $bytes) = @_;
      my $offset = 0;
      while ($offset < length $bytes) {
        my $written = syswrite $handle, $bytes, length($bytes) - $offset, $offset;
        exit 2 unless defined $written;
        $offset += $written;
      }
    }
    # Only the vendor diagnostics block may follow the two required lines.
    sub tail_is_diagnostics {
      my ($tail) = @_;
      my @lines = split /\n/, $tail, -1;
      my $partial = pop @lines;
      for my $line (@lines) {
        return 0 unless $line =~ /^help\[/ || $line =~ /^\s*$/;
      }
      return 1 if $partial eq "" || $partial =~ /^\s+$/;
      return 1 if $partial =~ /^help\[/;
      return 1 if index("help[", $partial) == 0;
      return 0;
    }
    sub still_interruption {
      my ($seen) = @_;
      return 0 if length($seen) > $max;
      return substr($head, 0, length $seen) eq $seen if length($seen) <= length($head);
      return 0 unless substr($seen, 0, length $head) eq $head;
      return tail_is_diagnostics(substr($seen, length $head));
    }
    while (1) {
      my $count = sysread STDIN, my $chunk, 65536;
      exit 2 unless defined $count;
      last if $count == 0;
      if ($streaming) {
        write_all(*STDOUT, $chunk);
        next;
      }
      $candidate .= $chunk;
      if (still_interruption($candidate)) {
        # Staged only while the response is still a candidate interruption, so
        # a large unrelated response is streamed on instead of buffered here.
        write_all($staged, $chunk);
      } else {
        write_all(*STDOUT, $candidate);
        $streaming = 1;
      }
    }
    exit 10 if !$streaming
      && length($candidate) >= length($head)
      && substr($candidate, 0, length $head) eq $head;
    write_all(*STDOUT, $candidate) unless $streaming;
  ' "$1"
}

# The one thing this adapter says when the bounded retry genuinely failed: a
# broken answer channel, naming the board, carrying the exact last server
# response as bounded indented evidence. Indenting that quoted payload is what
# keeps it out of every field this adapter reads at a line start, so a server
# response can never forge the board or the verdict.
poll_broken_channel_report() {  # <board> <attempts> <response-file>
  printf 'error: the Lavish answer channel for this board stopped responding\n'
  printf 'code: POLL_UNRECOVERABLE\n'
  printf 'channel: broken\n'
  printf 'board: %s\n' "$1"
  printf 'attempts: %s\n' "$2"
  printf 'last_response:\n'
  head -c 2048 -- "$3" | head -n 20 | awk '{ print "  " $0 }'
}

# Seconds between retries. FM_LAVISH_POLL_RETRY_DELAY is a bounded test
# override; a malformed or out-of-range value is refused rather than quietly
# rounded, because silently changing a retry cadence is how a bound stops
# meaning anything.
poll_retry_delay() {
  local delay=${FM_LAVISH_POLL_RETRY_DELAY-}
  if [ -z "$delay" ]; then
    printf '%s\n' "$POLL_RETRY_DELAY_DEFAULT"
    return 0
  fi
  case "$delay" in
    *[!0-9]*) die "FM_LAVISH_POLL_RETRY_DELAY must be whole seconds from 0 to $POLL_RETRY_DELAY_MAX: $delay" ;;
  esac
  [ "$delay" -le "$POLL_RETRY_DELAY_MAX" ] \
    || die "FM_LAVISH_POLL_RETRY_DELAY must be whole seconds from 0 to $POLL_RETRY_DELAY_MAX: $delay"
  printf '%s\n' "$delay"
}

cmd_poll() {
  local artifact=${1-} delay attempt=0 response cleanup_command rc filter_rc
  local pipeline_status
  [ -n "$artifact" ] || usage
  [ "$#" -eq 1 ] || usage
  command -v lavish-axi >/dev/null 2>&1 || die "lavish-axi is not installed"
  fm_lavish_prepare_server
  delay=$(poll_retry_delay) || exit 1
  response=$(mktemp "${TMPDIR:-/tmp}/fm-lavish-poll.XXXXXX") || die "cannot stage the poll response"
  printf -v cleanup_command 'rm -f -- %q' "$response"
  # shellcheck disable=SC2064 # $cleanup_command must expand now, while the staged path is still set.
  trap "$cleanup_command" EXIT
  # Retirement stops this listener by signalling its process group, and bash runs
  # no EXIT trap for an uncaught signal, so each one cleans up the staged
  # response and then re-raises itself with the default disposition, leaving the
  # process dying exactly as the runner expects.
  local signal
  for signal in INT TERM HUP; do
    # shellcheck disable=SC2064 # Same reason: expand now, while both are set.
    trap "$cleanup_command; trap - $signal; kill -$signal $$" "$signal"
  done
  while :; do
    lavish-axi poll "$artifact" | poll_response_filter "$response"
    pipeline_status=("${PIPESTATUS[@]}")
    rc=${pipeline_status[0]}
    filter_rc=${pipeline_status[1]}
    case "$filter_rc" in
      0) break ;;
      10)
        if [ "$attempt" -lt "$POLL_RETRY_LIMIT" ]; then
          attempt=$((attempt + 1))
          sleep "$delay"
        else
          poll_broken_channel_report "$artifact" "$((attempt + 1))" "$response"
          break
        fi
        ;;
      *) die "cannot classify the poll response" ;;
    esac
  done
  return "$rc"
}

# Read one field of the response's leading `session:` block. Those fields are
# INDENTED, so each is read as the first indented match inside that block rather
# than an anchored whole-line match; anchoring on "^status:" silently never
# matches and treats every ended review as feedback. Confining the read to the
# leading block is also what stops prompt payload text from forging a session
# field. <field> is a fixed field name supplied by this adapter, never by input.
session_field() {  # <result-file> <field>
  awk -v field="$2" '
    $0 == "session:" { in_s=1; next }
    in_s && $0 !~ /^[[:space:]]/ { exit }
    in_s && $0 ~ "^[[:space:]]+" field ":[[:space:]]*[A-Za-z_]+[[:space:]]*$" {
      sub("^[[:space:]]+" field ":[[:space:]]*", ""); sub(/[[:space:]]*$/, ""); print; exit }
  ' "$1"
}

# Classify a completed result into a lifecycle state for the handler.
cmd_classify() {
  local file=${1-} status error_code error_message
  [ -n "$file" ] || usage
  [ -f "$file" ] || die "result file does not exist: $file"
  status=$(session_field "$file" status)
  case "$status" in
    feedback) printf 'feedback\n'; return 0 ;;
    ended)    printf 'ended\n'; return 0 ;;
    waiting)  printf 'waiting\n'; return 0 ;;
  esac
  error_message=$(awk 'NR == 1 && /^error:[[:space:]]*/ { sub(/^error:[[:space:]]*/, ""); print }' "$file")
  error_code=$(awk '
    NR == 1 && /^error:[[:space:]]*/ { in_error=1; next }
    in_error && /^code:[[:space:]]*[A-Z_]+[[:space:]]*$/ {
      sub(/^code:[[:space:]]*/, ""); sub(/[[:space:]]*$/, ""); print; exit }
    in_error { exit }
  ' "$file")
  if [ -z "$error_message" ]; then
    printf 'unknown\n'
  elif [ "$error_code" = NOT_FOUND ] || [[ "$error_message" == "No active Lavish Editor session"* ]]; then
    printf 'missing\n'
  else
    # An error response is a poll that failed, never silence and never feedback.
    printf 'poll-error\n'
  fi
}

# The board a broken-channel report names, read only as a top-level field ahead
# of the indented server payload, so nothing inside that payload can forge it.
report_board() {  # <result-file>
  awk '
    /^last_response:/ { exit }
    /^board: / { sub(/^board: /, ""); print; exit }
  ' "$1"
}

# Only the report this adapter mints itself counts as a broken channel: its
# exact first line, with `code: POLL_UNRECOVERABLE` and `channel: broken` as
# top-level fields ahead of the indented evidence, so a vendor payload captured
# verbatim is never announced or acknowledged here.
report_is_own_broken_channel() {  # <result-file>
  awk '
    NR == 1 { if ($0 != "error: the Lavish answer channel for this board stopped responding") { bad = 1; exit } next }
    /^last_response:/ { exit }
    $0 == "code: POLL_UNRECOVERABLE" { code = 1 }
    $0 == "channel: broken" { channel = 1 }
    END { exit (bad || !code || !channel) }
  ' "$1"
}

# This adapter announces its own broken channel, so the runner publishes only
# what is left unhandled afterwards (see bin/fm-procevent.sh's announcement seam).
cmd_self_announcing() { return 0; }

# Apply exactly one captured result: a recovery failure this adapter's own poll
# reported. It is announced as a broken channel naming the board and then
# acknowledged, so the reader is told the board stopped listening instead of
# receiving an ordinary result wake to decode. Every other result - real
# feedback, an ended or missing session, a single failed poll - is left
# unhandled and announced exactly as before. The wake is appended BEFORE the
# acknowledgement, so a crash between them leaves the result announced again
# rather than silently retired.
cmd_autohandle() {  # <source-id> <sequence> <result-file>
  local id=${1-} seq=${2-} file=${3-} board
  [ "$#" -eq 3 ] || usage
  fm_procevent_source_id_valid "$id" || die "source id must be path-safe: $id"
  case "$seq" in ''|*[!0-9]*) die "sequence must be a nonnegative integer: $seq" ;; esac
  [ -f "$file" ] && [ ! -L "$file" ] || die "result file does not exist: $file"
  [ "$(cmd_classify "$file")" = poll-error ] || return 1
  report_is_own_broken_channel "$file" || return 1
  board=$(report_board "$file")
  [ -n "$board" ] || return 1
  fm_wake_append check "lavish-broken:$id:$seq" \
    "check: lavish board stopped listening: ${board:0:256} (source $id sequence $seq)" || return 1
  "$SCRIPT_DIR/fm-procevent.sh" handled "$id" "$seq" >/dev/null || return 1
}

# A live published poll for this exact board, read only from the owning
# runner's own process group and only as a whole argv word: a foreign poll of
# the same board, or of a superstring path, can never stand in for the owned
# listener. This is the Lavish half of the liveness proof and the reason
# `listening` can tell a board that is really being polled from one whose
# listener is only registered: the generic runner can prove its own child is
# running, but only this adapter knows that child must in turn be holding a
# `lavish-axi poll` for this board.
poll_process_pid() {  # <board> <runner-leader-pid>
  local pid
  pid=$(ps -eo pid=,pgid=,args= 2>/dev/null | FM_LAVISH_BOARD="$1" FM_LAVISH_RUNNER="$2" perl -ne '
    my ($pid, $pgid, $args) = /^\s*(\d+)\s+(\d+)\s+(.*)$/ or next;
    next unless $pgid == $ENV{FM_LAVISH_RUNNER};
    next unless index($args, "lavish-axi") >= 0;
    next unless $args =~ /(?:^|[ \t])poll(?:[ \t]|$)/;
    next unless $args =~ /(?:^|[ \t])\Q$ENV{FM_LAVISH_BOARD}\E(?:[ \t]|$)/;
    print "$pid\n";
    last;
  ')
  [ -n "$pid" ] || return 1
  printf '%s\n' "$pid"
}

# Prove this board is genuinely being polled right now, before a caller tells the
# captain it is ready for answers. Ownership is the generic runner's to prove,
# because none of it is Lavish-specific; the published poll for this board is
# this adapter's.
cmd_listening() {  # <artifact.html>
  local artifact=${1-} id real detail poll_pid runner_pid status=0
  [ -n "$artifact" ] || usage
  [ "$#" -eq 1 ] || usage
  id=$(cmd_source_id "$artifact") || exit 1
  real=$(perl -MCwd=realpath -e '$p = realpath($ARGV[0]); defined($p) or exit 1; print "$p\n"' "$artifact" 2>/dev/null) \
    || die "cannot resolve the artifact path: $artifact"
  detail=$("$SCRIPT_DIR/fm-procevent.sh" alive "$id" 2>&1) || status=$?
  if [ "$status" -ne 0 ]; then
    printf 'not-listening: %s\n' "$real"
    printf 'detail: %s\n' "$detail"
    return 1
  fi
  runner_pid=${detail##*runner=}
  runner_pid=${runner_pid%%[!0-9]*}
  [ -n "$runner_pid" ] || die "cannot read the owning runner from: $detail"
  if ! poll_pid=$(poll_process_pid "$real" "$runner_pid"); then
    # The listener is up but is not holding a poll this instant: a bounded retry
    # between attempts. Not a dead channel, and still not something to promise
    # the captain on.
    printf 'recovering: %s (the listener holds no poll right now, between bounded retries)\n' "$real"
    printf 'detail: %s\n' "$detail"
    return 3
  fi
  printf 'listening: %s\n' "$real"
  printf 'detail: %s poll-process=%s\n' "$detail" "$poll_pid"
}

# Whether a captured result ends this source, for the generic runner's automatic
# retirement. Lavish's notion of "ended" lives here and nowhere else: an ended
# session produces nothing further, a missing session has nothing left to
# produce, and the published poll delivers the final feedback of a `Send & End`
# review marked with session_ended and returns only empty ended sessions after
# it. Anything else - including an unreadable result - keeps the source armed.
cmd_terminal() {
  local file=${1-}
  [ -n "$file" ] || usage
  [ -f "$file" ] || die "result file does not exist: $file"
  case "$(cmd_classify "$file")" in
    ended|missing) return 0 ;;
  esac
  case "$(session_field "$file" session_ended)" in
    true|True|TRUE) return 0 ;;
  esac
  return 1
}

# Print `key<TAB>answer<TAB>label[<TAB>mode]` for every structured choice the
# captain submitted in a captured result; the optional mode column relays the
# card's declared close mode (`done` or `release`) to the keyed-answer intake. The published response frames queued feedback as
# a `prompts[N]{field,...}:` header followed by exactly N indented CSV rows whose
# quoted fields carry JSON-style escapes, so this reads the declared field ORDER
# rather than assuming a fixed column, and takes only rows whose `tag` field is
# `choice`. A freeform `message` row is captain prose and is deliberately never a
# source of decision keys. A row that does not carry both a slug-shaped `question`
# and an `answer` inside its `Context data:` block is skipped, so a deck that does
# not key its forms by decision key simply yields nothing.
# The question cap is 128 so any task id fits, including the long legacy
# `<origin>-decision-<key>` identities pre-collapse decks still carry; the
# security property is the slug SHAPE, which is unchanged.
cmd_answers() {
  local file=${1-}
  [ -n "$file" ] || usage
  [ -f "$file" ] && [ ! -L "$file" ] || die "result file does not exist: $file"
  perl -MJSON::PP -e '
    use strict; use warnings;
    my ($path) = @ARGV;
    open my $fh, "<", $path or exit 1;
    my (@fields, $want, @rows);
    while (my $line = <$fh>) {
      if (!@fields) {
        next unless $line =~ /^prompts\[(\d+)\]\{([^}]*)\}:\s*$/;
        ($want, @fields) = ($1, split /,/, $2);
        next;
      }
      last unless $line =~ /^\s/;
      last if @rows >= $want;
      chomp $line;
      push @rows, $line;
    }
    close $fh;
    my %seen;
    my @out;
    for my $row (@rows) {
      $row =~ s/^\s+//;
      my @vals;
      while (length $row) {
        if ($row =~ s/^"((?:[^"\\]|\\.)*)"//) {
          my $v = $1;
          $v =~ s/\\(.)/$1 eq "n" ? "\n" : $1 eq "t" ? "\t" : $1 eq "r" ? "\r" : $1/ge;
          push @vals, $v;
        } else {
          $row =~ s/^([^,]*)//;
          push @vals, $1;
        }
        last unless $row =~ s/^,//;
      }
      my %f;
      $f{$fields[$_]} = $vals[$_] for 0 .. $#fields;
      next unless defined $f{tag} && $f{tag} eq "choice";
      my $prompt = $f{prompt};
      next unless defined $prompt && $prompt =~ /Context data:\s*(\{.*\})/s;
      my $ctx = $1;
      my $data = eval { decode_json($ctx) };
      next unless ref($data) eq "HASH";
      my $key = $data->{question};
      my $answer = $data->{answer};
      next if !defined($key) || ref($key) || !defined($answer) || ref($answer);
      my $mode = "";
      if (exists $data->{close}) {
        next if !defined($data->{close}) || ref($data->{close})
          || ($data->{close} ne "done" && $data->{close} ne "release");
        $mode = $data->{close};
      }
      next unless $key =~ /\A[A-Za-z0-9._-]{1,128}\z/;
      next unless length $answer && length($answer) <= 512;
      my $label = defined $f{text} ? $f{text} : "";
      s/[\x00-\x1f\x7f]/ /g for ($answer, $label);
      $label = substr($label, 0, 512);
      # A re-answered form appears again later in the queue; the last submission wins.
      if (defined $seen{$key}) { $out[$seen{$key}] = undef }
      $seen{$key} = scalar @out;
      push @out, length $mode ? "$key\t$answer\t$label\t$mode" : "$key\t$answer\t$label";
    }
    print "$_\n" for grep { defined } @out;
  ' "$file"
}

case "${1-}" in
  arm)       shift; cmd_arm "$@" ;;
  listening) shift; cmd_listening "$@" ;;
  retire)    shift; cmd_retire "$@" ;;
  poll)      shift; cmd_poll "$@" ;;
  source-id) shift; cmd_source_id "$@" ;;
  classify)  shift; cmd_classify "$@" ;;
  terminal)  shift; cmd_terminal "$@" ;;
  answers)   shift; cmd_answers "$@" ;;
  autohandle) shift; cmd_autohandle "$@" ;;
  self-announcing) shift; cmd_self_announcing "$@" ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
