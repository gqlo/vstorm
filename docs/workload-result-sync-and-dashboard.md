# Workload result sync and dashboard

Design for capturing guest workload results (initially fio), syncing host-side vstorm **manifests** (run inventory), and browsing collected data in a simple web dashboard.

Related: [cloud-init and fio workload](cloud-init-fio-workload.md), [logging and batch manifests](logging.md). Collector: [`monitoring/data-collector/`](../monitoring/data-collector/). First guest integration: [`workload/cloudinit-fio-workload.yaml`](../workload/cloudinit-fio-workload.yaml).

## Simple path (recommended)

1. Start the collector; open the dashboard to **browse** batches / VMs / result payloads.
2. Create VMs with **fio knobs once** via `vstorm --env FIO_*=…` (and optional `RESULT_SERVER_URL` override; lab collector is the default).
3. Each guest runs **one** fio job at boot, POSTs **one** result when finished, then exits (`Type=oneshot`).
4. Watch status and drill into JSON on the dashboard.

```bash
# Terminal A — collector
python3 monitoring/data-collector/serve.py --listen 0.0.0.0:8080 --data-dir ./data-collector-data
# Open http://<host>:8080/

# Terminal B — fio params at create; one job per VM; POST once
vstorm --cloudinit=workload/cloudinit-fio-workload.yaml \
  --env FIO_SIZE=1G \
  --env WORKLOAD_TYPE=randrw \
  --env RESULT_SERVER_URL=http://<reachable-host>:8080/v1/results \
  --cores=4 --memory=8Gi --vms=10 --wait
```

Dashboard is browse-first (batches → VMs → results → payload). No run-once / run-N / forever controls in the UI or guest.

## Goals

- **Pass fio / workload knobs once at VM create** (`vstorm --env`); guest runs a single job with those params.
- After the job completes, POST structured JSON (metrics + identity) to a collector **once**.
- Dashboard home: **list of vstorm batches**, each with a **VM status summary**; drill into VMs and payloads; create→boot histogram; archive/notes/delete.
- From **vstorm on the host**, once per run, POST a **manifest** (inventory + sizing + cmdline); join guest results on `batch_id`.
- Work for **fio first**, but keep the result schema workload-agnostic (`workload_kind` on results).

## Non-goals (v1)

- Multi-cycle / forever guest loops or dashboard run-mode controls (`idle` / `once` / `count` / `forever`)
- Pushing commands **into** the guest (no inbound HTTP/SSH/`virtctl` required)
- Time-based fio as the only job definition (`FIO_TIME_BASED=1` remains supported as job length)
- Embedding raw vstorm stdout into every guest result payload
- Grafana / Prometheus wiring for guest workload JSON (CNV/descheduler dashboards: [`ocp-lab/templates/dashboard/json/`](../../ocp-lab/templates/dashboard/json/); provision via [`monitoring/scripts/provision-grafana-dashboards.sh`](../monitoring/scripts/provision-grafana-dashboards.sh))
- Host-side harvest of guest journals via `virtctl` / `helpers/log-vm`
- Multi-user RBAC or multi-tenant isolation
- TLS / HTTPS for the collector (v1 is plain **HTTP** on a trusted/lab network)
- Live rewriting of fio tunables from the dashboard (set `FIO_*` at create via `--env`)

## Assumptions

| Decision | Choice |
|----------|--------|
| Guest job model | **One-shot**: boot → one fio job → optional POST → exit |
| Transport | **HTTP** JSON over a reachable lab network: guests POST results; vstorm POSTs manifests. Example: `http://<host>:8080/v1/results`. TLS out of scope for v1; optional bearer token still allowed. |
| Record types | `manifest` (host inventory) \| `result` (finished workload job) \| `error` (incident); join on `batch_id` |
| Server role | One process: ingest + query + dashboard |
| Collector | Python (`monitoring/data-collector/serve.py`), stdlib preferred |

## Current gap

Status vs this design (as of the current tree).

### Done

| Area | Status |
|------|--------|
| Guest capture | One-shot fio; timestamps; result/error POST + pending spool when `RESULT_SERVER_URL` is set. |
| Host manifest | **vstorm** POSTs `record_type: "manifest"` when `RESULT_SERVER_URL` is in `--env`; auto-injects `VSTORM_BATCH_ID`; incremental `manifest_phase: "progress"` POSTs while waiting on DataVolumes at scale, plus a `"final"` POST when the wait completes/times out. |
| Collector + browse UI | Ingest, SQLite, batches list, batch/VM/payload views (no run-control buttons). |
| Transport | Plain HTTP (v1). |

### Still open / by design

| Area | Notes |
|------|-------|
| Per-VM `VSTORM_VM_NAME` | Not injected (shared cloud-init Secret per namespace). Guest uses hostname unless user sets `--env VSTORM_VM_NAME=…`. |
| Unset / empty `RESULT_SERVER_URL` | No POST; guest still runs the one fio job locally. vstorm defaults `RESULT_SERVER_URL` to the lab collector unless overridden or cleared with `--env RESULT_SERVER_URL=`. |
| Legacy policy API | Collector may still expose `/v1/policy` endpoints from earlier designs; the fio guest no longer polls them. |
| Full log upload API | Batch POST may include truncated `log_text` (64 KiB); separate log upload not required for v1. |

## Architecture

```text
  Dashboard UI (browse)           Collector                         Guest
  -------------------             ---------                         -----
  list batches / VMs / payloads   ingest + SQLite index
                                        ^
                                        |  POST /v1/results (manifest from vstorm)
                                        |  POST /v1/results (one result from guest)
                                        |
                                  guest boots
                                        |
                                  run one fio job (FIO_* from --env)
                                        |
                                  POST result once ---------------> store + show on UI
                                  exit (systemd oneshot)
```

Guests never need inbound ports. The dashboard never talks to the VM directly.

### End-to-end flow

1. Start collector; open dashboard.
2. Run vstorm with `RESULT_SERVER_URL` + fio `--env`; vstorm POSTs a **manifest** and injects `VSTORM_BATCH_ID`.
3. Guest boots, writes timestamp, starts `fio-workload.service` (oneshot).
4. Guest POSTs a **heartbeat** with `agent_state: "running"`, then runs **one** fio job; on completion POSTs a **result** JSON (collector clears agent state to `idle` / `error`). Spools locally if the collector is down.
5. Service exits. Dashboard shows the batch, VM, and payload.

## Legacy: run policy API

Earlier designs used guest policy polling (`idle` / `once` / `count` / `forever`). The fio guest **no longer** polls policy. Collector `/v1/policy` endpoints may still exist for compatibility; they are unused by the one-shot workload.

### Policy fields (legacy)

| Field | Meaning |
|-------|---------|
| `mode` | `idle` \| `once` \| `count` \| `forever` \| `stop` |
| `remaining` | For `count` / `once`: cycles left (server decrements on each **result** ingest). Ignored for `forever` / `idle`. |
| `revision` | Monotonic id; bumped when policy is set or remaining is consumed |
| `updated_at` | When the policy last changed |
| `run` | Convenience boolean on GET: whether the guest should start a cycle now |
| `agent_state` / `last_poll_at` / `last_status_at` | Last known guest state (from heartbeats / policy polls) |

Semantics:

- **`idle`** — do not start a new cycle; if a cycle is running, let it finish (v1).
- **`once`** — stored as `count` with `remaining=1`.
- **`count`** — run until `remaining` reaches 0 on the collector, then become `idle`.
- **`forever`** — start another cycle whenever the previous one ends, until policy changes.
- **`stop`** — accepted by the API and immediately stored as `idle` (same as Idle in the UI). No mid-cycle SIGKILL in v1.

### Defaults and boot env

| Variable | Description |
|----------|-------------|
| `RESULT_SERVER_URL` | Collector base or results URL (required for push + poll) |
| `WORKLOAD_RUN_MODE` | Initial policy if none stored yet: `idle` (recommended with dashboard) or `forever` (soak / backward compatible) |
| `WORKLOAD_RUN_COUNT` | If mode is `count` at boot, initial N |
| `WORKLOAD_POLL_SECONDS` | How often to poll policy while idle or between cycles (e.g. 5) |
| `VSTORM_BATCH_ID` / `VSTORM_VM_NAME` | Identity for policy lookup and result join |

When the agent first registers (or first poll), if no policy row exists, the collector creates one from `WORKLOAD_RUN_MODE` / `WORKLOAD_RUN_COUNT`.

### Why pull, not push

Lab VMs typically reach the collector via egress/NAT. Requiring `virtctl exec`, SSH, or a guest listen port breaks that model. Polling keeps one HTTP server and works for fio and future workloads.

## Guest agent behavior

Replace the hard-coded forever loop with:

```text
  loop forever:
    policy = GET /v1/policy?batch_id=&vm_name=  (creates row from WORKLOAD_RUN_* on first poll)
    if not policy.run:          # idle, or count/once with remaining=0
        POST status (idle) optional
        sleep POLL_SECONDS
        continue
    run one cycle (fio / other)
    POST result record              # collector decrements remaining for count/once
    # re-check policy next iteration (Idle / new N / forever noticed between cycles)
```

- **One cycle** = one fio job (size- or time-based), then report as `record_type: "result"`.
- Persistent `job.counter` / `jobN` naming stays; payload field `cycle` is the sequence number (not the record type).
- Between cycles the agent always re-reads policy so Idle / “run 2 more” apply without restarting systemd.
- Remaining is authoritative on the **collector** (updated on result ingest); the guest trusts `run` / `remaining` from the next GET.
- systemd unit stays `Restart=always` as a crash safety net; the **logical** loop is policy-driven, not “always run fio”.

### Per cycle capture (unchanged intent)

1. Record `fio_start` (UTC ISO-8601 with `Z`).
2. Run fio with `--output-format=json` to a results file.
3. Record `fio_stop`.
4. Build **result** payload (identity, command, `fio_group_reporting`, workload fingerprint).
5. Set `reported_at`; POST (leave `results/<job>-payload.json` on disk); spool under `pending/` on failure.

All payload timestamps are **UTC**, written as ISO-8601 with an explicit timezone (`…Z` or `…+00:00`). The collector still indexes them as unix seconds internally for sorting.

### Boot timestamp

Shared across **all** workload cloud-inits via `vstorm-boot-timestamp.service` (`/opt/vstorm-boot-timestamp.sh`):

- **File:** `/root/timestamp.txt` (override with `RESULT_TIMESTAMP_FILE`). Append on each oneshot run / reboot. **First numeric unix field** = boot (non-numeric header lines are skipped). Data lines: `unix_utc, YYYY-MM-DDTHH:MM:SSZ` (UTC).
- **Collector:** when `RESULT_SERVER_URL` and `VSTORM_BATCH_ID` are set, the unit POSTs a `record_type: "heartbeat"` / `workload_kind: "boot"` payload with `boot_timestamp`. The dashboard indexes that for create→boot charts/CSV even when no fio (or other) **result** has arrived yet.
- **Fio:** still embeds `boot_timestamp` on its result POST (reads the same file; does not own the write). Other profiles (stress-ng, dirty-mem, default) rely on the boot heartbeat for collector boot times.
- **DV created:** vstorm lists DataVolumes in batch namespaces (and any with `batch-id`) and adds `dv_created_at` (earliest), `dv_created` (list with `role`, `ready_at`, `phase`), and `vm_dv_created` / `vm_data_dv_created` (per-VM root / data DV create times) to the host **manifest**.
- **Base DV (import):** when the create path uses `{basename}-base`, the manifest also includes batch-level `base_dv_created_at` / `base_dv_ready_at` / `base_dv_bound_at` (and a `base_dv` list). These are distinct from per-VM clone `dv_*`.
- **VolumeSnapshot:** with snapshot cloning, `snapshot_created_at` / `snapshot_ready_at` (and a `snapshots` list) are posted from VolumeSnapshot `creationTimestamp` and Ready condition.
- **DV ready (clone completed):** from DV `status.conditions` — prefer `Ready=True` `lastTransitionTime`, else `Running` reason `Completed`. Exposed as `dv_ready_at`, per-entry `ready_at`, and `vm_dv_ready` / `vm_data_dv_ready`. Smart snapshot clones often complete in ~1–2s.
- **SSH port ready (host probe):** with `--wait-ssh`, vstorm probes guest port 22 (or `--service` targetPort) via `virtctl port-forward` + `nc` — no password/key. Each VM has a 30s timeout; any still down fails the run after the manifest POST. Fields: `vm_ssh_ready`, `vm_ssh_failed`, `ssh_ready_at`, `ssh_ready_status`.
- **PVC created:** vstorm lists PVCs in batch namespaces and adds `pvc_created_at`, `pvc_created`, `vm_pvc_created` (root), and `vm_data_pvc_created` (blank data disk). Blank data DataVolumes are labeled `batch-id` so they appear in the DV list.
- **DV→boot histogram / summary (per VM):** create→boot seconds use this fallback order for each VM independently:
  1. `vm_dv_created[vm]` / per-VM `dv_created_at_unix` when present
  2. else batch `dv_created_at` (earliest DV in the batch)
  3. else vstorm `started_at`
  That way a single earliest DV timestamp is **not** applied to every VM when per-VM create times exist.
- Boot-times / all-timestamps CSVs include absolute UTC columns:
  `batch_started_at_utc`, `base_dv_created_at_utc`, `base_dv_ready_at_utc`,
  `base_dv_bound_at_utc`, `snapshot_created_at_utc`, `snapshot_ready_at_utc`,
  `dv_created_at_utc`, `dv_ready_at_utc`, `pvc_created_at_utc`, `pvc_bound_at_utc`,
  `data_dv_created_at_utc`, `data_dv_ready_at_utc`, `data_pvc_created_at_utc`,
  `data_pvc_bound_at_utc`, `ssh_ready_at_utc`, `boot_timestamp_utc` (plus identity fields).
  Duration columns (integer seconds, left of the absolute timestamps):
  `base_dv_creation_s` (bound−created), `snapshot_creation_s` (ready−created),
  `dv_creation_s` (pvc bound−dv created), `data_dv_creation_s` (data pvc bound−data dv created),
  `vm_ready_s` (boot−dv created). Blank when either endpoint is missing. PVC bound time
  comes from the owning DV `Bound=True` condition (`lastTransitionTime`).

Standalone source of the script: [`workload/vstorm-boot-timestamp.sh`](../workload/vstorm-boot-timestamp.sh)
(single source of truth; embedded `write_files` copies must stay identical — covered by bats).

## Host-side manifest (vstorm)

One or more `record_type: "manifest"` / `source: "vstorm"` POSTs after successful create, with names, sizing, cmdline, etc. Auto-inject `VSTORM_BATCH_ID`. This is the collector counterpart of the local `logs/batch-{id}.manifest` inventory — same facts, different place. See fields in the example below.

**Incremental at scale:** waiting for every DataVolume to reach Ready/Bound can take hours with thousands of VMs. When `RESULT_SERVER_URL` is configured, vstorm POSTs an early manifest right after VM create (batch inventory, DV timestamps still partial).
It then sends further `manifest_phase: "progress"` POSTs whenever the pending-DV count changes (throttled by `MANIFEST_PROGRESS_INTERVAL`, default 60s), and finally a `manifest_phase: "final"` POST once the wait completes or times out.
Every POST is a full manifest that replaces the collector's stored copy for that `batch_id` — there is no server-side merge, so a `progress` payload can have empty/partial `vm_dv_ready` / `vm_pvc_bound` maps while a later `progress` or the `final` payload fills them in.

`manifest_phase: "final"` means no further automatic POSTs are coming from this vstorm run — it does **not** guarantee every DV timestamp was captured. If the 30-minute DV wait hit its deadline with DVs still pending, the final manifest is still posted with whatever was collected, and `dv_wait_timed_out: true` is set so consumers can tell "finished cleanly" apart from "final, but truncated by timeout".

### Manifest payload example

Abbreviated example: `total_vms` / `total_namespaces` describe the full batch, while
`vms`, `vm_*`, `dv_created`, and `pvc_created` below show only a few entries for
readability (a real POST includes every VM’s per-VM timestamps).

```json
{
  "schema_version": 1,
  "record_type": "manifest",
  "source": "vstorm",
  "manifest_phase": "final",
  "reported_at": "2026-07-22T05:50:00Z",
  "started_at": "2026-07-22T05:48:20Z",
  "stopped_at": "2026-07-22T05:50:00Z",
  "base_dv_created_at": "2026-07-22T05:48:30Z",
  "base_dv_ready_at": "2026-07-22T05:48:40Z",
  "base_dv_bound_at": "2026-07-22T05:48:41Z",
  "snapshot_created_at": "2026-07-22T05:48:42Z",
  "snapshot_ready_at": "2026-07-22T05:48:44Z",
  "dv_created_at": "2026-07-22T05:48:45Z",
  "dv_ready_at": "2026-07-22T05:48:47Z",
  "vm_dv_created": {
    "rhel9-8a494b-1": "2026-07-22T05:48:45Z",
    "rhel9-8a494b-2": "2026-07-22T05:48:46Z"
  },
  "vm_dv_ready": {
    "rhel9-8a494b-1": "2026-07-22T05:48:47Z",
    "rhel9-8a494b-2": "2026-07-22T05:48:48Z"
  },
  "vm_ssh_ready": {
    "rhel9-8a494b-1": "2026-07-22T05:49:10Z",
    "rhel9-8a494b-2": "2026-07-22T05:49:11Z"
  },
  "ssh_ready_at": "2026-07-22T05:49:10Z",
  "ssh_ready_status": "ok",
  "dv_created": [
    {"namespace": "8a494b-ns-1", "name": "rhel9-8a494b-1", "created_at": "2026-07-22T05:48:45Z", "ready_at": "2026-07-22T05:48:47Z", "role": "root", "phase": "Succeeded"}
  ],
  "pvc_created_at": "2026-07-22T05:48:46Z",
  "vm_pvc_created": {
    "rhel9-8a494b-1": "2026-07-22T05:48:46Z",
    "rhel9-8a494b-2": "2026-07-22T05:48:47Z"
  },
  "vm_data_pvc_created": {
    "rhel9-8a494b-1": "2026-07-22T05:48:48Z"
  },
  "pvc_created": [
    {"namespace": "8a494b-ns-1", "name": "rhel9-8a494b-1", "created_at": "2026-07-22T05:48:46Z", "role": "root"}
  ],
  "batch_id": "8a494b",
  "basename": "rhel9",
  "total_vms": 10,
  "total_namespaces": 2,
  "namespaces": ["8a494b-ns-1", "8a494b-ns-2"],
  "vms": [
    "8a494b-ns-1/rhel9-8a494b-1",
    "8a494b-ns-1/rhel9-8a494b-2"
  ],
  "cores": 4,
  "memory": "8Gi",
  "cloudinit": "workload/cloudinit-fio-workload.yaml",
  "guest_env": {
    "FIO_SIZE": "1G",
    "RESULT_SERVER_URL": "http://host:8080/v1/results",
    "VSTORM_BATCH_ID": "8a494b",
    "WORKLOAD_RUN_MODE": "idle"
  },
  "storage_class": "ocs-storagecluster-ceph-rbd",
  "volume_mode": "Block",
  "cmdline": ["vstorm", "--cloudinit=workload/cloudinit-fio-workload.yaml", "--cores=4", "--memory=8Gi", "--vms=10"],
  "log_path": "logs/8a494b-2026-07-22T05:48:20.log",
  "log_text": "…truncated host log (up to 64 KiB)…",
  "cluster": {
    "api_server": "https://api.vlan622.rdu2.scalelab.redhat.com:6443",
    "oc_version": "Client Version: 4.16.0\nKustomize Version: v5.0.4-0.20230601165947-6ce0bf390ce3\nServer Version: 4.16.0\nKubernetes Version: v1.29.6+3af9982",
    "worker_nodes": 50,
    "master_nodes": 3
  }
}
```

All timestamps are UTC ISO-8601 with an explicit timezone suffix (`Z` = UTC).

## Payload schema (v1)

| Field | Meaning |
|-------|---------|
| `record_type` | `manifest` \| `result` \| `error` \| `heartbeat` |
| `source` | `vstorm` \| `guest` |
| `workload_kind` | Guest only: `fio`, later `stress-ng`, … — omit on manifest |

Legacy aliases still accepted on ingest: `batch`→`manifest`, `cycle`→`result`, `event`→`error`, `status`→`heartbeat`.

### Result payload (`record_type: "result"`, `workload_kind: "fio"`)

One completed workload invocation (one fio job). Timing: UTC ISO-8601 with explicit timezone (`…Z`). No unix fields in the payload.

```json
{
  "schema_version": 1,
  "record_type": "result",
  "source": "guest",
  "workload_kind": "fio",
  "status": "ok",
  "error_message": null,
  "fio_start": "2026-07-22T05:50:50Z",
  "fio_stop": "2026-07-22T05:52:00Z",
  "reported_at": "2026-07-22T05:52:03Z",
  "boot_timestamp": "2026-07-22T05:50:25Z",
  "service_start": "2026-07-22T05:50:25Z",
  "hostname": "vm-8a494b-1",
  "batch_id": "8a494b",
  "vm_name": "vm-8a494b-1",
  "cycle": 1,
  "job_name": "job1",
  "cpu_count": 4,
  "mem_total_kb": 8165432,
  "fio_command": ["fio", "--name=job1", "..."],
  "fio_rc": 0,
  "fio_group_reporting": { "fio version": "...", "jobs": [] },
  "workload": {
    "WORKLOAD_TYPE": "randrw",
    "FIO_SIZE": "1G",
    "FIO_BS": "4k",
    "FIO_IODEPTH": "16",
    "FIO_NUMJOBS": "1",
    "FIO_DIRECT": "1",
    "FIO_RW": "randrw"
  }
}
```

| Field | Meaning |
|-------|---------|
| `fio_start` / `fio_stop` | fio process start / exit (UTC) |
| `reported_at` | payload build time for POST (UTC) |
| `boot_timestamp` / `service_start` | guest boot / service start (UTC) |
| `cycle` | Sequence number of this invocation on the guest (`jobN`) — not the record type |

Failed fio jobs still POST as `result` (with `status` / `fio_rc`). Unreachable collector → spool under `$FIO_DIRECTORY/results/pending/` (default `/root/data/results/pending/`); optional `record_type: "error"` / `status: "post_error"`.

### Error payload (incident)

Compact guest incident when something fails around reporting (not a metrics sample):

```json
{
  "schema_version": 1,
  "record_type": "error",
  "source": "guest",
  "workload_kind": "fio",
  "status": "post_error",
  "error_message": "failed to POST …; left in guest pending spool",
  "cycle": 1,
  "batch_id": "8a494b",
  "vm_name": "vm-8a494b-1",
  "reported_at": "2026-07-22T05:52:05Z"
}
```

### Heartbeat payload

Lightweight so the dashboard can show idle / workload running / error without waiting for the next result:

```json
{
  "schema_version": 1,
  "record_type": "heartbeat",
  "source": "guest",
  "workload_kind": "fio",
  "batch_id": "8a494b",
  "vm_name": "vm-8a494b-1",
  "hostname": "vm-8a494b-1",
  "agent_state": "idle",
  "vmi_phase": "Running",
  "policy_mode": "idle",
  "reported_at": "2026-07-22T05:53:20Z"
}
```

`agent_state`: `idle` \| `running` \| `error` (guest may also use other labels) — drives **workload running** in the summary.  
Optional `vmi_phase` (KubeVirt VMI phase, e.g. `Running`) — drives **VMI running**; omit when unknown (summary shows `—` until any phase is reported). Guests typically omit this; a host/cluster sync can POST heartbeats with `source: "vstorm"` and `vmi_phase` set.  
`policy_mode` in the current guest script is the boot env `WORKLOAD_RUN_MODE` (not the last polled collector policy). Authoritative mode/remaining live in the collector `vm_policies` row and on `GET …/policy`.

## Collector and API

One Python process: ingest, **policy store**, query, dashboard.

| Endpoint | Purpose |
|----------|---------|
| `POST /v1/results` | Ingest manifest / result / error / heartbeat |
| `GET /healthz` | Liveness |
| `GET /v1/batches` | List batches (`q`, `archived`, `batch_id`, `namespace`, `api_server`, `today=1`, `date=YYYY-MM-DD`, `date_from` / `date_to`); response includes `items` + `facets` |
| `GET /v1/timestamps` | Flat VM timing rows across batches (same filters as `GET /v1/batches`); used by the **Timestamps** table view (`#/timestamps`) and its optional **Download CSV** |
| `GET /v1/batches/{id}` | Batch detail + VMs + series |
| `GET /v1/batches/{id}/results/{result_id}` | One stored payload |
| `GET /v1/batches/{id}/vms/{vm}` | Per-VM results + **current policy + agent status** |
| `GET /v1/batches/{id}/results` | Filtered results (`record_type=result`, …) |
| `GET /v1/batches/{id}/vms/{vm}/policy` | Desired run policy for that VM |
| `PUT /v1/batches/{id}/vms/{vm}/policy` | Set policy (`mode`, `remaining`, …) — used by dashboard |
| `POST /v1/batches/{id}/policy` | Fan-out: set same policy on all VMs, or only `vm_names: […]` when provided |
| `DELETE /v1/batches/{id}` | Delete run |
| `PATCH /v1/batches/{id}` | Label / notes / archived |
| Static `/` | Dashboard |

Policy GET may accept identity query params if the guest uses a shared results URL, e.g. `GET /v1/policy?batch_id=&vm_name=` as an alias.

### Storage

- Raw JSON under `data/results/{batch_id}/…`
  - Manifest: `manifest.json` (legacy `batch.json` accepted on ingest and rewritten)
  - Results / errors / heartbeats: `result-{vm}-{n}-{ISO}-{id8}.json` (and `error-…` / `heartbeat-…`), where ISO is filesystem-safe UTC (colons → dashes), e.g. `2026-07-22T05-52-03Z`
- SQLite: results index + **`vm_policies`** (`batch_id`, `vm_name`, `mode`, `remaining`, `revision`, `updated_at`, agent status columns)

## Dashboard

Primary UX: **see every vstorm run**, skim **how many VMs are doing what**, drill into one VM and its cycle payloads — without SSH into guests.

```text
  Home: Batches list (one row per vstorm batch)
      |
      | click batch_id
      v
  Run detail
      |-- VM status + manifest / FIO guest env (launch params)
      |-- VM table (status / mode / cycles)
      |-- boot-time histogram (create → guest boot)
      |
      | click VM
      v
  VM detail  ---- cycle history
      |
      v
  Cycle / payload view
```

### 1. Batches list (home)

The home page is a **list of batches created by vstorm** — one row per `batch_id`. Prefer rows that have a host `record_type: "manifest"` payload; if only guest cycles have arrived, still show an inferred batch so nothing is invisible.

**Summary strip** (across the current list):

| Summary | Meaning |
|---------|---------|
| Batches | Count of listed batches |
| VMs created | Sum of `configured` / `total_vms` |
| Contacted collector | Guests that have polled or POSTed (not `waiting` / “not contacted”) |
| Running / idle / not contacted / error | From per-batch `vm_summary` (API key for not-contacted remains `waiting`; chips also show VMI running / queued / stale when present) |

**Table columns (as implemented):**

| Column | Source |
|--------|--------|
| Batch | `batch_id` (+ archived badge); click → run detail |
| Basename | vstorm metadata |
| Started / Stopped | vstorm `started_at` / `stopped_at` |
| Workload status | `N running · N idle` (workload mid-fio vs not) |
| Cycles | Cycle POST count |
| Errors | Error cycle/event count |
| IOPS avg / BW avg | Aggregate from cycles |
| Workload | Fingerprint or cloud-init path |

**Filters:** date (all / today UTC / specific day), batch id, namespace, API server, text search, active / archived / all. Optional **Auto** refresh (off by default); use **Refresh** for a one-shot update.

### 2. Run detail

Everything for one vstorm batch on one page.

**Summary (top):** batch id, basename, fingerprint/cloud-init, workload running/idle,
**boot time avg / min / max** (create → guest boot) with
**Download detailed object creation timestamps**, and **VMs / Namespaces / DVs / PVCs**
counts (from manifest `total_vms` / `total_namespaces` and `dv_created` / `pvc_created`
lists). Summary also shows **Batch started** plus VM/namespace/DV/PVC counts.
Base DV / VolumeSnapshot times (often one per namespace) live in the Timestamps /
CSV views, not this summary. Per-VM clone DV/PVC durations are on the VMs table.
On the **Batches** list: **Timestamps** opens an
in-browser table (`#/timestamps`); use **Download CSV** on that page when you want a file.
aggregates VM timing rows across batches matching the current filters (`GET /v1/timestamps`).

**VM rollup meanings** (same definitions as the VM table `ui_status`):

| Metric | Meaning |
|--------|---------|
| Created | From vstorm batch `total_vms` / `vms[]` |
| Contacted collector | Not `waiting` (UI: not contacted) |
| VMI running | Guests (or host sync) reporting `vmi_phase: "Running"`; `—` until any phase is known |
| Workload running | Guest POSTs heartbeat with `agent_state: "running"` before the fio cycle; cleared to `idle`/`error` when the **result** is ingested |
| Idle | Policy idle (or remaining 0), not workload-running |
| Queued | Policy `once`/`count`/`forever` but not currently in a cycle |
| Not contacted | Listed in the manifest VM list (or seen empty), never contacted collector (`ui_status` / summary key: `waiting`) |
| Error / stale | Last status error, or no poll within ~120s |

Example: `10 created · 8 contacted · 8 VMI running · 2 workload running · 4 idle · 2 not contacted`.

**Batch-wide controls:** not shown in the UI. Set `WORKLOAD_RUN_MODE` at create, or call `POST /v1/batches/{id}/policy` from a script if needed.

**vstorm metadata panel:** API server, worker/master node counts, `oc version`, namespaces, cmdline, **guest_env (FIO launch params)**, storage, notes/label — from `record_type: "manifest"`. Button: **View manifest**. Archive / Delete.

**VMs table:** paginated at **100 rows / page** (First / Prev / Next / Last). Same
controls on Timestamps tables and the VM Cycles table when there are more than 100 rows.

| Column | Meaning |
|--------|---------|
| VM | Link to VM detail |
| Workload status | `running` (mid-fio) or `idle` (everything else) |
| Mode | Policy mode + remaining (read-only; set at boot or via API) |
| `dv_creation_s` | Root PVC bound − DV created (seconds) |
| `data_dv_creation_s` | Data PVC bound − data DV created (seconds); blank when no data disk |
| `vm_ready_s` | Boot − DV created (seconds) |
| Boot | Boot timestamp when known |

Base DV / VolumeSnapshot absolute timestamps remain in the Timestamps / CSV views
(not on the run summary or VMs table).

**Charts:** histogram of **DV create → guest boot** duration (per-VM or batch
`dv_created_at` from the manifest, falling back to batch `started_at`) to per-VM
`boot_timestamp`, with min / avg / max. CSV download includes absolute UTC timestamps
(`base_dv_*`, `snapshot_*`, `dv_created_at_utc`, `dv_ready_at_utc`, `pvc_created_at_utc`,
`pvc_bound_at_utc`, `data_dv_created_at_utc`, `data_dv_ready_at_utc`,
`data_pvc_created_at_utc`, `data_pvc_bound_at_utc`, `boot_timestamp_utc`, etc.), not
derived duration columns.

### 3. VM detail

- Identity: hostname, CPU/RAM, boot timestamp when known.
- **Status strip:** agent state, policy mode/remaining/revision (read-only).
- **Cycles table:** cycle number, timing, fio_rc, IOPS/BW, status; click → payload view.

### 4. Cycle / payload view

- Highlighted summary (command, timing, exit code).
- Collapsible **`fio_group_reporting`**.
- Full raw JSON (copy / download).
- Same viewer for the vstorm batch payload from run detail.

### Run policy (API / boot; not dashboard buttons)

- Guests poll `GET /v1/policy`; boot `WORKLOAD_RUN_MODE` / `WORKLOAD_RUN_COUNT` seed the first policy row.
- **`idle`** — no new cycles (API `mode=idle`; `stop` is accepted and stored as idle).
- **`once`** — one cycle, then idle.
- **`count`** — N cycles then idle.
- **`forever`** — soak until policy changes.
- Prefer setting mode at create for the simple collect path. Guests that have never polled will not run until they check in (`RESULT_SERVER_URL` / `VSTORM_BATCH_ID`).

### Manage (non-control)

- Archive / unarchive, notes, label, delete run (confirm).

### Browse UX rules

- Home = **vstorm batches first**, not a flat dump of cycle files.
- VM status chips on run detail and the VMs table Workload status column show only `running` or `idle`.
- Every stored result is one click from its **full JSON**.
- Deep links: `/#/runs/{batch_id}`, `/#/runs/{batch_id}/vms/{vm}`, payload routes.
- Prefer skim-friendly tables; large JSON behind “View payload”.

## Example usage

See **[Simple path (recommended)](#simple-path-recommended)** above. Cap jobs with `WORKLOAD_MAX_JOBS` or use `WORKLOAD_RUN_MODE=once` / `count` when you do not want a forever soak.

## Implementation touchpoints

| Area | Status |
|------|--------|
| [`vstorm`](../vstorm) | POSTs `record_type: "manifest"` when `RESULT_SERVER_URL` is in `--env`; auto-injects `VSTORM_BATCH_ID`; optional truncated `log_text` |
| [`workload/cloudinit-fio-workload.yaml`](../workload/cloudinit-fio-workload.yaml) | Fio one-shot; result POST; reads shared boot timestamp |
| [`workload/vstorm-boot-timestamp.sh`](../workload/vstorm-boot-timestamp.sh) | Shared boot file + optional boot heartbeat POST (embedded in all cloud-inits) |
| `monitoring/data-collector/serve.py` | Ingest; policy GET/PUT/fan-out; remaining consume on cycle ingest; VM status rollups; ISO filenames |
| [`monitoring/data-collector/static/`](../monitoring/data-collector/static/) | Browse batches / VMs / payloads; helpers in `dashboard-lib.js` |
| [`docs/cloud-init-fio-workload.md`](cloud-init-fio-workload.md) | Env table includes `RESULT_SERVER_*` / `WORKLOAD_RUN_*` |
| `tests/` | `monitoring/tests/test_workload_result.py` — helpers, ingest/record types, policy, queries, HTTP API |

## References

- [cloud-init and fio workload](cloud-init-fio-workload.md)
- [logging and batch manifests](logging.md)
- [workload/cloudinit-fio-workload.yaml](../workload/cloudinit-fio-workload.yaml)
- [README.md](../README.md) — Cloud-init and `--env`
- [monitoring/](../monitoring/README.md) — cluster Prom/Grafana; guest collector under `monitoring/data-collector/`
