# Cloud-init and stress-ng workload

Run a configurable stress-ng workload inside VMs at boot. For VM CPU and memory options (`--cores`, `--memory`, etc.), see the main [README](../README.md#options).

## Quick start: example commands

| Goal | Command |
|------|---------|
| Medium VMs + default (memory-heavy) workload | `vstorm --cloudinit=workload/cloudinit-stress-ng-workload.yaml --cores=4 --memory=8Gi --vms=10` |
| CPU-heavy workload, 8 cores per VM | `vstorm --cloudinit=workload/cloudinit-stress-ng-workload.yaml --env WORKLOAD_TYPE=cpu-heavy --cores=8 --memory=16Gi --vms=5` |
| Custom min/max CPU and memory % | `vstorm --cloudinit=workload/cloudinit-stress-ng-workload.yaml --env CPU_PERCENT_MIN=25 --env CPU_PERCENT_MAX=75 --env MEM_PERCENT_MIN=40 --env MEM_PERCENT_MAX=85 --vms=10` |
| Short duration, high activity | `vstorm --cloudinit=workload/cloudinit-stress-ng-workload.yaml --env DURATION_MIN=5 --env DURATION_MAX=120 --env CPU_ACTIVE_PROBABILITY=85 --env MEM_ACTIVE_PROBABILITY=85 --vms=10` |
| Allocate RAM only (no CPU burn) | `vstorm --cloudinit=workload/cloudinit-stress-ng-workload.yaml --env 'STRESS_NG_CUSTOM_OPTS=--vm $MEM_WORKERS --vm-bytes ${mem_to_use}M --vm-hang 0' --vms=5` |
| Dry-run to preview | `vstorm -n --cloudinit=workload/cloudinit-stress-ng-workload.yaml --env WORKLOAD_TYPE=balanced --vms=5` |

Default preset is **memory-heavy** (no `--env` needed). Combine with any VM sizing.

## Image requirements and recommendation

**Default image link:** vstorm uses this disk image by default (override with `--dv-url` or `--datasource`):

**<http://storage.scalelab.redhat.com/lee/vm-images/rhel9-cloud-init.qcow>**

The workload **installs `stress-ng` via the guest's package manager** at first boot. Use vstorm's **default QCOW image** (the URL above) or a **custom QCOW** that has **working DNF/Yum (or APT) repositories** — or has `stress-ng` preinstalled.

**OCP OS images** (DataSources from `openshift-virtualization-os-images`, e.g. `rhel9`) are **minimal**: no enabled repos, no Podman, no preinstalled `stress-ng`. The workload will fail on them ("There are no enabled repositories" / "failed to install stress-ng").

**We highly recommend using a customized QCOW image**: vstorm's default URL (if that image has repos), or `--dv-url` with your own QCOW2 (repos enabled or stress-ng preinstalled), or a custom DataSource built from such an image. With `--datasource=rhel9` (or similar), the workload will not work unless the image is customized.

## Run at boot

```bash
vstorm --cloudinit=workload/cloudinit-stress-ng-workload.yaml --vms=10 --namespaces=2
```

Cloud-init will install `stress-ng`, write the workload script to `/opt/stress_ng_random_vm.sh`, and enable `stress-workload.service` so the workload runs forever (and survives reboots).

## Workload presets: `WORKLOAD_TYPE`

| Preset | CPU load | Memory % | Use case |
|--------|----------|----------|----------|
| `memory-heavy` | 10–50% | 80–95% | Memory pressure, migration |
| `cpu-heavy` | 50–100% | 20–80% | CPU saturation |
| `balanced` | 30–70% | 40–70% | Mixed load |

```bash
# Default is memory-heavy
vstorm --cloudinit=workload/cloudinit-stress-ng-workload.yaml --cores=4 --memory=8Gi --vms=10

# CPU-heavy or balanced
vstorm --cloudinit=workload/cloudinit-stress-ng-workload.yaml --env WORKLOAD_TYPE=cpu-heavy --vms=10
vstorm --cloudinit=workload/cloudinit-stress-ng-workload.yaml --env WORKLOAD_TYPE=balanced --vms=10 --namespaces=2
```

## Tuning: min/max and behavior

Override with `--env KEY=VAL` (repeat as needed):

| Parameter | Description |
|-----------|-------------|
| `CPU_PERCENT_MIN`, `CPU_PERCENT_MAX` | CPU % when active |
| `MEM_PERCENT_MIN`, `MEM_PERCENT_MAX` | Memory % (capped at 95) |
| `CPU_ACTIVE_PROBABILITY` | Chance (1–100) to run CPU stress in a cycle; default 50. Set with `MEM_ACTIVE_PROBABILITY` to different values to run CPU and memory out of sync (CPU-only, memory-only, or both per cycle). |
| `MEM_ACTIVE_PROBABILITY` | Chance (1–100) to run memory stress in a cycle; default 50. |
| `DURATION_MIN`, `DURATION_MAX` | Min/max stress duration in seconds (default 5–600) |
| `STRESS_TOGETHER` | `true` = one process; `false` = separate CPU/memory |
| `STRESS_NG_CUSTOM_OPTS` | When set, active cycles run `stress-ng $STRESS_NG_CUSTOM_OPTS --timeout ${duration}s` (script appends `--timeout`). All other tunables still apply; you can use `$mem_to_use`, `$MEM_WORKERS`, `$duration`, `$CPU_CORES`, `$cpu_load`, etc. in the value. Example: allocate RAM without burning CPU: `--vm $MEM_WORKERS --vm-bytes ${mem_to_use}M --vm-hang 0`. |

```bash
# Custom CPU and memory range
vstorm --cloudinit=workload/cloudinit-stress-ng-workload.yaml \
  --env CPU_PERCENT_MIN=20 --env CPU_PERCENT_MAX=40 \
  --env MEM_PERCENT_MIN=50 --env MEM_PERCENT_MAX=70 \
  --cores=4 --memory=8Gi --vms=10

# Short duration, high activity
vstorm --cloudinit=workload/cloudinit-stress-ng-workload.yaml \
  --env DURATION_MIN=10 --env DURATION_MAX=60 --env CPU_ACTIVE_PROBABILITY=90 --env MEM_ACTIVE_PROBABILITY=90 --vms=10

# Combine preset + overrides
vstorm --cloudinit=workload/cloudinit-stress-ng-workload.yaml \
  --env WORKLOAD_TYPE=balanced \
  --env CPU_PERCENT_MIN=50 --env CPU_PERCENT_MAX=90 --env CPU_ACTIVE_PROBABILITY=75 --env MEM_ACTIVE_PROBABILITY=75 \
  --cores=4 --memory=8Gi --vms=10 --namespaces=2

# CPU and memory out of sync: CPU active in ~70% of cycles, memory in ~40%
vstorm --cloudinit=workload/cloudinit-stress-ng-workload.yaml \
  --env CPU_ACTIVE_PROBABILITY=70 --env MEM_ACTIVE_PROBABILITY=40 --vms=10

# Custom stress-ng options: allocate RAM only (--vm-hang 0 = no CPU thrash). All tunables (duration, mem_to_use, etc.) still apply.
vstorm --cloudinit=workload/cloudinit-stress-ng-workload.yaml \
  --env 'STRESS_NG_CUSTOM_OPTS=--vm $MEM_WORKERS --vm-bytes ${mem_to_use}M --vm-hang 0' --vms=5
```

## Monitoring

From the host, use **helpers/log-vm** (uses `virtctl ssh`; set `STRESS_WORKLOAD_PASSWORD` to the VM root password from your cloud-init). It shows both cloud-init and the workload unit journal in one run:

```bash
helpers/log-vm <vm-name> <namespace> [lines]
helpers/log-vm -u <unit> <vm-name> <namespace> [lines]
# Example: helpers/log-vm rhel9-abc123-1 vm-abc123-ns-1 30
# Set password: STRESS_WORKLOAD_PASSWORD=<your-vm-root-password> helpers/log-vm <vm> <ns>
```

Inside a VM (e.g. via `virtctl console` or SSH):

```bash
systemctl status stress-workload.service
journalctl -u stress-workload.service -f
```

Example output:

```
Cycle 1: ACTIVE - Running stress test for 237 seconds...
Cycle 2: IDLE - Sleeping for 45 seconds...
Cycle 3: ACTIVE - Running stress test for 89 seconds...
```

---

## Design and internals

For contributors and users who want to understand or extend the workload.

### Purpose and scope

- **Scope**: How vstorm injects cloud-init userdata into VMs, how that userdata is processed at first boot, the structure of the stress-ng workload, and guest env injection via `--env`.

### End-to-end flow

1. User runs vstorm with `--cloudinit=workload/cloudinit-stress-ng-workload.yaml`.
2. vstorm reads the file, replaces `{VSTORM_GUEST_ENV}` with `--env` lines if present, base64-encodes, and injects into the cloud-init Secret template.
3. A Secret is created per namespace; each VM references it via `cloudInitNoCloud.secretRef`.
4. On first boot, the guest runs cloud-init (`write_files`, `runcmd`, `packages`).

### Cloud-init modules used

| Module | Purpose |
|--------|---------|
| **write_files** | Script at `/opt/stress_ng_random_vm.sh`, systemd unit, `/etc/default/vstorm-guest-env`. |
| **runcmd** | SSH config, `systemctl daemon-reload`, enable and start `stress-workload.service`. |
| **packages** | Installs `stress-ng`. Requires working repos; not available on minimal OCP OS images. |

### File layout

| Location | Role |
|----------|------|
| **workload/** | Cloud-init YAML (e.g. `cloudinit-stress-ng-workload.yaml`). |
| **templates/cloudinit-secret.yaml** | Secret template with `userdata: {CLOUDINIT_B64}`. |
| **vstorm** | Reads file, replaces `{VSTORM_GUEST_ENV}`, base64-encodes, substitutes into template. |

### Built-in workload structure

[workload/cloudinit-stress-ng-workload.yaml](../workload/cloudinit-stress-ng-workload.yaml): script at `/opt/stress_ng_random_vm.sh`, systemd unit at
`/etc/systemd/system/stress-workload.service`, env from `--env` in `/etc/default/vstorm-guest-env`.
The simulator runs in an infinite loop — each cycle it rolls independently for CPU and memory (`CPU_ACTIVE_PROBABILITY`, `MEM_ACTIVE_PROBABILITY`; both default to 50%), so you can have CPU-only, memory-only, both, or idle. When stress runs, it uses randomized CPU/memory levels for a random duration (`DURATION_MIN`–`DURATION_MAX`).

**Deployment**: Via `--cloudinit` (recommended), or set env with `--env KEY=VAL`; or copy and run the script standalone inside a VM (`scp` + `ssh`).

### References

- [README.md](../README.md) — Custom cloud-init section
- [workload/cloudinit-stress-ng-workload.yaml](../workload/cloudinit-stress-ng-workload.yaml) — built-in workload cloud-init
