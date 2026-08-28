#!/usr/bin/env bash
# Run snapshot + view on the fixed fixture with pinned clock; write <out>.json and <out>.view.
# Usage: byte-identity-run.sh <repo-worktree> <fixture-dir> <out-prefix>
set -eu
REPO=$1 FIX=$2 OUT=$3
home="$FIX/parent"
fb="$home/fakebin"
rm -rf "$FIX/root-override"; mkdir -p "$FIX/root-override"
env PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$FIX/root-override" \
  FM_SNAPSHOT_NOW=2026-07-14T00:00:00Z \
  "$REPO/bin/fm-fleet-snapshot.sh" --json > "$OUT.json"
env PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$FIX/root-override" \
  FM_SNAPSHOT_NOW=2026-07-14T00:00:00Z \
  "$REPO/bin/fm-fleet-view.sh" > "$OUT.view"
