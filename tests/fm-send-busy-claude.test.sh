#!/usr/bin/env bash
# tests/fm-send-busy-claude.test.sh - fm-send against an IDLE claude pane whose
# composer carries claude 2.1.220's U+00A0 padding.
#
# Task fm-send-busy-false-negative. fm-send reported landed steers as failures
# (`text not submitted ... verdict=pending`) on roughly ten consecutive
# supervisor steers to busy claude panes. The cause is not the busy pane: claude
# 2.1.220 pads its bare `❯` composer prompt with U+00A0 rather than a plain
# space, no POSIX [[:space:]] class matches U+00A0, so trimmed composer content
# was never exactly `❯` and EVERY clear claude composer classified as real,
# unsubmitted text. The busy case was simply where a supervisor kept hitting it.
#
# SCOPE: every pane below reads IDLE to the code under test, so these cases
# cover the idle path only, which is where the defect lives. The busy-queued
# Enter fallback in bin/fm-tmux-lib.sh is NOT exercised: it calls
# fm_pane_is_busy with no harness argument, so the generic
# FM_TMUX_BUSY_REGEX_DEFAULT applies and claude's own thinking footer cannot
# match it. Real mid-turn coverage waits on item kimi-busy, which owns that
# missing harness argument; do not fake it by writing a foreign harness's busy
# signature into a claude fixture.
#
# Both directions are pinned here, because the value of the submit check is
# entirely in the second one:
#   1. A steer whose composer clears - to claude's queued-message affordance
#      included - must exit 0.
#   2. A steer whose Enter is genuinely swallowed - text still sitting in the
#      composer - must still exit NON-ZERO.
#
# The composer rows below are literal captures from claude 2.1.220 (tmux,
# `capture-pane -e`), NBSP padding and SGR runs intact, so a future claude
# rendering change breaks this test rather than the fleet.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SEND="$ROOT/bin/fm-send.sh"
TMP_ROOT=$(fm_test_tmproot fm-send-busy-claude)

# Captured claude 2.1.220 composer rows. \302\240 is the U+00A0 pad after `❯`.
CLAUDE_ROW_CLEAR=$(printf '\033[39m\342\235\257\302\240')
CLAUDE_ROW_QUEUED=$(printf '\033[38;5;246m\342\235\257\302\240\033[2m\033[39mPress up to edit queued messages\033[0m')
CLAUDE_ROW_TEXT=$(printf '\033[39m\342\235\257\302\240fix findings 1 and 3, skip 2')
# claude's mid-turn footer. It matches FM_TMUX_CLAUDE_BUSY_REGEX_DEFAULT but not
# the generic default the submit core actually applies, so a pane carrying it
# still reads idle here (see SCOPE above, item kimi-busy).
CLAUDE_THINKING_FOOTER='✢ Lollygagging… (13s · thinking with xhigh effort)'

# make_pane <dir> <footer|""> <composer-row>
# Writes the styled pane the fake tmux replays. The composer sits on row 3
# (0-based), which is what the fake reports as cursor_y.
make_pane() {
  local dir=$1 footer=$2 composer=$3
  {
    printf 'the modern rules crystallised into the ones still taught\n'
    printf '%s\n' "$footer"
    printf '\342\224\200\342\224\200\342\224\200\342\224\200 \342\206\257 \342\224\200\n'
    printf '%s\n' "$composer"
    printf '\342\224\200\342\224\200\342\224\200\342\224\200\n'
    printf '  /tmp/proj  master \302\267 Opus 5\n'
  } > "$dir/pane.ansi"
  # `capture-pane` without -e returns the same screen with the SGR runs gone.
  local esc; esc=$(printf '\033')
  LC_ALL=C sed "s/${esc}\\[[0-9;]*m//g" "$dir/pane.ansi" > "$dir/pane.plain"
}

# make_case <name> <footer|""> -> echoes the case dir.
# The fake tmux clears the composer to the queued-affordance row on Enter,
# unless <dir>/.swallow exists, in which case Enter is dropped entirely.
make_case() {
  local name=$1 footer=$2 dir fb
  dir="$TMP_ROOT/$name-$RANDOM"
  fb="$dir/fakebin"
  mkdir -p "$fb" "$dir/state"
  printf 'window=sess:win\nharness=claude\nkind=ship\nbackend=tmux\n' > "$dir/state/steer.meta"
  printf '%s\n' "$footer" > "$dir/.footer"
  printf '%s\n' "$CLAUDE_ROW_QUEUED" > "$dir/.cleared"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
D="${FM_FAKE_PANE_DIR:?}"
case "${1:-}" in
  display-message)
    for a in "$@"; do
      case "$a" in *cursor_y*) printf '3\n'; exit 0 ;; esac
    done
    printf '%%1\n'; exit 0 ;;
  capture-pane)
    # Honour -S/-E: the composer reader asks for the single cursor row, and a
    # mock that returned the whole screen would hide a row-scoped regression.
    styled=0 start= end=
    shift
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -e) styled=1 ;;
        -S) start=$2; shift ;;
        -E) end=$2; shift ;;
      esac
      shift
    done
    src="$D/pane.plain"; [ "$styled" = 1 ] && src="$D/pane.ansi"
    case "$start" in ''|-*|0) start=0 ;; esac
    case "$end" in ''|-) end=$(( $(wc -l < "$src") - 1 )) ;; esac
    sed -n "$((start + 1)),$((end + 1))p" "$src"
    exit 0 ;;
  send-keys)
    shift
    is_enter=0 text=
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -t) shift ;;
        -l) ;;
        Enter) is_enter=1 ;;
        *) text=$1 ;;
      esac
      shift
    done
    if [ "$is_enter" = 1 ]; then
      printf 'Enter\n' >> "$D/sent.log"
      [ -e "$D/.swallow" ] && exit 0
      "$D/rebuild" "$(cat "$D/.cleared")"
    else
      printf 'typed\n' >> "$D/sent.log"
      "$D/rebuild" "$(sed -n 4p "$D/pane.ansi")$text"
    fi
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  # rebuild <composer-row>: re-render the pane with a new composer row.
  cat > "$dir/rebuild" <<SH
#!/usr/bin/env bash
set -u
$(declare -f make_pane)
make_pane "$dir" "\$(cat "$dir/.footer")" "\$1"
SH
  chmod +x "$dir/rebuild"
  make_pane "$dir" "$footer" "$CLAUDE_ROW_CLEAR"
  : > "$dir/sent.log"
  printf '%s\n' "$dir"
}

run_send() {  # <dir> <stderr-file> -> exit status of fm-send
  local dir=$1 err=$2
  PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_ROOT_OVERRIDE="$dir" \
    FM_FAKE_PANE_DIR="$dir" FM_SEND_SLEEP=0.05 FM_SEND_SETTLE=0 \
    "$SEND" fm-steer 'note from firstmate: also check the second finding' \
    >/dev/null 2>"$err"
}

# --- Direction 1: the steer landed and the composer cleared -----------------

test_queued_affordance_steer_exits_zero() {
  local dir err
  dir=$(make_case thinking-queued "$CLAUDE_THINKING_FOOTER")
  err="$dir/send.err"
  run_send "$dir" "$err" \
    || fail "fm-send reported a cleared claude composer as an unsubmitted steer: $(cat "$err")"
  grep -qF 'Press up to edit queued messages' "$dir/pane.plain" \
    || fail "test setup: the pane should have ended in claude's queued-message state"
  # One Enter is enough once the cleared composer is read correctly. The extra
  # retries were themselves harmful: a live busy pane queued the steer TWICE.
  [ "$(grep -c '^Enter$' "$dir/sent.log")" -eq 1 ] \
    || fail "a confirmed submit sent $(grep -c '^Enter$' "$dir/sent.log") Enters, risking a duplicate queued steer"
  pass "fm-send: a steer clearing into claude's queued-message state exits 0 with a single Enter"
}

test_idle_claude_steer_exits_zero() {
  local dir err
  dir=$(make_case idle-clear "")
  err="$dir/send.err"
  run_send "$dir" "$err" \
    || fail "fm-send failed on an idle claude pane: $(cat "$err")"
  pass "fm-send: a steer to an idle claude pane still exits 0"
}

# --- Direction 2: the regression that matters -------------------------------

test_genuine_swallow_still_exits_nonzero() {
  local dir err
  dir=$(make_case genuine-swallow "")
  err="$dir/send.err"
  # Text typed, every Enter dropped: the instruction is sitting unsubmitted in
  # the composer. This MUST stay loud - it is the whole point of the check.
  touch "$dir/.swallow"
  if run_send "$dir" "$err"; then
    fail "fm-send exited zero on a genuinely swallowed Enter (silent unsubmitted instruction)"
  fi
  grep -qF 'not submitted' "$err" || fail "fm-send did not explain the swallowed submit: $(cat "$err")"
  grep -qF 'note from firstmate: also check the second finding' "$dir/pane.plain" \
    || fail "test setup: the swallowed text should still be sitting in the composer"
  pass "fm-send: a genuinely swallowed Enter still exits non-zero"
}

test_swallow_is_not_masked_by_the_queued_affordance() {
  local dir err
  dir=$(make_case affordance-swallow "")
  err="$dir/send.err"
  # Delivery is judged from the COMPOSER, never from the screen. Reading the
  # "Press up to edit queued messages" placeholder as a success signal anywhere
  # on the pane was the first theory of this bug; it would have reported this
  # swallowed instruction as delivered. Text left in the composer stays pending.
  make_pane "$dir" "Press up to edit queued messages" "$CLAUDE_ROW_TEXT"
  printf 'Press up to edit queued messages\n' > "$dir/.footer"
  touch "$dir/.swallow"
  if run_send "$dir" "$err"; then
    fail "an unrelated queued-message affordance masked a genuinely unsubmitted composer"
  fi
  grep -qF 'not submitted' "$err" || fail "fm-send did not explain the swallowed submit: $(cat "$err")"
  pass "fm-send: the queued affordance elsewhere on screen does not mask unsubmitted composer text"
}

test_queued_affordance_steer_exits_zero
test_idle_claude_steer_exits_zero
test_genuine_swallow_still_exits_nonzero
test_swallow_is_not_masked_by_the_queued_affordance
