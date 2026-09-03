#!/usr/bin/env bash
# Behavior tests for bin/fm-lavish-lib.sh: the allowlist a Lavish server is
# started with is derived from this machine at call time, and a server that
# rejects that identity is cleared out of the way without narrowing its bind,
# dropping a host it was serving, or touching a stranger on the port.
#
# The server under test is a real HTTP listener that answers /health exactly as
# Lavish does - 200 with its app marker for a Host it was started with, 403
# "forbidden host" for anything else - and exits on POST /shutdown unless told
# to stay. Tailscale and hostname are PATH stubs, so the derived identity and
# the probe candidates are fixtures rather than this machine's.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIB="$ROOT/bin/fm-lavish-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-lavish-server)

command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }
command -v lsof >/dev/null 2>&1 || { echo "skip: lsof not found"; exit 0; }
command -v curl >/dev/null 2>&1 || { echo "skip: curl not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

TAILNET_NAME=fixture-host.example.ts.net
TAILNET_IP=100.64.0.9
MACHINE_IP=198.51.100.7

FAKEBIN=$(fm_fakebin "$TMP_ROOT")
cat > "$FAKEBIN/tailscale" <<SH
#!/usr/bin/env bash
# Stands in for this machine's tailnet identity, MagicDNS name with the trailing
# dot the real \`tailscale status --json\` prints.
printf '{"Self":{"DNSName":"$TAILNET_NAME.","TailscaleIPs":["$TAILNET_IP"]}}\n'
SH
chmod +x "$FAKEBIN/tailscale"

cat > "$FAKEBIN/hostname" <<SH
#!/usr/bin/env bash
# Stands in for this machine's interface addresses and FQDN, so the probe
# candidates are fixtures rather than this box's real identity.
case "\${1-}" in
  -I) printf '%s\n' "$MACHINE_IP $TAILNET_IP" ;;
  -f) printf 'fixture-host.internal\n' ;;
  *) printf 'fixture-host\n' ;;
esac
SH
chmod +x "$FAKEBIN/hostname"

SERVER="$TMP_ROOT/fixture-server.py"
cat > "$SERVER" <<'PY'
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

bind, port, allowed, app = sys.argv[1], int(sys.argv[2]), sys.argv[3].split(","), sys.argv[4]
stay = len(sys.argv) > 5


class Handler(BaseHTTPRequestHandler):
    def _hostname(self):
        return self.headers.get("Host", "").split(":", 1)[0]

    def _send(self, code, body):
        payload = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        if self._hostname() not in allowed:
            self._send(403, '{"error":"forbidden host"}')
            return
        self._send(200, '{"ok":true,"app":"%s","version":"test"}' % app)

    def do_POST(self):
        if self.path == "/shutdown" and self._hostname() in allowed:
            self._send(200, '{"ok":true}')
            if not stay:
                raise SystemExit(0)
            return
        self._send(403, '{"error":"forbidden host"}')

    def log_message(self, *args):
        pass


HTTPServer((bind, port), Handler).serve_forever()
PY

free_port() {
  python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()'
}

SERVER_PIDS=()
start_server() {  # <bind> <port> <allowed-csv> <app> [stay]
  python3 "$SERVER" "$@" &
  SERVER_PIDS+=("$!")
  local deadline=$((SECONDS + 10))
  while [ "$SECONDS" -lt "$deadline" ]; do
    curl -sS -m 2 -o /dev/null "http://127.0.0.1:$2/health" 2>/dev/null && return 0
    sleep 0.1
  done
  fail "the fixture server on port $2 never came up"
}

lavish_teardown() {
  local pid
  for pid in ${SERVER_PIDS[@]+"${SERVER_PIDS[@]}"}; do
    kill "$pid" 2>/dev/null || true
  done
  fm_test_cleanup
}
trap lavish_teardown EXIT INT TERM

alive() {  # <pid>
  kill -0 "$1" 2>/dev/null
}

wait_gone() {  # <pid> <failure message>
  local deadline=$((SECONDS + 10))
  while alive "$1" && [ "$SECONDS" -lt "$deadline" ]; do sleep 0.1; done
  alive "$1" && fail "$2"
  return 0
}

STDERR_FILE="$TMP_ROOT/prepare-stderr"

prepare() {  # <env assignments...> -> RC=, ALLOWED=, HOST= and LINK= lines
  # shellcheck disable=SC2016 # The reporting body runs in the child shell, after the lib is sourced there.
  # Every Lavish variable is cleared first: the host runner may carry the very
  # stale values this library exists to repair. The child runs under set -eu
  # exactly like the strictest wired caller (bin/fm-bearings-board.sh), so a
  # nonzero repair status kills it before the RC= line is printed.
  env -u LAVISH_AXI_ALLOWED_HOSTS -u LAVISH_AXI_HOST -u LAVISH_AXI_LINK_HOST -u LAVISH_AXI_PORT \
    PATH="$FAKEBIN:$PATH" "$@" bash -c '
    set -eu
    . "$1"
    fm_lavish_prepare_server >/dev/null 2>"$2"
    printf "RC=%s\n" "$?"
    printf "ALLOWED=%s\n" "${LAVISH_AXI_ALLOWED_HOSTS-}"
    printf "HOST=%s\n" "${LAVISH_AXI_HOST-unset}"
    printf "LINK=%s\n" "${LAVISH_AXI_LINK_HOST-unset}"
  ' _ "$LIB" "$STDERR_FILE"
}

# --- 1. the identity is merged into an inherited list, with no server running --
PORT=$(free_port)
out=$(prepare LAVISH_AXI_PORT="$PORT" LAVISH_AXI_ALLOWED_HOSTS="15.204.113.4 127.0.0.1 localhost")
assert_contains "$out" "ALLOWED=15.204.113.4 127.0.0.1 localhost $TAILNET_NAME $TAILNET_IP" \
  "a stale inherited list is extended with this machine's identity, never replaced"
assert_contains "$out" "HOST=unset" "no running server means no bind is pinned"
pass "the derived identity extends the inherited allowlist"

# --- 2. a server that rejects the identity is cleared out of the way ----------
PORT=$(free_port)
start_server 127.0.0.1 "$PORT" "127.0.0.1,localhost" lavish-axi
STALE_PID=${SERVER_PIDS[-1]}
out=$(prepare LAVISH_AXI_PORT="$PORT" LAVISH_AXI_ALLOWED_HOSTS="15.204.113.4 127.0.0.1 localhost")
assert_contains "$out" "$TAILNET_NAME" "the repaired allowlist carries the identity the server rejected"
wait_gone "$STALE_PID" "a server rejecting this machine's own hostname was left running"
pass "a stale-allowlist server is shut down so the next start carries the repair"

# --- 3. a server that already answers the identity is left alone -------------
PORT=$(free_port)
start_server 127.0.0.1 "$PORT" "127.0.0.1,localhost,$TAILNET_NAME" lavish-axi
GOOD_PID=${SERVER_PIDS[-1]}
prepare LAVISH_AXI_PORT="$PORT" >/dev/null
sleep 0.5
alive "$GOOD_PID" || fail "a correctly configured server was restarted for nothing"
kill "$GOOD_PID" 2>/dev/null || true
pass "a server that already answers the identity keeps serving"

# --- 4. a listener that is not Lavish is never touched -----------------------
PORT=$(free_port)
start_server 127.0.0.1 "$PORT" "127.0.0.1,localhost" other-app
FOREIGN_PID=${SERVER_PIDS[-1]}
prepare LAVISH_AXI_PORT="$PORT" >/dev/null
sleep 0.5
alive "$FOREIGN_PID" || fail "a non-Lavish listener on the port was shut down"
kill "$FOREIGN_PID" 2>/dev/null || true
pass "a stranger on the port is left running"

# --- 5. repairing the allowlist never narrows the bind -----------------------
# The wildcard bind is the case this protects: the running server is reachable
# beyond loopback only because a parent set it, so a restart from a shell that
# never had that value would black out every board this home serves.
PORT=$(free_port)
start_server 0.0.0.0 "$PORT" "127.0.0.1,localhost" lavish-axi
WIDE_PID=${SERVER_PIDS[-1]}
out=$(prepare LAVISH_AXI_PORT="$PORT")
assert_contains "$out" "HOST=0.0.0.0" "the restart lost the reachability the running server had"
wait_gone "$WIDE_PID" "the wildcard-bound stale server was left running"
pass "a restart preserves the bind the running server was reachable on"

# --- 6. an operator's own bind choice wins over the observed one -------------
PORT=$(free_port)
start_server 0.0.0.0 "$PORT" "127.0.0.1,localhost" lavish-axi
OWN_PID=${SERVER_PIDS[-1]}
out=$(prepare LAVISH_AXI_PORT="$PORT" LAVISH_AXI_HOST=127.0.0.1)
assert_contains "$out" "HOST=127.0.0.1" "an explicitly configured bind was overwritten"
wait_gone "$OWN_PID" "the stale server was left running"
pass "an explicit bind is never overwritten by the observed one"

# --- 7. hosts the displaced server serves survive into the replacement -------
# The repairing caller carries no LAVISH_AXI_* value at all, so every host the
# replacement must keep serving is knowable only by asking the running server.
PORT=$(free_port)
start_server 127.0.0.1 "$PORT" "$MACHINE_IP,127.0.0.1,localhost" lavish-axi
STALE_PID=${SERVER_PIDS[-1]}
out=$(prepare LAVISH_AXI_PORT="$PORT")
assert_contains "$out" "$MACHINE_IP" \
  "a host only the displaced server carried was dropped from the replacement allowlist"
assert_contains "$out" "$TAILNET_NAME" "the repaired allowlist lost this machine's identity"
assert_contains "$out" "LINK=$MACHINE_IP" \
  "session links would be minted loopback-only after the repair"
wait_gone "$STALE_PID" "the stale server was left running"
pass "an environment-poor repair keeps every host the displaced server serves"

# --- 8. a shutdown that never completes is reported, not fatal ---------------
PORT=$(free_port)
start_server 127.0.0.1 "$PORT" "127.0.0.1,localhost" lavish-axi stay
STUCK_PID=${SERVER_PIDS[-1]}
out=$(prepare LAVISH_AXI_PORT="$PORT")
assert_contains "$out" "RC=0" "a stuck shutdown must not fail a set -e caller"
assert_contains "$(cat "$STDERR_FILE")" "port $PORT did not shut down" \
  "the shutdown timeout diagnostic does not name the port"
alive "$STUCK_PID" || fail "the stuck fixture died unexpectedly"
kill "$STUCK_PID" 2>/dev/null || true
pass "a stuck shutdown is reported on stderr and the caller continues"
