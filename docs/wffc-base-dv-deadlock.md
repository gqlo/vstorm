# WaitForFirstConsumer + base DataVolume deadlock

Why URL-import batches on local storage (LVMS / TopoLVM) can stick forever in
`PendingPopulation` / `CloneInProgress`, and how vstorm avoids it.

## Symptom

Typical stuck resources after `--dv-url` (or default URL) on a WFFC storage class:

| Resource | Phase / status |
|---|---|
| DV / PVC `base` (or `{basename}-base`) | `PendingPopulation` / `Pending` |
| Per-VM DV / PVC | `CloneInProgress` / `Pending` |
| VirtualMachine | `Provisioning` |
| `virt-launcher-…` pod | `Pending` — `VolumeBinding: context deadline exceeded` |

PVC events on `base`:

```text
WaitForFirstConsumer  waiting for first consumer to be created before binding
```

PVC / DV events on the clone:

```text
Waiting for a volume to be created either by the external provisioner 'topolvm.io' ...
```

The image URL itself is usually fine (HTTP 200). Capacity on the LVMS node is
usually fine. The batch never recovers without cleanup.

Seen in live testing as Test 9 (`docs/live-cluster-test-report.md`) and again
with batch `vstorm-eaa604` on `lvms-lvm-*-ssd-storage`.

## Disk creation paths

```text
1. Snapshot (default for OCS):
   source → base DV/PVC → VolumeSnapshot → VM DVs clone from snapshot

2. No-snapshot + DataSource:
   DataSource → each VM DV clones directly from DataSource  (no base DV)

3. No-snapshot + URL (--dv-url / default URL):
   HTTP URL → base DV/PVC → each VM DV clones from base PVC
```

Path 3 is the one that deadlocks on WaitForFirstConsumer storage.

## Why it deadlocks

### WaitForFirstConsumer

Storage classes such as LVMS set:

```yaml
volumeBindingMode: WaitForFirstConsumer
```

The provisioner will not create a volume until a **consumer Pod** that mounts
the PVC is scheduled. That delay is intentional: it keeps the volume on the
same node as the Pod (local disks cannot move).

### Who consumes what

In URL mode vstorm creates:

1. One **base** DataVolume per namespace — HTTP import of the qcow; nothing
   mounts this PVC except CDI’s importer / populator path.
2. One **per-VM** DataVolume — `source.pvc.name: base` (see
   `templates/vm-clone.yaml`).
3. A `virt-launcher` Pod that mounts only the **per-VM** PVC, not `base`.

So the only Pod that would satisfy WFFC for `base` never exists. `base` stays
`Pending` forever.

### Clone cannot finish without a bound source

CDI still starts a host-assisted clone from `base`:

- A temporary PVC + `cdi-upload-…` Pod can bind (often with
  `cdi.kubevirt.io/storage.bind.immediate.requested` on the tmp claim).
- The source-clone side needs `base` bound and populated.
- The target PVC stays Pending / populator-waiting.
- `virt-launcher` waits on VolumeBinding and times out.

```text
                  WFFC: needs consumer
                         │
                         ▼
   HTTP ──► base PVC ──────────────► never binds
              ▲
              │ clone source
              │
   VM DV ◄────┘          virt-launcher mounts VM DV only
              │                    │
              └──── CloneInProgress / Pending ◄── VolumeBinding timeout
```

Classic circular wait:

- `base` waits for a consumer that will never schedule against it.
- Clone / VM wait for `base` to become Ready.
- Neither side can make progress.

## What does *not* fix it by itself

| Approach | Why it fails |
|---|---|
| Skip waiting for `base`, create VMs anyway | VMs consume the clone PVC, not `base`; WFFC on `base` is unchanged |
| Disable snapshots only | URL path still creates an intermediate base DV |
| More disk / healthier TopoLVM | Binding never starts; capacity is irrelevant |

## How vstorm handles it

On detecting `volumeBindingMode: WaitForFirstConsumer`:

1. **Snapshots are disabled** — a snapshot needs a bound base PVC.
2. **DataSource + no-snapshot** — skip the base DV entirely; each VM’s
   DataVolumeTemplate clones from the DataSource, and `virt-launcher` is the
   WFFC consumer for that claim.
3. **URL import (`--dv-url`)** — keep the base DV, but annotate it so CDI
   requests Immediate bind for that claim only:

   ```yaml
   metadata:
     annotations:
       cdi.kubevirt.io/storage.bind.immediate.requested: "true"
   ```

   Applied via `templates/dv.yaml` when WFFC is detected. The import can then
   populate without a consumer Pod; clone VMs proceed after `base` is Ready.
   On Immediate-binding storage classes the annotation is omitted.

## Choosing a mode on LVMS

| Goal | Recommended |
|---|---|
| Use cluster golden image / DataSource | `--no-snapshot --datasource=NAME` |
| Import a custom qcow URL | `--dv-url=…` (WFFC auto-annotates base) |
| Avoid PVC import entirely | `--containerdisk=…` |

## Cleanup of a stuck batch

```bash
# example: vstorm-eaa604-ns-1
oc delete ns "${BATCH_ID}-ns-1"   # and other ns in the batch
```

Then recreate with a current vstorm that applies the bind-immediate annotation
(or use the DataSource path above).

## Related

- Storage pitfalls table in [README.md](../README.md#storage-considerations)
- WFFC unit tests: `tests/05-storage-wffc.bats`
- Live failure write-up: [live-cluster-test-report.md](live-cluster-test-report.md) (Test 9)
- Clone-mode overview: [testing.md](testing.md) (DataSource clone path)
