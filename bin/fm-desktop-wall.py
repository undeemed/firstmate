#!/usr/bin/env python3
"""fm-desktop-wall - one listener and one snapshot loop for every VNC desktop.

Design, cost model and rationale: docs/desktop-wall.md.

ENDPOINTS (all on the single listener)
  /wall/                    the wall page
  /wall/api/state           registry + liveness + snapshot age + last status line
  /wall/api/view    POST    {"visible":[name,...],"interval":n} viewer heartbeat
  /wall/snap/<name>.webp    latest snapshot
  /vnc.html?path=websockify?token=<name>
                            live noVNC for one desktop, token-routed
  everything else           noVNC's own static files

USAGE
  fm-desktop-wall.py [--registry <path>] [--snapshot-dir <path>] [--port 6090]
                     [--listen <ip>] [--cert <p> --key <p>] [--web-root <dir>]
                     [--interval 5] [--min-interval 2] [--viewer-ttl 15]
                     [--workers 4]

  The registry is the only source of desktops: no display number or port is
  written down here. bin/fm-desktop.sh owns that file and its schema.
"""

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

try:
    from websockify.token_plugins import BasePlugin
    from websockify.websocketproxy import ProxyRequestHandler
except ImportError:  # the registry and gating helpers stay importable without it
    BasePlugin = ProxyRequestHandler = object

NAME_RE = re.compile(r"^[a-z0-9][a-z0-9-]*$")
HERE = Path(__file__).resolve().parent
WALL_PAGE = HERE / "fm-desktop-wall.html"
X_SOCKET_DIR = Path(os.environ.get("FM_DESKTOP_X_SOCKET_DIR", "/tmp/.X11-unix"))
STATUS_TAIL_BYTES = 4096
CAPTURE_TIMEOUT = 20.0
TICK_SECONDS = 1.0
SNAPSHOT_WIDTH = 480
SNAPSHOT_QUALITY = 70


def load_registry(path):
    """[{name, display, rfb_port, ...}] - empty when the registry is unreadable."""
    try:
        with open(path) as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return []
    out = [
        entry
        for entry in data.get("desktops", [])
        if NAME_RE.match(entry.get("name", ""))
        and isinstance(entry.get("display"), int)
    ]
    return sorted(out, key=lambda d: d["display"])


class RegistryTokens(BasePlugin):
    """websockify token routing straight off the registry: token = desktop name.

    Looked up per connection in the serving child, so a desktop created after
    startup is routable with no restart and no derived token file.
    """

    def __init__(self, src):
        self.source = src

    def lookup(self, token):
        for desktop in load_registry(self.source):
            if desktop["name"] == token:
                return ("127.0.0.1", desktop.get("rfb_port", 5900 + desktop["display"]))
        return None


def display_up(display):
    return (X_SOCKET_DIR / ("X%d" % display)).exists()


def snapshot_meta(opts, name):
    try:
        return json.loads((Path(opts.snapshot_dir) / ("%s.json" % name)).read_text())
    except (OSError, ValueError):
        return {}


def viewer_file(opts, name):
    return Path(opts.snapshot_dir) / "viewers" / name


def viewer_interval(opts, name, now=None):
    """Interval a viewer is asking for, or None when nobody is watching.

    This is the whole cost model: no viewer, no capture. The floor is applied
    here too, so a stale or hand-written viewer file cannot drive the box faster
    than the server allows.
    """
    path = viewer_file(opts, name)
    try:
        stat = path.stat()
        raw = path.read_text().strip()
    except OSError:
        return None
    if (now or time.time()) - stat.st_mtime > opts.viewer_ttl:
        return None
    try:
        return max(opts.min_interval, float(raw))
    except ValueError:
        return opts.interval


def last_status_line(path):
    if not path:
        return ""
    try:
        with open(path, "rb") as fh:
            fh.seek(0, os.SEEK_END)
            fh.seek(max(0, fh.tell() - STATUS_TAIL_BYTES))
            body = fh.read().decode("utf-8", "replace")
    except OSError:
        return ""
    lines = [line for line in body.splitlines() if line.strip()]
    return lines[-1][:200] if lines else ""


def wall_state(opts):
    now = time.time()
    tiles = []
    for desktop in load_registry(opts.registry):
        meta = snapshot_meta(opts, desktop["name"])
        tiles.append(
            {
                "name": desktop["name"],
                "label": desktop.get("label") or desktop["name"],
                "display": desktop["display"],
                "group": desktop.get("group") or "ungrouped",
                "owner": desktop.get("owner", ""),
                "project": desktop.get("project", ""),
                "up": display_up(desktop["display"]),
                "status": last_status_line(desktop.get("status_file", "")),
                "captured_ago": round(now - meta["captured"], 1)
                if meta.get("captured")
                else None,
                "changed_ago": round(now - meta["changed"], 1)
                if meta.get("changed")
                else None,
                "error": meta.get("error", ""),
            }
        )
    return {"server_time": now, "tiles": tiles}


class Snapshots:
    """Capture loop. Parent process only: it owns the pool and the in-flight set."""

    def __init__(self, opts):
        self.opts = opts
        self.dir = Path(opts.snapshot_dir)
        (self.dir / "viewers").mkdir(parents=True, exist_ok=True)
        self.pool = ThreadPoolExecutor(max_workers=opts.workers)
        self.in_flight = set()
        self.lock = threading.Lock()

    def capture(self, name, display):
        tmp = self.dir / ("%s.tmp.webp" % name)
        # x11grab reads the root window and auto-detects geometry, so a resized
        # desktop needs no registry change and no second process per capture.
        cmd = [
            "ffmpeg", "-loglevel", "error", "-nostdin",
            "-f", "x11grab", "-draw_mouse", "0", "-i", ":%d" % display,
            "-frames:v", "1", "-vf", "scale=%d:-1" % SNAPSHOT_WIDTH,
            "-q:v", str(SNAPSHOT_QUALITY), "-y", str(tmp),
        ]  # fmt: skip
        meta = snapshot_meta(self.opts, name)
        try:
            subprocess.run(
                cmd, capture_output=True, timeout=CAPTURE_TIMEOUT, check=True
            )
            body = tmp.read_bytes()
            digest = hashlib.sha256(body).hexdigest()
            os.replace(tmp, self.dir / ("%s.webp" % name))
            now = time.time()
            meta = {
                "captured": now,
                "changed": now
                if digest != meta.get("sha")
                else meta.get("changed", now),
                "sha": digest,
                "error": "",
            }
        except (subprocess.SubprocessError, OSError) as exc:
            meta = dict(meta)
            meta["captured"] = time.time()
            meta["error"] = str(exc)[:200]
        tmp.unlink(missing_ok=True)
        (self.dir / ("%s.json" % name)).write_text(json.dumps(meta))
        with self.lock:
            self.in_flight.discard(name)

    def due(self, desktop, now):
        interval = viewer_interval(self.opts, desktop["name"], now)
        if interval is None or not display_up(desktop["display"]):
            return False
        return (
            now - snapshot_meta(self.opts, desktop["name"]).get("captured", 0)
            >= interval
        )

    def run_forever(self):
        while True:
            now = time.time()
            for desktop in load_registry(self.opts.registry):
                name = desktop["name"]
                with self.lock:
                    if name in self.in_flight or not self.due(desktop, now):
                        continue
                    self.in_flight.add(name)
                self.pool.submit(self.capture, name, desktop["display"])
            time.sleep(TICK_SECONDS)


class WallHandler(ProxyRequestHandler):
    """noVNC proxy plus the wall's own routes. One per connection, in a child."""

    @property
    def opts(self):
        return self.server.wall_opts

    def _known(self):
        return {d["name"] for d in load_registry(self.opts.registry)}

    def _send(self, body, content_type):
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _send_file(self, path, content_type):
        try:
            body = Path(path).read_bytes()
        except OSError:
            self.send_error(404)
            return
        self._send(body, content_type)

    def do_GET(self):
        route = self.path.split("?", 1)[0]
        if route in ("/wall", "/wall/", "/wall/index.html"):
            self._send_file(WALL_PAGE, "text/html; charset=utf-8")
        elif route == "/wall/api/state":
            self._send(json.dumps(wall_state(self.opts)).encode(), "application/json")
        elif route.startswith("/wall/snap/"):
            name = route[len("/wall/snap/") :].removesuffix(".webp")
            if name in self._known():
                self._send_file(
                    Path(self.opts.snapshot_dir) / ("%s.webp" % name), "image/webp"
                )
            else:
                self.send_error(404)
        else:
            super().do_GET()

    def do_POST(self):
        if self.path.split("?", 1)[0] != "/wall/api/view":
            self.send_error(405)
            return
        try:
            length = min(int(self.headers.get("Content-Length", "0")), 65536)
            payload = json.loads(self.rfile.read(length) or b"{}")
            requested = float(payload.get("interval", self.opts.interval))
            visible = list(payload.get("visible", []))[:512]
        except (ValueError, TypeError):
            self.send_error(400)
            return
        # The floor lives here, not in the page: a client cannot ask this box for
        # a 100ms capture loop.
        interval = max(self.opts.min_interval, requested)
        known = self._known()
        for name in visible:
            if name in known:
                viewer_file(self.opts, name).write_text(str(interval))
        self._send(
            json.dumps(
                {"interval": interval, "min_interval": self.opts.min_interval}
            ).encode(),
            "application/json",
        )


def parse_args(argv):
    fm_home = Path(os.environ.get("FM_HOME", HERE.parent))
    p = argparse.ArgumentParser(description="single-listener VNC desktop wall")
    p.add_argument("--registry", default=str(fm_home / "state" / "desktops.json"))
    p.add_argument("--snapshot-dir", default=str(fm_home / "state" / "desktop-wall"))
    p.add_argument("--listen", default="127.0.0.1")
    p.add_argument("--port", type=int, default=6090)
    p.add_argument("--cert", default="")
    p.add_argument("--key", default="")
    p.add_argument("--web-root", default="/usr/share/novnc")
    p.add_argument("--interval", type=float, default=5.0, help="default interval")
    p.add_argument("--min-interval", type=float, default=2.0, help="server-side floor")
    p.add_argument("--viewer-ttl", type=float, default=15.0)
    p.add_argument("--workers", type=int, default=4)
    return p.parse_args(argv)


def main(argv=None):
    if ProxyRequestHandler is object:
        sys.exit("fm-desktop-wall: python3 websockify is required to serve")
    from websockify.websocketproxy import WebSocketProxy

    opts = parse_args(argv)
    snaps = Snapshots(opts)
    threading.Thread(target=snaps.run_forever, daemon=True).start()

    server = WebSocketProxy(
        RequestHandlerClass=WallHandler,
        listen_host=opts.listen,
        listen_port=opts.port,
        cert=opts.cert,
        key=opts.key,
        ssl_only=bool(opts.cert),
        web=opts.web_root,
        file_only=True,
        token_plugin=RegistryTokens(opts.registry),
    )
    server.wall_opts = opts
    server.start_server()


if __name__ == "__main__":
    sys.exit(main())
