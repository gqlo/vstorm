# Testing

vstorm uses [Bats](https://github.com/bats-core/bats-core) (Bash Automated Testing System) for unit tests and GitHub Actions for CI.

## How the tests work

All tests use **dry-run mode** (`-n` or `-q`) unless they need live-mode behavior (StorageProfile auto-detection, WFFC handling), in which case they use a **mock `oc`** script. No real cluster is required.

Each test:

1. Runs `vstorm` with a fixed `--batch-id` and specific flags
2. Captures the full stdout/stderr via Bats `run`
3. Asserts on the generated YAML: resource kinds, names, namespaces, labels, template fields, and counts

This validates that the correct templates are selected, variables are substituted, and the creation flow (DV, snapshot/no-snapshot, VM, cloud-init Secret) matches expectations.

## Running tests locally

```bash
# Run all tests
bats tests/

# Run a single test by name
bats tests/vstorm.bats --filter "QS: default DataSource"
```

Bats is available via most package managers (`apt install bats`, `brew install bats-core`).

## Test categories

### Quick Start (QS-1 through QS-10)

One test per README Quick Start example. Each validates the full YAML output end-to-end:

| Test | Command | What it validates |
|---|---|---|
| QS-1 | `--vms=10 --namespaces=2` | DataSource DV, snapshot, 10 VMs, auto cloud-init, labels, VM spec |
| QS-2 | `--datasource=fedora --vms=5` | Fedora DataSource in DV, snapshot path, auto cloud-init |
| QS-3 | `--dv-url=... --vms=10` | URL import DV with explicit size, snapshot, 10 VMs, no auto cloud-init |
| QS-4 | `--cloudinit=...stress... --vms=10` | Custom cloud-init Secret per namespace, secretRef, not auto-applied |
| QS-5 | `--datasource=centos-stream9 --vms=5` | Different DataSource with default cloud-init auto-applied |
| QS-6 | `--storage-class=my-nfs-sc --vms=10` | Non-OCS storage class auto-disables snapshots, direct DataSource clone (no base DV) |
| QS-7 | `--storage-class=X --snapshot-class=Y --vms=10` | Custom storage + snapshot class pair keeps snapshots enabled |
| QS-8 | `--no-snapshot --vms=10` | Explicit no-snapshot mode, direct DataSource clone, auto cloud-init |
| QS-9 | `-n --vms=10` | Dry-run outputs YAML, no `oc apply`, no completion message |
| QS-10 | `--delete=a3f7b2` | Delete dry-run shows correct `oc delete` command |

### Dirty-rate cloud-init workload

The file [workload/cloudinit-dirty-mem-pages.yaml](../workload/cloudinit-dirty-mem-pages.yaml)
installs `gcc`, writes `dirty-mem-pages.c`, compiles to `/usr/local/bin/dirty-mem-pages`, and starts
`dirty-mem-pages.service`. The RAM fraction is passed from the host with
**`--env DIRTY_RATE_FRACTION=`*value*** (0.1–0.9). If `--env` is not used, the service defaults to
**0.5** via `Environment=` in the unit file.

Example dry-run:

```bash
vstorm -n --batch-id=dr-test --datasource=rhel9 --vms=1 --namespaces=1 \
  --cloudinit=workload/cloudinit-dirty-mem-pages.yaml --env DIRTY_RATE_FRACTION=0.4
```

### Dry-run YAML file tests

| Test | What it validates |
|---|---|
| YAML file saved | Dry-run creates a file with all resource types and document separators |
| Batch ID and namespaces | Correct batch ID and namespace names in the saved YAML file |
| No-snapshot YAML | DataSource clone (no PVC clone, no snapshot) in saved file |
| Quiet mode | `-q` mode does not create a YAML file |

### Core functionality

- **Batch ID** -- auto-generated 6-character hex ID
- **Namespace naming** -- `vm-{batch}-ns-{N}` pattern
- **VM distribution** -- even spread with remainder in first namespaces

### Validation / error handling

- `--delete` without a value is rejected
- Non-numeric positional arguments are rejected
- `--cloudinit` with a missing file fails
- `--dv-url=` with no URL fails
- Too many positional arguments rejected with diagnostic count
- Misplaced options after positional arguments are detected (ERR-23 through ERR-26)
- `--` end-of-options marker does not trigger false positives (ERR-27)

### YAML structure

Each Kubernetes resource type has a dedicated structure test:

| Test | Validates |
|---|---|
| DataSource DV | `storage:` API, accessModes, volumeMode, explicit size for WFFC compatibility |
| URL DV | `source.http.url`, explicit `storage: 50Gi` |
| VirtualMachine | metadata, runStrategy, dataVolumeTemplates, CPU/memory, devices, firmware, scheduling, volumes |
| VolumeSnapshot | apiVersion, snapshotClassName, PVC source |
| Namespace | apiVersion, name, batch-id label |
| Cloud-init Secret | apiVersion, name, namespace, type, userdata, labels |
| `--run-strategy=Halted` | `runStrategy: Halted` |

### No-snapshot mode (NS-1 through NS-8)

Tests for `--no-snapshot` which skips VolumeSnapshots. With a DataSource, each VM's inline DataVolumeTemplate clones directly from the DataSource (no intermediate base DV). With a URL import, VMs still clone from a base PVC:

| Test | Command | What it validates |
|---|---|---|
| NS-1 | `--no-snapshot --vms=3` | Skips VolumeSnapshot creation, skips base DV, uses inline DataVolumeTemplates |
| NS-2 | `--no-snapshot --vms=2` | VMs use `sourceRef` (DataSource) not `source.pvc`, no `rhel9-base` reference |
| NS-3 | `--no-snapshot --dv-url=...` | URL import mode still creates base DV and uses PVC clone |
| NS-4 | `--no-snapshot --cloudinit=...` | Cloud-init works with direct DataSource clone |
| NS-5 | `--no-snapshot --vms=10 --namespaces=3` | Multiple namespaces with direct DataSource clone |
| NS-6 | `--no-snapshot --storage-class=my-sc` | Custom storage class applied, no base DV |
| NS-7 | `--snapshot-class=...` | Explicit `--snapshot-class` produces snapshot-based flow |
| NS-8 | `--no-snapshot --cores=4 --memory=8Gi` | `vm-datasource.yaml` template is well-formed with all fields |

### Direct DataSource clone (DC-1 through DC-10)

Tests for the direct DataSource clone path (no-snapshot + DataSource), where each VM's inline DataVolumeTemplate clones directly from the DataSource. This eliminates the intermediate base DV/PVC, avoiding WaitForFirstConsumer deadlocks:

| Test | Command | What it validates |
|---|---|---|
| DC-1 | `--no-snapshot --datasource=fedora` | Custom DataSource name propagates into each VM's inline DV `sourceRef` |
| DC-2 | `--no-snapshot --datasource=win2k22 --basename=win2k22` | DataSource name and namespace appear correctly in inline DV |
| DC-3 | `--no-snapshot --storage-size=50Gi` | Custom storage size propagates into inline DV's storage request |
| DC-4 | `--no-snapshot --vms=3` | Each VM gets a uniquely named DV (`rhel9-{batch}-1`, `-2`, `-3`), no `rhel9-base` |
| DC-5 | `--no-snapshot --vms=4 --namespaces=2` | Multi-namespace: no per-namespace base DV, each VM references DataSource |
| DC-6 | `--no-snapshot --dv-url=...` | URL import still creates base DV and uses PVC clone (old path preserved) |
| DC-7 | `--snapshot-class=...` | Snapshot mode still creates base DV + VolumeSnapshot (old path preserved) |
| DC-8 | `--no-snapshot --access-mode=ReadWriteOnce` | RWO access mode correctly applied to inline DV in `vm-datasource.yaml` |
| DC-9 | *(live mode, mock oc)* | Completion message shows "direct DataSource clone, no base DVs" |
| DC-10 | `--no-snapshot --run-strategy=Halted` | `runStrategy: Halted` works with direct DataSource clone path |

### Auto-detection (AD-1 through AD-4)

Tests for automatic snapshot mode detection based on `--storage-class` and `--snapshot-class`:

| Test | Command | What it validates |
|---|---|---|
| AD-1 | `--storage-class=my-nfs-sc` | Custom storage class without snapshot-class auto-disables snapshots, uses direct DataSource clone |
| AD-2 | `--storage-class=my-rbd-sc --snapshot-class=my-snap` | Both classes provided keeps snapshots enabled |
| AD-3 | `--storage-class=my-ceph-sc --snapshot-class=my-snap` | Explicit `--snapshot-class` keeps snapshots enabled |
| AD-4 | *(no storage flags)* | Default OCS storage class keeps snapshots enabled |

### Access mode options (AM-1 through AM-6)

Tests for `--access-mode` CLI option:

| Test | Command | What it validates |
|---|---|---|
| AM-1 | *(default)* | Default access mode is `ReadWriteMany` |
| AM-2 | `--access-mode=ReadWriteOnce --no-snapshot` | RWO sets `ReadWriteOnce` on all resources, no `ReadWriteMany` |
| AM-3 | `--access-mode=ReadWriteOnce --no-snapshot` | Long-form option works |
| AM-4 | `--access-mode=ReadWriteMany` | RWX sets `ReadWriteMany` |
| AM-5 | `--access-mode=ReadWriteOnce --snapshot-class=...` | RWO applies to snapshot-based VMs too |
| AM-6 | `--access-mode=ReadWriteOnce --no-snapshot --dv-url=...` | RWO with URL import mode |

### Missing option coverage (OPT-1 through OPT-13)

Tests that ensure every CLI option has at least one test case:

| Test | Command | What it validates |
|---|---|---|
| OPT-1 | `--pvc-base-name=custom-base --snapshot-class=...` | Custom PVC name propagates into VolumeSnapshot `persistentVolumeClaimName` |
| OPT-2 | `--request-cpu=500m` | CPU request appears in `resources.requests.cpu` in VM spec |
| OPT-3 | `--request-memory=512Mi` | Memory request appears in `resources.requests.memory` in VM spec |
| OPT-4 | `--request-cpu=2 --request-memory=4Gi` | Both CPU and memory requests present together |
| OPT-5 | `--vms-per-namespace=3 --namespaces=2` | Calculates total VMs (6), distributes 3 per namespace |
| OPT-6 | `--run-strategy=RerunOnFailure` | Custom run strategy value propagates to VM YAML |
| OPT-7 | `--run-strategy=Always` | Sets `runStrategy: Always` |
| OPT-8 | `--wait` | Option accepted without error |
| OPT-9 | `--wait=false` | Option accepted without error |
| OPT-10 | `--create-existing-vm` | Option accepted without error |
| OPT-11 | `--no-create-existing-vm` | Option accepted without error |
| OPT-12 | `-h` | Displays help/usage text |
| OPT-13 | `8 3` (positional args) | 8 VMs across 3 namespaces via positional arguments |

### StorageProfile auto-detection (SP-1 through SP-5)

Live-mode tests using a **mock `oc`** that returns configured `StorageProfile` access modes:

| Test | Mock returns | What it validates |
|---|---|---|
| SP-1 | `ReadWriteOnce` | Auto-detects RWO from StorageProfile (e.g. LVMS) |
| SP-2 | `ReadWriteMany` | Auto-detects RWX from StorageProfile (e.g. OCS/Ceph) |
| SP-3 | *(unavailable)* | Falls back to default `ReadWriteMany` with warning |
| SP-4 | `ReadWriteMany` + `--access-mode=ReadWriteOnce` | Explicit RWO overrides StorageProfile RWX |
| SP-5 | `ReadWriteOnce` + `--access-mode=ReadWriteMany` | Explicit RWX overrides StorageProfile RWO |

### WaitForFirstConsumer handling (WFFC-1 through WFFC-5)

Live-mode tests using a mock `oc` that simulates WaitForFirstConsumer (WFFC) storage classes:

| Test | Scenario | What it validates |
|---|---|---|
| WFFC-1 | WFFC + DataSource + no-snapshot | Skips base DV entirely (direct DataSource clone avoids deadlock) |
| WFFC-2 | WFFC + URL import + no-snapshot | Skips DV wait, proceeds to VM creation (VMs trigger PVC binding) |
| WFFC-3 | Immediate binding + URL import | Normal DV wait (no skip), all DVs complete before VMs |
| WFFC-4 | WFFC + explicit `--snapshot-class` | Snapshot mode auto-disabled with warning, falls back to direct DataSource clone |
| WFFC-5 | WFFC in dry-run | WFFC warning shown when `oc` is available in dry-run |

### Option combination tests (COMBO-1 through COMBO-49)

Multi-option combination tests that validate interactions between 3+ options used together. Organized into 9 categories:

#### Category 1: Clone path x Storage options (COMBO-1 through COMBO-9)

| Test | Combination | What it validates |
|---|---|---|
| COMBO-1 | `--storage-class=X --access-mode=ReadWriteOnce --no-snapshot` | Custom SC + access mode on inline DataSource DV |
| COMBO-2 | `--storage-class=X --snapshot-class=Y --access-mode=ReadWriteOnce` | All 3 storage options in snapshot path |
| COMBO-3 | `--storage-class=X --access-mode=ReadWriteOnce --dv-url=...` | Custom SC + access mode on URL base DV + PVC clone VM |
| COMBO-4 | `--storage-class=X --storage-size=50Gi --dv-url=...` | Custom SC + size on URL import DV |
| COMBO-5 | `--storage-size=50Gi --no-snapshot` | Custom size on inline DataSource DV |
| COMBO-6 | `--storage-size=50Gi --snapshot-class=...` | Custom size on base DV + snapshot flow |
| COMBO-7 | `--access-mode=ReadWriteMany --dv-url=... --snapshot-class=...` | RWX on URL + snapshot path |
| COMBO-8 | `--access-mode=ReadWriteOnce --storage-class=X --no-snapshot --storage-size=50Gi` | All storage options on DataSource clone path |
| COMBO-9 | `--access-mode=ReadWriteOnce --storage-class=X --snapshot-class=Y` | Access mode with custom SC pair |

#### Category 2: Clone path x Cloud-init (COMBO-10 through COMBO-14)

| Test | Combination | What it validates |
|---|---|---|
| COMBO-10 | `--dv-url=... --snapshot-class=... --cloudinit=FILE` | URL + snapshot + custom cloud-init |
| COMBO-11 | `--dv-url=... --no-snapshot --cloudinit=FILE` | URL + no-snapshot + custom cloud-init |
| COMBO-12 | `--no-snapshot --cloudinit=FILE --namespaces=3` | Secret created per namespace in DataSource clone |
| COMBO-13 | `--dv-url=... --snapshot-class=...` (no `--cloudinit`) | URL+snapshot: no auto cloud-init applied |
| COMBO-14 | `--no-snapshot --basename=fedora --cloudinit=FILE` | Custom basename affects Secret name + DataSource clone |

#### Category 3: Clone path x VM resource requests (COMBO-15 through COMBO-18)

| Test | Combination | What it validates |
|---|---|---|
| COMBO-15 | `--request-cpu=2 --request-memory=4Gi --snapshot-class=...` | Resource requests in `vm-snap.yaml` template |
| COMBO-16 | `--request-cpu=2 --request-memory=4Gi --dv-url=... --no-snapshot` | Resource requests in `vm-clone.yaml` template |
| COMBO-17 | `--cores=4 --memory=8Gi --request-cpu=2 --request-memory=4Gi` | Limits and requests all together (snapshot path) |
| COMBO-18 | `--cores=4 --memory=8Gi --request-cpu=2 --request-memory=4Gi --no-snapshot` | Same on DataSource clone path |

#### Category 4: Clone path x VM lifecycle (COMBO-19 through COMBO-24)

| Test | Combination | What it validates |
|---|---|---|
| COMBO-19 | `--run-strategy=Halted --snapshot-class=...` | `runStrategy: Halted` in snapshot VM template |
| COMBO-20 | `--run-strategy=Halted --dv-url=... --no-snapshot` | Halted with URL import PVC clone |
| COMBO-21 | `--run-strategy=Always --no-snapshot` | `runStrategy: Always` explicit on DataSource clone |
| COMBO-22 | `--run-strategy=Manual --snapshot-class=...` | Custom strategy on snapshot path |
| COMBO-23 | `--run-strategy=Manual --no-snapshot` | Custom strategy on DataSource clone |
| COMBO-24 | `--run-strategy=Manual --dv-url=... --no-snapshot` | Custom strategy on URL PVC clone |

#### Category 5: Scale x Clone path (COMBO-25 through COMBO-29)

| Test | Combination | What it validates |
|---|---|---|
| COMBO-25 | `--vms-per-namespace=3 --namespaces=2 --no-snapshot` | VMs-per-ns with DataSource direct clone |
| COMBO-26 | `--vms-per-namespace=3 --namespaces=2 --snapshot-class=...` | VMs-per-ns with snapshot flow |
| COMBO-27 | `--vms-per-namespace=4 --namespaces=3 --cloudinit=FILE` | VMs-per-ns + cloud-init Secret per namespace |
| COMBO-28 | positional `7 3` + `--no-snapshot --cloudinit=FILE` | Positional args with clone path + cloud-init |
| COMBO-29 | positional `5 2` + `--cores=4 --memory=8Gi` | Positional args with VM config options |

#### Category 6: Naming x Clone path (COMBO-30 through COMBO-34)

| Test | Combination | What it validates |
|---|---|---|
| COMBO-30 | `--basename=myvm --pvc-base-name=myvm-base --snapshot-class=...` | Both naming options set (different from defaults) |
| COMBO-31 | `--basename=myvm --snapshot-class=...` (default pvc-base-name) | basename changes VM/DV/snapshot names, PVC name stays `rhel9-base` |
| COMBO-32 | `--datasource=fedora --basename=custom-vm --no-snapshot` | DataSource and basename are different values |
| COMBO-33 | `--basename=myvm --no-snapshot --namespaces=2` | Custom basename on DataSource clone across namespaces |
| COMBO-34 | `--basename=myvm --dv-url=... --no-snapshot` | Custom basename on URL import path |

#### Category 7: Option precedence and conflicts (COMBO-35 through COMBO-42)

| Test | Combination | What it validates |
|---|---|---|
| COMBO-35 | `--vms-per-namespace=3 --vms=10 --namespaces=2` | `--vms-per-namespace` overrides `--vms` (total=6, not 10) |
| COMBO-36 | `--vms=10` + positional `5` | Positional arg overrides `--vms` |
| COMBO-37 | `--snapshot-class=X --no-snapshot` | Explicit `--no-snapshot` wins over `--snapshot-class` |
| COMBO-38 | `--snapshot-class=X` (no `--storage-class`) | `--snapshot-class` alone keeps snapshot mode enabled |
| COMBO-39 | `--run-strategy=Halted --wait` | Both accepted without error in dry-run |
| COMBO-40 | `--dv-url=... --datasource=fedora` | `--dv-url` clears DataSource |
| COMBO-41 | `--run-strategy=Always --run-strategy=Halted` | Last flag wins (Halted) |
| COMBO-42 | `--run-strategy=Halted --run-strategy=Always` | Last wins (Always) |

#### Category 8: WFFC x Other options (COMBO-43 through COMBO-46)

Live-mode tests using a mock `oc` that simulates WFFC storage combined with other features:

| Test | Combination | What it validates |
|---|---|---|
| COMBO-43 | WFFC + `--cloudinit=FILE --no-snapshot` | Cloud-init Secret still created under WFFC |
| COMBO-44 | WFFC + `--dv-url=...` (auto-detected RWO) | WFFC + URL import skips DV wait |
| COMBO-45 | WFFC + `--vms-per-namespace=3 --namespaces=2` | WFFC at scale |
| COMBO-46 | WFFC + `--snapshot-class=... --cloudinit=FILE` | WFFC auto-disables snapshot, cloud-init still works |

#### Category 9: Dry-run / Quiet x Clone path (COMBO-47 through COMBO-49)

| Test | Combination | What it validates |
|---|---|---|
| COMBO-47 | `-q --no-snapshot --vms=3` | Quiet mode with DataSource clone path |
| COMBO-48 | `-q --dv-url=... --vms=2` | Quiet mode with URL import |
| COMBO-49 | `-q --delete=abc123` | Quiet mode with delete |

## Three clone paths

vstorm uses three different clone strategies depending on the mode:

```text
1. Snapshot mode (default for OCS storage):
   DataSource → base DV/PVC → VolumeSnapshot → VM DVs clone from snapshot

2. No-snapshot + DataSource (default for non-OCS storage):
   DataSource → VM DVs clone directly from DataSource (no base DV)

3. No-snapshot + URL import (--dv-url):
   URL → base DV/PVC → VM DVs clone from base PVC
```

Path 2 was introduced to eliminate the intermediate base DV, which caused WaitForFirstConsumer deadlocks with local storage (e.g. LVMS). Each VM's Pod directly acts as the WFFC consumer for its own DV.

## CI pipeline

GitHub Actions runs three jobs on every push and PR to `main`:

| Job | Tool | Scope |
|---|---|---|
| `test` | `bats` | All tests in `tests/` |
| `lint-yaml` | `yamllint` | `helpers/*.yaml` |
| `lint-markdown` | `markdownlint-cli2` | All `*.md` files |

Configuration files:

- `.yamllint` -- relaxes line length (200), disables document-start and truthy checks, allows `#cloud-config` comments
- `.markdownlint.yaml` -- increases line length (400), disables MD040 and MD060
