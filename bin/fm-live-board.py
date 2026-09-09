#!/usr/bin/env python3
"""Live fleet view: what every agent is doing right now, rendered on each request.

Read-only, and it reads nothing itself: bin/fm_fleet_read.py is the one fleet
read layer, shared with the terminal screen in bin/fm-fleet-tui.py, so the two
surfaces cannot disagree about what the fleet is. Homes are discovered from the
fleet's own records - the registry and the pool's home markers - so a new or
renamed home appears here without editing this file.

Nothing is cached and nothing is invented: a field that cannot be read says so,
and each task's last status line is shown as the wake EVENT it is, never as
current state.

  python3 bin/fm-live-board.py [port]        # default 8899, binds 0.0.0.0
"""

import html
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
# Imported after the path above, so the read layer resolves from bin/ however
# this script was invoked.
import fm_fleet_read
from fm_fleet_read import age, count

REFRESH_SECONDS = 15


def dot(task):
    if task["endpoint"] == "alive":
        return "go" if task["busy"] == "busy" else "wait"
    return "bad" if task["endpoint"] == "dead" else "wait"


def render(fleet):
    now = time.strftime("%H:%M:%S")
    counts = fleet["counts"]
    parts = [
        f"""<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="refresh" content="{REFRESH_SECONDS}">
<title>Fleet - live</title><style>
:root{{--bg:#0f1117;--panel:#161923;--line:#262b3a;--ink:#e8eaf0;--dim:#9aa3b8;--faint:#6b7488;
--go:#4ade80;--wait:#fbbf24;--bad:#f87171;--done:#60a5fa}}
*{{box-sizing:border-box}}body{{margin:0;background:var(--bg);color:var(--ink);
font:15px/1.5 ui-sans-serif,-apple-system,"Segoe UI",Roboto,sans-serif}}
header{{padding:20px 28px;border-bottom:1px solid var(--line);display:flex;
justify-content:space-between;align-items:baseline;gap:20px;flex-wrap:wrap}}
h1{{margin:0;font-size:19px;letter-spacing:-.01em}}
.meta{{color:var(--faint);font-size:12.5px}}
main{{padding:20px 28px 60px;max-width:1200px}}
.mate{{background:var(--panel);border:1px solid var(--line);border-radius:11px;
margin-bottom:14px;overflow:hidden}}
.mhead{{display:flex;align-items:center;gap:11px;padding:13px 16px;border-bottom:1px solid var(--line)}}
.mhead b{{font-size:15px}}
.dot{{width:9px;height:9px;border-radius:50%;flex:0 0 auto}}
.dot.go{{background:var(--go);box-shadow:0 0 9px var(--go)}}
.dot.wait{{background:var(--wait)}}.dot.bad{{background:var(--bad)}}.dot.done{{background:var(--done)}}
.state{{color:var(--dim);font-size:12.5px;margin-left:auto;text-align:right;min-width:0;
overflow-wrap:anywhere}}
.say{{padding:9px 16px;color:var(--dim);font-size:13px;border-bottom:1px solid var(--line);
overflow-wrap:anywhere}}
.say .v{{color:var(--faint);text-transform:uppercase;font-size:10.5px;letter-spacing:.08em;
margin-right:7px}}
.w{{display:flex;gap:11px;align-items:flex-start;padding:11px 16px 11px 30px;
border-top:1px solid #1e2230}}
.w .body{{min-width:0;flex:1}}
.w .name{{font-size:13.5px;font-weight:600}}
.w .note{{color:var(--faint);font-size:12.5px;margin-top:3px;overflow-wrap:anywhere}}
.tag{{font-size:10.5px;color:var(--faint);border:1px solid var(--line);border-radius:20px;
padding:1px 7px;margin-left:6px}}
.empty{{padding:12px 16px;color:var(--faint);font-size:13px}}
a{{color:var(--done)}}
</style></head><body>
<header><h1>Fleet - live</h1>
<div class="meta">{counts["tasks_busy"]} of {counts["tasks"]} workers mid-turn ·
{counts["homes"]} homes · {counts["holds"]} held tasks ·
read in {fleet["elapsed_ms"]}ms · refreshes every {REFRESH_SECONDS}s · {now}</div>
</header><main>"""
    ]

    for home in fleet["homes"]:
        sup = home["supervision"]
        backlog = home["backlog"]
        holds = [hold["id"] for hold in home["holds"] if hold["hold_kind"] == "captain"]
        head_dot = "bad" if home.get("error") else "go" if home["tasks"] else "wait"
        parts.append(
            f'<div class="mate"><div class="mhead"><span class="dot {head_dot}"></span>'
            f"<b>{html.escape(home['label'])}</b>"
            f'<span class="tag">{html.escape(home["source"])}</span>'
            f'<span class="state">wakes {count(sup["wake_depth"])}'
            f" · beat {age(sup['beat_age'])} · {html.escape(sup['lock'] or 'lock unread')}"
            f" · backlog {count(backlog['in_flight'])}/{count(backlog['queued'])}/{count(backlog['held'])}"
            f" in-flight/queued/held</span></div>"
        )
        if home.get("error"):
            parts.append(f'<div class="empty">{html.escape(home["error"])}</div>')
        if holds:
            parts.append(
                '<div class="say"><span class="v">captain holds</span>'
                f"{html.escape(', '.join(holds))}</div>"
            )
        if not home["tasks"] and not home.get("error"):
            parts.append('<div class="empty">No work under way here.</div>')

        for task in sorted(home["tasks"], key=lambda t: t["id"]):
            pr = f' <a href="{html.escape(task["pr"])}">PR</a>' if task["pr"] else ""
            tags = "".join(
                f'<span class="tag">{html.escape(value)}</span>'
                for value in (
                    task["kind"],
                    task["mode"],
                    task["harness"],
                    task["backend"],
                )
                if value
            )
            event = task["last_event"]
            if event:
                note = (
                    f'<span class="v">event {age(event["age_secs"])} ago</span>'
                    f"{html.escape(event['verb'] or '')}: {html.escape((event['note'] or '')[:300])}"
                )
            else:
                note = '<span class="v">event</span>nothing said yet'
            parts.append(
                f'<div class="w"><span class="dot {dot(task)}" style="margin-top:5px"></span>'
                f'<div class="body"><div class="name">{html.escape(task["id"])}'
                f'<span class="tag">{html.escape(task["endpoint"] or "endpoint unread")}</span>'
                f'<span class="tag">{html.escape(task["busy"] or "busy unread")}</span>'
                f"{tags}{pr}</div>"
                f'<div class="note">{note}</div></div></div>'
            )
        parts.append("</div>")

    parts.append("</main></body></html>")
    return "".join(parts)


class Handler(BaseHTTPRequestHandler):
    # The page carries live fleet activity, so the listener is public only behind
    # an unguessable path token. Every other path is a flat 404 that reveals
    # nothing about what is served here, and the refresh meta keeps the token in
    # the URL so the browser re-authenticates itself on every reload.
    token = ""

    def do_GET(self):
        want = f"/{self.token}"
        if self.path.split("?", 1)[0].rstrip("/") != want.rstrip("/"):
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        body = render(fm_fleet_read.read_fleet()).encode("utf8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Referrer-Policy", "no-referrer")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_a):
        pass


if __name__ == "__main__":
    import os
    import secrets

    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8899
    Handler.token = os.environ.get("FM_BOARD_TOKEN") or secrets.token_urlsafe(18)
    print(f"http://15.204.113.4:{port}/{Handler.token}", flush=True)
    HTTPServer(("0.0.0.0", port), Handler).serve_forever()
