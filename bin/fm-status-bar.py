#!/usr/bin/env python3
"""Live status bar for every agent: one row per state/*.meta, refreshed every 5s.

Reads state/<id>.status (last line) and state/<id>.meta; serves plain HTML on
every interface (0.0.0.0) with no token, so bind it only where the host firewall
already limits reach. Read-only.
"""
import html, os, re, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

FM_HOME = os.environ.get("FM_HOME", os.path.expanduser("~/Dev/firstmate"))
STATE = os.path.join(FM_HOME, "state")
PORT = int(os.environ.get("FM_STATUS_BAR_PORT", "6091"))
WORDS = {"done": "#3fb950", "working": "#58a6ff", "needs-decision": "#d29922", "blocked": "#f85149",
         "resolved": "#8b949e", "parked": "#d29922", "stale": "#f85149"}

def rows():
    out = []
    for f in sorted(os.listdir(STATE)):
        if not f.endswith(".meta"):
            continue
        tid = f[:-5]
        sp = os.path.join(STATE, tid + ".status")
        last, age = "", None
        if os.path.exists(sp):
            lines = [l for l in open(sp, errors="replace").read().splitlines() if l.strip()]
            last = lines[-1] if lines else ""
            age = int(time.time() - os.path.getmtime(sp))
        word = re.match(r"\s*(?:\[[^\]]*\]\s*)?([a-z-]+)", last)
        word = word.group(1) if word else "?"
        out.append((tid, word, age, last))
    return out

def fmt_age(a):
    if a is None: return "-"
    return f"{a}s" if a < 60 else f"{a//60}m" if a < 3600 else f"{a//3600}h{(a%3600)//60:02d}"

def page():
    cards = []
    for tid, word, age, last in rows():
        c = WORDS.get(word, "#c9d1d9")
        stale = age is not None and age > 1800 and word not in ("done", "resolved")
        short = re.sub(r"^\s*(\[[^\]]*\]\s*)?[a-z-]+\s*(\[key=[^\]]*\])?\s*(corr=\S+)?:?\s*", "", last)
        cards.append(
            f"<div class=card style='border-left-color:{c}'>"
            f"<div class=top><span class=id>{html.escape(tid)}</span>"
            f"<span class=state style='color:{c}'>{html.escape(word)}</span>"
            f"<span class='age{' warn' if stale else ''}'>{fmt_age(age)}</span></div>"
            f"<div class=last>{html.escape(short[:260])}</div></div>")
    return f"""<!doctype html><html><head><meta charset=utf-8><meta http-equiv=refresh content=5>
<meta name=viewport content="width=device-width,initial-scale=1"><title>fleet</title><style>
*{{box-sizing:border-box}}body{{background:#0d1117;color:#c9d1d9;font:16px/1.4 -apple-system,system-ui,sans-serif;margin:0;padding:10px 12px calc(10px + env(safe-area-inset-bottom))}}
h1{{font-size:13px;color:#8b949e;font-weight:500;margin:0 0 10px;letter-spacing:.02em}}
.card{{background:#161b22;border:1px solid #21262d;border-left:4px solid;border-radius:8px;padding:10px 12px;margin-bottom:8px}}
.top{{display:flex;align-items:baseline;gap:8px;flex-wrap:wrap}}
.id{{font:600 16px/1.3 ui-monospace,monospace;color:#e6edf3;flex:1;min-width:0;overflow-wrap:anywhere}}
.state{{font-weight:600;font-size:14px}}.age{{color:#8b949e;font-size:13px;font-variant-numeric:tabular-nums}}.warn{{color:#f85149;font-weight:600}}
.last{{color:#b1bac4;font-size:15px;margin-top:6px;overflow-wrap:anywhere;display:-webkit-box;-webkit-line-clamp:3;-webkit-box-orient:vertical;overflow:hidden}}
@media(min-width:900px){{body{{max-width:1100px;margin:auto}}.wrap{{display:grid;grid-template-columns:1fr 1fr;gap:8px}}.card{{margin:0}}}}
</style></head><body><h1>fleet · {len(cards)} agents · {time.strftime('%H:%M:%S')} · live</h1><div class=wrap>{''.join(cards)}</div></body></html>"""

class H(BaseHTTPRequestHandler):
    def do_GET(self):
        b = page().encode()
        self.send_response(200); self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def log_message(self, *a): pass

if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", PORT), H).serve_forever()
