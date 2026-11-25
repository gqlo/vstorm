# Cloud-init and fio workload

Run a configurable fio storage I/O workload inside VMs at boot. For VM CPU and memory options (`--cores`, `--memory`, etc.), see the main [README](../README.md#options).

## Quick start: example commands

| Goal | Command |
|------|---------|
| Default (randrw) on medium VMs | `vstorm --cloudinit=workload/fio/cloudinit-fio-workload.yaml --cores=4 --memory=8Gi --vms=10` |
| Mixed random read/write | `vstorm --cloudinit=workload/fio/cloudinit-fio-workload.yaml --env WORKLOAD_TYPE=randrw --vms=5` |
| Sequential write, larger file | `vstorm --cloudinit=workload/fio/cloudinit-fio-workload.yaml --env WORKLOAD_TYPE=seqwrite --env FIO_SIZE=4G --vms=5` |
| Custom block size and queue depth | `vstorm --cloudinit=workload/fio/cloudinit-fio-workload.yaml --env FIO_BS=64k --env FIO_IODEPTH=64 --vms=10` |
| Short time-based job for quicker feedback | `vstorm --cloudinit=workload/fio/cloudinit-fio-workload.yaml --env FIO_TIME_BASED=1 --env FIO_RUNTIME=15 --vms=5` |
| Dry-run to preview | `vstorm -n --cloudinit=workload/fio/cloudinit-fio-workload.yaml --env WORKLOAD_TYPE=randread --vms=5` |

Default preset is **randrw** (no `--env` needed). Combine with any VM sizing.

## Image requirements and recommendation

The workload **installs `fio` via the guest's package manager** at first boot. Use a **customized QCOW** (or DataSource) that has **working DNF/Yum (or APT) repositories** — or has `fio` preinstalled. When supplying `--dv-url`, prefer an **HTTPS** source with a **pinned digest or signature**; do not treat unsigned HTTP URLs as a verified default.

**OCP OS images** (DataSources from `openshift-virtualization-os-images`, e.g. `rhel9`) are **minimal**: no enabled repos, no preinstalled `fio`. The workload will fail on them ("There are no enabled repositories" / "failed to install fio").

**Recommended:** a custom DataSource or `--dv-url` pointing at an image you control and can verify. Minimal OCP DataSources (`--datasource=rhel9` and similar) will not work unless customized. vstorm's built-in lab HTTP default (if any) is for convenience only and is **not** integrity-verified — override it for integrity-sensitive runs.

Ensure the guest root disk is large enough for `FIO_SIZE` (default `1G`) plus the OS; raise `--storage-size` if needed.

## Run at boot

```bash
vstorm --cloudinit=workload/fio/cloudinit-fio-workload.yaml --vms=10 --namespaces=2
```

Cloud-init will install `fio`, write the workload script to `/opt/fio_workload.sh`, and enable `fio-workload.service` (**one-shot**: runs a single fio job at boot, then exits; does not loop). I/O targets a file under `/root/data` on the guest root filesystem (exercises the VM PVC/DV backing store).

Pass `FIO_*` / `WORKLOAD_TYPE` once via `vstorm --env`. If `RESULT_SERVER_URL` is set, the guest POSTs **one** result JSON when the job finishes. See [workload result sync and dashboard](workload-result-sync-and-dashboard.md).

## Workload presets: `WORKLOAD_TYPE`

| Preset | fio `--rw` | Default `FIO_BS` | Use case |
|--------|------------|------------------|----------|
| `randrw` | `randrw` | `4k` | Mixed random (50/50 unless `FIO_RWMIXREAD` set; default) |
| `randwrite` | `randwrite` | `4k` | Random write pressure |
| `randread` | `randread` | `4k` | Random read latency / IOPS |
| `seqwrite` | `write` | `4k` | Sequential write |
| `seqread` | `read` | `4k` | Sequential read |

```bash
# Default is randrw
vstorm --cloudinit=workload/fio/cloudinit-fio-workload.yaml --cores=4 --memory=8Gi --vms=10

# Write-only or sequential
vstorm --cloudinit=workload/fio/cloudinit-fio-workload.yaml --env WORKLOAD_TYPE=randwrite --vms=10
vstorm --cloudinit=workload/fio/cloudinit-fio-workload.yaml --env WORKLOAD_TYPE=seqwrite --env FIO_SIZE=2G --vms=5
```

## Tuning: env overrides

Override with `--env KEY=VAL` (repeat as needed):

| Parameter | Description |
|-----------|-------------|
| `FIO_DIRECTORY` | Job file directory (default `/root/data`). With `--data-disk-size=N` (opt-in blank `vdb`), mounts `/dev/vdb` here (by mount **source**) and records UUID in `/etc/fstab`. Boot time comes from shared `vstorm-boot-timestamp.service` (`/root/timestamp.txt`); fio reads it for result payloads. |
| `FIO_DATA_DEVICE` | Block device for optional data disk (default `/dev/vdb`); formatted + mounted onto `FIO_DIRECTORY` when present |
| `FIO_SIZE` | File size per job (default `1G`) |
| `FIO_BS` | Block size (overrides preset default) |
| `FIO_IODEPTH` | Queue depth (default `16`) |
| `FIO_NUMJOBS` | Parallel jobs (default `1`) |
| `FIO_TIME_BASED` | `1` = add `--time_based --runtime`; `0` = no runtime limit (default) |
| `FIO_RUNTIME` | Seconds when `FIO_TIME_BASED=1` (default `60`) |
| `FIO_DIRECT` | `1` = O_DIRECT (default), `0` = buffered |
| `FIO_RW` | Override `--rw` independently of `WORKLOAD_TYPE` |
| `FIO_RWMIXREAD` | Read percentage for `randrw`/`rw` (default `50`) |
| `FIO_CUSTOM_OPTS` | When set, run `fio $FIO_CUSTOM_OPTS` once (plus time args only if `FIO_TIME_BASED=1`) |
| `RESULT_SERVER_URL` | Collector results URL (e.g. `http://host:8080/v1/results`). Enables one POST after the job finishes |
| `RESULT_SERVER_TOKEN` | Optional bearer token for collector auth |
| `RESULT_RETRY` / `RESULT_TIMEOUT` | POST retry count / curl timeouts (see script defaults) |
| `VSTORM_BATCH_ID` | Batch id for result join (auto-injected by vstorm when creating VMs) |
| `VSTORM_VM_NAME` | Optional; defaults to guest hostname |

```bash
# Custom block size and depth
vstorm --cloudinit=workload/fio/cloudinit-fio-workload.yaml \
  --env FIO_BS=64k --env FIO_IODEPTH=64 \
  --cores=4 --memory=8Gi --vms=10

# Larger working set, time-based short job
vstorm --cloudinit=workload/fio/cloudinit-fio-workload.yaml \
  --env WORKLOAD_TYPE=randrw --env FIO_SIZE=4G --env FIO_TIME_BASED=1 --env FIO_RUNTIME=30 --vms=5

# Custom fio options (script appends --time_based --runtime only when FIO_TIME_BASED=1)
vstorm --cloudinit=workload/fio/cloudinit-fio-workload.yaml \
  --env 'FIO_CUSTOM_OPTS=--name=custom --filename=/root/data/custom.dat --rw=randread --bs=4k --iodepth=16 --size=512M --direct=1 --ioengine=libaio' \
  --vms=5

# Collect: set FIO_* once, run one job, POST result to collector
vstorm --cloudinit=workload/fio/cloudinit-fio-workload.yaml \
  --env FIO_SIZE=1G --env WORKLOAD_TYPE=randrw \
  --env RESULT_SERVER_URL=http://<reachable-host>:8080/v1/results \
  --cores=4 --memory=8Gi --vms=10 --wait

# Same with an explicit 50Gi data disk (omit --data-disk-size for none)
vstorm --cloudinit=workload/fio/cloudinit-fio-workload.yaml \
  --data-disk-size=50Gi \
  --env FIO_SIZE=10G --env WORKLOAD_TYPE=randrw \
  --env RESULT_SERVER_URL=http://<reachable-host>:8080/v1/results \
  --cores=4 --memory=8Gi --vms=10 --wait
```

## Monitoring

From the host, use **helpers/log-vm** (uses `virtctl ssh`; set `STRESS_WORKLOAD_PASSWORD` to the VM root password from your cloud-init):

```bash
helpers/log-vm -u fio-workload.service <vm-name> <namespace> [lines]
# Example: helpers/log-vm -u fio-workload.service rhel9-abc123-1 abc123-ns-1 30
```

Inside a VM (e.g. via `virtctl console` or SSH):

```bash
systemctl status fio-workload.service
journalctl -u fio-workload.service -f
```

Example output:

```
Starting fio workload (one-shot)
WORKLOAD_TYPE=randrw
FIO_RW=randrw FIO_SIZE=1G FIO_BS=4k FIO_IODEPTH=16 FIO_NUMJOBS=1
...
ACTIVE - Running fio (randrw, bs=4k) until size=1G completes...
fio completed successfully
One-shot workload finished.
```

---

## Design and internals

For contributors and users who want to understand or extend the workload.

### Purpose and scope

- **Scope**: How vstorm injects cloud-init userdata into VMs, how that userdata is processed at first boot, the structure of the fio workload, and guest env injection via `--env`.

### End-to-end flow

1. User runs vstorm with `--cloudinit=workload/fio/cloudinit-fio-workload.yaml`.
2. vstorm reads the file, replaces `{VSTORM_GUEST_ENV}` with `--env` lines if present, base64-encodes, and injects into the cloud-init Secret template.
3. A Secret is created per namespace; each VM references it via `cloudInitNoCloud.secretRef`.
4. On first boot, the guest runs cloud-init (`write_files`, `runcmd`, `packages`).

### Cloud-init modules used

| Module | Purpose |
|--------|---------|
| **write_files** | Script at `/opt/fio_workload.sh`, systemd unit, `/etc/default/vstorm-guest-env`. |
| **runcmd** | SSH config, `systemctl daemon-reload`, enable and start `fio-workload.service`. |
| **packages** | Installs `fio`. Requires working repos; not available on minimal OCP OS images. |

### File layout

| Location | Role |
|----------|------|
| **workload/** | Cloud-init YAML (e.g. `cloudinit-fio-workload.yaml`). |
| **templates/cloudinit-secret.yaml** | Secret template with `userdata: {CLOUDINIT_B64}`. |
| **vstorm** | Reads file, replaces `{VSTORM_GUEST_ENV}`, base64-encodes, substitutes into template. |

### Built-in workload structure

[workload/fio/cloudinit-fio-workload.yaml](../workload/fio/cloudinit-fio-workload.yaml): script at `/opt/fio_workload.sh`, systemd unit (`Type=oneshot`, `Restart=no`) at
`/etc/systemd/system/fio-workload.service`, env from `--env` in `/etc/default/vstorm-guest-env`.
Runs **one** fio job against a file under `FIO_DIRECTORY` (default `/root/data`). By default (`FIO_TIME_BASED=0`) there is no `--time_based`/`--runtime`; the job runs until `--size` completes. Set `FIO_TIME_BASED=1` to add `--time_based --runtime=${FIO_RUNTIME}` (default `60`s). Then the service exits.
**Deployment**: Via `--cloudinit` (recommended), or set env with `--env KEY=VAL`; or copy and run the script standalone inside a VM (`scp` + `ssh`).

### Result sync and dashboard (design)

To collect the one result after the job finishes and browse batches on the collector dashboard, see [workload result sync and dashboard](workload-result-sync-and-dashboard.md).

### References

- [README.md](../README.md) — Custom cloud-init section
- [workload/fio/cloudinit-fio-workload.yaml](../workload/fio/cloudinit-fio-workload.yaml) — built-in workload cloud-init
- [cloud-init and stress-ng workload](cloud-init-stress-ng-workload.md) — sibling CPU/memory workload
- [workload result sync and dashboard](workload-result-sync-and-dashboard.md) — result push + collector/dashboard
