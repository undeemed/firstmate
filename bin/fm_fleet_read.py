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

  python3 bin/fm_fleet_read.py --json     one fleet read as JSON
  python3 bin/fm_fleet_read.py --homes    just the discovered homes

Environment:
  FM_HOME                  the main home whose registry drives discovery
  FM_FLEET_READ_TIMEOUT    seconds allowed per home probe (default 25)
  FM_FLEET_READ_WORKERS    concurrent home probes (default 8)
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

BIN_DIR = Path(__file__).resolve().parent
PROBE = BIN_DIR / "fm-fleet-probe.sh"
DEFAULT_TIMEOUT = 25
DEFAULT_WORKERS = 8


def _env_int(name: str, default: int) -> int:
    raw = os.environ.get(name, "")
    return int(raw) if raw.isdigit() and int(raw) > 0 else default


def _main_home() -> str:
    return os.environ.get("FM_HOME") or str(BIN_DIR.parent)


def _run_probe(
    mode: str, home: str, timeout: int
) -> tuple[list[list[str]], str | None]:
    """Run one probe and split its records. Returns (records, error)."""
    env = dict(os.environ, FM_HOME=home)
    env.pop("FM_ROOT_OVERRIDE", None)
    env.pop("FM_STATE_OVERRIDE", None)
    env.pop("FM_CONFIG_OVERRIDE", None)
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
    if done.returncode != 0 and not done.stdout:
        detail = done.stderr.strip().splitlines()
        return [], f"probe failed: {detail[-1] if detail else done.returncode}"
    records = [line.split("\t") for line in done.stdout.splitlines() if line.strip()]
    return records, None


def _int_or_none(value: str) -> int | None:
    return int(value) if value.lstrip("-").isdigit() else None


def _field(row: list[str], index: int) -> str | None:
    if index >= len(row):
        return None
    value = row[index]
    return None if value in ("", "-") else value


def discover_homes(
    main_home: str | None = None, timeout: int | None = None
) -> list[dict]:
    """Every home of this fleet: the main home, its registry, and pool markers."""
    home = main_home or _main_home()
    timeout = timeout or _env_int("FM_FLEET_READ_TIMEOUT", DEFAULT_TIMEOUT)
    records, error = _run_probe("--homes", home, timeout)
    if error:
        return [{"label": "main", "path": home, "source": "main", "error": error}]
    homes = []
    for row in records:
        if row[0] != "home" or len(row) < 4:
            continue
        homes.append({"label": row[1], "path": row[2], "source": row[3]})
    return homes


def read_home(home: dict, timeout: int | None = None) -> dict:
    """One home's cheap read: its supervision header, backlog, holds, and tasks."""
    timeout = timeout or _env_int("FM_FLEET_READ_TIMEOUT", DEFAULT_TIMEOUT)
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
    records, error = _run_probe("--home", home["path"], timeout)
    if error:
        result["error"] = error
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
        elif kind == "task" and len(row) >= 11:
            task = {
                "id": row[1],
                "home": home["path"],
                "home_label": home["label"],
                "kind": _field(row, 2),
                "mode": _field(row, 3),
                "harness": _field(row, 4),
                "backend": _field(row, 5),
                "endpoint": _field(row, 6),
                "busy": _field(row, 7),
                "busy_source": _field(row, 8),
                "pr": _field(row, 9),
                "project": _field(row, 10),
                "last_event": None,
            }
            tasks[task["id"]] = task
            result["tasks"].append(task)
        elif kind == "event" and len(row) >= 4 and row[1] in tasks:
            tasks[row[1]]["last_event"] = {
                "age_secs": _int_or_none(row[2]),
                "verb": _field(row, 3),
                "note": _field(row, 4) if len(row) > 4 else None,
            }
    return result


def read_fleet(main_home: str | None = None, workers: int | None = None) -> dict:
    """One whole-fleet read. Homes are probed concurrently; slowest home sets the cost."""
    started = time.time()
    home = main_home or _main_home()
    workers = workers or _env_int("FM_FLEET_READ_WORKERS", DEFAULT_WORKERS)
    homes = discover_homes(home)
    with ThreadPoolExecutor(max_workers=max(1, min(workers, len(homes) or 1))) as pool:
        read = list(pool.map(read_home, homes))
    tasks = [task for entry in read for task in entry["tasks"]]
    return {
        "generated": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "elapsed_ms": int((time.time() - started) * 1000),
        "main_home": home,
        "homes": read,
        "counts": {
            "homes": len(read),
            "homes_unreadable": sum(1 for entry in read if entry.get("error")),
            "tasks": len(tasks),
            "tasks_live": sum(1 for task in tasks if task["endpoint"] == "alive"),
            "tasks_busy": sum(1 for task in tasks if task["busy"] == "busy"),
            "holds": sum(len(entry["holds"]) for entry in read),
        },
    }


def main(argv: list[str]) -> int:
    mode = argv[0] if argv else "--json"
    if mode in ("-h", "--help"):
        print(__doc__.strip())
        return 0
    if mode == "--homes":
        print(json.dumps(discover_homes(), indent=1))
        return 0
    if mode == "--json":
        print(json.dumps(read_fleet(), indent=1))
        return 0
    print(__doc__.strip(), file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
