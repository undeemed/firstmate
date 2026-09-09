#!/usr/bin/env python3
"""fm_fleet_read - the one fleet read layer every firstmate board renders from.

Fleet discovery and per-home reading live here exactly once, so a screen cannot
grow its own private idea of what the fleet is. Both renderers import this
module: bin/fm-fleet-tui.py (terminal) and bin/fm-live-board.py (web page).

It owns no state contract of its own. Every fact comes from
bin/fm-fleet-probe.sh, which reads it through the same shell owners firstmate
itself trusts, and this module only discovers homes, runs those probes
concurrently, and shapes the records. A field that cannot be read is None or an
explicit error string; nothing here guesses.

What it deliberately does NOT do: reconcile a task's current state. A task's
`last_event` is wake-EVENT history, not current truth, and every renderer must
label it that way. Ask bin/fm-crew-state.sh when current state matters - that
read costs seconds per task, which is why it is not on a refresh timer.

  python3 bin/fm_fleet_read.py            one fleet read as JSON

Environment:
  FM_HOME                  the main home whose registry drives discovery
  FM_FLEET_READ_TIMEOUT    seconds allowed per home probe (default 25)
"""

from __future__ import annotations

import json
import os
import subprocess
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

BIN_DIR = Path(__file__).resolve().parent
PROBE = BIN_DIR / "fm-fleet-probe.sh"
DEFAULT_TIMEOUT = 25


def age(secs: int | None) -> str:
    """One age word, shared so both boards say the same thing about the same number."""
    if secs is None:
        return "-"
    if secs < 60:
        return f"{secs}s"
    if secs < 3600:
        return f"{secs // 60}m"
    if secs < 86400:
        return f"{secs // 3600}h"
    return f"{secs // 86400}d"


def count(n: int | None) -> str:
    """A count, or `-` for one that could not be read, shared by both boards."""
    return "-" if n is None else str(n)


def _timeout() -> int:
    raw = os.environ.get("FM_FLEET_READ_TIMEOUT", "")
    return int(raw) if raw.isdigit() and int(raw) > 0 else DEFAULT_TIMEOUT


def _run_probe(mode: str, home: str) -> tuple[list[list[str]], str | None]:
    """Run one probe and split its records. Returns (records, error)."""
    env = dict(os.environ, FM_HOME=home)
    for override in ("FM_ROOT_OVERRIDE", "FM_STATE_OVERRIDE", "FM_CONFIG_OVERRIDE"):
        env.pop(override, None)
    timeout = _timeout()
    try:
        done = subprocess.run(
            [str(PROBE), mode],
            check=False,
            capture_output=True,
            text=True,
            timeout=timeout,
            env=env,
        )
    except subprocess.TimeoutExpired:
        return [], f"probe timed out after {timeout}s"
    except OSError as exc:
        return [], f"probe could not run: {exc}"
    records = [line.split("\t") for line in done.stdout.splitlines() if line.strip()]
    if done.returncode != 0:
        # A crashed probe may have written part of its records first. Keep them,
        # but name the failure, so a home is never silently shown incomplete.
        detail = done.stderr.strip().splitlines()
        return records, f"probe failed: {detail[-1] if detail else done.returncode}"
    return records, None


def _int_or_none(value: str) -> int | None:
    return int(value) if value.lstrip("-").isdigit() else None


def _field(row: list[str], index: int) -> str | None:
    if index >= len(row):
        return None
    return None if row[index] in ("", "-") else row[index]


def discover_homes() -> list[dict]:
    """Every home of this fleet: the main home, its registry, and pool markers."""
    home = os.environ.get("FM_HOME") or str(BIN_DIR.parent)
    records, error = _run_probe("--homes", home)
    homes = [
        {"label": row[1], "path": row[2], "source": row[3]}
        for row in records
        if row[0] == "home" and len(row) >= 4
    ]
    if not homes:
        return [
            {
                "label": "main",
                "path": home,
                "source": "main",
                "error": error or "no homes discovered",
            }
        ]
    if error:
        # Discovery crashed after listing some homes: show what it found, and
        # carry the failure on the first (main) entry rather than dropping it.
        homes[0]["error"] = error
    return homes


def read_home(home: dict) -> dict:
    """One home's cheap read: its supervision header, backlog, holds, and tasks."""
    result = dict(home)
    result.update(
        supervision={
            "wake_depth": None,
            "oldest_wake_age": None,
            "beat_age": None,
            "lock": None,
        },
        backlog={"in_flight": None, "queued": None, "held": None},
        holds=[],
        tasks=[],
    )
    if home.get("source", "").startswith("remote:"):
        result["error"] = (
            f"remote home on {home['source'].split(':', 1)[1]}, not read from here"
        )
        return result
    records, probe_error = _run_probe("--home", home["path"])
    if probe_error and not records:
        result["error"] = probe_error
        return result

    tasks: dict[str, dict] = {}
    for row in records:
        kind = row[0]
        if kind == "error":
            result["error"] = row[1] if len(row) > 1 else "unreadable"
        elif kind == "sup" and len(row) >= 5:
            result["supervision"] = {
                "wake_depth": _int_or_none(row[1]),
                "oldest_wake_age": _int_or_none(row[2]),
                "beat_age": _int_or_none(row[3]),
                "lock": _field(row, 4),
            }
        elif kind == "backlog" and len(row) >= 4:
            result["backlog"] = {
                "in_flight": _int_or_none(row[1]),
                "queued": _int_or_none(row[2]),
                "held": _int_or_none(row[3]),
            }
        elif kind == "hold" and len(row) >= 3:
            result["holds"].append({"id": row[1], "hold_kind": row[2]})
        elif kind == "task" and len(row) >= 10:
            task = {
                "id": row[1],
                "kind": _field(row, 2),
                "mode": _field(row, 3),
                "harness": _field(row, 4),
                "backend": _field(row, 5),
                "endpoint": _field(row, 6),
                "busy": _field(row, 7),
                "busy_source": _field(row, 8),
                "pr": _field(row, 9),
                "last_event": None,
            }
            tasks[task["id"]] = task
            result["tasks"].append(task)
        elif kind == "event" and len(row) >= 4 and row[1] in tasks:
            tasks[row[1]]["last_event"] = {
                "age_secs": _int_or_none(row[2]),
                "verb": _field(row, 3),
                "note": _field(row, 4),
            }
    if probe_error:
        # The probe crashed after writing part of this home. The partial read
        # stays visible, and the crash outranks any record-level error above.
        result["error"] = probe_error
    return result


def read_fleet() -> dict:
    """One whole-fleet read. Homes are probed concurrently, so the slowest home sets the cost."""
    started = time.time()
    homes = discover_homes()
    with ThreadPoolExecutor() as pool:
        read = list(pool.map(read_home, homes))
    tasks = [task for entry in read for task in entry["tasks"]]
    return {
        "generated": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "elapsed_ms": int((time.time() - started) * 1000),
        "homes": read,
        "counts": {
            "homes": len(read),
            "tasks": len(tasks),
            "tasks_live": sum(1 for task in tasks if task["endpoint"] == "alive"),
            "tasks_busy": sum(1 for task in tasks if task["busy"] == "busy"),
            "holds": sum(len(entry["holds"]) for entry in read),
        },
    }


if __name__ == "__main__":
    print(json.dumps(read_fleet(), indent=1))
