#!/usr/bin/env bash
# Behavior tests for the fleet read layer: home discovery, the cheap per-home
# probe, and the two renderers that consume it.
#
# Everything here drives the executable interfaces against a fixture home tree,
# so the fleet a screen shows is asserted from behavior and never from source.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROBE="$ROOT/bin/fm-fleet-probe.sh"
READER="$ROOT/bin/fm_fleet_read.py"
TUI="$ROOT/bin/fm-fleet-tui.py"
TMP_ROOT=$(fm_test_tmproot fm-fleet-read)

command -v python3 > /dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }

FAKEBIN=$(fm_fakebin "$TMP_ROOT")
cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
# A window whose name carries "gone" is absent; every other window exists.
set -u
target=""
prev=""
for arg in "$@"; do
  if [ "$prev" = "-t" ]; then target=$arg; fi
  prev=$arg
done
case "${1:-}" in
  display-message)
    case "$target" in
      *gone*) exit 1 ;;
      *) printf '%%1\n' ;;
    esac
    ;;
  capture-pane) printf 'quiet\n' ;;
esac
exit 0
SH
chmod +x "$FAKEBIN/tmux"
export PATH="$FAKEBIN:$PATH"

MAIN="$TMP_ROOT/main"
POOL="$TMP_ROOT/pool"
mkdir -p "$MAIN/state" "$MAIN/data" "$MAIN/config" "$MAIN/projects/alpha"
for name in 9 8; do
  mkdir -p "$POOL/$name/firstmate/state" "$POOL/$name/firstmate/config" "$POOL/$name/firstmate/data"
done
# A marker home with no state directory at all: readable enough to discover,
# not readable enough to probe.
mkdir -p "$POOL/7/firstmate"
printf 'pool-mate-p9\n' > "$POOL/9/firstmate/.fm-secondmate-home"
printf 'orphan-mate-o8\n' > "$POOL/8/firstmate/.fm-secondmate-home"
printf 'stateless-mate-s7\n' > "$POOL/7/firstmate/.fm-secondmate-home"

cat > "$MAIN/data/secondmates.md" <<EOF
- pool-mate-p9 - Owns alpha (home: $POOL/9/firstmate; scope: alpha work; projects: alpha; added 2026-09-01)
- remote-mate-r1 - Owns beta (host: mac.local; root: /Users/cap/fm; home: /Users/cap/fm/home; scope: beta work; projects: beta; added 2026-09-02)
EOF

fm_write_meta "$MAIN/state/ship-live.meta" \
  "window=default:fm-ship-live" \
  "worktree=$MAIN/projects/alpha" \
  "project=$MAIN/projects/alpha" \
  "kind=ship" \
  "mode=no-mistakes" \
  "harness=claude"
fm_write_meta "$MAIN/state/ship-gone.meta" \
  "window=default:fm-ship-gone" \
  "worktree=$MAIN/projects/alpha" \
  "kind=ship" \
  "mode=direct-PR" \
  "harness=claude" \
  "pr=https://github.com/o/r/pull/7"
fm_write_meta "$MAIN/state/mate-remote.meta" \
  "window=default:fm-mate-remote" \
  "home=/Users/cap/fm/home" \
  "remote_host=mac.local" \
  "kind=secondmate" \
  "mode=secondmate" \
  "harness=claude"

# The pull request this task reported before any merge poll recorded `pr=`.
printf 'working: building\ndone: PR https://github.com/o/r/pull/42 checks green\n' \
  > "$MAIN/state/ship-live.status"
printf 'blocked [key=creds]: needs a credential\n' > "$MAIN/state/ship-gone.status"

# Two structurally valid queued wakes, and a watcher beacon.
NOW=$(date +%s)
printf '%s\t1\tsignal\tship-live\tstatus changed\n%s\t2\tcheck\tpr\tmerge poll\n' \
  "$((NOW - 300))" "$((NOW - 120))" > "$MAIN/state/.wake-queue"
touch "$MAIN/state/.last-watcher-beat"

# One live child in the registered pool home, so a home with work reads as such.
fm_write_meta "$POOL/9/firstmate/state/pool-task.meta" \
  "window=default:fm-pool-task" \
  "worktree=$POOL/9/firstmate/projects/alpha" \
  "kind=scout" \
  "harness=claude"
printf 'working: reading the code\n' > "$POOL/9/firstmate/state/pool-task.status"

# A recorded idle turn through the real busy-state owner, so the busy verdict is
# a measured record rather than a rendered guess.
GEN=$("$ROOT/bin/fm-busy-event.sh" arm "$MAIN/state" ship-live)
"$ROOT/bin/fm-busy-event.sh" apply "$MAIN/state" ship-live idle \
  --gen "$GEN" --source claude-hook --event stop > /dev/null

export FM_FLEET_TREEHOUSE_ROOT="$POOL"

# --- discovery --------------------------------------------------------------

HOMES=$(FM_HOME="$MAIN" "$PROBE" --homes)
assert_contains "$HOMES" "main	$MAIN	main" "the main home is discovered as itself"
assert_contains "$HOMES" "pool-mate-p9	$POOL/9/firstmate	registry" "a registered home comes from the registry"
assert_contains "$HOMES" "orphan-mate-o8	$POOL/8/firstmate	marker" "an unregistered home is still discovered by its marker"
assert_contains "$HOMES" "remote-mate-r1	/Users/cap/fm/home	remote:mac.local" "a remote home is listed with its host"
pass "discovery finds the main home, the registry, and unregistered pool homes"

# --- one home ---------------------------------------------------------------

PROBED=$(FM_HOME="$MAIN" "$PROBE" --home)
assert_contains "$PROBED" "sup	2	" "the wake-queue depth is read from the home's own queue"
assert_contains "$PROBED" "	free" "an unlocked home reports its session lock as free"
assert_contains "$PROBED" "task	ship-live	ship	no-mistakes	claude	tmux	alive	idle" \
  "a live endpoint and its recorded idle turn are read from their own owners"
assert_contains "$PROBED" "https://github.com/o/r/pull/42" "a pull request reported in the status log is recovered"
assert_contains "$PROBED" "task	ship-gone	ship	direct-PR	claude	tmux	dead" "a missing endpoint reads as dead"
assert_contains "$PROBED" "task	mate-remote	secondmate	secondmate	claude	tmux	unknown	unknown	not-probed" \
  "a remote endpoint is never guessed from here"
assert_contains "$PROBED" "event	ship-gone	" "the status log's last line is emitted as an event record"
assert_contains "$PROBED" "blocked" "the event record keeps the verb the worker wrote"
pass "one home probes its supervision header, endpoints, busy verdicts, and events"

STATELESS=$(FM_HOME="$POOL/7/firstmate" "$PROBE" --home)
assert_contains "$STATELESS" "error	no state directory" "a home with no records says so"
[ ! -d "$POOL/7/firstmate/state" ] || fail "the probe created a state directory in a home it only reads"
pass "probing a home without records reports it and writes nothing"

# --- the read layer --------------------------------------------------------

FLEET=$(FM_HOME="$MAIN" python3 "$READER" --json)
python3 - "$FLEET" <<'PY' || fail "the read layer did not shape the fleet as expected"
import json
import sys

fleet = json.loads(sys.argv[1])
homes = {home["label"]: home for home in fleet["homes"]}
assert set(homes) >= {"main", "pool-mate-p9", "orphan-mate-o8", "remote-mate-r1"}, homes.keys()
assert fleet["counts"]["tasks"] == 4, fleet["counts"]
assert fleet["counts"]["tasks_live"] == 2, fleet["counts"]
assert homes["main"]["supervision"]["wake_depth"] == 2, homes["main"]["supervision"]
assert homes["main"]["supervision"]["beat_age"] is not None
assert "remote" in homes["remote-mate-r1"]["error"], homes["remote-mate-r1"]
assert homes["remote-mate-r1"]["tasks"] == []
tasks = {task["id"]: task for task in homes["main"]["tasks"]}
assert tasks["ship-live"]["endpoint"] == "alive", tasks["ship-live"]
assert tasks["ship-live"]["busy"] == "idle", tasks["ship-live"]
assert tasks["ship-live"]["last_event"]["verb"] == "done", tasks["ship-live"]
assert tasks["ship-gone"]["endpoint"] == "dead", tasks["ship-gone"]
assert tasks["mate-remote"]["endpoint"] == "unknown", tasks["mate-remote"]
assert homes["pool-mate-p9"]["tasks"][0]["id"] == "pool-task"
assert homes["orphan-mate-o8"]["tasks"] == []
assert fleet["elapsed_ms"] >= 0
PY
pass "the read layer returns one shaped fleet from every discovered home"

# --- the screens -----------------------------------------------------------

FRAME=$(FM_HOME="$MAIN" python3 "$TUI" --once)
assert_contains "$FRAME" "FIRSTMATE FLEET" "the screen names itself"
assert_contains "$FRAME" "ship-live" "every task in flight is on the screen"
assert_contains "$FRAME" "pool-task" "a pool home's task is on the same screen as the main home's"
assert_contains "$FRAME" "orphan-mate-o8" "an unregistered home is visible rather than silently absent"
assert_contains "$FRAME" "EVENT" "the last status line is labelled as a wake event, not current state"
assert_contains "$FRAME" "no work under way here" "a home with no work says so"
pass "the terminal screen renders the whole fleet from the read layer"

BOARD=$(FM_HOME="$MAIN" python3 - "$ROOT" <<'PY'
import importlib.util
import json
import sys

root = sys.argv[1]
sys.path.insert(0, f"{root}/bin")
spec = importlib.util.spec_from_file_location("board", f"{root}/bin/fm-live-board.py")
board = importlib.util.module_from_spec(spec)
spec.loader.exec_module(board)
import fm_fleet_read

print(board.render(fm_fleet_read.read_fleet()))
PY
) || fail "the web board could not render from the read layer"
assert_contains "$BOARD" "ship-live" "the web board lists the same tasks"
assert_contains "$BOARD" "orphan-mate-o8" "the web board discovers homes instead of hardcoding them"
assert_contains "$BOARD" "event" "the web board labels the last status line as an event"
pass "the web board renders the same discovered fleet"

# --- the backlog read ------------------------------------------------------

if command -v tasks-axi > /dev/null 2>&1; then
  cp "$ROOT/.tasks.toml" "$MAIN/.tasks.toml"
  (
    cd "$MAIN" || exit 1
    tasks-axi add ship-live "Ship Live" --repo alpha --kind ship --start > /dev/null
    tasks-axi add waiting-task "Waiting Task" --repo alpha --kind ship > /dev/null
    tasks-axi add captain-call "Captain Call" --repo alpha --kind task > /dev/null
    tasks-axi hold captain-call --reason "needs the captain" --kind captain > /dev/null
  ) || fail "the fixture backlog could not be written through tasks-axi"
  WITH_BACKLOG=$(cd "$MAIN" && FM_HOME="$MAIN" "$PROBE" --home)
  assert_contains "$WITH_BACKLOG" "backlog	1	" "the backlog counts come from the home's configured backend"
  assert_contains "$WITH_BACKLOG" "hold	captain-call	captain" "a task held for the captain is reported with its hold kind"
  pass "the backlog read asks tasks-axi for counts and captain holds"
else
  echo "skip: tasks-axi not found (backlog counts and captain holds unasserted)"
fi
