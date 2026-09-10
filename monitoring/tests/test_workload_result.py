#!/usr/bin/env python3
"""
Unit tests for monitoring/data-collector/serve.py (loaded by path).
Run from repo root: python3 -m unittest discover -s monitoring/tests -v
"""

from __future__ import annotations

import importlib.util
import json
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer
from pathlib import Path

_SERVE = Path(__file__).resolve().parent.parent / "data-collector" / "serve.py"


def _load_serve():
    spec = importlib.util.spec_from_file_location("workload_result_serve", _SERVE)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Cannot load spec for {_SERVE}")
    mod = importlib.util.module_from_spec(spec)
    sys.modules["workload_result_serve"] = mod
    spec.loader.exec_module(mod)
    return mod


wr = _load_serve()


def _fio_payload(
    *,
    batch_id: str = "b1",
    vm: str = "vm1",
    cycle: int = 1,
    iops: float = 1000.0,
    bw: float = 4096000.0,
    fio_rc: int = 0,
    status: str = "ok",
) -> dict:
    return {
        "schema_version": 1,
        "record_type": "result",
        "source": "guest",
        "workload_kind": "fio",
        "status": status,
        "error_message": None if status == "ok" else "fio failed",
        "fio_start": "2026-07-22T05:50:50Z",
        "fio_stop": "2026-07-22T05:52:00Z",
        "reported_at": "2026-07-22T05:52:03Z",
        "boot_timestamp": "2026-07-22T05:50:25Z",
        "service_start": "2026-07-22T05:50:25Z",
        "hostname": vm,
        "batch_id": batch_id,
        "vm_name": vm,
        "cycle": cycle,
        "job_name": f"job{cycle}",
        "cpu_count": 4,
        "mem_total_kb": 8000000,
        "fio_command": ["fio", f"--name=job{cycle}"],
        "fio_rc": fio_rc,
        "fio_group_reporting": {
            "jobs": [
                {
                    "read": {
                        "iops": iops / 2,
                        "bw_bytes": bw / 2,
                        "lat_ns": {"mean": 1000.0},
                    },
                    "write": {
                        "iops": iops / 2,
                        "bw_bytes": bw / 2,
                        "lat_ns": {"mean": 2000.0},
                    },
                }
            ]
        },
        "workload": {
            "WORKLOAD_TYPE": "randrw",
            "FIO_SIZE": "1G",
            "FIO_BS": "4k",
            "FIO_IODEPTH": "16",
            "FIO_NUMJOBS": "1",
            "FIO_DIRECT": "1",
            "FIO_RW": "randrw",
        },
    }


class TestHelpers(unittest.TestCase):
    def test_normalize_record_type_aliases(self) -> None:
        self.assertEqual(wr._normalize_record_type("batch"), "manifest")
        self.assertEqual(wr._normalize_record_type("cycle"), "result")
        self.assertEqual(wr._normalize_record_type("event"), "error")
        self.assertEqual(wr._normalize_record_type("status"), "heartbeat")
        self.assertEqual(wr._normalize_record_type("manifest"), "manifest")
        self.assertEqual(wr._normalize_record_type("result"), "result")

    def test_type_predicates(self) -> None:
        self.assertTrue(wr._is_manifest("batch"))
        self.assertTrue(wr._is_result("cycle"))
        self.assertTrue(wr._is_error("event"))
        self.assertTrue(wr._is_heartbeat("status"))

    def test_coerce_unix_iso_and_int(self) -> None:
        u = wr._coerce_unix("2026-07-22T05:52:03Z")
        self.assertIsNotNone(u)
        self.assertEqual(wr._coerce_unix("2026-07-22T05:52:03+00:00"), u)
        self.assertEqual(wr._coerce_unix(u), u)
        self.assertEqual(wr._coerce_unix(str(u)), u)
        self.assertIsNone(wr._coerce_unix("not-a-time"))
        self.assertIsNone(wr._coerce_unix(None))

    def test_filename_timestamp_prefers_iso(self) -> None:
        name = wr._filename_timestamp({"reported_at": "2026-07-22T05:52:03Z"}, 0)
        self.assertEqual(name, "2026-07-22T05-52-03Z")

    def test_extract_fio_metrics(self) -> None:
        iops, bw, lat = wr.extract_fio_metrics(_fio_payload())
        self.assertEqual(iops, 1000.0)
        self.assertEqual(bw, 4096000.0)
        self.assertEqual(lat, 1500.0)

    def test_extract_fio_metrics_missing(self) -> None:
        self.assertEqual(wr.extract_fio_metrics({}), (None, None, None))

    def test_workload_fingerprint(self) -> None:
        self.assertEqual(wr.workload_fingerprint(_fio_payload()), "randrw/1G/4k")
        self.assertEqual(
            wr.workload_fingerprint({"cloudinit": "workload/cloudinit-fio-workload.yaml"}),
            "workload/cloudinit-fio-workload.yaml",
        )

    def test_percentile(self) -> None:
        self.assertIsNone(wr.percentile([], 50))
        self.assertEqual(wr.percentile([10.0], 50), 10.0)
        self.assertEqual(wr.percentile([1.0, 2.0, 3.0, 4.0], 50), 2.5)

    def test_safe_name(self) -> None:
        self.assertEqual(wr._safe_name("vm/name:1"), "vm_name_1")
        self.assertEqual(wr._safe_name("..."), "unknown")

    def test_manifest_summary_strips_heavy_keys(self) -> None:
        summary = wr._manifest_summary(
            {
                "batch_id": "b1",
                "cluster": {"api_server": "https://api.example:6443"},
                "vms": ["ns/a"],
                "vm_dv_created": {"a": "2026-07-22T05:49:00Z"},
                "dv_created": ["x", "y"],
                "pvc_created": ["p"],
                "snapshots": ["s"],
                "cmdline": ["./vstorm"],
            }
        )
        self.assertEqual(summary["batch_id"], "b1")
        self.assertEqual(summary["cmdline"], ["./vstorm"])
        self.assertEqual(summary["dv_count"], 2)
        self.assertEqual(summary["pvc_count"], 1)
        self.assertEqual(summary["snapshot_count"], 1)
        self.assertNotIn("vms", summary)
        self.assertNotIn("vm_dv_created", summary)
        self.assertNotIn("dv_created", summary)

    def test_unix_map_from_payload(self) -> None:
        self.assertEqual(wr._unix_map_from_payload(None, "vm_dv_created"), {})
        self.assertEqual(wr._unix_map_from_payload({"vm_dv_created": "bad"}, "vm_dv_created"), {})
        got = wr._unix_map_from_payload(
            {"vm_dv_created": {"vm1": "2026-07-22T05:49:00Z", "vm2": "nope"}},
            "vm_dv_created",
        )
        self.assertEqual(set(got), {"vm1"})
        self.assertEqual(got["vm1"], 1784699340)


class TestStoreIngest(unittest.TestCase):
    def setUp(self) -> None:
        self._td = tempfile.TemporaryDirectory()
        self.store = wr.Store(Path(self._td.name))

    def tearDown(self) -> None:
        self.store._conn.close()
        self._td.cleanup()

    def test_manifest_writes_manifest_json_and_normalizes_legacy_batch(self) -> None:
        r = self.store.ingest(
            {
                "schema_version": 1,
                "record_type": "batch",
                "source": "vstorm",
                "batch_id": "m1",
                "basename": "rhel9",
                "total_vms": 2,
                "total_namespaces": 1,
                "vms": ["ns/vm1", "ns/vm2"],
                "reported_at": "2026-07-22T05:50:00Z",
                "started_at": "2026-07-22T05:48:20Z",
                "stopped_at": "2026-07-22T05:50:00Z",
                "cloudinit": "workload/cloudinit-fio-workload.yaml",
                "cores": 4,
                "memory": "8Gi",
            }
        )
        path = Path(self._td.name) / r["file_path"]
        self.assertTrue(path.exists())
        self.assertEqual(path.name, "manifest.json")
        payload = json.loads(path.read_text(encoding="utf-8"))
        self.assertEqual(payload["record_type"], "manifest")
        batch = self.store.get_batch("m1")
        self.assertIsNotNone(batch)
        assert batch is not None
        self.assertEqual(batch["basename"], "rhel9")
        self.assertEqual(batch["total_vms"], 2)
        self.assertEqual(batch["batch_payload"]["record_type"], "manifest")

    def test_result_file_prefix_and_metrics_indexed(self) -> None:
        r = self.store.ingest(_fio_payload(batch_id="r1", cycle=2))
        path = Path(self._td.name) / r["file_path"]
        self.assertTrue(path.name.startswith("result-vm1-2-"))
        self.assertIn("2026-07-22T05-52-03Z", path.name)
        batch = self.store.get_batch("r1")
        assert batch is not None
        self.assertEqual(batch["cycle_count"], 1)
        self.assertAlmostEqual(batch["iops_avg"], 1000.0)
        vms = {v["vm_name"]: v for v in batch["vms"]}
        # ISO boot_timestamp must be indexed (not only boot_timestamp_unix)
        self.assertEqual(vms["vm1"]["boot_timestamp_unix"], 1784699425)

    def test_legacy_cycle_event_status_normalized(self) -> None:
        cases = [
            ("cycle", "result", "result-"),
            ("event", "error", "error-"),
            ("status", "heartbeat", "heartbeat-"),
        ]
        for legacy, expected, prefix in cases:
            payload = {
                "schema_version": 1,
                "record_type": legacy,
                "source": "guest",
                "workload_kind": "fio",
                "batch_id": "leg",
                "vm_name": "vmx",
                "hostname": "vmx",
                "reported_at": "2026-07-22T05:52:03Z",
                "agent_state": "idle",
                "status": "post_error" if legacy == "event" else "ok",
                "cycle": 1,
            }
            r = self.store.ingest(payload)
            stored = json.loads(
                (Path(self._td.name) / r["file_path"]).read_text(encoding="utf-8")
            )
            self.assertEqual(stored["record_type"], expected)
            self.assertTrue(Path(r["file_path"]).name.startswith(prefix))

    def test_error_and_heartbeat_do_not_count_as_cycles(self) -> None:
        self.store.ingest(_fio_payload(batch_id="e1"))
        self.store.ingest(
            {
                "schema_version": 1,
                "record_type": "error",
                "source": "guest",
                "workload_kind": "fio",
                "batch_id": "e1",
                "vm_name": "vm1",
                "status": "post_error",
                "reported_at": "2026-07-22T05:53:00Z",
                "cycle": 1,
            }
        )
        self.store.ingest(
            {
                "schema_version": 1,
                "record_type": "heartbeat",
                "source": "guest",
                "workload_kind": "fio",
                "batch_id": "e1",
                "vm_name": "vm1",
                "agent_state": "idle",
                "reported_at": "2026-07-22T05:54:00Z",
            }
        )
        batch = self.store.get_batch("e1")
        assert batch is not None
        self.assertEqual(batch["cycle_count"], 1)
        self.assertEqual(batch["event_count"], 1)

    def test_boot_heartbeat_indexes_boot_timestamp_without_result(self) -> None:
        self.store.ingest(
            {
                "schema_version": 1,
                "record_type": "manifest",
                "source": "vstorm",
                "batch_id": "boot1",
                "basename": "rhel9",
                "total_vms": 1,
                "total_namespaces": 1,
                "started_at": "2026-07-22T05:48:00Z",
                "reported_at": "2026-07-22T05:50:00Z",
                "vms": ["ns1/vm-boot"],
            }
        )
        self.store.ingest(
            {
                "schema_version": 1,
                "record_type": "heartbeat",
                "source": "guest",
                "workload_kind": "boot",
                "status": "booted",
                "agent_state": "booted",
                "batch_id": "boot1",
                "vm_name": "vm-boot",
                "hostname": "vm-boot",
                "boot_timestamp": "2026-07-22T05:50:25Z",
                "reported_at": "2026-07-22T05:50:26Z",
            }
        )
        batch = self.store.get_batch("boot1")
        assert batch is not None
        self.assertEqual(batch["cycle_count"], 0)
        vms = {v["vm_name"]: v for v in batch["vms"]}
        self.assertEqual(vms["vm-boot"]["boot_timestamp_unix"], 1784699425)
        vm = self.store.get_vm("boot1", "vm-boot")
        assert vm is not None
        self.assertEqual(vm["identity"]["boot_timestamp_unix"], 1784699425)
        self.assertEqual(vm["cycle_count"], 0)

    def test_manifest_dv_created_exposed_on_batch_and_vms(self) -> None:
        self.store.ingest(
            {
                "schema_version": 1,
                "record_type": "manifest",
                "source": "vstorm",
                "batch_id": "dv1",
                "basename": "rhel9",
                "total_vms": 2,
                "total_namespaces": 1,
                "started_at": "2026-07-22T05:48:00Z",
                "base_dv_created_at": "2026-07-22T05:48:30Z",
                "base_dv_ready_at": "2026-07-22T05:48:40Z",
                "base_dv_bound_at": "2026-07-22T05:48:41Z",
                "snapshot_created_at": "2026-07-22T05:48:50Z",
                "snapshot_ready_at": "2026-07-22T05:48:55Z",
                "dv_created_at": "2026-07-22T05:49:00Z",
                "dv_ready_at": "2026-07-22T05:49:02Z",
                "vm_dv_created": {
                    "rhel9-dv1-1": "2026-07-22T05:49:10Z",
                    "rhel9-dv1-2": "2026-07-22T05:49:20Z",
                },
                "vm_dv_ready": {
                    "rhel9-dv1-1": "2026-07-22T05:49:12Z",
                    "rhel9-dv1-2": "2026-07-22T05:49:22Z",
                },
                "pvc_created_at": "2026-07-22T05:49:05Z",
                "pvc_bound_at": "2026-07-22T05:49:06Z",
                "vm_pvc_created": {
                    "rhel9-dv1-1": "2026-07-22T05:49:12Z",
                    "rhel9-dv1-2": "2026-07-22T05:49:22Z",
                },
                "vm_pvc_bound": {
                    "rhel9-dv1-1": "2026-07-22T05:49:13Z",
                    "rhel9-dv1-2": "2026-07-22T05:49:23Z",
                },
                "vm_data_dv_created": {
                    "rhel9-dv1-1": "2026-07-22T05:49:14Z",
                    "rhel9-dv1-2": "2026-07-22T05:49:24Z",
                },
                "vm_data_dv_ready": {
                    "rhel9-dv1-1": "2026-07-22T05:49:14Z",
                    "rhel9-dv1-2": "2026-07-22T05:49:24Z",
                },
                "vm_data_pvc_created": {
                    "rhel9-dv1-1": "2026-07-22T05:49:15Z",
                    "rhel9-dv1-2": "2026-07-22T05:49:25Z",
                },
                "vm_data_pvc_bound": {
                    "rhel9-dv1-1": "2026-07-22T05:49:16Z",
                    "rhel9-dv1-2": "2026-07-22T05:49:26Z",
                },
                "dv_created": [
                    {
                        "namespace": "ns1",
                        "name": "rhel9-base",
                        "created_at": "2026-07-22T05:48:30Z",
                        "role": "base",
                    },
                    {
                        "namespace": "ns1",
                        "name": "rhel9-dv1-1",
                        "created_at": "2026-07-22T05:49:10Z",
                        "role": "root",
                    },
                    {
                        "namespace": "ns1",
                        "name": "rhel9-dv1-2",
                        "created_at": "2026-07-22T05:49:20Z",
                        "role": "root",
                    },
                ],
                "pvc_created": [
                    {
                        "namespace": "ns1",
                        "name": "rhel9-dv1-1",
                        "created_at": "2026-07-22T05:49:12Z",
                        "role": "root",
                    },
                    {
                        "namespace": "ns1",
                        "name": "rhel9-dv1-2",
                        "created_at": "2026-07-22T05:49:22Z",
                        "role": "root",
                    },
                ],
                "snapshots": [
                    {
                        "namespace": "ns1",
                        "name": "rhel9-snap",
                        "created_at": "2026-07-22T05:48:50Z",
                        "ready": True,
                    }
                ],
                "reported_at": "2026-07-22T05:50:00Z",
                "vms": ["ns1/rhel9-dv1-1", "ns1/rhel9-dv1-2"],
            }
        )
        batch = self.store.get_batch("dv1")
        assert batch is not None
        self.assertEqual(batch["base_dv_created_at"], 1784699310)
        self.assertEqual(batch["base_dv_ready_at"], 1784699320)
        self.assertEqual(batch["base_dv_bound_at"], 1784699321)
        self.assertEqual(batch["snapshot_created_at"], 1784699330)
        self.assertEqual(batch["snapshot_ready_at"], 1784699335)
        self.assertEqual(batch["dv_count"], 3)
        self.assertEqual(batch["pvc_count"], 2)
        self.assertEqual(batch["snapshot_count"], 1)
        self.assertEqual(batch["total_vms"], 2)
        self.assertEqual(batch["dv_created_at"], 1784699340)
        self.assertEqual(batch["dv_ready_at"], 1784699342)
        self.assertEqual(batch["pvc_created_at"], 1784699345)
        self.assertEqual(batch["pvc_bound_at"], 1784699346)
        vms = {v["vm_name"]: v for v in batch["vms"]}
        self.assertEqual(vms["rhel9-dv1-1"]["base_dv_created_at_unix"], 1784699310)
        self.assertEqual(vms["rhel9-dv1-1"]["base_dv_ready_at_unix"], 1784699320)
        self.assertEqual(vms["rhel9-dv1-1"]["base_dv_bound_at_unix"], 1784699321)
        self.assertEqual(vms["rhel9-dv1-1"]["snapshot_created_at_unix"], 1784699330)
        self.assertEqual(vms["rhel9-dv1-1"]["snapshot_ready_at_unix"], 1784699335)
        self.assertEqual(vms["rhel9-dv1-2"]["base_dv_created_at_unix"], 1784699310)
        self.assertEqual(vms["rhel9-dv1-2"]["snapshot_ready_at_unix"], 1784699335)
        self.assertEqual(vms["rhel9-dv1-1"]["dv_created_at_unix"], 1784699350)
        self.assertEqual(vms["rhel9-dv1-2"]["dv_created_at_unix"], 1784699360)
        self.assertEqual(vms["rhel9-dv1-1"]["dv_ready_at_unix"], 1784699352)
        self.assertEqual(vms["rhel9-dv1-2"]["dv_ready_at_unix"], 1784699362)
        self.assertEqual(vms["rhel9-dv1-1"]["pvc_created_at_unix"], 1784699352)
        self.assertEqual(vms["rhel9-dv1-2"]["pvc_created_at_unix"], 1784699362)
        self.assertEqual(vms["rhel9-dv1-1"]["pvc_bound_at_unix"], 1784699353)
        self.assertEqual(vms["rhel9-dv1-2"]["pvc_bound_at_unix"], 1784699363)
        self.assertEqual(vms["rhel9-dv1-1"]["data_dv_created_at_unix"], 1784699354)
        self.assertEqual(vms["rhel9-dv1-2"]["data_dv_created_at_unix"], 1784699364)
        self.assertEqual(vms["rhel9-dv1-1"]["data_dv_ready_at_unix"], 1784699354)
        self.assertEqual(vms["rhel9-dv1-2"]["data_dv_ready_at_unix"], 1784699364)
        self.assertEqual(vms["rhel9-dv1-1"]["data_pvc_created_at_unix"], 1784699355)
        self.assertEqual(vms["rhel9-dv1-2"]["data_pvc_created_at_unix"], 1784699365)
        self.assertEqual(vms["rhel9-dv1-1"]["data_pvc_bound_at_unix"], 1784699356)
        self.assertEqual(vms["rhel9-dv1-2"]["data_pvc_bound_at_unix"], 1784699366)

    def test_manifest_without_base_or_snapshot_leaves_fields_none(self) -> None:
        self.store.ingest(
            {
                "schema_version": 1,
                "record_type": "manifest",
                "source": "vstorm",
                "batch_id": "nobase",
                "basename": "rhel9",
                "total_vms": 1,
                "started_at": "2026-07-22T05:48:00Z",
                "dv_created_at": "2026-07-22T05:49:00Z",
                "vm_dv_created": {"rhel9-nobase-1": "2026-07-22T05:49:10Z"},
                "reported_at": "2026-07-22T05:50:00Z",
                "vms": ["ns1/rhel9-nobase-1"],
            }
        )
        batch = self.store.get_batch("nobase")
        assert batch is not None
        self.assertIsNone(batch["base_dv_created_at"])
        self.assertIsNone(batch["base_dv_ready_at"])
        self.assertIsNone(batch["base_dv_bound_at"])
        self.assertIsNone(batch["snapshot_created_at"])
        self.assertIsNone(batch["snapshot_ready_at"])
        self.assertIsNone(batch["dv_count"])
        self.assertIsNone(batch["pvc_count"])
        self.assertIsNone(batch["snapshot_count"])
        vm = batch["vms"][0]
        self.assertIsNone(vm["base_dv_created_at_unix"])
        self.assertIsNone(vm["snapshot_created_at_unix"])
        self.assertEqual(vm["dv_created_at_unix"], 1784699350)

    def test_ingest_requires_batch_id(self) -> None:
        with self.assertRaises(ValueError):
            self.store.ingest({"record_type": "result", "source": "guest"})

    def test_list_results_filter_includes_legacy_alias(self) -> None:
        self.store.ingest(_fio_payload(batch_id="f1", cycle=1))
        # Simulate a pre-rename row still labeled cycle
        with self.store._lock:
            self.store._conn.execute(
                """
                UPDATE results SET record_type = 'cycle'
                WHERE batch_id = 'f1'
                """
            )
            self.store._conn.commit()
        listed = self.store.list_results("f1", record_type="result")
        self.assertEqual(listed["total"], 1)


class TestStorePolicy(unittest.TestCase):
    def setUp(self) -> None:
        self._td = tempfile.TemporaryDirectory()
        self.store = wr.Store(Path(self._td.name))

    def tearDown(self) -> None:
        self.store._conn.close()
        self._td.cleanup()

    def test_get_policy_creates_from_defaults(self) -> None:
        p = self.store.get_policy(
            "p1", "vm1", default_mode="count", default_remaining=3
        )
        self.assertEqual(p["mode"], "count")
        self.assertEqual(p["remaining"], 3)
        self.assertTrue(p["run"])
        self.assertEqual(p["revision"], 1)

    def test_once_stored_as_count_remaining_one(self) -> None:
        p = self.store.set_policy("p1", "vm1", mode="once")
        self.assertEqual(p["mode"], "count")
        self.assertEqual(p["remaining"], 1)
        self.assertTrue(p["run"])

    def test_stop_collapses_to_idle(self) -> None:
        self.store.set_policy("p1", "vm1", mode="forever")
        p = self.store.set_policy("p1", "vm1", mode="stop")
        self.assertEqual(p["mode"], "idle")
        self.assertEqual(p["remaining"], 0)
        self.assertFalse(p["run"])

    def test_result_ingest_decrements_remaining(self) -> None:
        self.store.set_policy("p1", "vm1", mode="count", remaining=2)
        self.store.ingest(_fio_payload(batch_id="p1", vm="vm1", cycle=1))
        p = self.store.get_policy("p1", "vm1")
        self.assertEqual(p["mode"], "count")
        self.assertEqual(p["remaining"], 1)
        self.store.ingest(_fio_payload(batch_id="p1", vm="vm1", cycle=2))
        p = self.store.get_policy("p1", "vm1")
        self.assertEqual(p["mode"], "idle")
        self.assertEqual(p["remaining"], 0)
        self.assertFalse(p["run"])

    def test_heartbeat_does_not_decrement(self) -> None:
        self.store.set_policy("p1", "vm1", mode="count", remaining=2)
        self.store.ingest(
            {
                "schema_version": 1,
                "record_type": "heartbeat",
                "source": "guest",
                "workload_kind": "fio",
                "batch_id": "p1",
                "vm_name": "vm1",
                "agent_state": "running",
                "reported_at": "2026-07-22T05:52:03Z",
            }
        )
        p = self.store.get_policy("p1", "vm1")
        self.assertEqual(p["remaining"], 2)
        self.assertEqual(p["agent_state"], "running")

    def test_result_clears_running_agent_state(self) -> None:
        self.store.set_policy("p1", "vm1", mode="idle", remaining=0)
        self.store.ingest(
            {
                "schema_version": 1,
                "record_type": "heartbeat",
                "source": "guest",
                "workload_kind": "fio",
                "batch_id": "p1",
                "vm_name": "vm1",
                "agent_state": "running",
                "reported_at": "2026-07-22T05:52:03Z",
            }
        )
        self.assertEqual(self.store.get_policy("p1", "vm1")["agent_state"], "running")
        self.store.ingest(_fio_payload(batch_id="p1", vm="vm1", cycle=1, status="ok"))
        self.assertEqual(self.store.get_policy("p1", "vm1")["agent_state"], "idle")
        self.store.ingest(
            {
                "schema_version": 1,
                "record_type": "heartbeat",
                "source": "guest",
                "workload_kind": "fio",
                "batch_id": "p1",
                "vm_name": "vm1",
                "agent_state": "running",
                "reported_at": "2026-07-22T05:53:03Z",
            }
        )
        self.store.ingest(_fio_payload(batch_id="p1", vm="vm1", cycle=2, status="fio_error"))
        self.assertEqual(self.store.get_policy("p1", "vm1")["agent_state"], "error")

    def test_heartbeat_vmi_phase_in_summary(self) -> None:
        self.store.ingest(
            {
                "schema_version": 1,
                "record_type": "manifest",
                "source": "vstorm",
                "batch_id": "vmi1",
                "basename": "rhel9",
                "total_vms": 2,
                "vms": ["ns/vm-a", "ns/vm-b"],
                "reported_at": "2026-07-22T05:50:00Z",
                "started_at": "2026-07-22T05:48:20Z",
                "stopped_at": "2026-07-22T05:50:00Z",
            }
        )
        detail = self.store.get_batch("vmi1")
        self.assertIsNone(detail["vm_summary"]["vmi_running"])
        self.store.ingest(
            {
                "schema_version": 1,
                "record_type": "heartbeat",
                "source": "vstorm",
                "workload_kind": "fio",
                "batch_id": "vmi1",
                "vm_name": "vm-a",
                "agent_state": "idle",
                "vmi_phase": "Running",
                "reported_at": "2026-07-22T05:52:03Z",
            }
        )
        self.store.ingest(
            {
                "schema_version": 1,
                "record_type": "heartbeat",
                "source": "vstorm",
                "workload_kind": "fio",
                "batch_id": "vmi1",
                "vm_name": "vm-b",
                "agent_state": "idle",
                "vmi_phase": "Pending",
                "reported_at": "2026-07-22T05:52:04Z",
            }
        )
        detail = self.store.get_batch("vmi1")
        self.assertEqual(detail["vm_summary"]["vmi_running"], 1)
        self.assertEqual(detail["vm_summary"]["running"], 0)
        vms = {v["vm_name"]: v for v in detail["vms"]}
        self.assertEqual(vms["vm-a"]["vmi_phase"], "Running")
        self.assertEqual(vms["vm-b"]["vmi_phase"], "Pending")

    def test_forever_not_decremented(self) -> None:
        self.store.set_policy("p1", "vm1", mode="forever")
        self.store.ingest(_fio_payload(batch_id="p1", vm="vm1", cycle=1))
        p = self.store.get_policy("p1", "vm1")
        self.assertEqual(p["mode"], "forever")
        self.assertTrue(p["run"])

    def test_batch_policy_fanout(self) -> None:
        self.store.ingest(
            {
                "schema_version": 1,
                "record_type": "manifest",
                "source": "vstorm",
                "batch_id": "fan",
                "basename": "rhel9",
                "total_vms": 2,
                "vms": ["ns/vm-a", "ns/vm-b"],
                "reported_at": "2026-07-22T05:50:00Z",
                "started_at": "2026-07-22T05:48:20Z",
                "stopped_at": "2026-07-22T05:50:00Z",
            }
        )
        out = self.store.set_batch_policy("fan", mode="once")
        self.assertEqual(out["updated"], 2)
        for name in ("vm-a", "vm-b"):
            p = self.store.get_policy("fan", name)
            self.assertEqual(p["mode"], "count")
            self.assertEqual(p["remaining"], 1)

    def test_batch_policy_subset_vm_names(self) -> None:
        self.store.ingest(
            {
                "schema_version": 1,
                "record_type": "manifest",
                "source": "vstorm",
                "batch_id": "sub",
                "basename": "rhel9",
                "total_vms": 2,
                "vms": ["ns/vm-a", "ns/vm-b"],
                "reported_at": "2026-07-22T05:50:00Z",
                "started_at": "2026-07-22T05:48:20Z",
                "stopped_at": "2026-07-22T05:50:00Z",
            }
        )
        out = self.store.set_batch_policy("sub", mode="forever", vm_names=["vm-a"])
        self.assertEqual(out["updated"], 1)
        self.assertEqual(self.store.get_policy("sub", "vm-a")["mode"], "forever")
        self.assertEqual(self.store.get_policy("sub", "vm-b")["mode"], "idle")

    def test_count_requires_remaining(self) -> None:
        with self.assertRaises(ValueError):
            self.store.set_policy("p1", "vm1", mode="count")


class TestStoreQueries(unittest.TestCase):
    def setUp(self) -> None:
        self._td = tempfile.TemporaryDirectory()
        self.store = wr.Store(Path(self._td.name))
        self.store.ingest(
            {
                "schema_version": 1,
                "record_type": "manifest",
                "source": "vstorm",
                "batch_id": "q1",
                "basename": "rhel9",
                "total_vms": 2,
                "vms": ["ns/vm1", "ns/vm2"],
                "reported_at": "2026-07-22T05:50:00Z",
                "started_at": "2026-07-22T05:48:20Z",
                "stopped_at": "2026-07-22T05:50:00Z",
                "cloudinit": "workload/x.yaml",
                "cores": 4,
                "memory": "8Gi",
            }
        )
        self.store.ingest(_fio_payload(batch_id="q1", vm="vm1", cycle=1, iops=2000))
        self.store.ingest(_fio_payload(batch_id="q1", vm="vm2", cycle=1, iops=1000))
        self.store.set_policy("q1", "vm1", mode="idle")
        self.store.ingest(
            {
                "schema_version": 1,
                "record_type": "heartbeat",
                "source": "guest",
                "workload_kind": "fio",
                "batch_id": "q1",
                "vm_name": "vm1",
                "agent_state": "idle",
                "reported_at": "2026-07-22T05:55:00Z",
            }
        )

    def tearDown(self) -> None:
        self.store._conn.close()
        self._td.cleanup()

    def test_list_batches_and_filter(self) -> None:
        result = self.store.list_batches(q="q1")
        items = result["items"]
        self.assertEqual(len(items), 1)
        self.assertEqual(items[0]["cycle_count"], 2)
        self.assertIn("vm_summary", items[0])
        self.assertIn("facets", result)
        self.assertIn("q1", result["facets"]["batch_ids"])

    def test_list_batches_filters_by_namespace_api_server_date(self) -> None:
        self.store.ingest(
            {
                "schema_version": 1,
                "record_type": "manifest",
                "source": "vstorm",
                "batch_id": "q2",
                "basename": "fedora",
                "total_vms": 1,
                "vms": ["q2-ns-1/fedora-1"],
                "namespaces": ["q2-ns-1"],
                "reported_at": "2026-07-27T12:00:00Z",
                "started_at": "2026-07-27T11:00:00Z",
                "stopped_at": "2026-07-27T11:05:00Z",
                "cluster": {
                    "api_server": "https://api.vlan622.rdu2.scalelab.redhat.com:6443",
                    "worker_nodes": 6,
                    "master_nodes": 3,
                },
            }
        )
        by_ns = self.store.list_batches(namespace="q2-ns")
        self.assertEqual([x["batch_id"] for x in by_ns["items"]], ["q2"])
        by_api = self.store.list_batches(api_server="vlan622")
        self.assertEqual([x["batch_id"] for x in by_api["items"]], ["q2"])
        by_batch = self.store.list_batches(batch_id="q1")
        self.assertEqual([x["batch_id"] for x in by_batch["items"]], ["q1"])
        by_day = self.store.list_batches(date="2026-07-22")
        self.assertEqual([x["batch_id"] for x in by_day["items"]], ["q1"])
        self.assertIn(
            "https://api.vlan622.rdu2.scalelab.redhat.com:6443",
            by_ns["facets"]["api_servers"],
        )

    def test_list_batches_persists_meta_without_reloading_manifest(self) -> None:
        self.store.ingest(
            {
                "schema_version": 1,
                "record_type": "manifest",
                "source": "vstorm",
                "batch_id": "meta1",
                "basename": "rhel9",
                "total_vms": 100,
                "vms": [f"ns/vm-{i}" for i in range(100)],
                "namespaces": ["ns-a", "ns-b"],
                "reported_at": "2026-07-28T12:00:00Z",
                "started_at": "2026-07-28T11:00:00Z",
                "cluster": {"api_server": "https://api.example.test:6443"},
            }
        )
        row = self.store._conn.execute(
            "SELECT api_server, namespaces_json FROM batches WHERE batch_id = ?",
            ("meta1",),
        ).fetchone()
        self.assertEqual(row["api_server"], "https://api.example.test:6443")
        self.assertEqual(json.loads(row["namespaces_json"]), ["ns-a", "ns-b"])

        loads = {"n": 0}
        orig = self.store._load_result_payload

        def counting_load(result_id: str):
            loads["n"] += 1
            return orig(result_id)

        self.store._load_result_payload = counting_load  # type: ignore[method-assign]
        try:
            listed = self.store.list_batches(batch_id="meta1")
        finally:
            self.store._load_result_payload = orig  # type: ignore[method-assign]
        self.assertEqual(loads["n"], 0)
        item = listed["items"][0]
        self.assertEqual(item["api_server"], "https://api.example.test:6443")
        self.assertEqual(item["namespaces"], ["ns-a", "ns-b"])
        self.assertEqual(item["vm_summary"]["configured"], 100)
        self.assertEqual(item["vm_summary"]["waiting"], 100)
        self.assertEqual(item["vm_summary"]["checked_in"], 0)

    def test_list_batches_backfills_legacy_meta_once(self) -> None:
        self.store.ingest(
            {
                "schema_version": 1,
                "record_type": "manifest",
                "source": "vstorm",
                "batch_id": "legacy1",
                "basename": "rhel9",
                "total_vms": 2,
                "vms": ["ns/a", "ns/b"],
                "namespaces": ["ns"],
                "reported_at": "2026-07-28T12:00:00Z",
                "started_at": "2026-07-28T11:00:00Z",
                "cluster": {"api_server": "https://api.legacy.test:6443"},
            }
        )
        # Simulate pre-migration row: columns exist but list meta never written.
        self.store._conn.execute(
            """
            UPDATE batches
            SET api_server = NULL, namespaces_json = NULL
            WHERE batch_id = ?
            """,
            ("legacy1",),
        )
        self.store._conn.commit()

        loads = {"n": 0}
        orig = self.store._load_result_payload

        def counting_load(result_id: str):
            loads["n"] += 1
            return orig(result_id)

        self.store._load_result_payload = counting_load  # type: ignore[method-assign]
        try:
            first = self.store.list_batches(batch_id="legacy1")
            self.assertEqual(loads["n"], 1)
            second = self.store.list_batches(batch_id="legacy1")
            self.assertEqual(loads["n"], 1)
        finally:
            self.store._load_result_payload = orig  # type: ignore[method-assign]

        self.assertEqual(first["items"][0]["api_server"], "https://api.legacy.test:6443")
        self.assertEqual(second["items"][0]["namespaces"], ["ns"])
        row = self.store._conn.execute(
            "SELECT api_server, namespaces_json FROM batches WHERE batch_id = ?",
            ("legacy1",),
        ).fetchone()
        self.assertEqual(row["api_server"], "https://api.legacy.test:6443")
        self.assertEqual(json.loads(row["namespaces_json"]), ["ns"])

    def test_list_batches_uses_denormalized_stats_without_cycle_scan(self) -> None:
        calls = {"n": 0}
        orig = self.store._cycle_stats

        def counting_stats(batch_id: str):
            calls["n"] += 1
            return orig(batch_id)

        self.store._cycle_stats = counting_stats  # type: ignore[method-assign]
        try:
            self.store.list_batches(q="q1")
            self.assertEqual(calls["n"], 0)
        finally:
            self.store._cycle_stats = orig  # type: ignore[method-assign]

        row = self.store._conn.execute(
            "SELECT list_sort_at, vm_summary_json FROM batches WHERE batch_id = ?",
            ("q1",),
        ).fetchone()
        self.assertIsNotNone(row["list_sort_at"])
        self.assertIsNotNone(row["vm_summary_json"])

    def test_list_batch_vms_paginates_without_full_payload(self) -> None:
        vms = [f"ns/vm-{i:04d}" for i in range(250)]
        self.store.ingest(
            {
                "schema_version": 1,
                "record_type": "manifest",
                "source": "vstorm",
                "batch_id": "page1",
                "basename": "rhel9",
                "total_vms": 250,
                "vms": vms,
                "namespaces": ["ns"],
                "reported_at": "2026-07-28T12:00:00Z",
                "started_at": "2026-07-28T11:00:00Z",
                "dv_created_at": "2026-07-28T11:01:00Z",
                "vm_dv_created": {f"vm-{i:04d}": "2026-07-28T11:01:00Z" for i in range(250)},
                "cluster": {"api_server": "https://api.page.test:6443"},
            }
        )
        indexed = self.store._conn.execute(
            "SELECT COUNT(*) AS c FROM batch_vms WHERE batch_id = ?", ("page1",)
        ).fetchone()["c"]
        self.assertEqual(indexed, 250)

        page = self.store.list_batch_vms("page1", limit=100, offset=100)
        assert page is not None
        self.assertEqual(page["total"], 250)
        self.assertEqual(page["limit"], 100)
        self.assertEqual(page["offset"], 100)
        self.assertEqual(len(page["items"]), 100)
        self.assertEqual(page["items"][0]["vm_name"], "vm-0100")
        self.assertEqual(page["items"][-1]["vm_name"], "vm-0199")

        summary = self.store.get_batch("page1", view="summary")
        assert summary is not None
        self.assertEqual(summary["view"], "summary")
        self.assertNotIn("vms", summary["batch_payload"] or {})
        self.assertNotIn("vm_dv_created", summary["batch_payload"] or {})
        self.assertEqual(summary["batch_payload"].get("cluster", {}).get("api_server"),
                         "https://api.page.test:6443")
        # Summary boot stubs only include VMs with boots; none yet.
        self.assertEqual(summary["vms"], [])
        self.assertEqual(summary["series"], [])
        self.assertIsNone(summary.get("boot_stats"))

        loads = {"n": 0}
        orig = self.store._load_result_payload

        def counting_load(result_id: str):
            loads["n"] += 1
            return orig(result_id)

        self.store._load_result_payload = counting_load  # type: ignore[method-assign]
        try:
            again = self.store.list_batch_vms("page1", limit=50, offset=0)
            self.store.get_batch("page1", view="summary")
        finally:
            self.store._load_result_payload = orig  # type: ignore[method-assign]
        self.assertEqual(loads["n"], 0)
        self.assertEqual(len(again["items"]), 50)

    def test_list_batch_vms_sorts_by_duration_columns(self) -> None:
        base = "2026-07-28T11:00:00Z"
        self.store.ingest(
            {
                "schema_version": 1,
                "record_type": "manifest",
                "source": "vstorm",
                "batch_id": "sort1",
                "basename": "rhel9",
                "total_vms": 3,
                "vms": ["vm-fast", "vm-slow", "vm-missing"],
                "namespaces": ["ns"],
                "reported_at": "2026-07-28T12:00:00Z",
                "started_at": base,
                "dv_created_at": base,
                "vm_dv_created": {
                    "vm-fast": "2026-07-28T11:00:00Z",
                    "vm-slow": "2026-07-28T11:00:00Z",
                    "vm-missing": "2026-07-28T11:00:00Z",
                },
                "vm_dv_bound": {
                    "vm-fast": "2026-07-28T11:00:30Z",
                    "vm-slow": "2026-07-28T11:02:00Z",
                },
            }
        )
        for vm_name, boot_iso in (
            ("vm-fast", "2026-07-28T11:01:00Z"),
            ("vm-slow", "2026-07-28T11:05:00Z"),
        ):
            self.store.ingest(
                {
                    "schema_version": 1,
                    "record_type": "heartbeat",
                    "source": "guest",
                    "workload_kind": "boot",
                    "batch_id": "sort1",
                    "vm_name": vm_name,
                    "boot_timestamp": boot_iso,
                    "reported_at": boot_iso,
                }
            )

        by_dv = self.store.list_batch_vms(
            "sort1", limit=10, offset=0, sort="dv_creation_s", order="asc"
        )
        assert by_dv is not None
        self.assertEqual(by_dv["sort"], "dv_creation_s")
        self.assertEqual(by_dv["order"], "asc")
        self.assertEqual(
            [x["vm_name"] for x in by_dv["items"]],
            ["vm-fast", "vm-slow", "vm-missing"],
        )

        by_dv_desc = self.store.list_batch_vms(
            "sort1", limit=10, offset=0, sort="dv_creation_s", order="desc"
        )
        assert by_dv_desc is not None
        self.assertEqual(
            [x["vm_name"] for x in by_dv_desc["items"]],
            ["vm-slow", "vm-fast", "vm-missing"],
        )

        by_ready = self.store.list_batch_vms(
            "sort1", limit=10, offset=0, sort="vm_ready_s", order="asc"
        )
        assert by_ready is not None
        self.assertEqual(by_ready["sort"], "vm_ready_s")
        self.assertEqual(
            [x["vm_name"] for x in by_ready["items"]],
            ["vm-fast", "vm-slow", "vm-missing"],
        )

        by_provision = self.store.list_batch_vms(
            "sort1", limit=10, offset=0, sort="vm_provision_s", order="asc"
        )
        assert by_provision is not None
        self.assertEqual(by_provision["sort"], "vm_provision_s")
        self.assertEqual(
            [x["vm_name"] for x in by_provision["items"]],
            ["vm-fast", "vm-slow", "vm-missing"],
        )

        by_boot = self.store.list_batch_vms(
            "sort1", limit=10, offset=0, sort="boot_timestamp", order="asc"
        )
        assert by_boot is not None
        self.assertEqual(by_boot["sort"], "boot_timestamp")
        self.assertEqual(
            [x["vm_name"] for x in by_boot["items"]],
            ["vm-fast", "vm-slow", "vm-missing"],
        )

        by_boot_desc = self.store.list_batch_vms(
            "sort1", limit=10, offset=0, sort="boot_timestamp", order="desc"
        )
        assert by_boot_desc is not None
        self.assertEqual(
            [x["vm_name"] for x in by_boot_desc["items"]],
            ["vm-slow", "vm-fast", "vm-missing"],
        )

    def test_ensure_batch_vm_index_backfills_legacy_rows(self) -> None:
        self.store.ingest(
            {
                "schema_version": 1,
                "record_type": "manifest",
                "source": "vstorm",
                "batch_id": "bf1",
                "basename": "rhel9",
                "total_vms": 2,
                "vms": ["ns/alpha", "beta"],  # bare name + namespaced
                "namespaces": ["ns"],
                "reported_at": "2026-07-28T12:00:00Z",
                "started_at": "2026-07-28T11:00:00Z",
                "dv_created_at": "2026-07-28T11:01:00Z",
                "dv_created": ["dv-a", "dv-b"],
                "pvc_created": ["pvc-a", "pvc-b"],
                "snapshots": ["snap-1"],
                "vm_dv_created": {"alpha": "2026-07-28T11:01:10Z"},
                "vm_dv_bound": {"alpha": "2026-07-28T11:01:20Z"},
                "vm_data_dv_created": {"alpha": "2026-07-28T11:01:30Z"},
                "vm_data_dv_bound": {"alpha": "2026-07-28T11:01:40Z"},
                "vm_ssh_ready": {"alpha": "2026-07-28T11:02:00Z"},
                "cluster": {"api_server": "https://api.bf.test:6443"},
            }
        )
        # Simulate pre-index DB: wipe index + summary.
        self.store._conn.execute("DELETE FROM batch_vms WHERE batch_id = ?", ("bf1",))
        self.store._conn.execute(
            "UPDATE batches SET summary_json = NULL WHERE batch_id = ?", ("bf1",)
        )
        self.store._conn.commit()
        self.assertEqual(
            self.store._conn.execute(
                "SELECT COUNT(*) AS c FROM batch_vms WHERE batch_id = ?", ("bf1",)
            ).fetchone()["c"],
            0,
        )

        page = self.store.list_batch_vms("bf1", limit=10, offset=0)
        assert page is not None
        self.assertEqual(page["total"], 2)
        by_name = {x["vm_name"]: x for x in page["items"]}
        self.assertIn("alpha", by_name)
        self.assertIn("beta", by_name)
        self.assertEqual(by_name["alpha"]["namespace"], "ns")
        self.assertIsNone(by_name["beta"]["namespace"])
        self.assertEqual(
            by_name["alpha"]["pvc_bound_at_unix"],
            wr._coerce_unix("2026-07-28T11:01:20Z"),
        )
        self.assertEqual(
            by_name["alpha"]["data_dv_created_at_unix"],
            wr._coerce_unix("2026-07-28T11:01:30Z"),
        )
        self.assertEqual(
            by_name["alpha"]["data_pvc_bound_at_unix"],
            wr._coerce_unix("2026-07-28T11:01:40Z"),
        )
        self.assertEqual(
            by_name["alpha"]["ssh_ready_at_unix"],
            wr._coerce_unix("2026-07-28T11:02:00Z"),
        )

        summary = self.store.get_batch("bf1", view="summary")
        assert summary is not None
        self.assertEqual(summary["dv_count"], 2)
        self.assertEqual(summary["pvc_count"], 2)
        self.assertEqual(summary["snapshot_count"], 1)
        self.assertEqual(summary["namespaces"], ["ns"])
        row = self.store._conn.execute(
            "SELECT summary_json FROM batches WHERE batch_id = ?", ("bf1",)
        ).fetchone()
        self.assertIsNotNone(row["summary_json"])

    def test_summary_includes_boot_stubs_and_policy_ui_statuses(self) -> None:
        self.store.ingest(
            {
                "schema_version": 1,
                "record_type": "manifest",
                "source": "vstorm",
                "batch_id": "ui1",
                "basename": "rhel9",
                "total_vms": 3,
                "vms": ["ns/run-vm", "ns/idle-vm", "ns/wait-vm"],
                "reported_at": "2026-07-28T12:00:00Z",
                "started_at": "2026-07-28T11:00:00Z",
                "dv_created_at": "2026-07-28T11:01:00Z",
                "vm_dv_created": {
                    "run-vm": "2026-07-28T11:01:00Z",
                    "idle-vm": "2026-07-28T11:01:00Z",
                    "wait-vm": "2026-07-28T11:01:00Z",
                },
            }
        )
        self.store.set_policy("ui1", "run-vm", mode="forever")
        self.store.set_policy("ui1", "idle-vm", mode="idle")
        self.store.set_policy("ui1", "err-vm", mode="count", remaining=1)
        self.store.ingest(
            {
                "schema_version": 1,
                "record_type": "heartbeat",
                "source": "guest",
                "workload_kind": "fio",
                "batch_id": "ui1",
                "vm_name": "run-vm",
                "agent_state": "running",
                "vmi_phase": "Running",
                "boot_timestamp": "2026-07-28T11:05:00Z",
                "reported_at": "2026-07-28T11:05:00Z",
            }
        )
        self.store.ingest(
            {
                "schema_version": 1,
                "record_type": "heartbeat",
                "source": "guest",
                "workload_kind": "fio",
                "batch_id": "ui1",
                "vm_name": "idle-vm",
                "agent_state": "idle",
                "boot_timestamp": "2026-07-28T11:06:00Z",
                "reported_at": "2026-07-28T11:06:00Z",
            }
        )
        self.store.ingest(
            {
                "schema_version": 1,
                "record_type": "heartbeat",
                "source": "guest",
                "workload_kind": "fio",
                "batch_id": "ui1",
                "vm_name": "err-vm",
                "agent_state": "error",
                "reported_at": "2026-07-28T11:07:00Z",
            }
        )
        # Stale: old last_poll_at
        self.store._conn.execute(
            """
            UPDATE vm_policies
            SET agent_state = 'idle', last_poll_at = 1, mode = 'idle', remaining = 0
            WHERE batch_id = ? AND vm_name = ?
            """,
            ("ui1", "idle-vm"),
        )
        self.store._conn.commit()

        page = self.store.list_batch_vms("ui1", limit=50, offset=0)
        assert page is not None
        # wait-vm from manifest + err-vm from policy sync
        self.assertGreaterEqual(page["total"], 4)
        by_name = {x["vm_name"]: x for x in page["items"]}
        self.assertEqual(by_name["run-vm"]["ui_status"], "running")
        self.assertEqual(by_name["err-vm"]["ui_status"], "error")
        self.assertEqual(by_name["idle-vm"]["ui_status"], "stale")
        self.assertEqual(by_name["wait-vm"]["ui_status"], "waiting")

        self.store.set_policy("ui1", "idle-vm", mode="count", remaining=3)
        self.store._conn.execute(
            """
            UPDATE vm_policies
            SET agent_state = NULL, last_poll_at = ?
            WHERE batch_id = ? AND vm_name = ?
            """,
            (int(time.time()), "ui1", "idle-vm"),
        )
        self.store._conn.commit()
        page2 = self.store.list_batch_vms("ui1", limit=50, offset=0)
        assert page2 is not None
        by_name2 = {x["vm_name"]: x for x in page2["items"]}
        self.assertEqual(by_name2["idle-vm"]["ui_status"], "queued")

        summary = self.store.get_batch("ui1", view="summary")
        assert summary is not None
        self.assertEqual(summary["vms"], [])
        self.assertIsNone(summary.get("boot_stats"))
        chart = self.store.boot_chart("ui1")
        assert chart is not None
        self.assertEqual(chart["count"], 2)
        self.assertIn(chart["label"], ("DV→boot", "Boot time"))
        boot_names = {v["vm_name"] for v in chart["samples"]}
        self.assertIn("run-vm", boot_names)
        self.assertIn("idle-vm", boot_names)
        self.assertEqual(summary["vm_summary"]["vmi_running"], 1)

    def test_boot_chart_uses_per_vm_dv_only_when_present(self) -> None:
        """Sequential batches: do not fall back to batch dv_created for VMs missing per-VM DV."""
        self.store.ingest(
            {
                "schema_version": 1,
                "record_type": "manifest",
                "source": "vstorm",
                "batch_id": "seq-partial",
                "basename": "rhel9",
                "total_vms": 2,
                "vms": ["ns/vm-a", "ns/vm-b"],
                "reported_at": "2026-07-28T12:00:00Z",
                "started_at": "2026-07-28T11:00:00Z",
                "dv_created_at": "2026-07-28T11:00:00Z",
                "vm_dv_created": {
                    "vm-a": "2026-07-28T11:10:00Z",
                },
            }
        )
        for vm_name, boot_iso in (
            ("vm-a", "2026-07-28T11:11:00Z"),
            ("vm-b", "2026-07-28T11:50:00Z"),
        ):
            self.store.ingest(
                {
                    "schema_version": 1,
                    "record_type": "heartbeat",
                    "source": "guest",
                    "workload_kind": "boot",
                    "batch_id": "seq-partial",
                    "vm_name": vm_name,
                    "boot_timestamp": boot_iso,
                    "reported_at": boot_iso,
                }
            )
        chart = self.store.boot_chart("seq-partial")
        assert chart is not None
        self.assertEqual(chart["count"], 1)
        self.assertEqual(chart["max_s"], 60)
        self.assertEqual(chart["samples"][0]["vm_name"], "vm-a")

    def test_list_batch_vms_unknown_and_result_only_batch(self) -> None:
        self.assertIsNone(self.store.list_batch_vms("missing-batch"))
        self.store.ingest(_fio_payload(batch_id="res-only", vm="solo"))
        page = self.store.list_batch_vms("res-only", limit=10, offset=0)
        assert page is not None
        self.assertEqual(page["total"], 1)
        self.assertEqual(page["items"][0]["vm_name"], "solo")
        self.assertIsNotNone(page["items"][0]["boot_timestamp_unix"])

    def test_summary_recovers_from_corrupt_summary_json(self) -> None:
        self.store.ingest(
            {
                "schema_version": 1,
                "record_type": "manifest",
                "source": "vstorm",
                "batch_id": "badsum",
                "basename": "rhel9",
                "total_vms": 1,
                "vms": ["ns/vm1"],
                "namespaces": ["ns"],
                "reported_at": "2026-07-28T12:00:00Z",
                "started_at": "2026-07-28T11:00:00Z",
                "cluster": {"api_server": "https://api.badsum.test:6443"},
            }
        )
        self.store._conn.execute(
            "UPDATE batches SET summary_json = ? WHERE batch_id = ?",
            ("{not-json", "badsum"),
        )
        self.store._conn.commit()
        summary = self.store.get_batch("badsum", view="summary")
        assert summary is not None
        self.assertEqual(
            summary["batch_payload"]["cluster"]["api_server"],
            "https://api.badsum.test:6443",
        )
        # Persisted repaired summary
        row = self.store._conn.execute(
            "SELECT summary_json FROM batches WHERE batch_id = ?", ("badsum",)
        ).fetchone()
        self.assertTrue(row["summary_json"].startswith("{"))

    def test_map_only_vm_names_indexed_and_delete_clears_batch_vms(self) -> None:
        self.store.ingest(
            {
                "schema_version": 1,
                "record_type": "manifest",
                "source": "vstorm",
                "batch_id": "maponly",
                "basename": "rhel9",
                "total_vms": 1,
                "vms": [],
                "reported_at": "2026-07-28T12:00:00Z",
                "started_at": "2026-07-28T11:00:00Z",
                "vm_dv_created": {"ghost": "2026-07-28T11:01:00Z"},
            }
        )
        page = self.store.list_batch_vms("maponly", limit=10, offset=0)
        assert page is not None
        self.assertEqual(page["total"], 1)
        self.assertEqual(page["items"][0]["vm_name"], "ghost")
        self.assertTrue(self.store.delete_batch("maponly"))
        self.assertEqual(
            self.store._conn.execute(
                "SELECT COUNT(*) AS c FROM batch_vms WHERE batch_id = ?", ("maponly",)
            ).fetchone()["c"],
            0,
        )

    def test_summary_edge_cases_no_payload_and_corrupt_namespaces(self) -> None:
        # Results-only batch: no summary_json / batch_result_id.
        self.store.ingest(_fio_payload(batch_id="edge1", vm="solo"))
        summary = self.store.get_batch("edge1", view="summary")
        assert summary is not None
        self.assertEqual(summary["view"], "summary")
        self.assertEqual(summary["batch_payload"], {})
        self.assertEqual(summary["vms"], [])
        self.assertIsNone(summary.get("boot_stats"))
        chart = self.store.boot_chart("edge1")
        assert chart is not None
        self.assertEqual(chart.get("count") or 0, 0)

        self.assertIsNone(
            self.store._load_summary_payload(
                {"batch_id": "edge1", "summary_json": None, "batch_result_id": None}
            )
        )
        self.assertEqual(self.store._boot_map_for_names("edge1", []), {})

        # Corrupt namespaces_json with empty summary namespaces falls back gracefully.
        self.store.ingest(
            {
                "schema_version": 1,
                "record_type": "manifest",
                "source": "vstorm",
                "batch_id": "edge2",
                "basename": "rhel9",
                "total_vms": 1,
                "vms": ["ns/vm1"],
                "reported_at": "2026-07-28T12:00:00Z",
                "started_at": "2026-07-28T11:00:00Z",
            }
        )
        self.store._conn.execute(
            """
            UPDATE batches
            SET namespaces_json = ?, summary_json = ?
            WHERE batch_id = ?
            """,
            ("{bad", json.dumps({"batch_id": "edge2", "record_type": "manifest"}), "edge2"),
        )
        self.store._conn.commit()
        summary2 = self.store.get_batch("edge2", view="summary")
        assert summary2 is not None
        self.assertEqual(summary2["namespaces"], [])

        # ensure_batch_vm_index no-ops when there is no manifest result id.
        self.store._conn.execute("DELETE FROM batch_vms WHERE batch_id = ?", ("edge1",))
        self.store._conn.execute(
            "UPDATE batches SET batch_result_id = NULL WHERE batch_id = ?", ("edge1",)
        )
        self.store._conn.commit()
        self.store._ensure_batch_vm_index("edge1")
        self.assertEqual(
            self.store._conn.execute(
                "SELECT COUNT(*) AS c FROM batch_vms WHERE batch_id = ?", ("edge1",)
            ).fetchone()["c"],
            0,
        )

    def test_policy_idle_status_on_paginated_vms(self) -> None:
        self.store.ingest(
            {
                "schema_version": 1,
                "record_type": "manifest",
                "source": "vstorm",
                "batch_id": "idle1",
                "basename": "rhel9",
                "total_vms": 1,
                "vms": ["ns/vm1"],
                "reported_at": "2026-07-28T12:00:00Z",
                "started_at": "2026-07-28T11:00:00Z",
            }
        )
        self.store.set_policy("idle1", "vm1", mode="idle")
        self.store._conn.execute(
            """
            UPDATE vm_policies
            SET agent_state = 'idle', last_poll_at = ?
            WHERE batch_id = ? AND vm_name = ?
            """,
            (int(time.time()), "idle1", "vm1"),
        )
        self.store._conn.commit()
        page = self.store.list_batch_vms("idle1", limit=10, offset=0)
        assert page is not None
        self.assertEqual(page["items"][0]["ui_status"], "idle")

    def test_get_batch_and_ensure_index_missing_payload_file(self) -> None:
        self.store.ingest(_fio_payload(batch_id="orphan", vm="solo"))
        # Drop the batches row but keep results → get_batch still works.
        self.store._conn.execute("DELETE FROM batches WHERE batch_id = ?", ("orphan",))
        self.store._conn.commit()
        full = self.store.get_batch("orphan")
        assert full is not None
        self.assertEqual(full["batch_id"], "orphan")
        summary = self.store.get_batch("orphan", view="summary")
        assert summary is not None
        self.assertEqual(summary["view"], "summary")

        self.store.ingest(
            {
                "schema_version": 1,
                "record_type": "manifest",
                "source": "vstorm",
                "batch_id": "nofile",
                "basename": "rhel9",
                "total_vms": 1,
                "vms": ["ns/vm1"],
                "reported_at": "2026-07-28T12:00:00Z",
                "started_at": "2026-07-28T11:00:00Z",
            }
        )
        row = self.store._conn.execute(
            "SELECT batch_result_id, file_path FROM batches b "
            "JOIN results r ON r.result_id = b.batch_result_id "
            "WHERE b.batch_id = ?",
            ("nofile",),
        ).fetchone()
        # Remove manifest file and wipe index so ensure tries to reload.
        (Path(self._td.name) / row["file_path"]).unlink()
        self.store._conn.execute("DELETE FROM batch_vms WHERE batch_id = ?", ("nofile",))
        self.store._conn.commit()
        self.store._ensure_batch_vm_index("nofile")
        self.assertEqual(
            self.store._conn.execute(
                "SELECT COUNT(*) AS c FROM batch_vms WHERE batch_id = ?", ("nofile",)
            ).fetchone()["c"],
            0,
        )

    def test_list_vm_timestamps_across_batches(self) -> None:
        for bid, vm, boot, started in (
            ("ts1", "vm-a", "2026-07-22T05:50:25Z", "2026-07-22T05:48:00Z"),
            ("ts2", "vm-b", "2026-07-22T06:00:00Z", "2026-07-22T05:55:00Z"),
        ):
            self.store.ingest(
                {
                    "schema_version": 1,
                    "record_type": "manifest",
                    "source": "vstorm",
                    "batch_id": bid,
                    "basename": "rhel9",
                    "total_vms": 1,
                    "vms": [f"ns/{vm}"],
                    "reported_at": started,
                    "started_at": started,
                    "dv_created_at": started,
                    "vm_dv_created": {vm: started},
                    "cloudinit": "workload/cloudinit-fio-workload.yaml",
                }
            )
            self.store.ingest(
                {
                    "schema_version": 1,
                    "record_type": "heartbeat",
                    "source": "guest",
                    "workload_kind": "boot",
                    "batch_id": bid,
                    "vm_name": vm,
                    "hostname": vm,
                    "boot_timestamp": boot,
                    "reported_at": boot,
                }
            )
        out = self.store.list_vm_timestamps(archived="0", batch_id="ts")
        self.assertEqual(out["total"], 2)
        by_vm = {r["vm_name"]: r for r in out["items"]}
        self.assertIn("vm-a", by_vm)
        self.assertIn("vm-b", by_vm)
        self.assertIsNotNone(by_vm["vm-a"]["boot_timestamp"])
        filtered = self.store.list_vm_timestamps(batch_id="ts1")
        self.assertEqual(filtered["total"], 1)
        self.assertEqual(filtered["items"][0]["batch_id"], "ts1")

    def test_list_vm_timestamps_includes_base_dv_and_snapshot(self) -> None:
        self.store.ingest(
            {
                "schema_version": 1,
                "record_type": "manifest",
                "source": "vstorm",
                "batch_id": "snap1",
                "basename": "rhel9",
                "total_vms": 1,
                "vms": ["ns1/rhel9-snap1-1"],
                "reported_at": "2026-07-22T05:50:00Z",
                "started_at": "2026-07-22T05:48:00Z",
                "base_dv_created_at": "2026-07-22T05:48:30Z",
                "base_dv_ready_at": "2026-07-22T05:48:40Z",
                "base_dv_bound_at": "2026-07-22T05:48:41Z",
                "snapshot_created_at": "2026-07-22T05:48:50Z",
                "snapshot_ready_at": "2026-07-22T05:48:55Z",
                "dv_created_at": "2026-07-22T05:49:00Z",
                "vm_dv_created": {"rhel9-snap1-1": "2026-07-22T05:49:10Z"},
                "cloudinit": "workload/cloudinit-fio-workload.yaml",
            }
        )
        self.store.ingest(
            {
                "schema_version": 1,
                "record_type": "heartbeat",
                "source": "guest",
                "workload_kind": "boot",
                "batch_id": "snap1",
                "vm_name": "rhel9-snap1-1",
                "hostname": "rhel9-snap1-1",
                "boot_timestamp": "2026-07-22T05:50:25Z",
                "reported_at": "2026-07-22T05:50:25Z",
            }
        )
        out = self.store.list_vm_timestamps(batch_id="snap1")
        self.assertEqual(out["total"], 1)
        row = out["items"][0]
        self.assertEqual(row["base_dv_created_at"], 1784699310)
        self.assertEqual(row["base_dv_ready_at"], 1784699320)
        self.assertEqual(row["base_dv_bound_at"], 1784699321)
        self.assertEqual(row["snapshot_created_at"], 1784699330)
        self.assertEqual(row["snapshot_ready_at"], 1784699335)
        self.assertEqual(row["dv_created_at"], 1784699350)
        self.assertEqual(row["boot_timestamp"], 1784699425)

    def test_get_vm_includes_policy(self) -> None:
        detail = self.store.get_vm("q1", "vm1")
        assert detail is not None
        self.assertEqual(detail["cycle_count"], 1)
        self.assertEqual(detail["policy"]["mode"], "idle")
        self.assertEqual(detail["identity"]["vm_name"], "vm1")

    def test_patch_and_delete_batch(self) -> None:
        patched = self.store.patch_batch(
            "q1", {"label": "soak", "notes": "n1", "archived": True}
        )
        assert patched is not None
        self.assertEqual(patched["label"], "soak")
        self.assertTrue(patched["archived"])
        self.assertTrue(self.store.delete_batch("q1"))
        self.assertIsNone(self.store.get_batch("q1"))


class TestHTTPApi(unittest.TestCase):
    def setUp(self) -> None:
        self._td = tempfile.TemporaryDirectory()
        self.store = wr.Store(Path(self._td.name))
        app = wr.App(self.store, token="secret")
        handler = wr.make_handler(app)
        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), handler)
        self.base = f"http://127.0.0.1:{self.httpd.server_address[1]}"
        self._thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)
        self._thread.start()

    def tearDown(self) -> None:
        self.httpd.shutdown()
        self.httpd.server_close()
        self.store._conn.close()
        self._td.cleanup()

    def _json(
        self,
        method: str,
        path: str,
        body: dict | None = None,
        *,
        token: str | None = "secret",
    ) -> tuple[int, dict]:
        data = None if body is None else json.dumps(body).encode("utf-8")
        req = urllib.request.Request(
            self.base + path,
            data=data,
            method=method,
            headers={"Content-Type": "application/json"},
        )
        if token is not None:
            req.add_header("Authorization", f"Bearer {token}")
        try:
            with urllib.request.urlopen(req, timeout=5) as resp:
                return resp.status, json.loads(resp.read().decode("utf-8"))
        except urllib.error.HTTPError as exc:
            raw = exc.read().decode("utf-8")
            try:
                parsed = json.loads(raw) if raw else {}
            except json.JSONDecodeError:
                parsed = {"error": raw}
            return exc.code, parsed

    def test_healthz_no_auth(self) -> None:
        status, body = self._json("GET", "/healthz", token=None)
        self.assertEqual(status, 200)
        self.assertTrue(body.get("ok"))

    def test_api_requires_token(self) -> None:
        status, _ = self._json("GET", "/v1/batches", token=None)
        self.assertEqual(status, 401)

    def test_post_result_and_get_policy(self) -> None:
        status, body = self._json("POST", "/v1/results", _fio_payload(batch_id="h1"))
        self.assertEqual(status, 201)
        self.assertIn("result_id", body)

        status, pol = self._json(
            "PUT",
            "/v1/batches/h1/vms/vm1/policy",
            {"mode": "count", "remaining": 2},
        )
        self.assertEqual(status, 200)
        self.assertEqual(pol["remaining"], 2)

        status, pol = self._json(
            "GET", "/v1/policy?batch_id=h1&vm_name=vm1&default_mode=idle"
        )
        self.assertEqual(status, 200)
        self.assertEqual(pol["mode"], "count")
        self.assertTrue(pol["run"])

        # Second result decrements
        self._json("POST", "/v1/results", _fio_payload(batch_id="h1", cycle=2))
        status, pol = self._json("GET", "/v1/batches/h1/vms/vm1/policy")
        self.assertEqual(status, 200)
        self.assertEqual(pol["remaining"], 1)

    def test_batch_and_timestamps_api_expose_base_dv_and_snapshot(self) -> None:
        status, _ = self._json(
            "POST",
            "/v1/results",
            {
                "schema_version": 1,
                "record_type": "manifest",
                "source": "vstorm",
                "batch_id": "api1",
                "basename": "rhel9",
                "total_vms": 1,
                "vms": ["ns1/rhel9-api1-1"],
                "reported_at": "2026-07-22T05:50:00Z",
                "started_at": "2026-07-22T05:48:00Z",
                "base_dv_created_at": "2026-07-22T05:48:30Z",
                "base_dv_ready_at": "2026-07-22T05:48:40Z",
                "base_dv_bound_at": "2026-07-22T05:48:41Z",
                "snapshot_created_at": "2026-07-22T05:48:50Z",
                "snapshot_ready_at": "2026-07-22T05:48:55Z",
                "dv_created_at": "2026-07-22T05:49:00Z",
                "vm_dv_created": {"rhel9-api1-1": "2026-07-22T05:49:10Z"},
            },
        )
        self.assertEqual(status, 201)

        status, batch = self._json("GET", "/v1/batches/api1")
        self.assertEqual(status, 200)
        self.assertEqual(batch["base_dv_created_at"], 1784699310)
        self.assertEqual(batch["base_dv_ready_at"], 1784699320)
        self.assertEqual(batch["base_dv_bound_at"], 1784699321)
        self.assertEqual(batch["snapshot_created_at"], 1784699330)
        self.assertEqual(batch["snapshot_ready_at"], 1784699335)
        vm = batch["vms"][0]
        self.assertEqual(vm["base_dv_created_at_unix"], 1784699310)
        self.assertEqual(vm["snapshot_ready_at_unix"], 1784699335)

        status, ts = self._json("GET", "/v1/timestamps?batch_id=api1")
        self.assertEqual(status, 200)
        self.assertEqual(ts["total"], 1)
        row = ts["items"][0]
        self.assertEqual(row["base_dv_bound_at"], 1784699321)
        self.assertEqual(row["snapshot_created_at"], 1784699330)
        self.assertEqual(row["snapshot_ready_at"], 1784699335)

    def test_batch_summary_and_paginated_vms_http(self) -> None:
        vms = [f"ns/vm-{i:03d}" for i in range(120)]
        status, _ = self._json(
            "POST",
            "/v1/results",
            {
                "schema_version": 1,
                "record_type": "manifest",
                "source": "vstorm",
                "batch_id": "http-page",
                "basename": "rhel9",
                "total_vms": 120,
                "vms": vms,
                "namespaces": ["ns"],
                "reported_at": "2026-07-28T12:00:00Z",
                "started_at": "2026-07-28T11:00:00Z",
                "dv_created_at": "2026-07-28T11:01:00Z",
                "vm_dv_created": {
                    f"vm-{i:03d}": "2026-07-28T11:01:00Z" for i in range(120)
                },
                "cluster": {"api_server": "https://api.http-page.test:6443"},
                "cmdline": ["./vstorm", "--vms=120"],
            },
        )
        self.assertEqual(status, 201)

        status, summary = self._json("GET", "/v1/batches/http-page?view=summary")
        self.assertEqual(status, 200)
        self.assertEqual(summary["view"], "summary")
        self.assertEqual(summary["total_vms"], 120)
        self.assertNotIn("vms", summary.get("batch_payload") or {})
        self.assertNotIn("vm_dv_created", summary.get("batch_payload") or {})
        self.assertEqual(
            summary["batch_payload"]["cluster"]["api_server"],
            "https://api.http-page.test:6443",
        )
        self.assertEqual(summary["series"], [])
        self.assertEqual(summary["vms"], [])
        self.assertIsNone(summary.get("boot_stats"))

        status, page = self._json(
            "GET", "/v1/batches/http-page/vms?limit=50&offset=50"
        )
        self.assertEqual(status, 200)
        self.assertEqual(page["total"], 120)
        self.assertEqual(page["limit"], 50)
        self.assertEqual(page["offset"], 50)
        self.assertEqual(len(page["items"]), 50)
        self.assertEqual(page["items"][0]["vm_name"], "vm-050")
        self.assertEqual(page["items"][-1]["vm_name"], "vm-099")

        status, exported = self._json(
            "GET", "/v1/batches/http-page/vms?limit=120&offset=0&export=1"
        )
        self.assertEqual(status, 200)
        self.assertEqual(exported["total"], 120)
        self.assertEqual(exported["limit"], 120)
        self.assertEqual(len(exported["items"]), 120)

        status, capped = self._json(
            "GET", "/v1/batches/http-page/vms?limit=9999&offset=0"
        )
        self.assertEqual(status, 200)
        self.assertEqual(capped["limit"], 500)
        self.assertEqual(len(capped["items"]), 120)

        status, chart = self._json("GET", "/v1/batches/http-page/boot-chart")
        self.assertEqual(status, 200)
        self.assertEqual(chart.get("count"), 0)
        self.assertEqual(chart.get("samples"), [])

        status, bad = self._json(
            "GET", "/v1/batches/http-page/vms?limit=nope&offset=0"
        )
        self.assertEqual(status, 400)
        self.assertIn("limit", bad.get("error", "").lower())

        status, missing = self._json("GET", "/v1/batches/no-such/vms")
        self.assertEqual(status, 404)

        status, missing_batch = self._json(
            "GET", "/v1/batches/no-such?view=summary"
        )
        self.assertEqual(status, 404)

    def test_cors_preflight_and_get(self) -> None:
        origin = "http://127.0.0.1:5500"
        req = urllib.request.Request(
            self.base + "/v1/batches",
            method="OPTIONS",
            headers={
                "Origin": origin,
                "Access-Control-Request-Method": "GET",
                "Access-Control-Request-Headers": "authorization,content-type",
            },
        )
        with urllib.request.urlopen(req, timeout=5) as resp:
            self.assertEqual(resp.status, 204)
            self.assertEqual(resp.headers.get("Access-Control-Allow-Origin"), origin)
            allow = (resp.headers.get("Access-Control-Allow-Headers") or "").lower()
            self.assertIn("authorization", allow)
            methods = (resp.headers.get("Access-Control-Allow-Methods") or "").upper()
            self.assertIn("GET", methods)

        req = urllib.request.Request(
            self.base + "/healthz",
            method="GET",
            headers={"Origin": origin},
        )
        with urllib.request.urlopen(req, timeout=5) as resp:
            self.assertEqual(resp.status, 200)
            self.assertEqual(resp.headers.get("Access-Control-Allow-Origin"), origin)


if __name__ == "__main__":
    unittest.main()
