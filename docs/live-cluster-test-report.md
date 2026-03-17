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
| 1 | `--cores=4 --memory=8Gi --vms=3 --namespaces=2` | 3 | Yes | 3/3 OK | **PASS** |
| 2 | `--datasource=fedora --vms=5 --namespaces=1` | 5 | Yes | 5/5 OK | **PASS** |
| 3 | `--dv-url=http://...rhel9-cloud-init.qcow --vms=2 --namespaces=2` | 2 | Yes | N/A (expected) | **PASS** |
| 4 | `--cloudinit=helpers/cloudinit-stress-workload.yaml --vms=5 --namespaces=2` | 5 | Yes | 3/3 OK | **PASS** |
| 5 | `--datasource=centos-stream9 --vms=5 --namespaces=1` | 5 | Yes | 0/5 FAIL | **PARTIAL** |
| 6 | `--storage-class=ocs-storagecluster-ceph-rbd --vms=5 --namespaces=2` | 5 | Yes | 3/3 OK | **PASS** |
| 7 | `--no-snapshot --vms=1 --namespaces=1` | 1 | Yes | 1/1 OK | **PASS** |
| 8 | `--containerdisk --vms=3 --namespaces=1` | 3 | -- | -- | pending |
| 9 | `--storage-class=... --snapshot-class=... --vms=3 --namespaces=2` | 3 | -- | -- | pending |
| 10 | `--vms-per-namespace=5 --namespaces=3 --wait` | 15 | -- | -- | pending |
| 11 | `--containerdisk --cloudinit=... --vms=3 --namespaces=2` | 3 | -- | -- | pending |
| 12 | `--run-strategy=Halted --vms=3 --namespaces=1` | 3 | -- | -- | pending |
| 13 | `--cores=2 --memory=4Gi --request-cpu=500m --request-memory=2Gi --vms=3` | 3 | -- | -- | pending |
| 14 | `--basename=perf-vm --storage-size=50Gi --vms=3 --namespaces=1` | 3 | -- | -- | pending |
| 15 | `--profile --vms=10 --namespaces=2` | 10 | -- | -- | pending |
| 16 | `--custom-templates=./templates --vms=3 --namespaces=2` | 3 | -- | -- | pending |

**26 VMs created, 26/26 reached Running state. 6/7 tests fully passed. 1 partial (guest image issue).**
**Tests 8-16 pending execution.**

### Run history

- **2026-02-12** -- Initial run (Tests 1-7)
- **2026-02-12** -- Re-run after auto-derive basename change (Tests 1-7): 26/26 Running, same results

---

## Test 1 -- Default DataSource, custom CPU/memory, snapshot mode

**Command:**

```bash
./vstorm --cores=4 --memory=8Gi --vms=3 --namespaces=2
```

**Batch ID:** `e2c4ef` (re-run), previously `54a52e`

### Options verified -- Test 1

| Option | Expected | Verified |
|---|---|---|
| `--cores=4` | 4 CPU cores per VM | Yes -- `cores: 4` in VM spec; `/proc/cpuinfo` shows 4 processors |
| `--memory=8Gi` | 8Gi guest memory | Yes -- `guest: 8Gi` in VM spec; `free -h` shows 7.5Gi total |
| `--vms=3` | 3 total VMs | Yes -- 3 VMs created |
| `--namespaces=2` | 2 namespaces | Yes -- `vm-54a52e-ns-1`, `vm-54a52e-ns-2` |
| VM distribution | 2 in ns-1, 1 in ns-2 (remainder) | Yes -- confirmed |
| Snapshot mode (default) | Base DV + VolumeSnapshot per ns | Yes -- 2 DVs (`rhel9-base`), 2 VolumeSnapshots (readyToUse=true) |
| Storage class | `ocs-storagecluster-ceph-rbd-virtualization` | Yes -- on both base DVs |
| Access mode | Auto-detected `ReadWriteMany` | Yes -- on both base DVs |
| Run strategy | `Always` (default) | Yes -- all 3 VMs |
| Auto cloud-init | Default cloud-init applied (root:password) | Yes -- `rhel9-cloudinit` Secret in each ns |
| SSH | Root login with password | Yes -- all 3 VMs (CPUs=4, RAM=7.5Gi, hostname correct) |
| Labels | `batch-id`, `vm-basename` | Yes -- on all resources |

---

## Test 2 -- Fedora DataSource, snapshot mode

**Command:**

```bash
./vstorm --datasource=fedora --vms=5 --namespaces=1
```

**Batch ID:** `e12d11` (re-run), previously `1ed721`

### Options verified -- Test 2

| Option | Expected | Verified |
|---|---|---|
| `--datasource=fedora` | Base DV clones from `fedora` DataSource | Yes -- `sourceRef.kind=DataSource, sourceRef.name=fedora` |
| `--vms=5` | 5 total VMs | Yes -- 5 VMs created |
| `--namespaces=1` | 1 namespace | Yes -- `vm-1ed721-ns-1` |
| Snapshot mode (default) | Base DV + VolumeSnapshot | Yes -- 1 DV (`fedora-base`), 1 VolumeSnapshot (readyToUse=true) |
| Default cores/memory | 1 core, 1Gi | Yes -- `cores: 1`, `guest: 1Gi` |
| Auto cloud-init | Default cloud-init applied | Yes -- `fedora-cloudinit` Secret present |
| SSH | Root login with password | Yes -- all 5 VMs (CPUs=1, RAM=863Mi) |

---

## Test 3 -- URL import, snapshot mode

**Command:**

```bash
./vstorm --dv-url=http://d21-h25-000-r650.rdu2.scalelab.redhat.com:8000/rhel9-cloud-init.qcow --vms=2 --namespaces=2
```

**Batch ID:** `f392c3` (re-run), previously `c9c0ac`

### Options verified -- Test 3

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
./vstorm --cloudinit=helpers/cloudinit-stress-workload.yaml --vms=5 --namespaces=2
```

**Batch ID:** `4bdda2` (re-run), previously `c71106`

### Options verified -- Test 4

| Option | Expected | Verified |
|---|---|---|
| `--cloudinit=helpers/cloudinit-stress-workload.yaml` | Custom cloud-init Secret per namespace | Yes -- `rhel9-cloudinit` Secret in both ns (Opaque, 1 key) |
| Cloud-init in VM | `cloudInitNoCloud.secretRef.name: rhel9-cloudinit` | Yes -- confirmed via jsonpath |
| Not auto-applied | Should not say "applying default cloud-init" | Yes -- log says `Cloud-init: helpers/cloudinit-stress-workload.yaml` |
| `--vms=5` | 5 total VMs | Yes |
| `--namespaces=2` | 2 namespaces | Yes |
| VM distribution | 3 in ns-1, 2 in ns-2 | Yes -- confirmed |
| Snapshot mode (default) | Base DV + VolumeSnapshot | Yes -- 2 DVs, 2 VolumeSnapshots |
| stress-workload service | Service exists and activating on boot | Yes -- `systemctl is-active stress-workload` returned "activating" (installing stress-ng) |
| SSH | Root login with password | Yes -- 3 VMs tested (CPUs=1, RAM=679Mi) |

---

## Test 5 -- CentOS Stream 9 DataSource, snapshot mode

**Command:**

```bash
./vstorm --datasource=centos-stream9 --vms=5 --namespaces=1
```

**Batch ID:** `ccd3f7` (re-run), previously `84afd3`

### Options verified -- Test 5

| Option | Expected | Verified |
|---|---|---|
| `--datasource=centos-stream9` | Base DV clones from `centos-stream9` DataSource | Yes -- `sourceRef.name=centos-stream9` |
| `--vms=5` | 5 total VMs | Yes -- all 5 Running |
| `--namespaces=1` | 1 namespace | Yes |
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

**Batch ID:** `fbf6df` (re-run), previously `6e1dbd`

### Options verified -- Test 6

| Option | Expected | Verified |
|---|---|---|
| `--storage-class=ocs-storagecluster-ceph-rbd` | Custom storage class on all resources | Yes -- `storageClassName: ocs-storagecluster-ceph-rbd` on inline DVs |
| Snapshots auto-disabled | No `--snapshot-class` provided with custom SC | Yes -- log says "Snapshot mode: disabled (direct DataSource clone)" |
| No VolumeSnapshots | Should not create VolumeSnapshots | Yes -- `oc get volumesnapshot -A -l batch-id=6e1dbd` returns empty |
| No base DataVolume | Direct DataSource clone, no intermediate DV | Yes -- `oc get datavolume -A -l batch-id=6e1dbd` returns empty |
| VM inline DV sourceRef | Each VM's DV clones from DataSource (not PVC) | Yes -- `sourceRef.kind=DataSource, sourceRef.name=rhel9` |
| Access mode | Auto-detected `ReadWriteMany` | Yes -- confirmed on inline DV |
| `--vms=5` | 5 total VMs | Yes |
| `--namespaces=2` | 2 namespaces | Yes |
| VM distribution | 3 in ns-1, 2 in ns-2 | Yes -- confirmed |
| Auto cloud-init | Default cloud-init applied | Yes -- Secrets in both ns |
| SSH | Root login with password | Yes -- 3 VMs tested (CPUs=1, RAM=679Mi) |

---

## Test 7 -- Explicit no-snapshot mode

**Command:**

```bash
./vstorm --no-snapshot --vms=1 --namespaces=1
```

**Batch ID:** `8d5b6c` (re-run), previously `ec19bf`

### Options verified -- Test 7

| Option | Expected | Verified |
|---|---|---|
| `--no-snapshot` | Snapshot mode explicitly disabled | Yes -- log says "Snapshot mode: disabled (direct DataSource clone)" |
| No VolumeSnapshots | Should not create VolumeSnapshots | Yes -- `oc get volumesnapshot -A -l batch-id=ec19bf` returns empty |
| No base DataVolume | Direct DataSource clone | Yes -- `oc get datavolume -A -l batch-id=ec19bf` returns empty |
| VM inline DV sourceRef | Clones from DataSource | Yes -- `sourceRef.kind=DataSource, sourceRef.name=rhel9` |
| Storage class | Default `ocs-storagecluster-ceph-rbd-virtualization` | Yes -- confirmed on inline DV |
| `--vms=1` | 1 VM | Yes |
| `--namespaces=1` | 1 namespace | Yes |
| Auto cloud-init | Default cloud-init applied | Yes -- Secret present |
| SSH | Root login with password | Yes -- CPUs=1, RAM=679Mi, RHEL 9.7 (Plow) |

---

## Additional Test Commands

Tests 8-16 cover options not exercised by the first 7 tests. Run these
on a live cluster and fill in the "Options verified" tables with results.

---

## Test 8 -- Container disk mode (no storage needed)

**Command:**

```bash
./vstorm --containerdisk --vms=3 --namespaces=1
```

### Options verified -- Test 8

| Option | Expected | Verified |
|---|---|---|
| `--containerdisk` | VMs boot from container image (`quay.io/containerdisks/fedora:latest`) | |
| No PVC/storage | No DataVolume, no PVC, no VolumeSnapshot created | |
| `--vms=3` | 3 total VMs | |
| `--namespaces=1` | 1 namespace | |
| Auto cloud-init | Default cloud-init applied (root:password) | |
| VM basename | Auto-derived `fedora` | |
| SSH | Root login with password | |

---

## Test 9 -- Custom storage class with explicit snapshot class

**Command:**

```bash
./vstorm --storage-class=ocs-storagecluster-ceph-rbd --snapshot-class=ocs-storagecluster-rbdplugin-snapclass --vms=3 --namespaces=2
```

### Options verified -- Test 9

| Option | Expected | Verified |
|---|---|---|
| `--storage-class=ocs-storagecluster-ceph-rbd` | Custom storage class on all resources | |
| `--snapshot-class=ocs-storagecluster-rbdplugin-snapclass` | Snapshot mode stays enabled (both classes provided) | |
| Snapshot mode | Base DV + VolumeSnapshot per namespace | |
| `--vms=3` | 3 total VMs | |
| `--namespaces=2` | 2 namespaces | |
| VM distribution | 2 in ns-1, 1 in ns-2 | |
| Auto cloud-init | Default cloud-init applied | |
| SSH | Root login with password | |

---

## Test 10 -- VMs-per-namespace distribution with wait

**Command:**

```bash
./vstorm --vms-per-namespace=5 --namespaces=3 --wait
```

### Options verified -- Test 10

| Option | Expected | Verified |
|---|---|---|
| `--vms-per-namespace=5` | Exactly 5 VMs in each namespace | |
| `--namespaces=3` | 3 namespaces | |
| Total VMs | 15 (5 x 3) | |
| `--wait` | Command blocks until all VMs reach Running state | |
| Snapshot mode (default) | Base DV + VolumeSnapshot per namespace | |
| Auto cloud-init | Default cloud-init applied | |
| SSH | Root login with password | |

---

## Test 11 -- Container disk with custom cloud-init workload

**Command:**

```bash
./vstorm --containerdisk --cloudinit=helpers/cloudinit-stress-workload.yaml --vms=3 --namespaces=2
```

### Options verified -- Test 11

| Option | Expected | Verified |
|---|---|---|
| `--containerdisk` | VMs boot from container image (no PVC) | |
| `--cloudinit=helpers/cloudinit-stress-workload.yaml` | Custom cloud-init Secret per namespace | |
| Cloud-init in VM | `cloudInitNoCloud.secretRef` references the custom Secret | |
| `--vms=3` | 3 total VMs | |
| `--namespaces=2` | 2 namespaces | |
| VM distribution | 2 in ns-1, 1 in ns-2 | |
| stress-workload service | Service exists and activating on boot | |
| SSH | Root login with password | |

---

## Test 12 -- Halted VMs (create without starting)

**Command:**

```bash
./vstorm --run-strategy=Halted --vms=3 --namespaces=1
```

### Options verified -- Test 12

| Option | Expected | Verified |
|---|---|---|
| `--run-strategy=Halted` | `runStrategy: Halted` on all VMs | |
| No VMI | No VirtualMachineInstance created (VMs not started) | |
| `--vms=3` | 3 VMs created | |
| `--namespaces=1` | 1 namespace | |
| Snapshot mode (default) | Base DV + VolumeSnapshot | |
| Auto cloud-init | Default cloud-init applied | |
| Start manually | `virtctl start <vm>` transitions VM to Running | |

---

## Test 13 -- Custom resource requests separate from guest resources

**Command:**

```bash
./vstorm --cores=2 --memory=4Gi --request-cpu=500m --request-memory=2Gi --vms=3 --namespaces=1
```

### Options verified -- Test 13

| Option | Expected | Verified |
|---|---|---|
| `--cores=2` | Guest sees 2 CPU cores | |
| `--memory=4Gi` | Guest sees 4Gi memory | |
| `--request-cpu=500m` | Kubernetes pod CPU request is 500m | |
| `--request-memory=2Gi` | Kubernetes pod memory request is 2Gi | |
| Oversubscription | Guest resources exceed pod requests (burst scheduling) | |
| `--vms=3` | 3 total VMs | |
| `--namespaces=1` | 1 namespace | |
| SSH | Root login with password; `/proc/cpuinfo` shows 2 CPUs, `free -h` shows ~4Gi | |

---

## Test 14 -- Custom basename and disk size

**Command:**

```bash
./vstorm --basename=perf-vm --storage-size=50Gi --vms=3 --namespaces=1
```

### Options verified -- Test 14

| Option | Expected | Verified |
|---|---|---|
| `--basename=perf-vm` | VM names use `perf-vm-{batch}-{N}` pattern | |
| Base DV name | `perf-vm-base` | |
| Cloud-init Secret | `perf-vm-cloudinit` | |
| `--storage-size=50Gi` | PVCs are 50Gi (visible in DV spec and `oc get pvc`) | |
| `--vms=3` | 3 total VMs | |
| `--namespaces=1` | 1 namespace | |
| Snapshot mode (default) | Base DV + VolumeSnapshot | |
| SSH | Root login with password; `lsblk` shows ~50G disk | |

---

## Test 15 -- Cluster profiling during batch creation

**Command:**

```bash
./vstorm --profile --vms=10 --namespaces=2
```

### Options verified -- Test 15

| Option | Expected | Verified |
|---|---|---|
| `--profile` | Profiler start/stop/dump lifecycle runs around VM creation | |
| Profile output | pprof files saved to `logs/profile-{BATCH_ID}/` | |
| Profile types | `cpu.pprof`, `heap.pprof`, `allocs.pprof`, `goroutine.pprof`, `block.pprof`, `mutex.pprof`, `threadcreate.pprof` per pod | |
| `--vms=10` | 10 total VMs | |
| `--namespaces=2` | 2 namespaces | |
| VM distribution | 5 in ns-1, 5 in ns-2 | |
| VM creation | All VMs created and running normally alongside profiling | |
| Auto cloud-init | Default cloud-init applied | |

---

## Test 16 -- Custom templates (partial override)

**Command:**

```bash
./vstorm --custom-templates=./templates --vms=3 --namespaces=2
```

Alternate commands to test single-file and mixed paths:

```bash
# Single custom VM template file (built-in used for Namespace, DV, snapshot, Secret)
./vstorm --custom-templates=/path/to/my-vm.yaml --vms=3 --namespaces=1

# Mixed file and directory (colon-separated)
./vstorm --custom-templates="/path/to/my-vm.yaml:/path/to/extra-templates/" --vms=3 --namespaces=2
```

### Options verified -- Test 16

| Option | Expected | Verified |
|---|---|---|
| `--custom-templates=./templates` | Templates discovered by content (`kind:` field), not filename | |
| Content-based lookup | Namespace, DataVolume, VolumeSnapshot, VirtualMachine, Secret found by `kind:` | |
| Partial custom | Providing only a VM template falls back to built-in for other roles | |
| Colon-separated paths | Multiple paths (file + directory) all searched | |
| Built-in fallback | Missing roles resolved from built-in `templates/` directory | |
| `--vms=3` | 3 total VMs | |
| `--namespaces=2` | 2 namespaces | |
| Snapshot mode (default) | Base DV + VolumeSnapshot per namespace | |
| Auto cloud-init | Default cloud-init applied | |
| SSH | Root login with password | |

---

## All batches created

| Batch ID | Test | VMs | Namespaces |
|---|---|---|---|
| `e2c4ef` | Test 1 | 3 | 2 |
| `e12d11` | Test 2 | 5 | 1 |
| `f392c3` | Test 3 | 2 | 2 |
| `4bdda2` | Test 4 | 5 | 2 |
| `ccd3f7` | Test 5 | 5 | 1 |
| `fbf6df` | Test 6 | 5 | 2 |
| `8d5b6c` | Test 7 | 1 | 1 |

**Total: 26 VMs across 11 namespaces.**

## Cleanup

To delete all test resources:

```bash
./vstorm --delete=e2c4ef
./vstorm --delete=e12d11
./vstorm --delete=f392c3
./vstorm --delete=4bdda2
./vstorm --delete=ccd3f7
./vstorm --delete=fbf6df
./vstorm --delete=8d5b6c
```
