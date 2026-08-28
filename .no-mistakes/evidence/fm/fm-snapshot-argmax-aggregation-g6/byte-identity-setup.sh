#!/usr/bin/env bash
# Build a fixed small two-home fleet fixture (3 landed rows per home).
# Usage: byte-identity-setup.sh <repo-worktree> <fixture-dir>
set -eu
REPO=$1 FIX=$2
cd "$REPO"
. tests/lib.sh
home="$FIX/parent"
mkdir -p "$home/state" "$home/data" "$home/projects" "$home/config"
for i in 1 2; do
  id="small-mate-$i"
  mate="$FIX/$id"
  fm_make_secondmate_home "$id" "$mate"
  for j in 1 2 3; do
    printf -- '- [x] %s-landed-%s - Landed item %s (repo: sample) (kind: ship) (merged 2026-07-05)\n' \
      "$id" "$j" "$j" >> "$mate/data/backlog.md"
  done
  fm_append_secondmate_registry "$home" "$id" "$mate"
  fm_write_parent_secondmate_event "$home" "$id" "$mate" "watching scope"
done
# fakebin copied verbatim from tests/fm-fleet-snapshot-view.test.sh make_fakebin
fb=$(fm_fakebin "$home")
cat > "$fb/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
target=""
prev=""
for arg in "$@"; do
  if [ "$prev" = "-t" ]; then target=$arg; fi
  prev=$arg
done
case "${1:-}" in
  list-windows)
    sed -n 's/^window=[^:]*://p' "${FM_HOME:?}"/state/*.meta
    ;;
  display-message)
    case "$*" in
      *pane_current_command*)
        case "$target" in
          *dead-secondmate*) printf 'zsh\n' ;;
          *) printf 'codex\n' ;;
        esac
        ;;
      *) printf '%%1\n' ;;
    esac
    ;;
  capture-pane)
    case "$target" in
      *ship-task*|*active-secondmate*) printf 'work in progress\nesc to interrupt\n' ;;
      *) printf 'all quiet\n> \n' ;;
    esac
    ;;
esac
exit 0
SH
chmod +x "$fb/no-mistakes" "$fb/tmux"
echo "fixture ready at $FIX"
