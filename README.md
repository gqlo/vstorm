# Vstorm

- Scale up hundreds of VMs across multiple namespaces with one command on OpenShift Virtualization, without writing YAML.
- Auto-detects storage access modes, clone strategy, and snapshot support so it works with OCS/Ceph, LVMS, NFS, or any block- or filesystem-capable storage class.
- **Cloud-init** injects workloads at boot (e.g. stress-ng, fio). For steady dirty anonymous memory, `workload/cloudinit-dirty-mem-pages.yaml` installs a C program, compiles it on first boot, and runs it under systemd; tune the dirty page ratio with `--env DIRTY_RATE_FRACTION` (a fraction of guest physical RAM).
- **Self-built minimal guests** (high-density VM testing): a stripped x86_64-only kernel and small rootfs, often on the order of ~80 MB per guest, so you can pack many VMs onto finite CPU and RAM and stress scheduling, networking, and storage. Host the disk where the cluster can import it (for example `--dv-url` or your DataSource). Example layout and image live under [`custom-build-images/`](custom-build-images/).
- **`--profile`**: integrated cluster profiling captures Go runtime pprof data (CPU, heap, mutex, and more) from the KubeVirt control plane during batch runs.
- **Quality**: 257 `bats` tests, live cluster validation, and CI on every push (as of July 2026).

---

- [Prerequisites](#prerequisites)
- [Quick start](#quick-start)
- [Tab completion](#clone-and-setup)
- [Cloud-init](#cloud-init)
- [Cluster profiling](#cluster-profiling)
- [Options](#options)
- [How it works](#how-it-works)
- [Development](#development)
- **Docs:** [logging](docs/logging.md) | [cloud-init and stress-ng workload](docs/cloud-init-stress-ng-workload.md) | [cloud-init and fio workload](docs/cloud-init-fio-workload.md) | [workload result sync and dashboard](docs/workload-result-sync-and-dashboard.md)
- **More docs:** [cluster profiler](docs/cluster-profiler.md) | [testing](docs/testing.md) | [live cluster test report](docs/live-cluster-test-report.md) | [bug tracker](docs/bug-tracker.md) | [custom build images](custom-build-images/README.md)
- **Helpers:** [vm-ssh](helpers/vm-ssh) | [vm-export](helpers/vm-export) | [install-virtctl](helpers/install-virtctl)

---

## Prerequisites

- `oc` CLI logged into an OpenShift cluster
- OpenShift Virtualization operator installed (`openshift-cnv` namespace)
- A storage class that supports block or filesystem volumes (`ReadWriteMany` or `ReadWriteOnce` -- auto-detected; use `--volume-mode=Filesystem` for NFS/NAS)
- **With snapshots (default for OCS):** OpenShift Data Foundation with Ceph RBD storage class and a matching VolumeSnapshotClass
- **Without snapshots:** any compatible storage class -- pass `--storage-class=CLASS` and snapshots are auto-disabled
- **Without any storage class:** use `--containerdisk` -- only `oc` and OpenShift Virtualization are required; no PVC or storage configuration needed

## Quick start

### Clone and setup

```bash
git clone https://github.com/gqlo/vstorm.git
cd vstorm
echo "export PATH=\"$(pwd):\$PATH\"" >> ~/.bashrc
echo "source $(pwd)/tab-completion/vstorm.bash" >> ~/.bashrc
source ~/.bashrc
```

The first `echo` adds the vstorm directory to your `PATH` so you can run `vstorm` from anywhere. The second appends the tab completion script. Bash tab completion for options is available (e.g. `vstorm --de` + Tab completes to `--delete` or `--delete-all`). Start a new shell or run `source ~/.bashrc` to activate.

### Examples

```bash
# 1. Container disk (no PVC; boot from container image)
vstorm --containerdisk --vms=5 --namespaces=1

# 2. Default OCS storage (RHEL9 UEFI QCOW2 from URL, snapshot mode on)
vstorm --cores=4 --memory=8Gi --vms=10 --namespaces=2

# 3. Your own DV source (disk image URL)
vstorm --dv-url=http://myhost:8000/rhel9-disk.qcow2 --vms=10 --namespaces=2

# 4. Minimal guest (BIOS, tight memory/disk) from a small qcow2 URL, sshd pre-installed
vstorm --memory=80Mi --cores=1 \
  --dv-url=http://storage.scalelab.redhat.com/lee/vm-images/vm-80mb.qcow2 \
  --firmware=bios \
  --storage-size=100Mi \
  --vms=1

# 5. Cloud-init workload injected at boot
vstorm --cloudinit=workload/cloudinit-stress-ng-workload.yaml --vms=10 --namespaces=2

# 6. No OCS: use a different storage class (snapshots auto-disabled)
vstorm --storage-class=my-nfs-sc --vms=10 --namespaces=2

# 6b. NFS / filesystem PVC (required for NAS storage classes that do not support Block)
vstorm --storage-class=trident-nfs-svm --volume-mode=Filesystem --vms=10 --namespaces=2

# 7. Dry-run: preview generated YAML without applying
vstorm -n --vms=10 --namespaces=2

# 8. Delete all resources for a batch (prompts for confirmation)
vstorm --delete=a3f7b2

# 9. Delete all namespaces containing VMs on the cluster
vstorm --delete-all

# 10. Layer 2 primary UDN + NodePort (--udn-l2 default subnet 10.132.10.0/16; --service defaults: nodeport, port 22, targetPort 22, nodePort from 32222)
vstorm --udn-l2 --service --vms=10 --namespaces=2

# 10b. UDN with custom subnet CIDR
vstorm --udn-l2=10.200.0.0/16 --service --vms=10 --namespaces=2

# 11. UDN + container disk + NodePort (defaults: port 22, targetPort 22)
vstorm --udn-l2 --service --containerdisk --vms=6 --namespaces=3
# ssh -o PubkeyAuthentication=no root@<node-ip> -p <node-port>  (password: password)

# 12. UDN + ClusterIP (defaults: port 22, targetPort 22; access via pod network from a debug pod in the namespace)
vstorm --udn-l2 --service=clusterip --vms=20 --namespaces=4
# oc -n <batch-id>-ns-1 run -it --rm ssh-debug --image=quay.io/rh_ee_lguoqing/nettools-fedora:latest --restart=Never -- bash
# ssh -o PubkeyAuthentication=no root@svc-clusterip-<batch-id>.<batch-id>-ns-1.svc.cluster.local  (password: password)

# 13. UDN + NodePort: service port 8080, VM targetPort 8080 (nodeport:SERVICE_PORT)
vstorm --udn-l2 --service=nodeport:8080 --vms=10 --namespaces=2

# 14. UDN + NodePort: service port 22, VM targetPort 2222 (nodeport:SERVICE_PORT:TARGET_PORT)
vstorm --udn-l2 --service=nodeport:22:2222 --vms=10 --namespaces=2

# 15. VM Service without UDN (defaults: nodeport, port 22, targetPort 22)
vstorm --service --containerdisk --vms=6 --namespaces=3

# 16. Descheduler stress-ng workload with UDN + NodePort (l2bridge + DHCP networkData; basename labels the batch)
vstorm --memory=8Gi --cores=2 \
  --udn-l2 --service \
  --cloudinit=workload/cloudinit-stress-ng-workload.yaml \
  --env STRESS_TOGETHER=0 \
  --env CPU_ACTIVE_PROBABILITY=30 \
  --env MEM_ACTIVE_PROBABILITY=80 \
  --wait --wait-ssh --basename=desched-t1 --vms=11 --namespaces=2
```

## Cloud-init

Cloud-init user-data is stored in a per-namespace Kubernetes Secret and referenced via `cloudInitNoCloud.secretRef`, so there is no size limit and nothing needs to be baked into the disk image.

### Default cloud-init

When `--cloudinit` is omitted, vstorm injects [`workload/cloudinit-default.yaml`](workload/cloudinit-default.yaml) in every create mode (URL, DataSource, container disk). It configures:

- **Root password**: `password`
- **PasswordAuthentication** / **PermitRootLogin**: enabled in sshd
- **Boot timestamp**: `vstorm-boot-timestamp.service` writes `/root/timestamp.txt` and POSTs a boot heartbeat to the default lab collector (`RESULT_SERVER_URL`) unless you override or clear it via `--env` (no workload job)

### Result collector URL

By default vstorm injects:

`RESULT_SERVER_URL=http://n42-h01-b02-mx750c.rdu3.labs.perfscale.redhat.com:8080/v1/results`

so host manifests and guest boot/result POSTs go to that data-collector. Override with `--env RESULT_SERVER_URL=http://other:8080/v1/results`, or disable with `--env RESULT_SERVER_URL=`.

```bash
# Any mode: default profile (SSH + boot timestamp only)
vstorm --vms=10 --namespaces=2
vstorm --containerdisk --vms=5 --namespaces=1
vstorm --dv-url=http://example.com/disk.qcow2 --vms=5
```

Override with `--cloudinit=FILE` for fio / stress-ng / dirty-mem or a custom profile.

### Custom cloud-init

Use `--cloudinit=FILE` to inject any cloud-init user-data file. Built-in workloads live under `workload/`.

```bash
# stress-ng workload (memory-heavy default); presets, min/max, and more in docs/cloud-init-stress-ng-workload.md
vstorm --cloudinit=workload/cloudinit-stress-ng-workload.yaml --vms=10 --namespaces=2

# stress-ng with env overrides (repeatable --env); e.g. WORKLOAD_TYPE=cpu-heavy|balanced
vstorm --cloudinit=workload/cloudinit-stress-ng-workload.yaml --env WORKLOAD_TYPE=cpu-heavy --vms=5

# Steady anonymous dirty memory: compiles workload/dirty-mem-pages.c on first boot; DIRTY_RATE_FRACTION is a fraction of total physical RAM (0.1–0.9; default 0.5 if --env omitted)
vstorm --cores=4 --memory=8Gi --cloudinit=workload/cloudinit-dirty-mem-pages.yaml --dv-url=http://storage.scalelab.redhat.com/lee/vm-images/rhel9-cloud-init.qcow --env DIRTY_RATE_FRACTION=0.4 --vms=1

# fio storage I/O workload (randrw default); presets and tunables in docs/cloud-init-fio-workload.md
vstorm --cloudinit=workload/cloudinit-fio-workload.yaml --env FIO_SIZE=2G --vms=5
```

See [cloud-init and stress-ng workload](docs/cloud-init-stress-ng-workload.md) for stress-ng design, flow, and parameters. See [cloud-init and fio workload](docs/cloud-init-fio-workload.md) for fio presets and `--env` tunables. The dirty-mem workload uses [workload/dirty-mem-pages.c](workload/dirty-mem-pages.c).

### Custom VM template

Use `--vm-template=FILE` to supply your own `VirtualMachine` YAML instead of the built-in template. All other templates (Namespace, DataVolume, VolumeSnapshot, cloud-init Secret) remain built-in.

This is the right escape hatch for KubeVirt-specific VM settings that have no dedicated flag: CPU topology (sockets/threads/NUMA/hugepages), node affinity, tolerations, additional network interfaces, GPU passthrough, `dedicatedCpuPlacement`, custom labels, etc.

```bash
# Custom VM with NUMA pinning and a URL-imported disk
vstorm --vm-template=my-vm.yaml --dv-url=http://storage.example.com/rhel9.qcow2 \
       --cores=4 --memory=8Gi --vms=5

# Custom VM with a containerDisk baked in -- DV and VolumeSnapshot are skipped automatically
vstorm --vm-template=my-containerdisk-vm.yaml --cores=4 --memory=8Gi --vms=5
```

Start from a copy of the relevant built-in in `templates/` and modify `spec.domain`. Keep the
`{VM_CPU_CORES}`, `{VM_MEMORY}`, and other `{PLACEHOLDER}` lines so that `--cores`, `--memory`,
and other flags still apply. See [docs/custom_template_support.md](docs/custom_template_support.md)
for the full placeholder reference and design notes.

VM and related YAML templates ship in the `templates/` directory next to the `vstorm` script; each resource type is picked by **content** (`kind:` and structure), not by filename.

## Cluster profiling

vstorm can profile the KubeVirt control plane during VM creation using the
upstream
[cluster-profiler](https://github.com/kubevirt/kubevirt/blob/main/tools/cluster-profiler/cluster-profiler.go)
tool. The `--profile` flag wraps the normal VM creation flow with profiler
lifecycle management -- `start` begins CPU sampling, your VMs are created, then
`stop` + `dump` retrieves the CPU profile along with point-in-time snapshots of
all other Go pprof profile types (heap, allocs, goroutine, blocking, mutex,
threadcreate). Only CPU profiling requires the start/stop window; all other
profiles are captured as instantaneous snapshots at dump time.

```bash
# Profile all control-plane components during a 20-VM batch creation
vstorm --profile --vms=20 --namespaces=4

# Profile only virt-controller during a 50-VM stress workload run
vstorm --profile=virt-controller --cloudinit=workload/cloudinit-stress-ng-workload.yaml \
  --vms=50 --namespaces=10
```

Results are saved to `logs/profile-{BATCH_ID}/` with one subdirectory per pod,
each containing `cpu.pprof`, `heap.pprof`, `allocs.pprof`, `goroutine.pprof`,
`block.pprof`, `mutex.pprof`, and `threadcreate.pprof`. See
[docs/cluster-profiler.md](docs/cluster-profiler.md) for prerequisites,
feature gate management, and analysis instructions.

## Options

Run `./vstorm -h` from the repo directory to see all options and their defaults (positional arguments `number_of_vms` and `number_of_namespaces` are supported as shortcuts for `--vms` and `--namespaces`).

### UDN L2 networking

`--udn-l2[=CIDR]` enables Layer 2 primary UserDefinedNetwork (OVN) per namespace: namespaces are labeled for primary UDN, a `UserDefinedNetwork` CR is created, and VMs use `l2bridge` instead of default masquerade networking. Omit the CIDR to use the default subnet `10.132.10.0/16`; pass a CIDR (e.g. `--udn-l2=10.200.0.0/16`) to override.

### VM Service

`--service[=TYPE[:PORT[:TARGET_PORT]]]` creates a Kubernetes Service per namespace that load-balances TCP traffic across all VM pods with the batch basename (`kubevirt.io/domain` selector). Works with or without `--udn-l2`.

| Form | Meaning |
|---|---|
| `--service` | NodePort, service port 22, VM targetPort 22 |
| `--service=clusterip` | ClusterIP, port 22 |
| `--service=nodeport:8080` | NodePort, port and targetPort both 8080 |
| `--service=nodeport:22:2222` | NodePort, service port 22, VM targetPort 2222 |

NodePort values are auto-allocated from 32222 upward (one per namespace). OVN load-balances connections across running VM pods in each namespace.

### Other notes

`--volume-mode=Block|Filesystem` sets PVC `volumeMode` (default `Block`). Use `Filesystem` for NFS/NAS storage classes. Access mode is still auto-detected from the StorageProfile for the chosen volume mode unless you pass `--access-mode`.

`--data-disk-size=N` attaches a **blank** second disk (`vdb`) via a DataVolume (opt-in; e.g. `20G`). Omit the flag (or pass `0`) for no data disk. The fio cloud-init formats and mounts it on `/root/data` when present. Root/OS disk size remains `--storage-size`.

KubeVirt sets **no resource limits** by default — only requests. The guest VM cannot exceed `--memory` (enforced by QEMU), and CPU can burst beyond the request to use idle node capacity. Auto-limits only apply if the namespace has a ResourceQuota.

Use `--create-existing-vm` with `--batch-id` to re-apply VM YAML for an existing batch (e.g. after changing `--cores` or `--memory`); without it, VMs that already exist on the cluster are skipped.

## How it works

Each invocation auto-generates a **batch ID** as `vstorm-` plus 6 hex digits (e.g. `vstorm-a3f7b2`), so it always starts with letters. Override with `--batch-id=ID`. This ID is embedded in every resource name and applied as a Kubernetes label, making each run fully isolated.

The tool performs these steps in order:

1. **Create namespaces** -- `{batch}-ns-1`, `{batch}-ns-2`, ...
2. **Create UDN** *(optional, `--udn-l2`)* -- `UserDefinedNetwork` CR per namespace with the chosen subnet
3. **Create base disk** *(snapshot and URL modes only)* -- one DataVolume per namespace, cloned from a DataSource or imported from a URL; skipped in container disk mode
4. **Snapshot base disk** *(snapshot mode only)* -- creates a VolumeSnapshot per namespace for fast cloning; skipped in container disk mode
5. **Create VMs** -- each VM gets its own disk, cloned from the snapshot, DataSource, base PVC, or container image depending on mode
6. **Create VM Services** *(optional, `--service`)* -- NodePort or ClusterIP Service per namespace, load-balancing to VM pods

### Storage considerations

vstorm auto-detects most storage settings from the cluster. Here are the common pitfalls:

| Symptom | Cause | Fix |
|---|---|---|
| DV stuck in `PendingPopulation` | Access mode mismatch (e.g. RWX on RWO-only storage) | Use `--access-mode=ReadWriteOnce`, or let auto-detection handle it |
| PVC / DV rejected or stuck on NFS | Storage class only supports Filesystem, but default is Block | Pass `--volume-mode=Filesystem` |
| PVC stuck `Pending` ("waiting for first consumer") | WaitForFirstConsumer storage with an intermediate base PVC | Handled automatically -- snapshots are disabled and base PVC is skipped |
| `CloneValidationFailed: target size smaller than source` | Default 32Gi is smaller than your golden image | Use `--storage-size=50Gi` (or larger) |
| VolumeSnapshot never becomes ready | No matching VolumeSnapshotClass for your storage | Pass `--snapshot-class=CLASS`, or omit it to auto-disable snapshots |
| VMs can't live-migrate | PVCs use ReadWriteOnce (local storage) | Expected -- use shared storage (Ceph/NFS) with RWX for live migration |

In every create mode, when `--cloudinit` is omitted, [`workload/cloudinit-default.yaml`](workload/cloudinit-default.yaml) is auto-injected (root password `password`, boot-timestamp heartbeat only; no fio/stress workload). Override with `--cloudinit=FILE`.

VMs are distributed evenly across namespaces, with any remainder allocated to the first namespaces.

## Development

### CI workflow

GitHub Actions runs four independent jobs on every push and pull request to `main` (defined in `.github/workflows/test.yaml`):

| Job | Tool | What it checks |
|---|---|---|
| `test` | `bats` | Runs all unit tests (`bats tests/`) |
| `test-python` | `unittest` | Monitoring / data-collector Python tests (`monitoring/tests/`; needs `pip install -r monitoring/tests/requirements.txt`) |
| `lint-yaml` | `yamllint` | Lints plain YAML (`helpers/`, `workload/`, `monitoring/yaml/`, `monitoring/tests/fixtures/`, `.github/workflows/`) |
| `lint-markdown` | `markdownlint-cli2` | Lints all Markdown files (`**/*.md`) |

All four jobs run in parallel on `ubuntu-latest`. The same checks are also enforced locally by the pre-commit hook (Python tests when monitoring paths are staged).

### Pre-commit hook

A git pre-commit hook is included in `hooks/` that automatically runs tests and linters before each commit. To enable it:

```bash
git config core.hooksPath hooks
```

The hook runs only the checks relevant to the files you are committing:

| Staged files | Check |
|---|---|
| `vstorm`, `templates/*`, `helpers/*`, `workload/*`, `tests/*.bats` | `bats tests/` |
| `monitoring/data-collector/*`, `monitoring/tests/*`, `monitoring/scripts/*` | `python3 -m unittest discover -s monitoring/tests -v` |
| `helpers/*.yaml`, `workload/*.yaml`, `monitoring/yaml/*.yaml`, `monitoring/tests/fixtures/*.yaml`, `.github/workflows/*.yaml` | `yamllint` on changed files |
| any staged `*.md` / `*.MD` (e.g. `docs/...`, `monitoring/...`) | `markdownlint-cli2` on changed files |

If any check fails, the commit is aborted. Fix the issues and commit again. In emergencies, use `git commit --no-verify` to skip the hook.

### Project layout

```
vstorm              # main script
tab-completion/
  vstorm.bash       # Bash tab completion (source to enable)
docs/
  logging.md         # logging, manifests, and logs/ directory structure
  cloud-init-stress-ng-workload.md # cloud-init and stress-ng workload
  cloud-init-fio-workload.md       # cloud-init and fio storage I/O workload
  testing.md         # how tests work, categories, and CI pipeline
helpers/
  install-virtctl    # download and install virtctl from the cluster
  vm-ssh             # quick virtctl SSH wrapper
  vm-export          # export a VM disk as a qcow2 image
  cloudinit-default.yaml            # default cloud-init (root password SSH)
workload/
  cloudinit-stress-ng-workload.yaml  # unified stress-ng workload (WORKLOAD_TYPE, env overrides)
  cloudinit-fio-workload.yaml        # fio storage I/O workload (WORKLOAD_TYPE, env overrides)
  cloudinit-dirty-mem-pages.yaml     # compile to dirty-mem-pages; --env DIRTY_RATE_FRACTION=0.1-0.9
  dirty-mem-pages.c                  # source for dirty-mem workload (embedded in cloud-init YAML)
hooks/
  pre-commit         # git pre-commit hook (runs tests and linters)
templates/
  namespace.yaml     # namespace template
  udn-l2.yaml        # UserDefinedNetwork (Layer 2 primary UDN)
  vm-service.yaml    # Service template (NodePort/ClusterIP to VM pods)
  dv.yaml            # DataVolume template (import from URL)
  dv-datasource.yaml # DataVolume template (clone from DataSource)
  volumesnap.yaml    # VolumeSnapshot template
  vm-snap.yaml          # VirtualMachine template (clone from snapshot)
  vm-datasource.yaml    # VirtualMachine template (clone from DataSource, no-snapshot mode)
  vm-clone.yaml         # VirtualMachine template (clone from PVC, URL import mode)
  vm-containerdisk.yaml # VirtualMachine template (container disk, no storage class needed)
  vm-snap-udn.yaml      # VirtualMachine + l2bridge (snapshot mode, UDN)
  vm-datasource-udn.yaml
  vm-clone-udn.yaml
  vm-containerdisk-udn.yaml
  cloudinit-secret.yaml # cloud-init userdata Secret template
tests/
  *.bats            # unit tests (run with: bats tests/)
logs/                # created at runtime -- logs and batch manifests
```
