# Vstorm

Spin up hundreds of VMs across multiple namespaces with a single command on
OpenShift Virtualization -- no YAML to write. It auto-detects
storage access modes, clone strategy, and snapshot support from the cluster, so
it works out of the box with OCS/Ceph, LVMS, NFS, or any block-capable storage
class. No storage class at all? Use `--containerdisk` to boot VMs directly from
a container image with no PVC required. Each run gets a unique batch ID for easy inspection and cleanup.
Cloud-init injection runs custom workloads (e.g. stress-ng) at VM boot.
Integrated cluster profiling (`--profile`) captures Go runtime-level
performance data -- CPU, heap, mutex, and other pprof profiles -- from
the KubeVirt control plane during batch runs.
Backed by 193 unit tests, live cluster validation, and CI on every push
(as of March 2026).

---

- [Prerequisites](#prerequisites)
- [Quick start](#quick-start)
- [How it works](#how-it-works)
- [Managing batches](#managing-batches)
- [Options](#options)
- [Tab completion](#clone-and-setup)
- [Cloud-init](#cloud-init)
- [Cluster profiling](#cluster-profiling)
- [Development](#development)
- **Docs:** [logging](docs/logging.md) | [stress workload](docs/stress-workload.md) | [cluster profiler](docs/cluster-profiler.md) | [testing](docs/testing.md) | [live cluster test report](docs/live-cluster-test-report.md) | [bug tracker](docs/bug-tracker.md)
- **Helpers:** [vm-ssh](helpers/vm-ssh) | [vm-export](helpers/vm-export) | [install-virtctl](helpers/install-virtctl) | [stress_ng_random_vm.sh](helpers/stress_ng_random_vm.sh)

---

## Prerequisites

- `oc` CLI logged into an OpenShift cluster
- OpenShift Virtualization operator installed (`openshift-cnv` namespace)
- A storage class that supports block volumes (`ReadWriteMany` or `ReadWriteOnce` -- auto-detected)
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
# Create 10 RHEL9 VMs (4 cores, 8Gi memory) using default OCS storage class
# Defaults: datasource=rhel9, snapshot mode=on, access mode=auto-detect, cloud-init=auto
vstorm --cores=4 --memory=8Gi --vms=10 --namespaces=2

# Use a different DataSource (e.g. Fedora) with default OCS storage
# VM basename auto-derived: "fedora", base DV: "fedora-base", secret: "fedora-cloudinit"
vstorm --datasource=fedora --vms=5 --namespaces=1

# Import a custom QCOW2 instead of using a DataSource (default OCS storage)
# No cloud-init auto-injected in URL mode; VM basename: "vm", base DV: "vm-base"
vstorm --dv-url=http://myhost:8000/rhel9-disk.qcow2 --vms=10 --namespaces=2

# No storage class available? Boot Fedora VMs directly from a container image
# No PVC or storage configuration needed; cloud-init auto-injected (root password: password)
vstorm --containerdisk --vms=5 --namespaces=1

# Create VMs with a cloud-init workload injected at boot (default OCS storage)
# Custom cloud-init replaces the default auto-injected one
vstorm --cloudinit=helpers/cloudinit-stress-workload.yaml --vms=10 --namespaces=2

# Use a different DataSource with default OCS storage (root password: password)
# VM basename auto-derived: "centos-stream9"
vstorm --datasource=centos-stream9 --vms=5 --namespaces=1

# Use a non-OCS storage class (snapshots auto-disabled because no --snapshot-class)
vstorm --storage-class=my-nfs-sc --vms=10 --namespaces=2

# Use a custom storage class with snapshots (provide both classes to keep snapshots on)
vstorm --storage-class=my-rbd-sc --snapshot-class=my-rbd-snap --vms=10 --namespaces=2

# Explicitly disable snapshots on default OCS storage (VMs clone directly from DataSource)
vstorm --no-snapshot --vms=10 --namespaces=2

# Dry-run to preview generated YAML without applying
vstorm -n --vms=10 --namespaces=2

# Delete all resources for a batch (prompts for confirmation)
vstorm --delete=a3f7b2

# Delete ALL vstorm batches on the cluster
vstorm --delete-all
```

### Defaults

Unless overridden, vstorm uses these built-in defaults:

| Setting | Default | Notes |
|---|---|---|
| CPU cores | `1` | Visible to guest VM; Kubernetes CPU request defaults to cores/10 |
| Memory | `1Gi` | Visible to guest VM; no resource limit set by default |
| VMs | `1` | Total VMs |
| Namespaces | `1` | Total namespaces |
| Storage class | `ocs-storagecluster-ceph-rbd-virtualization` | OCS virtualization-optimized class |
| Storage size | `32Gi` | Per-VM disk size |
| Access mode | Auto-detected from StorageProfile | Falls back to `ReadWriteMany` |
| DataSource | `rhel9` | From `openshift-virtualization-os-images` namespace |
| Snapshot mode | **enabled** | Auto-disabled when custom `--storage-class` is used without `--snapshot-class` |
| Snapshot class | `ocs-storagecluster-rbdplugin-snapclass` | Used when snapshot mode is enabled |
| Container disk | off | Enable with `--containerdisk`; default image `quay.io/containerdisks/fedora:latest` |
| Run strategy | `Always` | VMs start immediately |
| Cloud-init | Auto-injected for DataSource and container disk VMs | Sets root password to `password`; not injected for `--dv-url` |
| VM basename | Derived from DataSource or image name | e.g. `rhel9`, `fedora`; `fedora` for default containerdisk; generic `vm` for `--dv-url` |

## How it works

Each invocation auto-generates a 6-character hex **batch ID** (e.g. `a3f7b2`). This ID is embedded in every resource name and applied as a Kubernetes label, making each run fully isolated.

The tool performs these steps in order:

1. **Create namespaces** -- `vm-{batch}-ns-1`, `vm-{batch}-ns-2`, ...
2. **Create base disk** *(snapshot and URL modes only)* -- one DataVolume per namespace, cloned from a DataSource or imported from a URL; skipped in container disk mode
3. **Snapshot base disk** *(snapshot mode only)* -- creates a VolumeSnapshot per namespace for fast cloning; skipped in container disk mode
4. **Create VMs** -- each VM gets its own disk, cloned from the snapshot, DataSource, base PVC, or container image depending on mode

### Clone modes

vstorm has four disk modes, auto-selected based on your options:

| Mode | Flow | When used |
|---|---|---|
| **Snapshot** | DataSource → base DV → VolumeSnapshot → VM clones | Default for OCS storage |
| **Direct DataSource** | DataSource → each VM clones directly | `--storage-class` without `--snapshot-class`, or `--no-snapshot` |
| **URL import** | URL → base DV → each VM clones from base PVC | `--dv-url` with `--no-snapshot` |
| **Container disk** | Container image → each VM boots directly | `--containerdisk`; no storage class or PVC required |

The direct DataSource path skips the intermediate base DV entirely, which avoids deadlocks with WaitForFirstConsumer storage classes (e.g. LVMS, local storage).

Mode auto-detection:

| Options | Snapshot mode |
|---|---|
| *(defaults -- OCS storage)* | Enabled |
| `--storage-class=X` *(no snapshot-class)* | **Auto-disabled** |
| `--storage-class=X --snapshot-class=Y` | Enabled (matching pair) |
| `--no-snapshot` | Disabled (explicit) |
| `--snapshot` | Enabled (explicit override) |

### Storage considerations

vstorm auto-detects most storage settings from the cluster. Here are the common pitfalls:

| Symptom | Cause | Fix |
|---|---|---|
| DV stuck in `PendingPopulation` | Access mode mismatch (e.g. RWX on RWO-only storage) | Use `--rwo`, or let auto-detection handle it |
| PVC stuck `Pending` ("waiting for first consumer") | WaitForFirstConsumer storage with an intermediate base PVC | Handled automatically -- snapshots are disabled and base PVC is skipped |
| `CloneValidationFailed: target size smaller than source` | Default 32Gi is smaller than your golden image | Use `--storage-size=50Gi` (or larger) |
| VolumeSnapshot never becomes ready | No matching VolumeSnapshotClass for your storage | Pass `--snapshot-class=CLASS`, or omit it to auto-disable snapshots |
| VMs can't live-migrate | PVCs use ReadWriteOnce (local storage) | Expected -- use shared storage (Ceph/NFS) with RWX for live migration |

In DataSource mode (default), a cloud-init is auto-injected to enable root SSH with password `password`.

VMs are distributed evenly across namespaces, with any remainder allocated to the first namespaces.

## Managing batches

### Resource naming

| Resource | Name pattern | Example |
|---|---|---|
| Namespace | `vm-{batch}-ns-{N}` | `vm-a3f7b2-ns-1` |
| DataVolume (base) | `{basename}-base` *(snapshot/URL modes only)* | `rhel9-base` |
| VolumeSnapshot | `{basename}-vm-{batch}-ns-{N}` *(snapshot mode only)* | `rhel9-vm-a3f7b2-ns-1` |
| VirtualMachine | `{basename}-{batch}-{ID}` | `rhel9-a3f7b2-3` |

### Labels

All resources are labeled for easy querying:

- `batch-id` -- the batch ID for this run
- `vm-basename` -- the base image name (on DataVolumes, VolumeSnapshots, and VMs)

### Inspecting batches

After creation, the tool prints ready-to-use commands:

```bash
# List all VMs in a batch
oc get vm -A -l batch-id=a3f7b2

# List all namespaces in a batch
oc get ns -l batch-id=a3f7b2

# List all batch manifest files
ls logs/*.manifest
```

A manifest file (`logs/batch-{BATCH_ID}.manifest`) is written after each run with a summary of all created resources. See [docs/logging.md](docs/logging.md) for details on log files, manifests, and the `logs/` directory structure.

### Deleting batches

Use `--delete` to remove all resources for a specific batch, or `--delete-all` to clean up every vstorm batch on the cluster:

```bash
# Preview what would be deleted
vstorm -n --delete=a3f7b2

# Delete all resources for a batch (prompts for confirmation)
vstorm --delete=a3f7b2

# Skip the confirmation prompt (for scripting)
vstorm --delete=a3f7b2 --yes

# Discover and delete ALL vstorm batches on the cluster
vstorm --delete-all

# Delete all batches without prompting
vstorm --delete-all -y
```

This deletes the batch's namespaces, which cascades and removes all VMs, DataVolumes, VolumeSnapshots, and PVCs inside them. The batch manifest file is also cleaned up.

Safety features:

- **Batch ID validation** -- rejects wildcards (`*`), commas, spaces, and other special characters that could confuse label selectors
- **Namespace pattern check** -- refuses to delete any namespace that doesn't match the `vm-{batch}-ns-{N}` naming pattern, protecting system and operator namespaces
- **Confirmation prompt** -- asks before deleting (bypass with `-y` or `--yes`)

## Options

```
Usage: vstorm [options] [number_of_vms [number_of_namespaces]]

    -h                          Show help
    -n                          Dry-run (show YAML without applying)
    -q                          Quiet mode (show only log messages, no YAML)

    --cores=N                   CPU cores visible to the guest VM (default: 1)
    --memory=N                  Memory visible to the guest VM (default: 1Gi)
    --request-cpu=N             Kubernetes CPU request for scheduling (default: same as --cores)
    --request-memory=N          Kubernetes memory request for scheduling (default: same as --memory)

    --vms=N                     Total number of VMs (default: 1)
    --namespaces=N              Number of namespaces (default: 1)
    --vms-per-namespace=N       VMs per namespace (overrides --vms; takes precedence)

    --storage-class=class       Storage class name (auto-disables snapshots
                                unless --snapshot-class is also provided)
    --storage-size=N            Disk size (default: 32Gi; must be >= source image)
    --access-mode=MODE          PVC access mode (auto-detected from StorageProfile)
    --rwo                       Shortcut for --access-mode=ReadWriteOnce
    --rwx                       Shortcut for --access-mode=ReadWriteMany

    --datasource=NAME           Clone from OCP DataSource (default: rhel9)
    --dv-url=URL                Import disk from URL (overrides --datasource)
    --containerdisk[=IMAGE]     Boot VMs from a container image -- no storage class needed
                                (default: quay.io/containerdisks/fedora:latest)
    --snapshot-class=class      Snapshot class name (implies --snapshot)
    --snapshot                  Use VolumeSnapshots for cloning (default for OCS)
    --no-snapshot               Clone VMs directly (no snapshot needed)

    --start                     Start VMs (equivalent to --run-strategy=Always)
    --stop                      Don't start VMs (equivalent to --run-strategy=Halted)
    --run-strategy=strategy     Run strategy (default: Always)
    --wait                      Wait for all VMs to reach Running state
    --nowait                    Don't wait (default)
    --create-existing-vm        Re-apply all VMs even if they already exist
                                (use with --batch-id to update an existing batch)
    --cloudinit=FILE            Inject cloud-init user-data from FILE into each VM
    --custom-templates=PATH     Use YAML templates from PATH (file or directory;
                                colon-separated for multiple paths).
                                Falls back to built-in templates/ for any missing roles

    --delete=BATCH_ID           Delete all resources for the given batch
    --delete-all                Delete ALL vstorm batches on the cluster
    -y / --yes                  Skip confirmation prompt for delete operations

    --profile[=COMPONENT]       Profile KubeVirt control plane (CPU + memory + more)
                                Optional: virt-api, virt-controller, virt-handler, virt-operator

    --batch-id=ID               Set batch ID (auto-generated if omitted)
    --basename=name             VM base name (default: derived from DataSource or image name)
    --pvc-base-name=name        Base PVC name (default: derived from --basename)
```

Note: KubeVirt sets **no resource limits** by default -- only requests. The guest VM
cannot exceed `--memory` (enforced by QEMU), and CPU can burst beyond the request
to use idle node capacity. Auto-limits only apply if the namespace has a ResourceQuota.

## Cloud-init

Cloud-init user-data is stored in a per-namespace Kubernetes Secret and referenced via `cloudInitNoCloud.secretRef`, so there is no size limit and nothing needs to be baked into the disk image.

### Default cloud-init (DataSource and container disk modes)

When using a DataSource (the default) or `--containerdisk`, a built-in cloud-init (`helpers/cloudinit-default.yaml`) is automatically injected if no `--cloudinit` is specified. It configures:

- **Root password**: `password`
- **PasswordAuthentication**: enabled in sshd
- **PermitRootLogin**: enabled in sshd

```bash
# DataSource VMs reachable via: ssh root@<vm-ip>  (password: password)
vstorm --vms=10 --namespaces=2

# Container disk VMs work the same way -- no storage class required
vstorm --containerdisk --vms=5 --namespaces=1
```

To override, pass your own file with `--cloudinit=FILE`. In URL mode (`--dv-url`), no cloud-init is injected unless explicitly requested.

### Custom cloud-init

Use `--cloudinit=FILE` to inject any cloud-init user-data file:

```bash
vstorm --cloudinit=helpers/cloudinit-stress-workload.yaml --vms=10 --namespaces=2
```

The `cloudinit-stress-workload.yaml` config installs `stress-ng` and runs a bursty workload simulator as a systemd service. See [docs/stress-workload.md](docs/stress-workload.md) for details.

## Custom templates

Use `--custom-templates=PATH` to point vstorm at your own YAML template files or directories. Templates are discovered by **content** (`kind:` field), not by filename, so you can name files however you like.

```bash
# Use a custom VM template (built-in templates used for Namespace, DV, etc.)
vstorm --custom-templates=/path/to/my-vm.yaml --vms=5

# Use a whole directory of custom templates
vstorm --custom-templates=/path/to/my-templates/ --vms=10

# Mix files and directories (colon-separated)
vstorm --custom-templates="/path/to/my-vm.yaml:/path/to/extra-templates/" --vms=10
```

Partial custom is supported: provide only the templates you want to override and vstorm falls back to the built-in `templates/` directory for any missing roles. For example, providing just a VirtualMachine template file is enough -- Namespace, DataVolume, VolumeSnapshot, and cloud-init Secret templates are sourced from the built-in set.

When a custom template uses literal values instead of `{PLACEHOLDER}` syntax (e.g. `batch-id: "abc123"`), vstorm adopts those values unless the corresponding CLI option is explicitly passed.

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
vstorm --profile=virt-controller --cloudinit=helpers/cloudinit-stress-workload.yaml \
  --vms=50 --namespaces=10
```

Results are saved to `logs/profile-{BATCH_ID}/` with one subdirectory per pod,
each containing `cpu.pprof`, `heap.pprof`, `allocs.pprof`, `goroutine.pprof`,
`block.pprof`, `mutex.pprof`, and `threadcreate.pprof`. See
[docs/cluster-profiler.md](docs/cluster-profiler.md) for prerequisites,
feature gate management, and analysis instructions.

## Development

### CI workflow

GitHub Actions runs three independent jobs on every push and pull request to `main` (defined in `.github/workflows/test.yaml`):

| Job | Tool | What it checks |
|---|---|---|
| `test` | `bats` | Runs all unit tests (`bats tests/`) |
| `lint-yaml` | `yamllint` | Lints helper YAML files (`helpers/*.yaml`) |
| `lint-markdown` | `markdownlint-cli2` | Lints all Markdown files (`**/*.md`) |

All three jobs run in parallel on `ubuntu-latest`. The same checks are also enforced locally by the pre-commit hook.

### Pre-commit hook

A git pre-commit hook is included in `hooks/` that automatically runs tests and linters before each commit. To enable it:

```bash
git config core.hooksPath hooks
```

The hook runs only the checks relevant to the files you are committing:

| Staged files | Check |
|---|---|
| `vstorm`, `templates/*`, `helpers/*`, `tests/*.bats` | `bats tests/` |
| `helpers/*.yaml` | `yamllint` on changed files |
| `*.md` | `markdownlint-cli2` on changed files |

If any check fails, the commit is aborted. Fix the issues and commit again. In emergencies, use `git commit --no-verify` to skip the hook.

### Project layout

```
vstorm              # main script
tab-completion/
  vstorm.bash       # Bash tab completion (source to enable)
docs/
  logging.md         # logging, manifests, and logs/ directory structure
  stress-workload.md # stress-ng workload simulator documentation
  testing.md         # how tests work, categories, and CI pipeline
helpers/
  install-virtctl    # download and install virtctl from the cluster
  vm-ssh             # quick virtctl SSH wrapper
  vm-export          # export a VM disk as a qcow2 image
  stress_ng_random_vm.sh            # standalone stress-ng workload script
  cloudinit-default.yaml            # default cloud-init (root password SSH)
  cloudinit-stress-workload.yaml    # cloud-init user-data for stress workload
hooks/
  pre-commit         # git pre-commit hook (runs tests and linters)
templates/
  namespace.yaml     # namespace template
  dv.yaml            # DataVolume template (import from URL)
  dv-datasource.yaml # DataVolume template (clone from DataSource)
  volumesnap.yaml    # VolumeSnapshot template
  vm-snap.yaml          # VirtualMachine template (clone from snapshot)
  vm-datasource.yaml    # VirtualMachine template (clone from DataSource, no-snapshot mode)
  vm-clone.yaml         # VirtualMachine template (clone from PVC, URL import mode)
  vm-containerdisk.yaml # VirtualMachine template (container disk, no storage class needed)
  cloudinit-secret.yaml # cloud-init userdata Secret template
tests/
  vstorm.bats       # unit tests (run with: bats tests/)
logs/                # created at runtime -- logs and batch manifests
```
