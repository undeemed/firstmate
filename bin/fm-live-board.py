#!/usr/bin/env python3
"""Live fleet view: what every agent is doing right now, rendered on each request.

Read-only. It shells out to the same sources firstmate itself trusts - herdr's
pane list for liveness, each home's state/<id>.meta for identity, and the tail of
state/<id>.status for the last thing that worker actually said - and renders them
as one page. Nothing is cached and nothing is invented: a field that cannot be
read says so.

  python3 bin/fm-live-board.py [port]        # default 8899, binds 0.0.0.0
"""
import html
import json
import subprocess
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

MAIN = Path("/home/ubuntu/Dev/firstmate")
HOMES = {
    "dorm": Path("/home/ubuntu/.treehouse/firstmate-4e604a/1/firstmate"),
    "swarm": Path("/home/ubuntu/.treehouse/firstmate-4e604a/2/firstmate"),
    "tetanus": Path("/home/ubuntu/.treehouse/firstmate-4e604a/3/firstmate"),
    "aa-demo": Path("/home/ubuntu/.treehouse/firstmate-4e604a/4/firstmate"),
}
REFRESH_SECONDS = 15


def run(cmd, timeout=10):
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return out.stdout
    except Exception:
        return ""


def panes():
    """pane_id -> (agent, status). Empty dict when herdr cannot be read."""
    raw = run(["herdr", "pane", "list"])
    try:
        rows = json.loads(raw)["result"]["panes"]
    except Exception:
        return {}
    return {r["pane_id"]: (r.get("agent") or "none", r.get("agent_status") or "unknown") for r in rows}


def meta_fields(path):
    fields = {}
    try:
        for line in path.read_text(errors="replace").split():
            if "=" in line:
                k, _, v = line.partition("=")
                fields[k] = v
    except Exception:
        pass
    return fields


def last_status(home, task):
    f = home / "state" / f"{task}.status"
    try:
        lines = [ln for ln in f.read_text(errors="replace").splitlines() if ln.strip()]
    except Exception:
        return None, None
    if not lines:
        return None, None
    line = lines[-1]
    verb, _, rest = line.partition(":")
    return verb.strip(), rest.strip()


def collect():
    live = panes()
    fleet = []
    for label, home in HOMES.items():
        mate_id = {"dorm": "dorm-mate-d9", "swarm": "swarm-mate-s6",
                   "tetanus": "tetanus-mate-t1", "aa-demo": "aa-demo-mate-a1"}[label]
        mate_meta = meta_fields(MAIN / "state" / f"{mate_id}.meta")
        pane = mate_meta.get("window", "").replace("default:", "")
        agent, status = live.get(pane, ("none", "no pane"))
        verb, note = last_status(MAIN, mate_id)
        workers = []
        state_dir = home / "state"
        if state_dir.is_dir():
            for m in sorted(state_dir.glob("*.meta")):
                task = m.stem
                wf = meta_fields(m)
                wpane = wf.get("window", "").replace("default:", "")
                wagent, wstatus = live.get(wpane, ("none", "no pane"))
                wverb, wnote = last_status(home, task)
                workers.append({
                    "task": task, "pane": wpane or "-", "agent": wagent, "status": wstatus,
                    "verb": wverb, "note": wnote, "project": wf.get("project", ""),
                    "mode": wf.get("mode", ""), "pr": wf.get("pr", ""),
                })
        fleet.append({
            "label": label, "id": mate_id, "pane": pane or "-", "agent": agent,
            "status": status, "verb": verb, "note": note, "workers": workers,
            "home_readable": state_dir.is_dir(),
        })
    return fleet


def dot(status):
    return {"working": "go", "busy": "go", "idle": "wait", "done": "done",
            "unknown": "bad", "no pane": "bad"}.get(status, "wait")


def render(fleet):
    now = time.strftime("%H:%M:%S")
    live_workers = sum(1 for m in fleet for w in m["workers"] if w["status"] in ("working", "busy"))
    total_workers = sum(len(m["workers"]) for m in fleet)
    parts = [f"""<!doctype html><html><head><meta charset="utf-8">
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
<div class="meta">{live_workers} of {total_workers} workers busy · refreshes every {REFRESH_SECONDS}s · {now}</div>
</header><main>"""]

    for m in fleet:
        parts.append(f'<div class="mate"><div class="mhead"><span class="dot {dot(m["status"])}"></span>'
                     f'<b>{html.escape(m["label"])}</b>'
                     f'<span class="tag">{html.escape(m["agent"])}</span>'
                     f'<span class="state">{html.escape(m["status"])} · {html.escape(m["pane"])}</span></div>')
        if m["verb"]:
            parts.append(f'<div class="say"><span class="v">{html.escape(m["verb"])}</span>'
                         f'{html.escape((m["note"] or "")[:400])}</div>')
        if not m["home_readable"]:
            parts.append('<div class="empty">Its own records cannot be read from here.</div>')
        elif not m["workers"]:
            parts.append('<div class="empty">No workers running.</div>')
        for w in m["workers"]:
            pr = (f' <a href="{html.escape(w["pr"])}">PR</a>' if w["pr"].startswith("http") else "")
            note = html.escape((w["note"] or "")[:300]) if w["note"] else "no word yet"
            verb = f'<span class="v">{html.escape(w["verb"])}</span>' if w["verb"] else ""
            mode = f'<span class="tag">{html.escape(w["mode"])}</span>' if w["mode"] else ""
            parts.append(f'<div class="w"><span class="dot {dot(w["status"])}" style="margin-top:5px"></span>'
                         f'<div class="body"><div class="name">{html.escape(w["task"])}'
                         f'<span class="tag">{html.escape(w["status"])}</span>'
                         f'{mode}{pr}</div>'
                         f'<div class="note">{verb}{note}</div></div></div>')
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
        body = render(collect()).encode("utf8")
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
