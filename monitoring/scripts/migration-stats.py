#!/usr/bin/env python3
"""
Extract VMIM migration statistics from the cluster.

Modes:
- Migration duration CSV:
  - Compute time in seconds between Pending → Succeeded for each VMIM
  - Differentiate evacuation (kubevirt-evacuation-*), workload (workload*), migration (kubevirt-migrate*)
  - Output columns: "type, workload, vmim name, time in seconds"
- Summary:
  - Aggregate statistics over completed migrations (first/last completion, span, per‑hour rate, min/median/max)
  - Include a count of currently running VMIs
- Eviction counts:
  - Count evacuation VMIMs (kubevirt-evacuation-*) per VMI (namespace + spec.vmiName)
  - Default: only VMIMs with phase Succeeded (completed evacuations)

Usage:
  # No arguments: print summary only (all namespaces)
  python migration-stats.py

  # CSV of VMIM times (stdout or --output)
  python migration-stats.py --csv [--output out.csv]
  python migration-stats.py --namespace NAMESPACE [--output out.csv]
  python migration-stats.py --name VMIM_NAME [--namespace NAMESPACE] [--output out.csv]

  # Summary explicitly
  python migration-stats.py --summary [-n NAMESPACE]

  # Eviction counts: stderr summary only (buckets + total); per-VMI CSV only with --output
  python migration-stats.py --eviction-counts
  python migration-stats.py --eviction-counts --output evictions.csv

  # Time range filter (overlap with VMIM Pending→Succeeded interval; open-ended if omitted)
  # UTC: ISO-8601 e.g. 2026-03-19T10:00:00Z, or space-separated e.g. 2026-02-19 17:28:51
  python migration-stats.py --csv --start 2026-03-19T10:00:00Z --end 2026-03-19T11:00:00Z
  python migration-stats.py --csv --start "2026-02-19 17:28:51" --end "2026-02-19 18:00:00"
  python migration-stats.py --summary --start 2026-03-19T10:00:00Z
  python migration-stats.py --eviction-counts --start 2026-03-19T10:00:00Z --end 2026-03-19T11:00:00Z

Requires: oc in PATH, cluster access.
"""

import argparse
import csv
import json
import subprocess
import sys
from collections import Counter
from datetime import datetime, timezone


def namespace_exists(namespace: str) -> bool:
    """Return True if the namespace exists in the cluster."""
    result = subprocess.run(
        ["oc", "get", "namespace", namespace],
        capture_output=True,
        text=True,
        check=False,
    )
    return result.returncode == 0


def get_vmim_json(namespace: str | None, name: str | None) -> dict:
    """Fetch VMIM(s). If namespace is None, query all namespaces (-A)."""
    if namespace is not None:
        cmd = ["oc", "get", "vmim", "-n", namespace, "-o", "json"]
        if name:
            cmd.insert(3, name)  # oc get vmim NAME -n NAMESPACE -o json
    else:
        cmd = ["oc", "get", "vmim", "-A", "-o", "json"]
        if name:
            cmd.insert(3, name)  # oc get vmim NAME -A -o json
    result = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if result.returncode != 0:
        print(result.stderr or result.stdout, file=sys.stderr)
        sys.exit(1)
    return json.loads(result.stdout)


VMIM_TYPE_PREFIXES = (
    ("kubevirt-evacuation-", "evacuation"),
    ("workload", "workload"),
    ("kubevirt-migrate", "migration"),
)
# Summary line always lists these (0 if no completed VMIMs of that type).
VMIM_SUMMARY_TYPES = ("evacuation", "workload", "migration", "other")


def vmim_type(item: dict) -> str:
    """Return type from VMIM metadata.name (see VMIM_TYPE_PREFIXES); else 'other'."""
    name = item.get("metadata", {}).get("name", "")
    for prefix, typ in VMIM_TYPE_PREFIXES:
        if name.startswith(prefix):
            return typ
    return "other"


def workload_name(item: dict) -> str:
    """Return the workload (VMI) name from VMIM spec.vmiName, or fallback to VMIM name."""
    return (
        item.get("spec", {}).get("vmiName")
        or item.get("metadata", {}).get("name", "")
    )


def count_running_vmis(namespace: str | None) -> int | None:
    """Count VirtualMachineInstances with phase Running. None if oc get vmi fails."""
    if namespace is not None:
        cmd = ["oc", "get", "vmi", "-n", namespace, "-o", "json"]
    else:
        cmd = ["oc", "get", "vmi", "-A", "-o", "json"]
    result = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if result.returncode != 0:
        print(result.stderr or result.stdout, file=sys.stderr)
        return None
    data = json.loads(result.stdout)
    items = data.get("items", [])
    return sum(1 for item in items if item.get("status", {}).get("phase") == "Running")


def list_vmis(namespace: str | None) -> set[tuple[str, str]]:
    """Return a set of (namespace, vmi_name) for all VMIs in scope."""
    if namespace is not None:
        cmd = ["oc", "get", "vmi", "-n", namespace, "-o", "json"]
    else:
        cmd = ["oc", "get", "vmi", "-A", "-o", "json"]
    result = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if result.returncode != 0:
        print(result.stderr or result.stdout, file=sys.stderr)
        return set()
    data = json.loads(result.stdout)
    items = data.get("items", [])
    vmis: set[tuple[str, str]] = set()
    for item in items:
        meta = item.get("metadata", {}) or {}
        ns = meta.get("namespace", "") or ""
        name = meta.get("name", "") or ""
        if ns and name:
            vmis.add((ns, name))
    return vmis


def migration_seconds(item: dict) -> float | None:
    timestamps = item.get("status", {}).get("phaseTransitionTimestamps") or []
    by_phase = {t["phase"]: t["phaseTransitionTimestamp"] for t in timestamps}
    pending = by_phase.get("Pending")
    succeeded = by_phase.get("Succeeded")
    if not pending or not succeeded:
        return None
    t0 = datetime.fromisoformat(pending.replace("Z", "+00:00"))
    t1 = datetime.fromisoformat(succeeded.replace("Z", "+00:00"))
    return (t1 - t0).total_seconds()


def migration_succeeded_and_seconds(item: dict) -> tuple[datetime, float] | None:
    """Return (succeeded_utc, duration_seconds) or None if not available."""
    timestamps = item.get("status", {}).get("phaseTransitionTimestamps") or []
    by_phase = {t["phase"]: t["phaseTransitionTimestamp"] for t in timestamps}
    pending = by_phase.get("Pending")
    succeeded = by_phase.get("Succeeded")
    if not pending or not succeeded:
        return None
    t0 = datetime.fromisoformat(pending.replace("Z", "+00:00"))
    t1 = datetime.fromisoformat(succeeded.replace("Z", "+00:00"))
    return (t1, (t1 - t0).total_seconds())


def parse_iso8601_utc(value: str) -> datetime:
    """
    Parse a UTC timestamp for --start/--end.

    Accepts:
    - ISO-8601 with optional trailing Z or offset (e.g. 2026-03-19T10:00:00Z)
    - Space-separated UTC (e.g. 2026-02-19 17:28:51 or with fractional seconds)
    """
    s = value.strip()
    if not s:
        raise ValueError("empty timestamp")
    for fmt in ("%Y-%m-%d %H:%M:%S", "%Y-%m-%d %H:%M:%S.%f"):
        try:
            return datetime.strptime(s, fmt).replace(tzinfo=timezone.utc)
        except ValueError:
            continue
    dt = datetime.fromisoformat(s.replace("Z", "+00:00"))
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt


def vmim_pending_succeeded_interval(item: dict) -> tuple[datetime, datetime] | None:
    """
    Return (pending_dt, succeeded_dt) from phaseTransitionTimestamps.

    Excludes VMIMs missing either Pending or Succeeded timestamps.
    """
    timestamps = item.get("status", {}).get("phaseTransitionTimestamps") or []
    by_phase = {t["phase"]: t["phaseTransitionTimestamp"] for t in timestamps}
    pending = by_phase.get("Pending")
    succeeded = by_phase.get("Succeeded")
    if not pending or not succeeded:
        return None
    t0 = datetime.fromisoformat(pending.replace("Z", "+00:00"))
    t1 = datetime.fromisoformat(succeeded.replace("Z", "+00:00"))
    return (t0, t1)


def interval_overlaps(
    pending_dt: datetime,
    succeeded_dt: datetime,
    start_dt: datetime | None,
    end_dt: datetime | None,
) -> bool:
    """
    Include VMIM if its [pending_dt, succeeded_dt] interval overlaps [start_dt, end_dt].

    Overlap rule:
      succeeded_dt >= start_dt AND pending_dt <= end_dt
    with open-ended sides supported via None.
    """
    if succeeded_dt < pending_dt:
        return False
    if start_dt is not None and succeeded_dt < start_dt:
        return False
    if end_dt is not None and pending_dt > end_dt:
        return False
    return True


def filter_items_by_time_range(
    items: list[dict],
    start_dt: datetime | None,
    end_dt: datetime | None,
) -> list[dict]:
    """Filter VMIM items by overlap with requested Pending→Succeeded time range."""
    if start_dt is None and end_dt is None:
        return items

    filtered: list[dict] = []
    for item in items:
        interval = vmim_pending_succeeded_interval(item)
        if interval is None:
            continue
        pending_dt, succeeded_dt = interval
        if interval_overlaps(pending_dt, succeeded_dt, start_dt, end_dt):
            filtered.append(item)
    return filtered


def eviction_counts(
    items: list[dict],
    all_vmis: set[tuple[str, str]] | None = None,
) -> list[tuple[str, str, int]]:
    """
    Return a list of (namespace, vmi_name, evacuation_count).

    Only VMIMs with status.phase == "Succeeded" are counted.
    """
    counts: dict[tuple[str, str], int] = {}
    for item in items:
        if vmim_type(item) != "evacuation":
            continue
        status_phase = item.get("status", {}).get("phase")
        if status_phase != "Succeeded":
            continue
        meta = item.get("metadata", {})
        ns = meta.get("namespace", "") or ""
        vmi = workload_name(item)
        key = (ns, vmi)
        counts[key] = counts.get(key, 0) + 1

    # Ensure VMIs with zero evacuations are present when requested
    if all_vmis is not None:
        for key in all_vmis:
            counts.setdefault(key, 0)

    # Sort by count desc, then namespace, then vmi_name
    sorted_items = sorted(
        counts.items(),
        key=lambda kv: (-kv[1], kv[0][0], kv[0][1]),
    )
    return [(ns, vmi, count) for (ns, vmi), count in sorted_items]


def eviction_threshold_summary(
    evict_rows: list[tuple[str, str, int]],
    thresholds: list[int] = [0, 1, 2, 3, 4, 5],
) -> dict[int, int]:
    """
    Given per-VMI evacuation counts, count how many VMIs have evacuation_count == threshold.
    """
    return {t: sum(1 for _, _, c in evict_rows if c == t) for t in thresholds}


def print_migration_summary(items: list[dict], namespace: str | None) -> None:
    """
    Print summary: first/last completion date, total migrations,
    time span in hours (first to last completion), average per hour,
    shortest/longest/median migration time in seconds, running VM count.
    """
    running = count_running_vmis(namespace)
    running_label = str(running) if running is not None else "N/A"

    completed = []
    for item in items:
        pair = migration_succeeded_and_seconds(item)
        if pair is not None:
            t = vmim_type(item)
            completed.append((pair[0], pair[1], t))

    if not completed:
        print("No completed migrations (Pending→Succeeded) to summarize.", file=sys.stderr)
        print(f"  Total running VMs:          {running_label}", file=sys.stderr)
        return

    succeeded_dates = [s for s, _, _ in completed]
    durations_sec = [d for _, d, _ in completed]
    earliest = min(succeeded_dates)
    latest = max(succeeded_dates)
    total_migrations = len(completed)
    span_seconds = (latest - earliest).total_seconds()
    total_hours = span_seconds / 3600.0 if span_seconds > 0 else 0.0
    avg_per_hour = total_migrations / total_hours if total_hours > 0 else total_migrations

    type_counts = Counter(t for _, _, t in completed)
    breakdown = ", ".join(f"{k}: {type_counts.get(k, 0)}" for k in VMIM_SUMMARY_TYPES)

    shortest_sec = min(durations_sec)
    longest_sec = max(durations_sec)
    sorted_d = sorted(durations_sec)
    n = len(sorted_d)
    median_sec = sorted_d[n // 2] if n % 2 else (sorted_d[n // 2 - 1] + sorted_d[n // 2]) / 2.0

    print("Migration summary:", file=sys.stderr)
    print(f"  Total running VMs:                    {running_label}", file=sys.stderr)
    print(f"  Time span (hours):                    {total_hours:.2f}", file=sys.stderr)
    print(f"  Total migrations:                     {total_migrations}  ({breakdown})", file=sys.stderr)
    print(f"  First migration completed:            {earliest.isoformat()}", file=sys.stderr)
    print(f"  Last migration completed:             {latest.isoformat()}", file=sys.stderr)
    print(f"  Average migrations per hour:          {avg_per_hour:.2f}", file=sys.stderr)
    print(f"  Shortest migration duration:          {shortest_sec:.2f} s", file=sys.stderr)
    print(f"  Longest migration duration:           {longest_sec:.2f} s", file=sys.stderr)
    print(f"  Median migration duration:            {median_sec:.2f} s", file=sys.stderr)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Extract VMIM migration statistics (durations, summary, eviction counts)."
    )
    parser.add_argument("--namespace", "-n", default=None, help="Namespace (default: all namespaces)")
    parser.add_argument("--name", "-N", default=None, help="VMIM name (omit to list all VMIMs)")
    parser.add_argument(
        "--output",
        "-o",
        default=None,
        help=(
            "CSV output path. Migration CSV: default stdout; use - for stdout. "
            "Eviction counts (-c): default summary on stderr only; use -o FILE or -o - for per-VMI CSV."
        ),
    )
    parser.add_argument(
        "--start",
        default=None,
        help="Start of time window (UTC): ISO-8601 e.g. 2026-03-19T10:00:00Z or 2026-02-19 17:28:51. Overlap with Pending→Succeeded.",
    )
    parser.add_argument(
        "--end",
        default=None,
        help="End of time window (UTC): ISO-8601 e.g. 2026-03-19T10:00:00Z or 2026-02-19 17:28:51. Overlap with Pending→Succeeded.",
    )
    parser.add_argument(
        "--summary",
        "-s",
        action="store_true",
        help="Print summary (migration stats + total running VMs)",
    )
    parser.add_argument(
        "--csv",
        action="store_true",
        help="Print CSV of VMIM times (Succeeded - Pending) for each VMIM",
    )
    parser.add_argument(
        "--eviction-counts",
        "-c",
        action="store_true",
        help="Eviction summary on stderr (buckets + total); per-VMI CSV only with -o/--output",
    )
    args = parser.parse_args()

    if len(sys.argv) == 1:
        args.summary = True

    if args.namespace is not None and not namespace_exists(args.namespace):
        print(f"Error: namespace '{args.namespace}' does not exist.", file=sys.stderr)
        sys.exit(1)

    data = get_vmim_json(args.namespace, args.name)
    items = data.get("items", [data]) if "items" in data else [data]

    start_dt = None
    end_dt = None
    if args.start is not None:
        try:
            start_dt = parse_iso8601_utc(args.start)
        except ValueError:
            print(
                f"Error: invalid --start '{args.start}'. Use UTC e.g. 2026-03-19T10:00:00Z or 2026-02-19 17:28:51.",
                file=sys.stderr,
            )
            sys.exit(1)
    if args.end is not None:
        try:
            end_dt = parse_iso8601_utc(args.end)
        except ValueError:
            print(
                f"Error: invalid --end '{args.end}'. Use UTC e.g. 2026-03-19T10:00:00Z or 2026-02-19 17:28:51.",
                file=sys.stderr,
            )
            sys.exit(1)

    items = filter_items_by_time_range(items, start_dt=start_dt, end_dt=end_dt)

    # Eviction-counts mode: takes precedence over summary/csv
    if args.eviction_counts:
        # Always include VMIs with zero evacuations by default
        all_vmis = list_vmis(args.namespace)
        evict_rows = eviction_counts(items, all_vmis=all_vmis)
        if not evict_rows:
            sys.exit(1)
        if args.output:
            if args.output == "-":
                out = sys.stdout
                close_out = False
            else:
                out = open(args.output, "w", newline="")
                close_out = True
            try:
                writer = csv.writer(out)
                writer.writerow(["namespace", "vmi_name", "evacuation_count"])
                writer.writerows(evict_rows)
            finally:
                if close_out:
                    out.close()
        thresholds = [0, 1, 2, 3, 4, 5]
        summary = eviction_threshold_summary(evict_rows, thresholds=thresholds)
        print("Eviction count buckets (VMI has evacuation_count == X):", file=sys.stderr)
        print(f"  =0: {summary[0]}", file=sys.stderr)
        print(f"  =1: {summary[1]}", file=sys.stderr)
        print(f"  =2: {summary[2]}", file=sys.stderr)
        print(f"  =3: {summary[3]}", file=sys.stderr)
        print(f"  =4: {summary[4]}", file=sys.stderr)
        print(f"  =5: {summary[5]}", file=sys.stderr)
        # Σ evacuation_count over VMIs == Σ (X × VMIs with evacuation_count == X) for all X (not only 0..5)
        total_evacuations = sum(c for _, _, c in evict_rows)
        bucket_weighted_0_5 = sum(t * summary[t] for t in thresholds)
        print(
            f"  Total (Σ evacuation_count = Σ X × (=X bucket)): {total_evacuations}",
            file=sys.stderr,
        )
        if bucket_weighted_0_5 != total_evacuations:
            print(
                f"  Note: buckets above only cover X=0..5; weighted sum 0..5 = {bucket_weighted_0_5}",
                file=sys.stderr,
            )
        return

    if args.summary:
        print_migration_summary(items, args.namespace)
        return

    all_namespaces = args.namespace is None
    rows = []
    for item in items:
        meta = item.get("metadata", {})
        name = meta.get("name", "")
        ns = meta.get("namespace", "")
        if all_namespaces and ns:
            display_name = f"{ns}/{name}"
        else:
            display_name = name
        typ = vmim_type(item)
        workload = workload_name(item)
        sec = migration_seconds(item)
        sec_str = f"{sec:.2f}" if sec is not None else ""
        rows.append((typ, workload, display_name, sec_str))

    out = open(args.output, "w", newline="") if args.output else sys.stdout
    try:
        writer = csv.writer(out)
        writer.writerow(["type", "workload", "vmim name", "time in seconds"])
        writer.writerows(rows)
    finally:
        if args.output:
            out.close()

    if not rows:
        sys.exit(1)


if __name__ == "__main__":
    main()
