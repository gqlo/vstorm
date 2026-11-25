#!/usr/bin/env python3
"""POST sample manifest / result / heartbeat / error payloads to a local collector.

Usage:
  python3 monitoring/data-collector/seed_dummy.py
  python3 monitoring/data-collector/seed_dummy.py --url http://127.0.0.1:8080/v1/results
"""

from __future__ import annotations

import argparse
import json
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone


def utc(dt: datetime) -> str:
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def post(url: str, payload: dict, token: str | None) -> dict:
    data = json.dumps(payload).encode()
    headers = {"Content-Type": "application/json", "Accept": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(url, data=data, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as exc:
        body = exc.read().decode()
        raise SystemExit(f"POST failed HTTP {exc.code}: {body}") from exc


def fio_block(iops: float, bw: float, lat: float) -> dict:
    return {
        "iops": iops,
        "bw_bytes": bw,
        "lat_ns": {"mean": lat},
    }


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "--url",
        default="http://127.0.0.1:8080/v1/results",
        help="Collector POST URL (default %(default)s)",
    )
    ap.add_argument("--token", default=None, help="Optional bearer token")
    args = ap.parse_args()

    now = datetime.now(tz=timezone.utc)
    batches = [
        {
            "batch_id": "a1b2c3",
            "basename": "rhel9",
            "vms": [
                "a1b2c3-ns-1/rhel9-a1b2c3-1",
                "a1b2c3-ns-1/rhel9-a1b2c3-2",
                "a1b2c3-ns-1/rhel9-a1b2c3-3",
                "a1b2c3-ns-1/rhel9-a1b2c3-4",
                "a1b2c3-ns-1/rhel9-a1b2c3-5",
                "a1b2c3-ns-1/rhel9-a1b2c3-6",
                "a1b2c3-ns-1/rhel9-a1b2c3-7",
                "a1b2c3-ns-1/rhel9-a1b2c3-8",
            ],
            "namespaces": ["a1b2c3-ns-1"],
            "fingerprint": "randrw/1G/4k",
            "api_server": "https://api.vlan622.rdu2.scalelab.redhat.com:6443",
            "started_offset": timedelta(hours=1, minutes=15),
        },
        {
            "batch_id": "d4e5f6",
            "basename": "fedora",
            "vms": ["d4e5f6-ns-1/fedora-d4e5f6-1"],
            "namespaces": ["d4e5f6-ns-1"],
            "fingerprint": "randread/2G/64k",
            "api_server": "https://api.example.scalelab.redhat.com:6443",
            "started_offset": timedelta(days=1, hours=3),
        },
    ]

    posted = 0
    for i, b in enumerate(batches):
        started = now - b["started_offset"]
        stopped = started + timedelta(minutes=2)
        manifest = {
            "schema_version": 1,
            "record_type": "manifest",
            "source": "vstorm",
            "reported_at": utc(stopped),
            "started_at": utc(started),
            "stopped_at": utc(stopped),
            "batch_id": b["batch_id"],
            "basename": b["basename"],
            "total_vms": len(b["vms"]),
            "total_namespaces": len(b["namespaces"]),
            "namespaces": b["namespaces"],
            "vms": b["vms"],
            "cores": 4,
            "memory": "8Gi",
            "cloudinit": "workload/fio/cloudinit-fio-workload.yaml",
            "guest_env": {
                "FIO_SIZE": "1G",
                "RESULT_SERVER_URL": args.url,
                "WORKLOAD_RUN_MODE": "idle",
                "VSTORM_BATCH_ID": b["batch_id"],
            },
            "storage_class": "ocs-storagecluster-ceph-rbd",
            "volume_mode": "Block",
            "cmdline": [
                "vstorm",
                "--cloudinit=workload/fio/cloudinit-fio-workload.yaml",
                "--cores=4",
                "--memory=8Gi",
                f"--vms={len(b['vms'])}",
            ],
            "log_path": f"logs/{b['batch_id']}-dummy.log",
            "log_text": f"dummy seed for batch {b['batch_id']}\n",
            "cluster": {
                "api_server": b["api_server"],
                "oc_version": (
                    "Client Version: 4.16.0\n"
                    "Kustomize Version: v5.0.4\n"
                    "Server Version: 4.16.0\n"
                    "Kubernetes Version: v1.29.6+3af9982"
                ),
                "worker_nodes": 6 if i == 0 else 50,
                "master_nodes": 3,
            },
        }
        print("manifest", b["batch_id"], post(args.url, manifest, args.token))
        posted += 1

        # Staggered guest boot times (seconds after batch create start) for histogram demos.
        boot_offsets_s = (45, 58, 62, 75, 88, 95, 110, 140)
        for vi, vm_path in enumerate(b["vms"]):
            vm = vm_path.split("/", 1)[-1]
            offset_s = boot_offsets_s[vi % len(boot_offsets_s)]
            if i == 1:
                offset_s = 70 + vi * 15
            boot = started + timedelta(seconds=offset_s)
            # heartbeats
            for state in ("idle", "running", "idle"):
                hb = {
                    "schema_version": 1,
                    "record_type": "heartbeat",
                    "source": "guest",
                    "workload_kind": "fio",
                    "batch_id": b["batch_id"],
                    "vm_name": vm,
                    "hostname": vm,
                    "agent_state": state,
                    "vmi_phase": "Running",
                    "policy_mode": "idle",
                    "reported_at": utc(now - timedelta(minutes=5 - min(vi, 4))),
                }
                post(args.url, hb, args.token)
                posted += 1

            # a few successful cycles with rising metrics
            for cycle in range(1, 4):
                t0 = boot + timedelta(minutes=cycle * 3)
                t1 = t0 + timedelta(seconds=70)
                iops = 8000 + vi * 500 + cycle * 1200
                bw = 32_000_000 + vi * 1_000_000 + cycle * 2_000_000
                result = {
                    "schema_version": 1,
                    "record_type": "result",
                    "source": "guest",
                    "workload_kind": "fio",
                    "status": "ok",
                    "error_message": None,
                    "fio_start": utc(t0),
                    "fio_stop": utc(t1),
                    "reported_at": utc(t1 + timedelta(seconds=2)),
                    "boot_timestamp": utc(boot),
                    "service_start": utc(boot),
                    "hostname": vm,
                    "batch_id": b["batch_id"],
                    "vm_name": vm,
                    "cycle": cycle,
                    "job_name": f"job{cycle}",
                    "cpu_count": 4,
                    "mem_total_kb": 8_000_000,
                    "fio_command": [
                        "fio",
                        f"--name=job{cycle}",
                        "--rw=randrw",
                        "--bs=4k",
                        "--size=1G",
                    ],
                    "fio_rc": 0,
                    "fio_group_reporting": {
                        "fio version": "3.35",
                        "jobs": [
                            {
                                "jobname": f"job{cycle}",
                                "read": fio_block(iops / 2, bw / 2, 900.0 + cycle * 50),
                                "write": fio_block(iops / 2, bw / 2, 1100.0 + cycle * 40),
                            }
                        ],
                    },
                    "workload": {
                        "WORKLOAD_TYPE": "randrw" if i == 0 else "randread",
                        "FIO_SIZE": "1G" if i == 0 else "2G",
                        "FIO_BS": "4k" if i == 0 else "64k",
                        "FIO_IODEPTH": "16",
                        "FIO_NUMJOBS": "1",
                        "FIO_DIRECT": "1",
                        "FIO_RW": "randrw" if i == 0 else "randread",
                    },
                }
                print("result", b["batch_id"], vm, cycle, post(args.url, result, args.token))
                posted += 1

            # one post_error style incident on first VM of first batch
            if i == 0 and vi == 0:
                err = {
                    "schema_version": 1,
                    "record_type": "error",
                    "source": "guest",
                    "workload_kind": "fio",
                    "status": "post_error",
                    "error_message": "dummy: failed to POST cycle payload after retries; left in guest pending spool",
                    "fio_start": utc(boot + timedelta(minutes=12)),
                    "fio_stop": utc(boot + timedelta(minutes=13)),
                    "reported_at": utc(boot + timedelta(minutes=13, seconds=5)),
                    "hostname": vm,
                    "batch_id": b["batch_id"],
                    "vm_name": vm,
                    "cycle": 4,
                    "job_name": "job4",
                    "fio_rc": None,
                    "fio_group_reporting": None,
                }
                print("error", b["batch_id"], vm, post(args.url, err, args.token))
                posted += 1

            # one fio_error result on second batch
            if i == 1 and vi == 0:
                bad = {
                    "schema_version": 1,
                    "record_type": "result",
                    "source": "guest",
                    "workload_kind": "fio",
                    "status": "fio_error",
                    "error_message": "fio exited with status 1",
                    "fio_start": utc(boot + timedelta(minutes=15)),
                    "fio_stop": utc(boot + timedelta(minutes=15, seconds=5)),
                    "reported_at": utc(boot + timedelta(minutes=15, seconds=6)),
                    "boot_timestamp": utc(boot),
                    "service_start": utc(boot),
                    "hostname": vm,
                    "batch_id": b["batch_id"],
                    "vm_name": vm,
                    "cycle": 4,
                    "job_name": "job4",
                    "cpu_count": 4,
                    "mem_total_kb": 8_000_000,
                    "fio_command": ["fio", "--name=job4"],
                    "fio_rc": 1,
                    "fio_group_reporting": None,
                    "workload": {
                        "WORKLOAD_TYPE": "randread",
                        "FIO_SIZE": "2G",
                        "FIO_BS": "64k",
                        "FIO_IODEPTH": "16",
                        "FIO_NUMJOBS": "1",
                        "FIO_DIRECT": "1",
                        "FIO_RW": "randread",
                    },
                }
                print("fio_error", b["batch_id"], vm, post(args.url, bad, args.token))
                posted += 1

    print(f"Posted {posted} payloads to {args.url}")
    print("Open http://127.0.0.1:8080/  (batches a1b2c3, d4e5f6)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
