#!/usr/bin/env bash
# tests/spawn-helpers.sh - shared fixtures for the fm-spawn base-freshness suites
# (fm-spawn-pool-base-freshen and fm-spawn-clone-base-drift).
#
# Both drive the real spawn path through a fake tmux whose pane already sits in a
# pooled worktree, so the terminal stub, the task home scaffold, and the spawn
# invocation are identical. They encode spawn-lifecycle behavior rather than
# generic primitives, so they live here rather than in tests/lib.sh. The git
# fixtures the two suites build differ and stay with each suite.

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# A fake tmux whose pane reports FM_FAKE_PANE_PATH (the pooled worktree, as if
# `treehouse get` had already entered it) plus a no-op fake treehouse. Echoes the
# fakebin dir so a suite can add further shims to it.
fm_spawn_fake_terminal() {
	local dir=$1 fakebin
	fakebin=$(fm_fakebin "$dir")
	cat >"$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:?FM_FAKE_PANE_PATH unset}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows|has-session|new-session|new-window|kill-window|send-keys) exit 0 ;;
esac
exit 0
SH
	chmod +x "$fakebin/tmux"
	fm_fake_exit0 "$fakebin" treehouse
	printf '%s\n' "$fakebin"
}

# A firstmate home holding one task's brief, ready to spawn <id>.
fm_spawn_home() {
	local home=$1 id=$2
	mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
	printf 'codex\n' >"$home/config/crew-harness"
	printf 'brief for %s\n' "$id" >"$home/data/$id/brief.md"
	touch "$home/state/.last-watcher-beat"
}

# Run the real fm-spawn.sh against the case the caller built, reading the case
# globals both suites already set: HOME_DIR, PROJECT_DIR, POOL_DIR, FAKEBIN_DIR.
# Merges stderr into stdout so a case can assert on refusals and warnings.
fm_spawn_run() {
	local id=$1
	shift
	FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
		FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
		FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
		FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" FM_FAKE_PANE_PATH="$POOL_DIR" \
		PATH="$FAKEBIN_DIR:$PATH" \
		"$ROOT/bin/fm-spawn.sh" "$id" "$PROJECT_DIR" "$@" 2>&1
}
