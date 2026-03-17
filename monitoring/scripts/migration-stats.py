#!/usr/bin/env python3
"""
Extract VMIM migration time (Succeeded - Pending phaseTransitionTimestamp) in seconds.
Differentiates evacuation (kubevirt-evacuation-*), workload (workload*), migration (kubevirt-migrate*).
Output: CSV with columns "type, workload, vmim name, time in seconds".

Usage:
  # No arguments: print summary only (all namespaces)
  python migration-stats.py

  # CSV of VMIM times (stdout or --output)
  python migration-stats.py --csv [--output out.csv]
  python migration-stats.py --namespace NAMESPACE [--output out.csv]
  python migration-stats.py --name VMIM_NAME [--namespace NAMESPACE] [--output out.csv]

  # Summary explicitly
  python migration-stats.py --summary [-n NAMESPACE]

Requires: oc in PATH, cluster access.
"""

import argparse
import csv
import json
import subprocess
import sys
from collections import Counter
from datetime import datetime


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
    parser = argparse.ArgumentParser(description="Extract VMIM migration time (Succeeded - Pending) in seconds")
    parser.add_argument("--namespace", "-n", default=None, help="Namespace (default: all namespaces)")
    parser.add_argument("--name", "-N", default=None, help="VMIM name (omit to list all VMIMs)")
    parser.add_argument("--output", "-o", default=None, help="Output CSV path (default: stdout)")
    parser.add_argument("--summary", "-s", action="store_true", help="Print summary (migrations stats + total running VMs)")
    parser.add_argument("--csv", action="store_true", help="Print CSV of VMIM times (required for full listing with no other flags)")
    args = parser.parse_args()

    if len(sys.argv) == 1:
        args.summary = True

    if args.namespace is not None and not namespace_exists(args.namespace):
        print(f"Error: namespace '{args.namespace}' does not exist.", file=sys.stderr)
        sys.exit(1)

    data = get_vmim_json(args.namespace, args.name)
    items = data.get("items", [data]) if "items" in data else [data]

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
