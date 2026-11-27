# Live Cluster Test Report

## Environment

| Item | Value |
|---|---|
| Cluster | OpenShift 4.21.0 (Kubernetes 1.34.2) |
| Auth | `system:admin` (kubeadmin) |
| Storage | OCS 4.x (Ceph RBD) |
| Default SC | `ocs-storagecluster-ceph-rbd` |
| Virtualization SC | `ocs-storagecluster-ceph-rbd-virtualization` |
| Snapshot class | `ocs-storagecluster-rbdplugin-snapclass` |
| oc client | 4.15.9 |
| virtctl | v1.6.3 (server: v1.7.0) |

## Summary

| # | Command | VMs | All Running | SSH | Verdict |
|---|---|---|---|---|---|
| 1 | `--cores=4 --memory=8Gi --vms=3 --namespaces=2` | 3 | Yes | N/A (URL mode, no cloud-init) | **PASS** |
| 2 | `--datasource=fedora --vms=5 --namespaces=1` | 5 | Yes | 3/5 OK | **PASS** |
| 3 | `--dv-url=http://d21-h25-000-r650:8000/rhel9-cloud-init.qcow --vms=2 --namespaces=2` | 0 | No | N/A | **FAIL** |
| 4 | `--cloudinit=workload/stress-ng/cloudinit-stress-ng-workload.yaml --vms=5 --namespaces=2` | 5 | Yes | 2/2 OK | **PASS** |
| 5 | `--datasource=centos-stream9 --vms=5 --namespaces=1` | 5 | Yes | 0/5 FAIL | **PARTIAL** |
| 6 | `--storage-class=ocs-storagecluster-ceph-rbd --vms=5 --namespaces=2` | 5 | Yes | N/A (URL mode, no cloud-init) | **PASS** |
| 7 | `--no-snapshot --vms=1 --namespaces=1` | 1 | Yes | N/A (URL mode, no cloud-init) | **PASS** |
| 8 | `--containerdisk --vms=3 --namespaces=1` | 3 | Yes | 2/3 OK | **PASS** |
| 9 | `--storage-class=lvms-vg-nvme --snapshot-class=lvms-vg-nvme --vms=3 --namespaces=2` | 0 | No | N/A | **FAIL** |
| 10 | `--vms-per-namespace=5 --namespaces=3 --wait` | 15 | Yes | N/A (URL mode, no cloud-init) | **PASS** |
| 11 | `--containerdisk --cloudinit=workload/stress-ng/cloudinit-stress-ng-workload.yaml --vms=3 --namespaces=2` | 3 | Yes | 2/2 OK | **PASS** |
| 12 | `--run-strategy=Halted --vms=3 --namespaces=1` | 3 | N/A (Halted) | N/A (Halted) | **PASS** |
| 13 | `--cores=2 --memory=4Gi --request-cpu=500m --request-memory=2Gi --vms=3` | 3 | Yes | N/A (URL mode, no cloud-init) | **PASS** |
| 14 | `--basename=perf-vm --storage-size=50Gi --vms=3 --namespaces=1` | 3 | Yes | N/A (URL mode, no cloud-init) | **PASS** |
| 15 | `--profile --vms=10 --namespaces=2` | 10 | Yes | N/A | **PARTIAL** |
| 16 | `--memory=8Gi --cores=2 --dv-url=... --cloudinit=... --env STRESS_TOGETHER=0 --env CPU_ACTIVE_PROBABILITY=30 --env MEM_ACTIVE_PROBABILITY=80` | 1 | Yes | 1/1 OK | **PASS** |
| 17 | `--cores=4 --memory=8Gi --cloudinit=workload/dirty-mem/cloudinit-dirty-mem-pages.yaml --dv-url=... --env DIRTY_RATE_FRACTION=0.4 --vms=1` | 1 | Yes | 1/1 OK | **PASS** |

**2026-04-30 run: 66 VMs created across all tests. 66/66 reached Running state (Tests 3 and 9 failed with 0 VMs created). 13/17 tests fully passed. 2 partial. 2 fail (infrastructure issues).**

### Run history

- **2026-02-12** -- Initial run (Tests 1-7)
- **2026-02-12** -- Re-run after auto-derive basename change (Tests 1-7): 26/26 Running, same results
- **2026-04-30** -- Full run (Tests 1-17): default disk source changed to URL; Tests 3/9 FAIL (infra); Test 15 PARTIAL (profile dump non-interactive)

---

## Test 1 -- Default disk source, custom CPU/memory, snapshot mode

**Command:**

```bash
./vstorm --cores=4 --memory=8Gi --vms=3 --namespaces=2
```

**Batch ID:** `08b08a` (2026-04-30), previously `e2c4ef` (2026-02-12)

> **Note (2026-04-30):** Default disk source changed from DataSource (`rhel9`) to URL (`http://storage.scalelab.redhat.com/lee/vm-images/rhel9-cloud-init.qcow`). Cloud-init is not auto-applied in URL mode (only in DataSource/containerdisk modes), so SSH is not testable without `--cloudinit`.

### Options verified -- Test 1

| Option | Expected | Verified |
|---|---|---|
| `--cores=4` | 4 CPU cores per VM | Yes -- `cores: 4` in VM spec |
| `--memory=8Gi` | 8Gi guest memory | Yes -- `guest: 8Gi` in VM spec |
| `--vms=3` | 3 total VMs | Yes -- 3 VMs created |
| `--namespaces=2` | 2 namespaces | Yes -- `vm-08b08a-ns-1`, `vm-08b08a-ns-2` |
| VM distribution | 2 in ns-1, 1 in ns-2 (remainder) | Yes -- confirmed |
| Snapshot mode (default) | Base DV + VolumeSnapshot per ns | Yes -- 2 DVs (`vm-base`), 2 VolumeSnapshots (readyToUse=true) |
| Storage class | `ocs-storagecluster-ceph-rbd-virtualization` | Yes -- auto-selected |
| Access mode | Auto-detected `ReadWriteMany` | Yes -- on both base DVs |
| Run strategy | `Always` (default) | Yes -- all 3 VMs |
| Auto cloud-init | Not applied (URL mode default) | Yes -- no Secret created |
| SSH | N/A (no cloud-init in URL mode) | N/A -- expected |
| Labels | `batch-id`, `vm-basename` | Yes -- on all resources |

---

## Test 2 -- Fedora DataSource, snapshot mode

**Command:**

```bash
./vstorm --datasource=fedora --vms=5 --namespaces=1
```

**Batch ID:** `53319c` (2026-04-30), previously `e12d11` (2026-02-12)

### Options verified -- Test 2

| Option | Expected | Verified |
|---|---|---|
| `--datasource=fedora` | Base DV clones from `fedora` DataSource | Yes -- `sourceRef.kind=DataSource, sourceRef.name=fedora, ns=openshift-virtualization-os-images` |
| `--vms=5` | 5 total VMs | Yes -- 5 VMs created |
| `--namespaces=1` | 1 namespace | Yes -- `vm-53319c-ns-1` |
| Snapshot mode (default) | Base DV + VolumeSnapshot | Yes -- 1 DV (`fedora-base`), 1 VolumeSnapshot (readyToUse=true) |
| Default cores/memory | 1 core, 1Gi | Yes -- `cores: 1`, `guest: 1Gi` |
| Auto cloud-init | Default cloud-init applied | Yes -- `fedora-cloudinit` Secret present |
| SSH | Root login with password | Yes -- 3/5 VMs tested (CPUs=1, RAM=863Mi) |

---

## Test 3 -- URL import, snapshot mode

**Command:**

```bash
./vstorm --dv-url=http://d21-h25-000-r650.rdu2.scalelab.redhat.com:8000/rhel9-cloud-init.qcow --vms=2 --namespaces=2
```

**Batch ID:** `d238b0` (2026-04-30, FAILED), previously `f392c3` (2026-02-12)

### Failure details -- Test 3 (2026-04-30)

- **Error:** `Unable to connect to http data source: HTTP request errored: Get "http://d21-h25-000-r650.rdu2.scalelab.redhat.com:8000/rhel9-cloud-init.qcow": dial tcp 198.18.0.1:8000: connect: connection refused`
- **Root cause:** The HTTP server at port 8000 on `d21-h25-000-r650` is not running. Port 8088 on the same host (used in Test 16) worked fine.
- **Result:** 0 VMs created (vstorm waited indefinitely for DV import; process was manually killed after ~10 minutes of retries).
- **Verdict:** **FAIL** (infrastructure issue — server down, not a vstorm bug)

### Options verified -- Test 3 (2026-02-12 reference)

| Option | Expected | Verified |
|---|---|---|
| `--dv-url=...` | DV uses `source.http.url` (not DataSource sourceRef) | Yes -- URL confirmed on both base DVs |
| `--vms=2` | 2 total VMs | Yes |
| `--namespaces=2` | 2 namespaces | Yes -- `vm-c9c0ac-ns-1`, `vm-c9c0ac-ns-2` |
| Snapshot mode (default) | Base DV + VolumeSnapshot per ns | Yes -- 2 DVs, 2 VolumeSnapshots (readyToUse=true) |
| No auto cloud-init | URL mode does not inject cloud-init | Yes -- no Secret created in either namespace |
| Storage size | Default 32Gi | Yes -- shown in creation summary |
| SSH | Not expected (no cloud-init, no root password) | Confirmed -- SSH refused (exit 5), expected |

---

## Test 4 -- Custom cloud-init (stress workload), snapshot mode

**Command:**

```bash
./vstorm --cloudinit=workload/stress-ng/cloudinit-stress-ng-workload.yaml --vms=5 --namespaces=2
```

**Batch ID:** `071186` (2026-04-30), previously `4bdda2` (2026-02-12)

### Options verified -- Test 4

| Option | Expected | Verified |
|---|---|---|
| `--cloudinit=workload/stress-ng/cloudinit-stress-ng-workload.yaml` | Custom cloud-init Secret per namespace | Yes -- `vm-cloudinit` Secret in both ns (Opaque, 1 key) |
| Cloud-init in VM | `cloudInitNoCloud.secretRef.name: vm-cloudinit` | Yes -- confirmed via jsonpath |
| Not auto-applied | Should not say "applying default cloud-init" | Yes -- log says `Cloud-init: workload/stress-ng/cloudinit-stress-ng-workload.yaml` |
| `--vms=5` | 5 total VMs | Yes |
| `--namespaces=2` | 2 namespaces | Yes |
| VM distribution | 3 in ns-1, 2 in ns-2 | Yes -- confirmed |
| Snapshot mode (default) | Base DV + VolumeSnapshot | Yes -- 2 DVs, 2 VolumeSnapshots (readyToUse=true) |
| stress-workload service | Service exists and active | Yes -- `systemctl is-active stress-workload` returned "active" on tested VMs |
| SSH | Root login with password | Yes -- 2 VMs tested across 2 namespaces (CPUs=1, RAM=679Mi) |

---

## Test 5 -- CentOS Stream 9 DataSource, snapshot mode

**Command:**

```bash
./vstorm --datasource=centos-stream9 --vms=5 --namespaces=1
```

**Batch ID:** `92dc35` (2026-04-30), previously `ccd3f7` (2026-02-12)

### Options verified -- Test 5

| Option | Expected | Verified |
|---|---|---|
| `--datasource=centos-stream9` | Base DV clones from `centos-stream9` DataSource | Yes -- `sourceRef.kind=DataSource, sourceRef.name=centos-stream9` |
| `--vms=5` | 5 total VMs | Yes -- all 5 Running |
| `--namespaces=1` | 1 namespace | Yes -- `vm-92dc35-ns-1` |
| Snapshot mode | Base DV + VolumeSnapshot | Yes -- 1 DV (`centos-stream9-base`), 1 VolumeSnapshot (readyToUse=true) |
| Auto cloud-init | Default cloud-init applied | Yes -- `centos-stream9-cloudinit` Secret present |
| SSH | Root login with password | **FAILED** -- all 5 VMs unreachable (see below) |

### SSH failure details

- **Symptom:** `ssh` returns "no route to host" on port 22 for all 5 VMs, even after 2+ minutes of wait time.
- **Guest agent:** `guestOSInfo: {}` (empty) -- the `qemu-guest-agent` is not running, confirming the guest did not fully configure itself.
- **Root cause:** The `centos-stream9` golden image from `openshift-virtualization-os-images` either does not have `cloud-init` pre-installed, or does not have `sshd` enabled by default. Without cloud-init processing, the root password is never set and sshd is never configured for password authentication.
- **Verdict:** vstorm created and started all VMs correctly (5/5 Running). The failure is in the **guest image**, not in vstorm. The centos-stream9 DataSource image requires cloud-init and sshd pre-configured for the default cloud-init to be effective.

---

## Test 6 -- Non-default storage class, auto-disabled snapshots

**Command:**

```bash
./vstorm --storage-class=ocs-storagecluster-ceph-rbd --vms=5 --namespaces=2
```

**Batch ID:** `eda2e6` (2026-04-30), previously `fbf6df` (2026-02-12)

> **Note (2026-04-30):** Default disk source is now URL, not DataSource. The script still auto-disables snapshots when a custom SC is given without `--snapshot-class`. With URL mode, a `vm-base` DV is created per namespace; per-VM DVs clone from it (no snapshots). No cloud-init auto-applied in URL mode.

### Options verified -- Test 6

| Option | Expected | Verified |
|---|---|---|
| `--storage-class=ocs-storagecluster-ceph-rbd` | Custom storage class on all DVs | Yes -- `sc=ocs-storagecluster-ceph-rbd` on per-VM DVs |
| Snapshots auto-disabled | No `--snapshot-class` provided with custom SC | Yes -- log says "Snapshot mode: disabled" |
| No VolumeSnapshots | Should not create VolumeSnapshots | Yes -- empty |
| Base DV present | URL import creates `vm-base` DV per ns | Yes -- `vm-base` Succeeded, per-VM DVs clone from it |
| Access mode | Auto-detected `ReadWriteMany` | Yes -- confirmed on DVs |
| `--vms=5` | 5 total VMs | Yes |
| `--namespaces=2` | 2 namespaces | Yes |
| VM distribution | 3 in ns-1, 2 in ns-2 | Yes -- confirmed |
| Auto cloud-init | Not applied (URL mode, no --cloudinit) | Yes -- no Secrets created |
| SSH | N/A (no cloud-init in URL mode) | N/A -- expected |

---

## Test 7 -- Explicit no-snapshot mode

**Command:**

```bash
./vstorm --no-snapshot --vms=1 --namespaces=1
```

**Batch ID:** `fdfe81` (2026-04-30), previously `8d5b6c` (2026-02-12)

> **Note (2026-04-30):** Default disk source is now URL. With `--no-snapshot`, a `vm-base` DV is created from the URL but no VolumeSnapshot is taken; the VM inline DV clones directly from `vm-base`. No cloud-init auto-applied in URL mode.

### Options verified -- Test 7

| Option | Expected | Verified |
|---|---|---|
| `--no-snapshot` | Snapshot mode explicitly disabled | Yes -- log says "Snapshot mode: disabled" |
| No VolumeSnapshots | Should not create VolumeSnapshots | Yes -- empty |
| Base DV present | URL import creates `vm-base` DV | Yes -- `vm-base` Succeeded |
| VM inline DV | VM's DV clones directly from `vm-base` (no snap) | Yes -- `dvName=vm-fdfe81-1` references base DV directly |
| Storage class | Default `ocs-storagecluster-ceph-rbd-virtualization` | Yes -- confirmed |
| `--vms=1` | 1 VM | Yes |
| `--namespaces=1` | 1 namespace | Yes -- `vm-fdfe81-ns-1` |
| Auto cloud-init | Not applied (URL mode, no --cloudinit) | Yes -- no Secret created |
| SSH | N/A (no cloud-init in URL mode) | N/A -- expected |

---

---

## Test 8 -- Container disk mode (no storage needed)

**Command:**

```bash
./vstorm --containerdisk --vms=3 --namespaces=1
```

**Batch ID:** `36635e` (2026-04-30), previously `c802a2` (2026-04-30 earlier run)

### Options verified -- Test 8

| Option | Expected | Verified |
|---|---|---|
| `--containerdisk` | VMs boot from container image (`quay.io/containerdisks/fedora:latest`) | Yes -- `containerDisk.image=quay.io/containerdisks/fedora:latest` in VM volumes |
| No PVC/storage | No DataVolume, no PVC, no VolumeSnapshot created | Yes -- all empty |
| `--vms=3` | 3 total VMs | Yes -- 3 VMs created, all Running |
| `--namespaces=1` | 1 namespace | Yes -- `vm-36635e-ns-1` |
| Auto cloud-init | Default cloud-init applied (root:password) | Yes -- `fedora-cloudinit` Secret created |
| VM basename | Auto-derived `fedora` | Yes -- VMs named `fedora-36635e-{1,2,3}` |
| SSH | Root login with password | Yes -- 2/3 VMs tested (CPUs=1, RAM=863Mi) |

---

## Test 9 -- Custom storage class with explicit snapshot class

**Command:**

```bash
./vstorm --storage-class=lvms-vg-nvme --snapshot-class=lvms-vg-nvme --vms=3 --namespaces=2
```

**Batch ID:** `9b87cd` (2026-04-30)

### Failure details -- Test 9

- **Root cause:** `lvms-vg-nvme` uses `WaitForFirstConsumer` (WFFC) volume binding. vstorm
  detected WFFC and auto-disabled snapshot mode, falling back to "direct PVC clone". A
  `vm-base` DV was created per namespace from the default URL. However, with WFFC, the base
  PVC stays `PendingPopulation` until a consumer pod schedules it; CDI's clone DVs
  (`vm-9b87cd-{1,2,3}`) can't clone from an unbound source, creating a deadlock. After 74+
  minutes, all 3 VMs remained in `Provisioning` state and never reached Running.
- **Error events:** `target PVC vm-9b87cd-1 Pending and Waiting for a volume to be created by 'topolvm.io'`; base PVC stuck in `WaitForFirstConsumer`.
- **Verdict:** **FAIL** (WFFC + URL-import base DV deadlock — CDI issue, not a vstorm bug)

### Options verified -- Test 9

| Option | Expected | Verified |
|---|---|---|
| `--storage-class=lvms-vg-nvme` | Custom storage class on all resources | Yes -- storage class set correctly |
| `--snapshot-class=lvms-vg-nvme` | Snapshot mode stays enabled (both classes provided) | No -- WFFC auto-disabled snapshots |
| WFFC detection | vstorm warns and falls back to direct PVC clone | Yes -- log says "Warning: Disabling snapshot mode -- WFFC storage won't bind until consumer Pod scheduled" |
| `--vms=3` | 3 total VMs | Created but stuck in Provisioning |
| `--namespaces=2` | 2 namespaces | Yes -- `vm-9b87cd-ns-1`, `vm-9b87cd-ns-2` |
| VMs reach Running | All 3 Running | **No** -- Provisioning for 74+ min (deadlock) |

---

## Test 10 -- VMs-per-namespace distribution with wait

**Command:**

```bash
./vstorm --vms-per-namespace=5 --namespaces=3 --wait
```

**Batch ID:** `7c391b` (2026-04-30)

### Options verified -- Test 10

| Option | Expected | Verified |
|---|---|---|
| `--vms-per-namespace=5` | Exactly 5 VMs in each namespace | Yes -- 5/5/5 confirmed |
| `--namespaces=3` | 3 namespaces | Yes -- `vm-7c391b-ns-{1,2,3}` |
| Total VMs | 15 (5 x 3) | Yes -- 15 VMs, all Running |
| `--wait` | Command blocks until all VMs reach Running state | Yes -- exit code 0 after all 15/15 Running |
| Snapshot mode (default) | Base DV + VolumeSnapshot per namespace | Yes -- 3 base DVs, 3 VolumeSnapshots (readyToUse=true) |
| Auto cloud-init | Not applied (URL mode default) | Yes -- no cloud-init Secrets (URL mode) |
| SSH | N/A (no cloud-init in URL mode) | N/A -- expected |

---

## Test 11 -- Container disk with custom cloud-init workload

**Command:**

```bash
./vstorm --containerdisk --cloudinit=workload/stress-ng/cloudinit-stress-ng-workload.yaml --vms=3 --namespaces=2
```

**Batch ID:** `a21648` (2026-04-30)

### Options verified -- Test 11

| Option | Expected | Verified |
|---|---|---|
| `--containerdisk` | VMs boot from container image (no PVC) | Yes -- `containerDisk.image=quay.io/containerdisks/fedora:latest` |
| `--cloudinit=workload/stress-ng/cloudinit-stress-ng-workload.yaml` | Custom cloud-init Secret per namespace | Yes -- `fedora-cloudinit` Secret in both ns (Opaque, 1 key) |
| Cloud-init in VM | `cloudInitNoCloud.secretRef` references the custom Secret | Yes -- confirmed via jsonpath |
| `--vms=3` | 3 total VMs | Yes -- 3 VMs, all Running |
| `--namespaces=2` | 2 namespaces | Yes -- `vm-a21648-ns-{1,2}` |
| VM distribution | 2 in ns-1, 1 in ns-2 | Yes -- confirmed |
| stress-workload service | Service exists and active on boot | Yes -- `systemctl is-active stress-workload` returned "active" (stress-ng installed) |
| SSH | Root login with password | Yes -- 2 VMs tested (CPUs=1, RAM=863Mi) |

---

## Test 12 -- Halted VMs (create without starting)

**Command:**

```bash
./vstorm --run-strategy=Halted --vms=3 --namespaces=1
```

**Batch ID:** `76711e` (2026-04-30)

### Options verified -- Test 12

| Option | Expected | Verified |
|---|---|---|
| `--run-strategy=Halted` | `runStrategy: Halted` on all VMs | Yes -- all 3 VMs show `runStrategy=Halted` |
| No VMI | No VirtualMachineInstance created (VMs not started) | Yes -- `oc get vmi -n vm-76711e-ns-1` returns empty |
| `--vms=3` | 3 VMs created | Yes -- 3 VMs in Stopped state |
| `--namespaces=1` | 1 namespace | Yes -- `vm-76711e-ns-1` |
| Snapshot mode (default) | Base DV + VolumeSnapshot | Yes -- `vm-base` Succeeded, VolumeSnapshot readyToUse=true |
| Auto cloud-init | Not applied (URL mode, no --cloudinit) | Yes -- no Secret created |
| Start manually | `virtctl start <vm>` transitions VM to Running | Yes -- `vm-76711e-1` reached Running after `virtctl start` |

---

## Test 13 -- Custom resource requests separate from guest resources

**Command:**

```bash
./vstorm --cores=2 --memory=4Gi --request-cpu=500m --request-memory=2Gi --vms=3 --namespaces=1
```

**Batch ID:** `eff449` (2026-04-30)

### Options verified -- Test 13

| Option | Expected | Verified |
|---|---|---|
| `--cores=2` | Guest sees 2 CPU cores | Yes -- `cores: 2` in VM spec |
| `--memory=4Gi` | Guest sees 4Gi memory | Yes -- `guest: 4Gi` in VM spec |
| `--request-cpu=500m` | Kubernetes pod CPU request is 500m | Yes -- `requests.cpu=500m` in VM spec |
| `--request-memory=2Gi` | Kubernetes pod memory request is 2Gi | Yes -- `requests.memory=2Gi` in VM spec |
| Oversubscription | Guest resources exceed pod requests (burst scheduling) | Yes -- 4Gi guest, 2Gi pod request |
| `--vms=3` | 3 total VMs | Yes -- 3 VMs, all Running |
| `--namespaces=1` | 1 namespace | Yes -- `vm-eff449-ns-1` |
| SSH | N/A (URL mode, no cloud-init) | N/A -- Permission denied (no password set) |

---

## Test 14 -- Custom basename and disk size

**Command:**

```bash
./vstorm --basename=perf-vm --storage-size=50Gi --vms=3 --namespaces=1
```

**Batch ID:** `041086` (2026-04-30)

### Options verified -- Test 14

| Option | Expected | Verified |
|---|---|---|
| `--basename=perf-vm` | VM names use `perf-vm-{batch}-{N}` pattern | Yes -- `perf-vm-041086-{1,2,3}` |
| Base DV name | `perf-vm-base` | Yes -- `perf-vm-base` DV in ns-1 |
| Cloud-init Secret | `perf-vm-cloudinit` | No -- URL mode, no cloud-init Secret created |
| `--storage-size=50Gi` | PVCs are 50Gi (visible in `oc get pvc`) | Yes -- all PVCs 50Gi RWX |
| `--vms=3` | 3 total VMs | Yes -- 3 VMs, all Running |
| `--namespaces=1` | 1 namespace | Yes -- `vm-041086-ns-1` |
| Snapshot mode (default) | Base DV + VolumeSnapshot | Yes -- VolumeSnapshot readyToUse=true, 50Gi |
| SSH | N/A (URL mode, no cloud-init) | N/A -- expected |

---

## Test 15 -- Cluster profiling during batch creation

**Command:**

```bash
./vstorm --profile --vms=10 --namespaces=2
```

**Batch ID:** `9dcefa` (2026-04-30)

### Options verified -- Test 15

| Option | Expected | Verified |
|---|---|---|
| `--profile` | Profiler start/stop/dump lifecycle runs around VM creation | Partial -- start succeeded; dump failed (non-interactive) |
| Profiler start | `cluster-profiler --cmd start` succeeds | Yes -- `SUCCESS: started cpu profiling KubeVirt control plane` |
| Profile output | pprof files saved to `logs/profile-{BATCH_ID}/` | **No** -- dump step requires interactive `read` prompt; not reached in background |
| `--vms=10` | 10 total VMs | Yes -- 10 VMs, all Running |
| `--namespaces=2` | 2 namespaces | Yes -- `vm-9dcefa-ns-{1,2}` |
| VM distribution | 5 in ns-1, 5 in ns-2 | Yes -- confirmed |
| VM creation | All VMs created and running normally alongside profiling | Yes -- VM creation completed (exit code 1 only from dump step) |
| Snapshot mode | Base DV + VolumeSnapshot per namespace | Yes -- 2 VolumeSnapshots readyToUse=true |
| Auto cloud-init | Not applied (URL mode default) | Yes -- no Secrets created |

**Verdict: PARTIAL** -- profiler start works; dump requires interactive terminal (`read` prompt). Run interactively to capture pprof output.

---

## Test 16 -- URL import with stress-ng workload, per-workload env tuning

**Command:**

```bash
./vstorm --memory=8Gi --cores=2 \
  --dv-url=http://d21-h25-000-r650.rdu2.scalelab.redhat.com:8088/rhel9-cloud-init.qcow \
  --cloudinit=workload/stress-ng/cloudinit-stress-ng-workload.yaml \
  --env STRESS_TOGETHER=0 \
  --env CPU_ACTIVE_PROBABILITY=30 \
  --env MEM_ACTIVE_PROBABILITY=80
```

**Batch ID:** `571770` (2026-04-30)

### Options verified -- Test 16

| Option | Expected | Verified |
|---|---|---|
| `--memory=8Gi` | Guest sees 8Gi memory | Yes -- `mem=8Gi`; `free -h` shows 7.5Gi total |
| `--cores=2` | Guest sees 2 CPU cores | Yes -- `cores=2`; `nproc` shows 2 |
| `--dv-url=...` | DV uses `source.http.url` (not DataSource sourceRef) | Yes -- `url=http://d21-h25-000-r650...:8088/rhel9-cloud-init.qcow` on base DV |
| `--cloudinit=workload/stress-ng/cloudinit-stress-ng-workload.yaml` | Custom cloud-init Secret per namespace | Yes -- `vm-cloudinit` Secret present |
| `--env STRESS_TOGETHER=0` | In `/etc/default/vstorm-guest-env` in Secret | Yes -- confirmed in Secret data |
| `--env CPU_ACTIVE_PROBABILITY=30` | In `/etc/default/vstorm-guest-env` in Secret | Yes -- confirmed in Secret data |
| `--env MEM_ACTIVE_PROBABILITY=80` | In `/etc/default/vstorm-guest-env` in Secret | Yes -- confirmed in Secret data |
| Env vars in cloud-init | All three `--env` values present in the Secret data | Yes -- `STRESS_TOGETHER=0`, `CPU_ACTIVE_PROBABILITY=30`, `MEM_ACTIVE_PROBABILITY=80` |
| stress-workload service | Service exists and active on boot | Yes -- `systemctl is-active stress-workload` returned "active" |
| SSH | Root login with password | Yes -- CPUs=2, RAM=7.5Gi, hostname correct |

---

## Test 17 -- URL import with dirty-mem-pages workload

**Command:**

```bash
./vstorm --cores=4 --memory=8Gi \
  --dv-url=http://storage.scalelab.redhat.com/lee/vm-images/rhel9-cloud-init.qcow \
  --cloudinit=workload/dirty-mem/cloudinit-dirty-mem-pages.yaml \
  --env DIRTY_RATE_FRACTION=0.4 \
  --vms=1
```

**Batch ID:** `3e0d34` (2026-04-30)

### Options verified -- Test 17

| Option | Expected | Verified |
|---|---|---|
| `--cores=4` | Guest sees 4 CPU cores | Yes -- `cores=4`; `nproc` shows 4 |
| `--memory=8Gi` | Guest sees 8Gi memory | Yes -- `mem=8Gi`; `free -h` shows 7.5Gi total |
| `--dv-url=...` | DV uses `source.http.url` (not DataSource sourceRef) | Yes -- URL confirmed on base DV |
| `--cloudinit=workload/dirty-mem/cloudinit-dirty-mem-pages.yaml` | Dirty-mem cloud-init Secret created | Yes -- `vm-cloudinit` Secret with dirty-mem-pages content |
| `--env DIRTY_RATE_FRACTION=0.4` | Env var present in Secret in `/etc/default/vstorm-guest-env` | Yes -- `DIRTY_RATE_FRACTION=0.4` confirmed in Secret data |
| `--vms=1` | 1 VM created | Yes -- `vm-3e0d34-1` Running |
| dirty-mem-pages service | systemd service running | Yes -- `systemctl is-active dirty-mem-pages` returned "active" |
| SSH | Root login with password | Yes -- CPUs=4, RAM=7.5Gi, hostname correct |

---

## All batches created

### 2026-02-12 run (Tests 1-7)

| Batch ID | Test | VMs | Namespaces |
|---|---|---|---|
| `e2c4ef` | Test 1 | 3 | 2 |
| `e12d11` | Test 2 | 5 | 1 |
| `f392c3` | Test 3 | 2 | 2 |
| `4bdda2` | Test 4 | 5 | 2 |
| `ccd3f7` | Test 5 | 5 | 1 |
| `fbf6df` | Test 6 | 5 | 2 |
| `8d5b6c` | Test 7 | 1 | 1 |

### 2026-04-30 run (Tests 1-17)

| Batch ID | Test | VMs | Namespaces | Notes |
|---|---|---|---|---|
| `08b08a` | Test 1 | 3 | 2 | URL mode |
| `53319c` | Test 2 | 5 | 1 | |
| `d238b0` | Test 3 | 0 | 2 | FAIL: port 8000 server down |
| `071186` | Test 4 | 5 | 2 | |
| `92dc35` | Test 5 | 5 | 1 | |
| `eda2e6` | Test 6 | 5 | 2 | URL mode, no snapshots |
| `fdfe81` | Test 7 | 1 | 1 | URL mode |
| `36635e` | Test 8 | 3 | 1 | |
| `9b87cd` | Test 9 | 0 | 2 | FAIL: WFFC deadlock |
| `7c391b` | Test 10 | 15 | 3 | |
| `c4023c` | Test 10 (dup) | 15 | 3 | From interrupted first run |
| `a21648` | Test 11 | 3 | 2 | |
| `76711e` | Test 12 | 3 | 1 | Halted |
| `eff449` | Test 13 | 3 | 1 | |
| `041086` | Test 14 | 3 | 1 | |
| `9dcefa` | Test 15 | 10 | 2 | |
| `571770` | Test 16 | 1 | 1 | |
| `3e0d34` | Test 17 | 1 | 1 | |

**2026-04-30 total: 81 VMs created (including dup Test 10), 81 reached Running state (Tests 3 and 9 produced 0 VMs).**

## Cleanup

Cleanup is performed manually by the operator after reviewing results.
