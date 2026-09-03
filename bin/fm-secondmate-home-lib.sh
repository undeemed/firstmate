#!/usr/bin/env bash
# fm-secondmate-home-lib.sh - read-only observation of a LOCAL secondmate home,
# for the only questions a parent may ask about a mate's tree without supervising
# it: is this the home that task records, does it still hold live child work, and
# is that home consuming its own wake queue.
#
# AGENTS.md forbids reconstructing or supervising a secondmate's child tree from
# the main home, so nothing here reads a child's pane, steers a child, or writes
# anything at all. It reads durable records only: the home's identity marker, the
# task records the home itself keeps, and the home's own durable wake queue.
#
# Why it exists (measured 2026-08-24): a mate that finished its own last item
# reported `done` while six of its children were still live and its own wake queue
# was accumulating their events unread. Every parent-side read agreed with the
# mate's own status log, none accounted for the tree, and the home's silence was
# reported as health twice.
#
# No side effects on source. set -u safe.

# 0 when <home> is the local home that task <id> records: a regular, never
# symlinked identity marker naming exactly that task. Seeding publishes that
# marker last, so its content is the home's seed-completion point.
fm_secondmate_home_bound() {  # <home> <task-id>
  local home=${1:-} id=${2:-} marker
  [ -n "$home" ] && [ -n "$id" ] || return 1
  marker="$home/.fm-secondmate-home"
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
  [ "$(cat "$marker" 2>/dev/null || true)" = "$id" ]
}

# Print how many LIVE child task records <home> holds. A task record exists from
# spawn until teardown removes it, so it is the home's own durable answer to
# "is work under way here" - no endpoint probe, and no read of a child at all.
# A registered secondmate of that home is not child work: a secondmate is idle by
# default and its own parent routes to it, so kind=secondmate records are excluded.
fm_secondmate_home_live_children() {  # <home>
  local home=${1:-} meta n=0
  if [ -n "$home" ] && [ -d "$home/state" ]; then
    for meta in "$home"/state/*.meta; do
      [ -f "$meta" ] && [ ! -L "$meta" ] || continue
      grep -qx 'kind=secondmate' "$meta" && continue
      n=$((n + 1))
    done
  fi
  printf '%s' "$n"
}

# Print the oldest structurally valid row in <home>'s own durable wake queue, or
# nothing when that queue is absent, unusable, or holds no valid row. The
# receiving home owns acknowledgement; an observer never changes the row or the
# queue.
fm_secondmate_home_oldest_queue_row() {  # <home>
  local home=${1:-} queue
  [ -n "$home" ] || return 0
  queue="$home/state/.wake-queue"
  [ -f "$queue" ] && [ ! -L "$queue" ] || return 0
  awk -F '\t' '
    NF >= 5 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ {
      if (!found || $2 < seq) {
        found = 1
        seq = $2
        row = $0
      }
    }
    END { if (found) print row }
  ' "$queue" 2>/dev/null || true
}

# Print how many structurally valid rows <home>'s own wake queue holds. Depth is
# the half of the picture the oldest row alone cannot give: one aged row is a home
# mid-turn, a deep queue behind that same row is a home that is not keeping up.
fm_secondmate_home_queue_depth() {  # <home>
  local home=${1:-} queue
  queue="$home/state/.wake-queue"
  if [ -z "$home" ] || [ ! -f "$queue" ] || [ -L "$queue" ]; then
    printf '0'
    return 0
  fi
  awk -F '\t' '
    NF >= 5 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ { n++ }
    END { printf "%d", n + 0 }
  ' "$queue" 2>/dev/null || printf '0'
}
