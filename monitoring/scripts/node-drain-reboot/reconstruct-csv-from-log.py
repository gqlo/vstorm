#!/usr/bin/env python3
"""Reconstruct mcp-reboot-watch per-node CSV from watch log + events TSV.

The original watch script gated CSV writes on MCN UPDATED=True, so some nodes
are missing entirely and others have node_end_time / per_node_total_duration_seconds
set to MCN completion time instead of boot_done_ts. Poll milestones logged as:

  node/<name> NodeNotSchedulable @ <iso>   -> cordoned_ts
  node/<name> NodeNotReady @ <iso>         -> drain_done_ts
  node/<name> NodeSchedulable @ <iso>      -> boot_done_ts

Usage:
  reconstruct-csv-from-log.py WATCH.log [EVENTS.tsv] [-o OUTPUT.csv]
"""

from __future__ import annotations

import argparse
import csv
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

CSV_HEADER = [
    "node",
    "drain_seconds",
    "boot_seconds",
    "per_node_total_duration_seconds",
    "node_start_time",
    "node_end_time",
    "cordoned_ts",
    "drain_done_ts",
    "boot_done_ts",
    "rendered_config",
    "data_source",
    "evt_cordoned_ts",
    "evt_drain_done_ts",
    "evt_boot_done_ts",
    "evt_drain_seconds",
    "evt_boot_seconds",
    "evt_phases_complete",
]

MILESTONE_RE = re.compile(
    r"node/([^\s]+) (NodeNotSchedulable|NodeNotReady|NodeSchedulable) @ ([0-9TZ:+-]+)"
)
TIMER_STARTED_RE = re.compile(r"Updating=True — timer started")
CONFIG_CHANGE_RE = re.compile(
    r"Rollout rendered config changed: ([^\s]+) -> ([^\s]+)"
)
REBOOT_CONFIG_RE = re.compile(
    r"Node will reboot into config (rendered-worker-[0-9a-f]+)"
)


def iso_epoch(iso: str) -> float:
    return datetime.fromisoformat(iso.replace("Z", "+00:00")).timestamp()


def duration_between(a: str | None, b: str | None) -> str:
    if not a or not b:
        return ""
    return str(int(iso_epoch(b) - iso_epoch(a)))


def parse_log_meta(log_text: str) -> tuple[float | None, str | None]:
    start_epoch = None
    target_cfg = None
    for line in log_text.splitlines():
        if start_epoch is None and TIMER_STARTED_RE.search(line):
            start_epoch = iso_epoch(line.split()[0])
        m = CONFIG_CHANGE_RE.search(line)
        if m:
            target_cfg = m.group(2)
    return start_epoch, target_cfg


def parse_poll_milestones(log_text: str) -> dict[str, dict[str, str]]:
    phase_map = {
        "NodeNotSchedulable": "cordoned",
        "NodeNotReady": "drain_done",
        "NodeSchedulable": "boot_done",
    }
    milestones: dict[str, dict[str, str]] = {}
    for line in log_text.splitlines():
        m = MILESTONE_RE.search(line)
        if not m:
            continue
        node, phase, ts = m.group(1), m.group(2), m.group(3)
        key = phase_map[phase]
        milestones.setdefault(node, {})[key] = ts
    return milestones


class EventTracker:
    def __init__(self, start_epoch: float | None, target_cfg: str | None) -> None:
        self.start_epoch = start_epoch
        self.target_cfg = target_cfg
        self.by_node: dict[str, dict[str, str]] = {}

    def _get(self, node: str, name: str) -> str | None:
        return self.by_node.get(node, {}).get(name)

    def _set_first(self, node: str, name: str, iso: str) -> None:
        if not iso:
            return
        node_events = self.by_node.setdefault(node, {})
        if name not in node_events:
            node_events[name] = iso

    def _set_earliest(self, node: str, name: str, iso: str) -> None:
        if not iso:
            return
        node_events = self.by_node.setdefault(node, {})
        existing = node_events.get(name)
        if existing and iso_epoch(iso) >= iso_epoch(existing):
            return
        node_events[name] = iso

    def apply(self, node: str, event_time: str, reason: str, message: str) -> None:
        if self.start_epoch is not None and iso_epoch(event_time) < self.start_epoch:
            return

        reboot = self._get(node, "reboot")
        rebooted = self._get(node, "rebooted")
        cordoned = self._get(node, "cordoned")
        event_epoch = iso_epoch(event_time)

        if reason == "Reboot":
            if self.target_cfg and self.target_cfg not in message:
                return
            self._set_first(node, "reboot", event_time)
        elif reason == "Rebooted":
            self._set_first(node, "rebooted", event_time)
        elif reason == "NodeNotSchedulable":
            if reboot and event_epoch >= iso_epoch(reboot):
                return
            self._set_earliest(node, "cordoned", event_time)
        elif reason == "NodeNotReady":
            if not cordoned or event_epoch < iso_epoch(cordoned):
                return
            if rebooted and event_epoch >= iso_epoch(rebooted):
                return
            boot = self._get(node, "boot_done")
            if boot and event_epoch >= iso_epoch(boot):
                return
            self._set_earliest(node, "drain_done", event_time)
        elif reason == "Uncordon":
            if self.target_cfg and self.target_cfg not in message:
                return
            if not reboot and not rebooted:
                return
            if reboot and event_epoch < iso_epoch(reboot):
                return
            self._set_first(node, "boot_done", event_time)
        elif reason == "NodeSchedulable":
            if self._get(node, "boot_done"):
                return
            if not reboot and not rebooted:
                return
            if reboot and event_epoch < iso_epoch(reboot):
                return
            self._set_first(node, "boot_done", event_time)

    def phases_complete(self, node: str) -> bool:
        ev = self.by_node.get(node, {})
        return all(k in ev for k in ("cordoned", "drain_done", "boot_done"))


def parse_events_tsv(path: Path, tracker: EventTracker) -> None:
    with path.open(newline="") as fh:
        reader = csv.DictReader(fh, delimiter="\t")
        rows = sorted(reader, key=lambda r: r["event_time"])
        for row in rows:
            tracker.apply(
                row["node"],
                row["event_time"],
                row["reason"],
                row.get("message", ""),
            )


def parse_reboot_configs(events_path: Path | None) -> dict[str, str]:
    configs: dict[str, str] = {}
    if not events_path or not events_path.exists():
        return configs
    with events_path.open(newline="") as fh:
        reader = csv.DictReader(fh, delimiter="\t")
        for row in reader:
            if row["reason"] != "Reboot":
                continue
            m = REBOOT_CONFIG_RE.search(row.get("message", ""))
            if m:
                configs[row["node"]] = m.group(1)
    return configs


def infer_data_source(poll: dict[str, str], events: EventTracker, node: str) -> str:
    # Reconstructed poll milestones are always observed; compare with events.
    evt = events.by_node.get(node, {})
    if not evt:
        return "observed"
    mismatches = 0
    matches = 0
    for key in ("cordoned", "drain_done", "boot_done"):
        p = poll.get(key)
        e = evt.get(key)
        if p and e:
            if p == e:
                matches += 1
            else:
                mismatches += 1
    if mismatches and matches:
        return "mixed"
    if mismatches:
        return "mixed"
    if events.phases_complete(node):
        return "mixed"
    return "observed"


def build_row(
    node: str,
    poll: dict[str, str],
    events: EventTracker,
    rendered_config: str,
) -> dict[str, str]:
    cord = poll["cordoned"]
    drained = poll["drain_done"]
    boot = poll["boot_done"]
    evt_cord = events._get(node, "cordoned") or ""
    evt_drained = events._get(node, "drain_done") or ""
    evt_boot = events._get(node, "boot_done") or ""
    return {
        "node": node,
        "drain_seconds": duration_between(cord, drained),
        "boot_seconds": duration_between(drained, boot),
        "per_node_total_duration_seconds": duration_between(cord, boot),
        "node_start_time": cord,
        "node_end_time": boot,
        "cordoned_ts": cord,
        "drain_done_ts": drained,
        "boot_done_ts": boot,
        "rendered_config": rendered_config,
        "data_source": infer_data_source(poll, events, node),
        "evt_cordoned_ts": evt_cord,
        "evt_drain_done_ts": evt_drained,
        "evt_boot_done_ts": evt_boot,
        "evt_drain_seconds": duration_between(evt_cord, evt_drained),
        "evt_boot_seconds": duration_between(evt_drained, evt_boot),
        "evt_phases_complete": "yes" if events.phases_complete(node) else "no",
    }


def reconstruct(
    log_path: Path,
    events_path: Path | None,
    original_csv: Path | None,
) -> tuple[list[dict[str, str]], dict[str, object]]:
    log_text = log_path.read_text()
    start_epoch, target_cfg = parse_log_meta(log_text)
    poll = parse_poll_milestones(log_text)
    events = EventTracker(start_epoch, target_cfg)
    if events_path and events_path.exists():
        parse_events_tsv(events_path, events)
    reboot_configs = parse_reboot_configs(events_path)

    original_configs: dict[str, str] = {}
    if original_csv and original_csv.exists():
        with original_csv.open(newline="") as fh:
            for row in csv.DictReader(fh):
                if row.get("rendered_config"):
                    original_configs[row["node"]] = row["rendered_config"]

    complete = {
        n: phases
        for n, phases in poll.items()
        if all(k in phases for k in ("cordoned", "drain_done", "boot_done"))
    }

    rows: list[dict[str, str]] = []
    for node in sorted(complete):
        cfg = (
            reboot_configs.get(node)
            or original_configs.get(node)
            or target_cfg
            or ""
        )
        rows.append(build_row(node, complete[node], events, cfg))

    stats = {
        "poll_nodes_all_phases": len(complete),
        "output_rows": len(rows),
        "target_cfg": target_cfg,
        "start_epoch_iso": (
            datetime.fromtimestamp(start_epoch, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
            if start_epoch
            else None
        ),
    }
    return rows, stats


def compare_with_original(
    reconstructed: list[dict[str, str]],
    original_csv: Path | None,
) -> dict[str, object]:
    if not original_csv or not original_csv.exists():
        return {"missing_from_original": [], "wrong_end_time": []}

    orig = {r["node"]: r for r in csv.DictReader(original_csv.open())}
    recon = {r["node"]: r for r in reconstructed}

    missing = sorted(set(recon) - set(orig))
    wrong_end = []
    for node, row in recon.items():
        if node not in orig:
            continue
        o = orig[node]
        if o.get("node_end_time") != row["node_end_time"]:
            wrong_end.append(
                {
                    "node": node,
                    "original_end": o.get("node_end_time"),
                    "reconstructed_end": row["node_end_time"],
                    "original_total": o.get("per_node_total_duration_seconds"),
                    "reconstructed_total": row["per_node_total_duration_seconds"],
                }
            )

    return {
        "missing_from_original": missing,
        "wrong_end_time": wrong_end,
        "original_row_count": len(orig),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", type=Path, help="mcp-reboot-watch log file")
    parser.add_argument(
        "events",
        type=Path,
        nargs="?",
        help="events TSV (default: same stem as log with .events.tsv)",
    )
    parser.add_argument(
        "-o",
        "--output",
        type=Path,
        help="output CSV (default: <log-stem>.reconstructed.csv)",
    )
    parser.add_argument(
        "--original-csv",
        type=Path,
        help="original CSV for comparison report (default: same stem as log with .csv)",
    )
    args = parser.parse_args()

    log_path = args.log
    if not log_path.exists():
        print(f"error: log not found: {log_path}", file=sys.stderr)
        return 1

    events_path = args.events
    if events_path is None:
        events_path = log_path.with_suffix(".events.tsv")
        if not events_path.exists():
            events_path = Path(str(log_path).replace(".log", ".events.tsv"))

    original_csv = args.original_csv
    if original_csv is None:
        candidate = Path(str(log_path).replace(".log", ".csv"))
        original_csv = candidate if candidate.exists() else None

    output = args.output
    if output is None:
        output = Path(str(log_path).replace(".log", ".reconstructed.csv"))

    rows, stats = reconstruct(log_path, events_path, original_csv)
    comparison = compare_with_original(rows, original_csv)

    with output.open("w", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=CSV_HEADER)
        writer.writeheader()
        writer.writerows(rows)

    print(f"Wrote {len(rows)} rows to {output}")
    print(f"  poll nodes with all 3 phases: {stats['poll_nodes_all_phases']}")
    if stats["target_cfg"]:
        print(f"  rollout config: {stats['target_cfg']}")
    if comparison.get("original_row_count") is not None:
        print(f"  original CSV rows: {comparison['original_row_count']}")
        missing = comparison["missing_from_original"]
        if missing:
            print(f"  added missing nodes ({len(missing)}): {', '.join(missing)}")
        wrong = comparison["wrong_end_time"]
        print(f"  rows with corrected node_end_time: {len(wrong)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
