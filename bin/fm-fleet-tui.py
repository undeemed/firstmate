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

Keys: q quit · r refresh now · j/k or arrows scroll · g/G top/bottom.

Environment: FM_HOME selects the main home when --main-home is absent;
FM_FLEET_READ_TIMEOUT and FM_FLEET_READ_WORKERS bound each read.
"""

from __future__ import annotations

import curses
import sys
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import fm_fleet_read

DEFAULT_INTERVAL = 15
# Screen roles, mapped to one curses colour pair each.
PLAIN, HEAD, GOOD, WARN, BAD, DIM = range(6)


def age(secs: int | None) -> str:
    if secs is None:
        return "-"
    if secs < 60:
        return f"{secs}s"
    if secs < 3600:
        return f"{secs // 60}m"
    if secs < 86400:
        return f"{secs // 3600}h"
    return f"{secs // 86400}d"


def endpoint_role(task: dict) -> int:
    if task["endpoint"] == "alive":
        return GOOD if task["busy"] == "busy" else PLAIN
    if task["endpoint"] == "dead":
        return BAD
    return DIM


def glyph(task: dict) -> str:
    if task["endpoint"] != "alive":
        return "x" if task["endpoint"] == "dead" else "?"
    return "*" if task["busy"] == "busy" else "o"


def fit(text: str, width: int) -> str:
    text = text.replace("\n", " ")
    return text if len(text) <= width else text[: max(0, width - 1)] + "…"


def frame(fleet: dict, width: int) -> list[tuple[str, int]]:
    """The whole screen as (text, role) lines, so curses and --once render the same."""
    counts = fleet["counts"]
    lines: list[tuple[str, int]] = []
    title = "FIRSTMATE FLEET"
    lines.append((f"{title} {'─' * max(0, width - len(title) - 1)}", HEAD))
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
        label = f"{home['label']} [{home['source']}]"
        detail = (
            f"wakes {sup['wake_depth'] if sup['wake_depth'] is not None else '-'}"
            f" (oldest {age(sup['oldest_wake_age'])})"
            f"  beat {age(sup['beat_age'])}"
            f"  lock {sup['lock'] or '-'}"
            f"  backlog {backlog['in_flight']}/{backlog['queued']}/{backlog['held']}"
            " in-flight/queued/held"
        )
        stale_beat = sup["beat_age"] is None or sup["beat_age"] > 300
        lines.append((fit(f"{label}  {detail}", width), WARN if stale_beat else HEAD))
        if home.get("error"):
            lines.append((fit(f"  ! {home['error']}", width), BAD))
        captain_holds = [
            hold["id"] for hold in home["holds"] if hold["hold_kind"] == "captain"
        ]
        if captain_holds:
            lines.append(
                (fit(f"  captain holds: {', '.join(captain_holds)}", width), WARN)
            )
        if not home["tasks"] and not home.get("error"):
            lines.append(("  no work under way here", DIM))

        for task in sorted(home["tasks"], key=lambda t: t["id"]):
            kind = "/".join(part for part in (task["kind"], task["mode"]) if part)
            runtime = "/".join(
                part for part in (task["harness"], task["backend"]) if part
            )
            busy = task["busy"] or "-"
            if task["busy"] and task["busy_source"]:
                busy = f"{busy} ({task['busy_source']})"
            row = (
                f"  {glyph(task)} {task['id']:<30} {kind:<20} {runtime:<12} "
                f"{task['endpoint'] or '-':<7} {busy:<22} {task['pr'] or ''}"
            )
            lines.append((fit(row, width), endpoint_role(task)))
            event = task["last_event"]
            if event:
                note = event["note"] or ""
                lines.append(
                    (
                        fit(
                            f"      EVENT {age(event['age_secs'])} ago · {event['verb']}: {note}",
                            width,
                        ),
                        DIM,
                    )
                )
            else:
                lines.append(("      EVENT none yet", DIM))
    return lines


def render_once(main_home: str | None) -> int:
    fleet = fm_fleet_read.read_fleet(main_home)
    for text, _role in frame(fleet, 160):
        print(text)
    return 0


class Reader:
    """Reads the fleet off the drawing thread, so a slow home never freezes the screen."""

    def __init__(self, main_home: str | None) -> None:
        self.main_home = main_home
        self.fleet: dict | None = None
        self.error: str | None = None
        self.read_at = 0.0
        self.busy = False
        self._lock = threading.Lock()

    def start(self) -> None:
        with self._lock:
            if self.busy:
                return
            self.busy = True
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self) -> None:
        try:
            fleet = fm_fleet_read.read_fleet(self.main_home)
            error = None
        except Exception as exc:  # a broken read must show as one line, not a traceback
            fleet, error = None, str(exc)
        with self._lock:
            if fleet is not None:
                self.fleet = fleet
            self.error = error
            self.read_at = time.time()
            self.busy = False


def loop(screen, main_home: str | None, interval: int) -> None:
    curses.curs_set(0)
    screen.nodelay(True)
    roles = {PLAIN: 0, HEAD: 0, GOOD: 0, WARN: 0, BAD: 0, DIM: 0}
    if curses.has_colors():
        curses.start_color()
        curses.use_default_colors()
        for pair, (role, colour) in enumerate(
            (
                (HEAD, curses.COLOR_CYAN),
                (GOOD, curses.COLOR_GREEN),
                (WARN, curses.COLOR_YELLOW),
                (BAD, curses.COLOR_RED),
            ),
            start=1,
        ):
            curses.init_pair(pair, colour, -1)
            roles[role] = curses.color_pair(pair)
        roles[HEAD] |= curses.A_BOLD
        roles[DIM] = curses.A_DIM

    reader = Reader(main_home)
    reader.start()
    top = 0
    while True:
        height, width = screen.getmaxyx()
        if reader.fleet is None:
            lines = (
                [("reading the fleet…", DIM)]
                if not reader.error
                else [(reader.error, BAD)]
            )
        else:
            lines = frame(reader.fleet, width - 1)
            if reader.error:
                lines.insert(
                    1, (fit(f"last read failed: {reader.error}", width - 1), BAD)
                )
        body = height - 1
        top = max(0, min(top, max(0, len(lines) - body)))
        screen.erase()
        for row, (text, role) in enumerate(lines[top : top + body]):
            try:
                screen.addstr(row, 0, text[: width - 1], roles[role])
            except curses.error:
                pass
        since = int(time.time() - reader.read_at) if reader.read_at else 0
        footer = (
            f" q quit · r refresh · j/k scroll · read {age(since)} ago · "
            f"every {interval}s{' · refreshing…' if reader.busy else ''}"
        )
        try:
            screen.addstr(height - 1, 0, footer[: width - 1], roles[HEAD])
        except curses.error:
            pass
        screen.refresh()

        key = screen.getch()
        if key in (ord("q"), ord("Q")):
            return
        if key in (ord("r"), ord("R")):
            reader.start()
        elif key in (curses.KEY_DOWN, ord("j")):
            top += 1
        elif key in (curses.KEY_UP, ord("k")):
            top = max(0, top - 1)
        elif key in (curses.KEY_NPAGE, ord(" ")):
            top += body
        elif key == curses.KEY_PPAGE:
            top = max(0, top - body)
        elif key == ord("g"):
            top = 0
        elif key == ord("G"):
            top = len(lines)
        if reader.read_at and time.time() - reader.read_at >= interval:
            reader.start()
        time.sleep(0.2)


def main(argv: list[str]) -> int:
    interval, main_home, once = DEFAULT_INTERVAL, None, False
    args = list(argv)
    while args:
        arg = args.pop(0)
        if arg in ("-h", "--help"):
            print(__doc__.strip())
            return 0
        if arg == "--once":
            once = True
        elif arg == "--interval" and args:
            value = args.pop(0)
            if not value.isdigit() or int(value) < 1:
                print(
                    "fm-fleet-tui: --interval takes whole seconds, 1 or more",
                    file=sys.stderr,
                )
                return 2
            interval = int(value)
        elif arg == "--main-home" and args:
            main_home = args.pop(0)
        else:
            print(f"fm-fleet-tui: unknown argument {arg}", file=sys.stderr)
            return 2
    if once:
        return render_once(main_home)
    curses.wrapper(loop, main_home, interval)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
