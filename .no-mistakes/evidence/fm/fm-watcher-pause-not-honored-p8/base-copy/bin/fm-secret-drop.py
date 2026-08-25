#!/usr/bin/env python3
"""One-time secret receiver: accept exactly one file, then stop listening.

Built for handing a credential from the captain's laptop to this box without it
passing through chat, a transcript, or an agent's context. It accepts a single
POST on an unguessable path, writes the body to a mode-0600 file, prints only a
fingerprint, and exits. Everything else - wrong path, second attempt, GET - is a
flat 404 that reveals nothing.

  python3 bin/fm-secret-drop.py <out-path> [port]

Prints the exact upload URL and the curl command to run on the sending machine.
"""
import hashlib
import os
import secrets
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

HOST_IP = "15.204.113.4"
MAX_BYTES = 1 << 20  # a key, never a payload


class Drop(BaseHTTPRequestHandler):
    token = ""
    out_path = ""
    received = False

    def _404(self):
        self.send_response(404)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_POST(self):
        if Drop.received or self.path.split("?", 1)[0] != f"/{Drop.token}":
            self._404()
            return
        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0 or length > MAX_BYTES:
            self._404()
            return
        body = self.rfile.read(length)
        # Write private-by-construction: create with 0600 rather than chmod after,
        # so the secret is never briefly world-readable on disk.
        fd = os.open(Drop.out_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "wb") as fh:
            fh.write(body)
        Drop.received = True
        digest = hashlib.sha256(body).hexdigest()[:16]
        self.send_response(200)
        msg = b"received\n"
        self.send_header("Content-Length", str(len(msg)))
        self.end_headers()
        self.wfile.write(msg)
        print(f"RECEIVED {len(body)} bytes -> {Drop.out_path} sha256:{digest}", flush=True)

    def do_GET(self):
        self._404()

    def log_message(self, *_a):
        pass


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        raise SystemExit(2)
    Drop.out_path = os.path.abspath(sys.argv[1])
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 8901
    Drop.token = os.environ.get("FM_DROP_TOKEN") or secrets.token_urlsafe(24)
    url = f"http://{HOST_IP}:{port}/{Drop.token}"
    print(f"UPLOAD_URL {url}", flush=True)
    print(f"SEND_WITH  curl -sS --data-binary @<file> {url}", flush=True)
    server = HTTPServer(("0.0.0.0", port), Drop)
    while not Drop.received:
        server.handle_request()
    print("closed after one delivery", flush=True)
