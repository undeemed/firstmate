#!/usr/bin/env python3
"""Fleet TUI: one always-on terminal screen for every task in flight, fleet-wide.

Read-only. It shows, per task, what stage it is at and the last thing it said,
for every home the fleet has - the main home plus every pool home - refreshed on
a timer. It steers nothing: use bin/fm-control.sh and bin/fm-send.sh for that.

Every fact comes from bin/fm_fleet_read.py, the one fleet read layer, so this
screen and the web board in bin/fm-live-board.py cannot disagree about what the
fleet is. A task's last status line is wake-EVENT history, labelled `EVENT` on
screen, never current truth; bin/fm-crew-state.sh owns current state and costs
seconds per task, which is why it is not on this timer.

  python3 bin/fm-fleet-tui.py                 live screen, 15s refresh
  python3 bin/fm-fleet-tui.py --interval 30   slower refresh
  python3 bin/fm-fleet-tui.py --once          print one frame and exit
  python3 bin/fm-fleet-tui.py --main-home <path>

Keys: q quit - r refresh now - j/k or arrows scroll - g/G top/bottom.

Environment: FM_HOME selects the main home when --main-home is absent, and
FM_FLEET_READ_TIMEOUT bounds each home's read.
"""
from __future__ import annotations

import argparse
import curses
import sys
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
# Imported after the path above, so the read layer resolves from bin/ however
# this script was invoked.
import fm_fleet_read
from fm_fleet_read import age

DEFAULT_INTERVAL = 15
POLL_MS = 200
# Screen roles, each mapped to one curses attribute once colours are known.
PLAIN, HEAD, GOOD, WARN, BAD, DIM = range(6)
ROLES = {role: 0 for role in (PLAIN, HEAD, GOOD, WARN, BAD, DIM)}


def mark(task: dict) -> tuple[str, int]:
    """One task's glyph and colour role, from its endpoint and its harness turn."""
    if task["endpoint"] == "dead":
        return "x", BAD
    if task["endpoint"] != "alive":
        return "?", DIM
    return ("*", GOOD) if task["busy"] == "busy" else ("o", PLAIN)


def fit(text: str, width: int) -> str:
    text = text.replace("\n", " ")
    return text if len(text) <= width else text[: max(0, width - 1)] + "…"


def frame(fleet: dict, width: int) -> list[tuple[str, int]]:
    """The whole screen as (text, role) lines, so curses and --once render the same."""
    counts = fleet["counts"]
    title = "FIRSTMATE FLEET"
    lines: list[tuple[str, int]] = [(f"{title} {'─' * max(0, width - len(title) - 1)}", HEAD)]
    summary = (
        f"{counts['homes']} homes · {counts['tasks']} tasks · "
        f"{counts['tasks_live']} endpoints alive · {counts['tasks_busy']} mid-turn · "
        f"{counts['holds']} held tasks · read in {fleet['elapsed_ms']}ms at {fleet['generated']}"
    )
    lines.append((summary, DIM))

    for home in fleet["homes"]:
        lines.append(("", PLAIN))
        sup = home["supervision"]
        backlog = home["backlog"]
        detail = (
            f"wakes {sup['wake_depth'] if sup['wake_depth'] is not None else '-'}"
            f" (oldest {age(sup['oldest_wake_age'])})"
            f"  beat {age(sup['beat_age'])}"
            f"  lock {sup['lock'] or '-'}"
            f"  backlog {backlog['in_flight']}/{backlog['queued']}/{backlog['held']}"
            " in-flight/queued/held"
        )
        stale_beat = sup["beat_age"] is None or sup["beat_age"] > 300
        lines.append((
            fit(f"{home['label']} [{home['source']}]  {detail}", width),
            WARN if stale_beat else HEAD,
        ))
        if home.get("error"):
            lines.append((fit(f"  ! {home['error']}", width), BAD))
        captain_holds = [hold["id"] for hold in home["holds"] if hold["hold_kind"] == "captain"]
        if captain_holds:
            lines.append((fit(f"  captain holds: {', '.join(captain_holds)}", width), WARN))
        if not home["tasks"] and not home.get("error"):
            lines.append(("  no work under way here", DIM))

        for task in sorted(home["tasks"], key=lambda t: t["id"]):
            glyph, role = mark(task)
            kind = "/".join(part for part in (task["kind"], task["mode"]) if part)
            runtime = "/".join(part for part in (task["harness"], task["backend"]) if part)
            busy = task["busy"] or "-"
            if task["busy"] and task["busy_source"]:
                busy = f"{busy} ({task['busy_source']})"
            row = (
                f"  {glyph} {task['id']:<30} {kind:<20} {runtime:<12} "
                f"{task['endpoint'] or '-':<7} {busy:<22} {task['pr'] or ''}"
            )
            lines.append((fit(row, width), role))
            event = task["last_event"]
            if event:
                note = event["note"] or ""
                lines.append((
                    fit(f"      EVENT {age(event['age_secs'])} ago · {event['verb']}: {note}", width),
                    DIM,
                ))
            else:
                lines.append(("      EVENT none yet", DIM))
    return lines


class Reader:
    """Reads the fleet off the drawing thread, so a slow home never freezes the screen."""

    def __init__(self, main_home: str | None) -> None:
        self.main_home = main_home
        self.fleet: dict | None = None
        self.error: str | None = None
        self.read_at = 0.0
        self.busy = False

    def start(self) -> None:
        if self.busy:
            return
        self.busy = True
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self) -> None:
        try:
            fleet, error = fm_fleet_read.read_fleet(self.main_home), None
        except Exception as exc:  # a broken read must show as one line, not a traceback
            fleet, error = None, str(exc)
        if fleet is not None:
            self.fleet = fleet
        self.error = error
        self.read_at = time.time()
        self.busy = False


def paint(screen, reader: Reader, interval: int, top: int) -> tuple[int, int]:
    """Draw one screen. Returns the clamped scroll offset and the body height."""
    height, width = screen.getmaxyx()
    if reader.fleet is None:
        lines = [(reader.error, BAD)] if reader.error else [("reading the fleet…", DIM)]
    else:
        lines = frame(reader.fleet, width - 1)
        if reader.error:
            lines.insert(1, (fit(f"last read failed: {reader.error}", width - 1), BAD))
    body = height - 1
    top = max(0, min(top, max(0, len(lines) - body)))
    screen.erase()
    for row, (text, role) in enumerate(lines[top:top + body]):
        try:
            screen.addstr(row, 0, text[: width - 1], ROLES[role])
        except curses.error:
            pass
    since = int(time.time() - reader.read_at) if reader.read_at else 0
    footer = (
        f" q quit · r refresh · j/k scroll · read {age(since)} ago · "
        f"every {interval}s{' · refreshing…' if reader.busy else ''}"
    )
    try:
        screen.addstr(height - 1, 0, footer[: width - 1], ROLES[HEAD])
    except curses.error:
        pass
    screen.refresh()
    return top, body


def loop(screen, main_home: str | None, interval: int) -> None:
    curses.curs_set(0)
    screen.timeout(POLL_MS)
    if curses.has_colors():
        curses.start_color()
        curses.use_default_colors()
        for pair, (role, colour) in enumerate(
            ((HEAD, curses.COLOR_CYAN), (GOOD, curses.COLOR_GREEN),
             (WARN, curses.COLOR_YELLOW), (BAD, curses.COLOR_RED)),
            start=1,
        ):
            curses.init_pair(pair, colour, -1)
            ROLES[role] = curses.color_pair(pair)
        ROLES[HEAD] |= curses.A_BOLD
        ROLES[DIM] = curses.A_DIM

    reader = Reader(main_home)
    reader.start()
    top = 0
    while True:
        top, body = paint(screen, reader, interval, top)
        key = screen.getch()
        if key in (ord("q"), ord("Q")):
            return
        if key in (ord("r"), ord("R")):
            reader.start()
        elif key in (curses.KEY_DOWN, ord("j")):
            top += 1
        elif key in (curses.KEY_UP, ord("k")):
            top = max(0, top - 1)
        elif key == ord("g"):
            top = 0
        elif key == ord("G"):
            top += body
        if reader.read_at and time.time() - reader.read_at >= interval:
            reader.start()


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="fm-fleet-tui.py",
        description=__doc__.strip().splitlines()[0],
        epilog="Keys: q quit - r refresh now - j/k or arrows scroll - g/G top/bottom.",
    )
    parser.add_argument("--interval", type=int, default=DEFAULT_INTERVAL,
                        help="seconds between reads (default 15)")
    parser.add_argument("--once", action="store_true", help="print one frame and exit")
    parser.add_argument("--main-home", help="the main home whose registry drives discovery")
    args = parser.parse_args(argv)
    if args.interval < 1:
        parser.error("--interval takes whole seconds, 1 or more")
    if args.once:
        for text, _role in frame(fm_fleet_read.read_fleet(args.main_home), 160):
            print(text)
        return 0
    curses.wrapper(loop, args.main_home, args.interval)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
