#!/usr/bin/env bash
# Behavior tests for the desktop registry (bin/fm-desktop.sh) and the wall
# service's cost model (bin/fm-desktop-wall.py).
#
# The registry is exercised through the CLI only. The wall's viewer gating,
# interval floor and token map are exercised through the module's public
# functions, which is the same contract the running listener uses; they are
# separated from the websockify import on purpose so this file runs on a CI
# machine that has no websockify, no X server and no ffmpeg.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DESKTOP="$ROOT/bin/fm-desktop.sh"
WALL="$ROOT/bin/fm-desktop-wall.py"

command -v jq >/dev/null 2>&1 || {
	echo "skip: jq not found"
	exit 0
}
command -v python3 >/dev/null 2>&1 || {
	echo "skip: python3 not found"
	exit 0
}

TMP_ROOT=$(fm_test_tmproot fm-desktop)

# A fixture home with its own registry, its own legacy TSV, and a fake X socket
# directory, so nothing here can see or touch a real desktop on the box.
new_home() { # <name> -> echoes the home path
	local home="$TMP_ROOT/$1"
	mkdir -p "$home/state" "$home/x" "$home/legacy"
	printf '%s' "$home"
}

desktop() { # <home> <args...>
	local home="$1"
	shift
	FM_HOME="$home" \
		FM_DESKTOP_LEGACY_REGISTRY="$home/legacy/registry" \
		FM_DESKTOP_X_SOCKET_DIR="$home/x" \
		"$DESKTOP" "$@"
}

test_register_records_display_rfb_and_metadata() {
	local home
	home=$(new_home register)
	desktop "$home" register seer --display 14 --group secondmates \
		--owner seer-mate-e3 --project seer >/dev/null ||
		fail "register failed"

	local got
	got=$(jq -r '.desktops[0] | [.name, (.display|tostring), (.rfb_port|tostring),
                                .group, .owner, .project] | join(" ")' \
		"$home/state/desktops.json")
	[ "$got" = "seer 14 5914 secondmates seer-mate-e3 seer" ] ||
		fail "registry row wrong: $got"

	desktop "$home" register seer --display 20 >/dev/null 2>&1 &&
		fail "a duplicate name must be refused"
	pass "register records display, derived rfb port and ownership"
}

test_name_must_be_token_safe() {
	local home
	home=$(new_home names)
	# The name is used as a websockify token and as a snapshot filename, so a
	# path separator or a shouty name has to be refused at the door.
	desktop "$home" register "../etc" --display 21 >/dev/null 2>&1 &&
		fail "a traversal name must be refused"
	desktop "$home" register "Seer Two" --display 21 >/dev/null 2>&1 &&
		fail "a name with a space must be refused"
	pass "unsafe desktop names are refused"
}

test_allocation_skips_live_and_legacy_displays() {
	local home
	home=$(new_home alloc)
	touch "$home/x/X11" "$home/x/X12"                   # displays already running
	printf 'other-agent\t13\n' >"$home/legacy/registry" # allocated elsewhere
	desktop "$home" register taken --display 14 >/dev/null

	# A fake launcher records the display create asked for and refuses to start it,
	# so allocation is observed without putting an X server on this machine.
	local fakebin
	fakebin=$(fm_fakebin "$home")
	cat >"$fakebin/tigervncserver" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$1" >>"$home/asked"
exit 1
SH
	chmod +x "$fakebin/tigervncserver"

	PATH="$fakebin:$PATH" FM_DESKTOP_FIRST=11 FM_DESKTOP_LAST=16 \
		desktop "$home" create newone >/dev/null 2>&1 &&
		fail "create must fail when the display cannot start"
	[ "$(cat "$home/asked")" = ":15" ] ||
		fail "expected :15 (11,12 running; 13 legacy; 14 registered), got $(cat "$home/asked")"
	jq -e '[.desktops[].name] == ["taken"]' "$home/state/desktops.json" >/dev/null ||
		fail "a failed create must not leave a record behind"
	pass "allocation avoids live and legacy-registered displays"
}

test_retire_drops_the_record_without_touching_the_display() {
	local home
	home=$(new_home retire)
	touch "$home/x/X15"
	desktop "$home" register subliminal --display 15 >/dev/null
	local out
	out=$(desktop "$home" retire subliminal)
	case "$out" in
	*"was NOT touched"*) ;;
	*) fail "retire must say the display was left alone: $out" ;;
	esac
	[ -e "$home/x/X15" ] || fail "retire must not remove the running display"
	jq -e '.desktops | length == 0' "$home/state/desktops.json" >/dev/null ||
		fail "retire must drop the record"
	pass "retire removes the record and never stops a display"
}

test_wall_reads_the_registry_and_gates_on_viewers() {
	local home
	home=$(new_home wall)
	desktop "$home" register seer --display 14 >/dev/null
	desktop "$home" register dorm --display 11 >/dev/null

	FM_DESKTOP_X_SOCKET_DIR="$home/x" python3 - "$WALL" "$home" <<'PY' || fail "wall gating"
import importlib.util, sys, time, os, pathlib

path, home = sys.argv[1], pathlib.Path(sys.argv[2])
spec = importlib.util.spec_from_file_location("wall", path)
wall = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wall)

desktops = wall.load_registry(home / "state" / "desktops.json")
assert [d["name"] for d in desktops] == ["dorm", "seer"], desktops
tokens = wall.RegistryTokens(home / "state" / "desktops.json")
assert tokens.lookup("seer") == ("127.0.0.1", 5914)
assert tokens.lookup("dorm") == ("127.0.0.1", 5911)
assert tokens.lookup("nope") is None

opts = wall.parse_args(["--registry", str(home / "state" / "desktops.json"),
                        "--snapshot-dir", str(home / "state" / "wall"),
                        "--min-interval", "2"])
(pathlib.Path(opts.snapshot_dir) / "viewers").mkdir(parents=True, exist_ok=True)

# No viewer at all: the desktop must never be captured.
assert wall.viewer_interval(opts, "seer") is None

# A viewer asking for 100ms gets the server floor, not what it asked for.
wall.viewer_file(opts, "seer").write_text("0.1")
assert wall.viewer_interval(opts, "seer") == 2.0

# A viewer that stopped reporting expires, and the desktop goes free again.
old = time.time() - 60
os.utime(wall.viewer_file(opts, "seer"), (old, old))
assert wall.viewer_interval(opts, "seer") is None

# Liveness is read from the X socket, not from the registry claiming it exists.
assert wall.display_up(14) is False
(home / "x" / "X14").touch()
assert wall.display_up(14) is True
PY
	pass "the wall enumerates the registry, routes tokens from it, floors the interval and captures only what a viewer watches"
}

test_register_records_display_rfb_and_metadata
test_name_must_be_token_safe
test_allocation_skips_live_and_legacy_displays
test_retire_drops_the_record_without_touching_the_display
test_wall_reads_the_registry_and_gates_on_viewers
