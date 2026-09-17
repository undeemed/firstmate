#!/usr/bin/env bash
# Opt-in live guard for the wall's keyed reconciliation.
#
# A live tile holds a noVNC session in an iframe. Rebuilding tile nodes on every
# refresh recreated that iframe, so every tick tore down the websocket and
# reconnected. Only a real browser and a real RFB target can prove that stopped:
# a DOM stub would count whatever the stub was written to count.
#
# It measures two things over at least three refresh ticks with one tile live:
#   - iframe creations, which must be exactly 1 (the one the toggle made)
#   - RFB connections to that desktop's port, which must be exactly 1
set -u

if [ "${FM_DESKTOP_WALL_LIVE_E2E:-0}" != 1 ]; then
	echo "skip: set FM_DESKTOP_WALL_LIVE_E2E=1 to run the live desktop-wall reconnect guard"
	exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
	printf 'not ok - %s\n' "$1" >&2
	exit 1
}
pass() { printf 'ok - %s\n' "$1"; }

for tool in tigervncserver websockify ffmpeg jq chrome-devtools-axi ss; do
	command -v "$tool" >/dev/null 2>&1 || fail "live guard needs $tool"
done
CHROME=""
for candidate in "$HOME/.cache/ms-playwright/chromium-1234/chrome-linux64/chrome" \
	"$(command -v google-chrome || true)" "$(command -v chromium || true)"; do
	[ -n "$candidate" ] && [ -x "$candidate" ] && CHROME="$candidate" && break
done
[ -n "$CHROME" ] || fail "live guard needs a chrome binary"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-wall-live.XXXXXX")
PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
CDP=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
WALL_PID=""
CHROME_PID=""
DISPLAY_NUM=""

cleanup() {
	[ -n "$CHROME_PID" ] && kill "$CHROME_PID" 2>/dev/null
	[ -n "$WALL_PID" ] && kill "$WALL_PID" 2>/dev/null
	# Only ever the display this test started itself.
	[ -n "$DISPLAY_NUM" ] && timeout 60 tigervncserver -kill ":$DISPLAY_NUM" >/dev/null 2>&1
	rm -rf "$LAB"
}
trap cleanup EXIT INT TERM

export FM_HOME="$LAB/home"
mkdir -p "$FM_HOME/state"
timeout 120 "$ROOT/bin/fm-desktop.sh" create wallprobe --group probe --owner live-guard \
	>"$LAB/create.log" 2>&1 || fail "could not create the guard's own desktop: $(cat "$LAB/create.log")"
DISPLAY_NUM=$(jq -r '.desktops[0].display' "$FM_HOME/state/desktops.json")
RFB_PORT=$((5900 + DISPLAY_NUM))

python3 "$ROOT/bin/fm-desktop-wall.py" --registry "$FM_HOME/state/desktops.json" \
	--snapshot-dir "$LAB/snaps" --listen 127.0.0.1 --port "$PORT" \
	>"$LAB/wall.log" 2>&1 &
WALL_PID=$!
for _ in $(seq 1 40); do
	curl -s -o /dev/null "http://127.0.0.1:$PORT/wall/" && break
	sleep 0.5
done
curl -s -o /dev/null "http://127.0.0.1:$PORT/wall/" || fail "wall did not start: $(cat "$LAB/wall.log")"

TMPDIR=/tmp DISPLAY=":$DISPLAY_NUM" "$CHROME" --user-data-dir="$LAB/profile" \
	--remote-debugging-port="$CDP" --window-size=1200,800 \
	--no-first-run --no-default-browser-check about:blank >"$LAB/chrome.log" 2>&1 &
CHROME_PID=$!
for _ in $(seq 1 60); do
	curl -s -o /dev/null "http://127.0.0.1:$CDP/json/version" && break
	sleep 0.5
done
curl -s -o /dev/null "http://127.0.0.1:$CDP/json/version" || fail "chrome did not expose CDP"

export CHROME_DEVTOOLS_AXI_BROWSER_URL="http://127.0.0.1:$CDP"
export CHROME_DEVTOOLS_AXI_SESSION="fm-wall-live-$$"
axi() { timeout 120 chrome-devtools-axi "$@" 2>/dev/null; }

axi open "http://127.0.0.1:$PORT/wall/?interval=2" >/dev/null || fail "could not open the wall"
sleep 4

# Arm the counter, then switch the tile live. The click itself is the one
# iframe creation the whole run is allowed.
armed=$(axi eval '(()=>{window.__ifr=0;window.__t0=performance.getEntriesByType("resource").filter(r=>r.name.includes("/wall/api/view")).length;new MutationObserver(ms=>{for(const m of ms)for(const n of m.addedNodes)if(n.tagName==="IFRAME")window.__ifr++}).observe(document.body,{subtree:true,childList:true});const b=document.querySelector(".tile[data-name=\"wallprobe\"] .golive");if(!b)return "no-tile";b.click();return "armed"})()')
case "$armed" in
*armed*) ;;
*) fail "could not arm the guard: $armed" ;;
esac

# At least three ticks at the 2s floor, sampling the RFB port throughout.
for _ in $(seq 1 12); do
	ss -tnH state established "( sport = :$RFB_PORT )" 2>/dev/null | awk '{print $4}'
	sleep 1
done | sort -u >"$LAB/conns"
connections=$(grep -c . "$LAB/conns" || true)

# The tool prints the JSON inside an escaped string; drop the escaping once and
# read the three numbers out of it.
result=$(axi eval '(()=>JSON.stringify({ticks:performance.getEntriesByType("resource").filter(r=>r.name.includes("/wall/api/view")).length-window.__t0,iframes:window.__ifr,live:document.querySelectorAll(".shot iframe").length}))()' | tr -d '\134')
field() { printf '%s' "$result" | grep -o "\"$1\":[0-9]*" | grep -o '[0-9]*$'; }
ticks=$(field ticks)
iframes=$(field iframes)
live=$(field live)

[ "${ticks:-0}" -ge 3 ] || fail "guard needs at least 3 refresh ticks, saw ${ticks:-0}"
[ "${iframes:-0}" = 1 ] || fail "expected exactly 1 iframe creation across $ticks ticks, got ${iframes:-0}"
[ "${live:-0}" = 1 ] || fail "the live tile lost its panel across $ticks ticks"
[ "${connections:-0}" = 1 ] || fail "expected exactly 1 RFB connection over the window, got ${connections:-0}"
pass "a live tile keeps one iframe and one RFB connection across $ticks refresh ticks"
