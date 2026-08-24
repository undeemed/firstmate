#!/usr/bin/env bash
# E2E proof for fm/tmpdir-spawn-fix: a real bin/fm-spawn.sh into a REAL tmux pane
# (private socket) launches a stub agent; we prove via /proc/<pid>/environ that the
# agent and a child process it starts inherit TMPDIR and GOTMPDIR inside the
# disk-backed per-task root, that no /tmp/fm-<id> is created, that a real
# bin/fm-teardown.sh removes the root, and that a meta recording the legacy
# /tmp/fm-<id> path is still removed (no leak).
#
# Only the tmux binary is real for pane handling; treehouse/gh-axi/gh are exit-0
# stubs and `claude` is a stub agent that records its pid, starts a child, and
# uses its $TMPDIR - exactly the "process the spawned agent starts" the
# acceptance criteria name.
set -u

REPO=$1 # worktree root (absolute)
EVID=$2 # evidence dir (absolute)

FIX=$(mktemp -d "${TMPDIR:-/tmp}/fm-e2e-proof.XXXXXX") || exit 1
LABEL="fm-e2e-$$"
TMUX_BIN=/usr/bin/tmux
LEGACY_DIR=

step() { printf '\n### %s\n' "$1"; }
die() {
	printf 'FAIL: %s\n' "$1"
	exit 1
}

cleanup() {
	"$TMUX_BIN" -L "$LABEL" kill-server 2>/dev/null || true
	[ -z "${LEGACY_DIR:-}" ] || rm -rf "$LEGACY_DIR"
	rm -rf "$FIX"
}
trap cleanup EXIT

ID="e2e-proof-$$"
HOMEDIR="$FIX/home"
PROJ="$FIX/project"
WT="$FIX/wt"
FAKEBIN="$FIX/fakebin"
OUT="$FIX/out"
TASKROOT="$FIX/tasktmp-root" # FM_TASKTMP_ROOT override (disk-backed root stand-in)
mkdir -p "$HOMEDIR/data/$ID" "$HOMEDIR/projects" "$HOMEDIR/state" "$HOMEDIR/config" \
	"$FAKEBIN" "$OUT" "$TASKROOT"

printf 'claude\n' >"$HOMEDIR/config/crew-harness"
printf 'e2e brief: do nothing\n' >"$HOMEDIR/data/$ID/brief.md"
touch "$HOMEDIR/state/.last-watcher-beat"

# Real project repo + a bare origin, like tests/lib.sh fm_git_worktree does.
git init -q "$PROJ" && (cd "$PROJ" && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init)
git clone -q --bare "$PROJ" "$PROJ.origin.git"
git -C "$PROJ" remote add origin "$PROJ.origin.git"
git -C "$PROJ" worktree add --quiet -b "wt-$ID" "$WT"

# fakebin: tmux -> REAL tmux pinned to a private socket; inert stubs for the rest.
cat >"$FAKEBIN/tmux" <<EOF
#!/usr/bin/env bash
exec $TMUX_BIN -L $LABEL "\$@"
EOF
chmod +x "$FAKEBIN/tmux"
for t in gh-axi gh; do
	printf '#!/usr/bin/env bash\nexit 0\n' >"$FAKEBIN/$t"
	chmod +x "$FAKEBIN/$t"
done
# treehouse stub: `treehouse get`, typed into the real pane by fm-spawn, enters a
# pre-provisioned git worktree subshell exactly like the real tool - the pane's
# cwd moves off the project so fm-spawn's worktree wait and validation see a
# real, distinct worktree top-level.
cat >"$FAKEBIN/treehouse" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
get)
	next=$(cat "$FM_E2E_OUT/next-wt")
	cd "$next" && exec bash -i
	;;
esac
exit 0
EOF
chmod +x "$FAKEBIN/treehouse"
ln -s "$(command -v jq)" "$FAKEBIN/jq"

# Stub agent: records its own pid + argv, starts a child process, and uses its
# TMPDIR the way a real build tool would.
cat >"$FAKEBIN/claude" <<'EOF'
#!/usr/bin/env bash
set -u
mkdir -p "${TMPDIR:?TMPDIR not set}/agent-scratch.$$"
sleep 600 &
echo "$!" > "$FM_E2E_OUT/child.pid"
echo "$$" > "$FM_E2E_OUT/claude.pid"
wait
EOF
chmod +x "$FAKEBIN/claude"

BASE_PATH="$(dirname "$(command -v python3)"):/usr/bin:/bin:/usr/sbin:/sbin"
E2E_PATH="$FAKEBIN:$BASE_PATH"

step "1. start a REAL tmux server (private socket $LABEL) with session 'firstmate'"
env -i HOME="$HOMEDIR" PATH="$E2E_PATH" TERM=xterm-256color SHELL=/bin/bash \
	FM_E2E_OUT="$OUT" FM_TASKTMP_ROOT="$TASKROOT" \
	"$TMUX_BIN" -L "$LABEL" new-session -d -s firstmate -x 220 -y 50 || die "tmux server"
"$TMUX_BIN" -L "$LABEL" list-sessions

SOCK="/tmp/tmux-$(id -u)/$LABEL"

run_fm() { # <script> <args...>
	local script=$1
	shift
	HOME="$HOMEDIR" FM_ROOT_OVERRIDE='' FM_HOME="$HOMEDIR" \
		FM_STATE_OVERRIDE="$HOMEDIR/state" FM_DATA_OVERRIDE="$HOMEDIR/data" \
		FM_PROJECTS_OVERRIDE="$HOMEDIR/projects" FM_CONFIG_OVERRIDE="$HOMEDIR/config" \
		FM_SPAWN_NO_GUARD=1 FM_GATE_REFUSE_BYPASS=1 FM_TASKTMP_ROOT="$TASKROOT" \
		TMUX="$SOCK,1,0" PATH="$E2E_PATH" \
		"$REPO/bin/$script" "$@" 2>&1
}

printf '%s\n' "$WT" >"$OUT/next-wt"
step "2. real fm-spawn of task $ID (harness claude -> stub agent) into that server"
run_fm fm-spawn.sh "$ID" "$PROJ" --harness claude --mode no-mistakes --yolo off
rc=$?
echo "fm-spawn exit=$rc"
[ "$rc" -eq 0 ] || {
	"$TMUX_BIN" -L "$LABEL" capture-pane -p -t firstmate 2>/dev/null | tail -20
	die "fm-spawn failed"
}

step "3. task meta records the disk-backed root (tasktmp= line)"
grep '^tasktmp=' "$HOMEDIR/state/$ID.meta" || die "no tasktmp= in meta"
TASK_TMP=$(grep '^tasktmp=' "$HOMEDIR/state/$ID.meta" | cut -d= -f2-)
case "$TASK_TMP" in "$TASKROOT/fm-$ID") ;; *) die "tasktmp is not under FM_TASKTMP_ROOT: $TASK_TMP" ;; esac

step "4. the launched agent process exists; read its /proc/<pid>/environ"
for _ in $(seq 1 60); do
	[ -s "$OUT/claude.pid" ] && break
	sleep 1
done
[ -s "$OUT/claude.pid" ] || {
	"$TMUX_BIN" -L "$LABEL" capture-pane -p -t firstmate | tail -25
	die "stub agent never started"
}
AGENT_PID=$(cat "$OUT/claude.pid")
CHILD_PID=$(cat "$OUT/child.pid")
echo "agent pid=$AGENT_PID  child pid=$CHILD_PID"
echo "--- /proc/$AGENT_PID/environ (TMPDIR/GOTMPDIR) ---"
tr '\0' '\n' <"/proc/$AGENT_PID/environ" | grep -E '^(TMPDIR|GOTMPDIR)=' || die "agent environ lacks TMPDIR/GOTMPDIR"
echo "--- /proc/$CHILD_PID/environ (process the agent started) ---"
tr '\0' '\n' <"/proc/$CHILD_PID/environ" | grep -E '^(TMPDIR|GOTMPDIR)=' || die "child environ lacks TMPDIR/GOTMPDIR"
AG_TMP=$(tr '\0' '\n' <"/proc/$AGENT_PID/environ" | sed -n 's/^TMPDIR=//p')
AG_GOTMP=$(tr '\0' '\n' <"/proc/$AGENT_PID/environ" | sed -n 's/^GOTMPDIR=//p')
[ "$AG_TMP" = "$TASK_TMP/tmp" ] || die "agent TMPDIR ($AG_TMP) != $TASK_TMP/tmp"
[ "$AG_GOTMP" = "$TASK_TMP/gotmp" ] || die "agent GOTMPDIR ($AG_GOTMP) != $TASK_TMP/gotmp"

step "5. the agent already used its TMPDIR (scratch dir it created) + root layout"
ls -la "$TASK_TMP" "$TASK_TMP/tmp"

step "6. no legacy /tmp/fm-<id> was created by any bin/ code path"
if [ -e "/tmp/fm-$ID" ]; then die "legacy /tmp/fm-$ID exists"; else echo "OK: /tmp/fm-$ID does not exist"; fi

step "7. real fm-teardown removes the recorded disk-backed root"
run_fm fm-teardown.sh "$ID"
echo "fm-teardown exit=$?"
if [ -e "$TASK_TMP" ]; then die "teardown left $TASK_TMP behind"; else echo "OK: $TASK_TMP removed"; fi

step "8. legacy-path teardown: a pre-change task whose meta records tasktmp=/tmp/fm-<id>"
ID2="e2e-legacy-$$"
mkdir -p "$HOMEDIR/data/$ID2"
printf 'legacy brief\n' >"$HOMEDIR/data/$ID2/brief.md"
git -C "$PROJ" worktree add --quiet -b "wt-$ID2" "$FIX/wt2"
printf '%s\n' "$FIX/wt2" >"$OUT/next-wt"
run_fm fm-spawn.sh "$ID2" "$PROJ" --harness claude --mode no-mistakes --yolo off || die "legacy spawn failed"
# Simulate the pre-change record: point the meta at the old shared-tmpfs path.
LEGACY_DIR="/tmp/fm-$ID2"
mkdir -p "$LEGACY_DIR/gotmp"
echo data >"$LEGACY_DIR/gotmp/left-behind"
NEW_ROOT=$(grep '^tasktmp=' "$HOMEDIR/state/$ID2.meta" | cut -d= -f2-)
sed -i "s|^tasktmp=.*|tasktmp=$LEGACY_DIR|" "$HOMEDIR/state/$ID2.meta"
echo "meta now records: $(grep '^tasktmp=' "$HOMEDIR/state/$ID2.meta")"
run_fm fm-teardown.sh "$ID2"
echo "fm-teardown exit=$?"
if [ -e "$LEGACY_DIR" ]; then die "teardown leaked legacy $LEGACY_DIR"; else echo "OK: legacy $LEGACY_DIR removed (recorded path is authoritative)"; fi
rm -rf "$NEW_ROOT" # fixture hygiene: the unrecorded replacement root

step "RESULT"
echo "ALL E2E CHECKS PASSED"
