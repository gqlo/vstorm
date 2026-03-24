#!/usr/bin/env python3
"""
Unit tests for monitoring/scripts/migration-stats.py (loaded by path; filename has a hyphen).
Run from repo root: python3 -m unittest discover -s monitoring/tests -v
"""

from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path

_SCRIPT = Path(__file__).resolve().parent.parent / "scripts" / "migration-stats.py"


def _load_migration_stats():
    spec = importlib.util.spec_from_file_location("migration_stats", _SCRIPT)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Cannot load spec for {_SCRIPT}")
    mod = importlib.util.module_from_spec(spec)
    sys.modules["migration_stats"] = mod
    spec.loader.exec_module(mod)
    return mod


ms = _load_migration_stats()


def _vmim(
    *,
    name: str,
    namespace: str,
    vmi_name: str,
    phase: str,
    pending_ts: str,
    succeeded_ts: str,
) -> dict:
    return {
        "metadata": {"name": name, "namespace": namespace},
        "spec": {"vmiName": vmi_name},
        "status": {
            "phase": phase,
            "phaseTransitionTimestamps": [
                {"phase": "Pending", "phaseTransitionTimestamp": pending_ts},
                {"phase": "Succeeded", "phaseTransitionTimestamp": succeeded_ts},
            ],
        },
    }


class TestParseIso8601Utc(unittest.TestCase):
    def test_accepts_z_suffix(self) -> None:
        dt = ms.parse_iso8601_utc("2026-03-19T10:00:00Z")
        self.assertEqual(dt.year, 2026)
        self.assertEqual(dt.month, 3)
        self.assertEqual(dt.day, 19)
        self.assertEqual(dt.hour, 10)

    def test_accepts_space_separated_utc(self) -> None:
        dt = ms.parse_iso8601_utc("2026-02-19 17:28:51")
        self.assertEqual(dt.year, 2026)
        self.assertEqual(dt.month, 2)
        self.assertEqual(dt.day, 19)
        self.assertEqual(dt.hour, 17)
        self.assertEqual(dt.minute, 28)
        self.assertEqual(dt.second, 51)
        self.assertIsNotNone(dt.tzinfo)

    def test_strips_whitespace(self) -> None:
        dt = ms.parse_iso8601_utc("  2026-02-19 17:28:51  ")
        self.assertEqual(dt.hour, 17)


class TestIntervalOverlaps(unittest.TestCase):
    def test_overlap_inside_window(self) -> None:
        p = ms.parse_iso8601_utc("2026-03-19T10:00:00Z")
        s = ms.parse_iso8601_utc("2026-03-19T10:30:00Z")
        start = ms.parse_iso8601_utc("2026-03-19T09:00:00Z")
        end = ms.parse_iso8601_utc("2026-03-19T11:00:00Z")
        self.assertTrue(ms.interval_overlaps(p, s, start, end))

    def test_touch_start_boundary_included(self) -> None:
        p = ms.parse_iso8601_utc("2026-03-19T09:00:00Z")
        s = ms.parse_iso8601_utc("2026-03-19T10:00:00Z")
        start = ms.parse_iso8601_utc("2026-03-19T10:00:00Z")
        end = ms.parse_iso8601_utc("2026-03-19T12:00:00Z")
        self.assertTrue(ms.interval_overlaps(p, s, start, end))

    def test_before_start_excluded(self) -> None:
        p = ms.parse_iso8601_utc("2026-03-19T08:00:00Z")
        s = ms.parse_iso8601_utc("2026-03-19T09:59:59Z")
        start = ms.parse_iso8601_utc("2026-03-19T10:00:00Z")
        end = ms.parse_iso8601_utc("2026-03-19T12:00:00Z")
        self.assertFalse(ms.interval_overlaps(p, s, start, end))

    def test_touch_end_boundary_included(self) -> None:
        p = ms.parse_iso8601_utc("2026-03-19T11:00:00Z")
        s = ms.parse_iso8601_utc("2026-03-19T12:00:00Z")
        start = ms.parse_iso8601_utc("2026-03-19T10:00:00Z")
        end = ms.parse_iso8601_utc("2026-03-19T11:00:00Z")
        self.assertTrue(ms.interval_overlaps(p, s, start, end))

    def test_after_end_excluded(self) -> None:
        p = ms.parse_iso8601_utc("2026-03-19T11:00:01Z")
        s = ms.parse_iso8601_utc("2026-03-19T12:00:00Z")
        start = ms.parse_iso8601_utc("2026-03-19T10:00:00Z")
        end = ms.parse_iso8601_utc("2026-03-19T11:00:00Z")
        self.assertFalse(ms.interval_overlaps(p, s, start, end))

    def test_open_start_only_end(self) -> None:
        p = ms.parse_iso8601_utc("2026-03-19T10:00:00Z")
        s = ms.parse_iso8601_utc("2026-03-19T11:00:00Z")
        end = ms.parse_iso8601_utc("2026-03-19T10:30:00Z")
        self.assertTrue(ms.interval_overlaps(p, s, None, end))

    def test_open_end_only_start(self) -> None:
        p = ms.parse_iso8601_utc("2026-03-19T10:00:00Z")
        s = ms.parse_iso8601_utc("2026-03-19T11:00:00Z")
        start = ms.parse_iso8601_utc("2026-03-19T10:45:00Z")
        self.assertTrue(ms.interval_overlaps(p, s, start, None))

    def test_inverted_pending_succeeded_false(self) -> None:
        p = ms.parse_iso8601_utc("2026-03-19T12:00:00Z")
        s = ms.parse_iso8601_utc("2026-03-19T10:00:00Z")
        start = ms.parse_iso8601_utc("2026-03-19T09:00:00Z")
        end = ms.parse_iso8601_utc("2026-03-19T13:00:00Z")
        self.assertFalse(ms.interval_overlaps(p, s, start, end))


class TestFilterItemsByTimeRange(unittest.TestCase):
    def test_no_bounds_returns_same_list(self) -> None:
        items = [_vmim(name="x", namespace="ns", vmi_name="v", phase="Succeeded", pending_ts="2026-01-01T00:00:00Z", succeeded_ts="2026-01-01T01:00:00Z")]
        self.assertIs(ms.filter_items_by_time_range(items, None, None), items)

    def test_filters_by_overlap(self) -> None:
        in_window = _vmim(
            name="kubevirt-evacuation-a",
            namespace="ns1",
            vmi_name="vm1",
            phase="Succeeded",
            pending_ts="2026-03-19T10:00:00Z",
            succeeded_ts="2026-03-19T10:05:00Z",
        )
        out_window = _vmim(
            name="kubevirt-evacuation-b",
            namespace="ns1",
            vmi_name="vm2",
            phase="Succeeded",
            pending_ts="2026-03-19T12:00:00Z",
            succeeded_ts="2026-03-19T12:05:00Z",
        )
        start = ms.parse_iso8601_utc("2026-03-19T09:00:00Z")
        end = ms.parse_iso8601_utc("2026-03-19T11:00:00Z")
        got = ms.filter_items_by_time_range([in_window, out_window], start, end)
        self.assertEqual(got, [in_window])

    def test_missing_timestamps_excluded(self) -> None:
        item = {
            "metadata": {"name": "kubevirt-evacuation-x", "namespace": "ns"},
            "spec": {"vmiName": "vm"},
            "status": {"phase": "Succeeded", "phaseTransitionTimestamps": []},
        }
        start = ms.parse_iso8601_utc("2026-03-19T09:00:00Z")
        end = ms.parse_iso8601_utc("2026-03-19T11:00:00Z")
        self.assertEqual(ms.filter_items_by_time_range([item], start, end), [])


class TestEvictionCounts(unittest.TestCase):
    def test_counts_only_succeeded_evacuation(self) -> None:
        e1 = _vmim(
            name="kubevirt-evacuation-1",
            namespace="ns",
            vmi_name="vmi-a",
            phase="Succeeded",
            pending_ts="2026-01-01T00:00:00Z",
            succeeded_ts="2026-01-01T01:00:00Z",
        )
        e2 = _vmim(
            name="kubevirt-evacuation-2",
            namespace="ns",
            vmi_name="vmi-a",
            phase="Succeeded",
            pending_ts="2026-01-02T00:00:00Z",
            succeeded_ts="2026-01-02T01:00:00Z",
        )
        pending = _vmim(
            name="kubevirt-evacuation-3",
            namespace="ns",
            vmi_name="vmi-a",
            phase="Pending",
            pending_ts="2026-01-03T00:00:00Z",
            succeeded_ts="2026-01-03T01:00:00Z",
        )
        migrate = _vmim(
            name="kubevirt-migrate-x",
            namespace="ns",
            vmi_name="vmi-b",
            phase="Succeeded",
            pending_ts="2026-01-01T00:00:00Z",
            succeeded_ts="2026-01-01T01:00:00Z",
        )
        rows = ms.eviction_counts([e1, e2, pending, migrate], all_vmis=None)
        self.assertEqual(rows, [("ns", "vmi-a", 2)])

    def test_all_vmis_adds_zeros(self) -> None:
        e = _vmim(
            name="kubevirt-evacuation-1",
            namespace="ns",
            vmi_name="vmi-a",
            phase="Succeeded",
            pending_ts="2026-01-01T00:00:00Z",
            succeeded_ts="2026-01-01T01:00:00Z",
        )
        all_vmis = {("ns", "vmi-a"), ("ns", "vmi-b")}
        rows = ms.eviction_counts([e], all_vmis=all_vmis)
        self.assertIn(("ns", "vmi-a", 1), rows)
        self.assertIn(("ns", "vmi-b", 0), rows)


class TestEvictionThresholdSummary(unittest.TestCase):
    def test_equality_buckets(self) -> None:
        rows = [("ns", "a", 0), ("ns", "b", 1), ("ns", "c", 1), ("ns", "d", 5)]
        s = ms.eviction_threshold_summary(rows, thresholds=[0, 1, 2, 3, 4, 5])
        self.assertEqual(s[0], 1)
        self.assertEqual(s[1], 2)
        self.assertEqual(s[5], 1)

    def test_weighted_bucket_sum_matches_total_when_counts_le_5(self) -> None:
        rows = [("ns", "a", 0), ("ns", "b", 1), ("ns", "c", 1), ("ns", "d", 5)]
        thresholds = [0, 1, 2, 3, 4, 5]
        s = ms.eviction_threshold_summary(rows, thresholds=thresholds)
        total = sum(c for _, _, c in rows)
        weighted = sum(t * s[t] for t in thresholds)
        self.assertEqual(weighted, total)
        self.assertEqual(total, 7)  # 0 + 1 + 1 + 5

    def test_weighted_0_5_can_differ_when_count_gt_5(self) -> None:
        rows = [("ns", "a", 6)]
        thresholds = [0, 1, 2, 3, 4, 5]
        s = ms.eviction_threshold_summary(rows, thresholds=thresholds)
        total = sum(c for _, _, c in rows)
        weighted = sum(t * s[t] for t in thresholds)
        self.assertEqual(total, 6)
        self.assertEqual(weighted, 0)


if __name__ == "__main__":
    unittest.main()
