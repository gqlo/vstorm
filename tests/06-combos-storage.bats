#!/usr/bin/env bats

# Unit tests for vstorm
# Run with: bats tests/

load 'helpers'

VSTORM="./vstorm"

setup_file() {
    setup_oc_mock
}

# ===============================================================
# Category 1: Clone Path x Storage Options (combos 1-9)
# ===============================================================

# ---------------------------------------------------------------
# COMBO-1: --storage-class + --access-mode=ReadWriteOnce + --no-snapshot
# ---------------------------------------------------------------
@test "combo: storage-class + RWO + no-snapshot on DataSource clone" {
  run bash "$VSTORM" -n --batch-id=cmb001 --datasource=rhel9 --storage-class=my-sc --access-mode=ReadWriteOnce \
    --no-snapshot --vms=2 --namespaces=1
  [ "$status" -eq 0 ]

  # --- Custom storage class applied ---
  [[ "$output" == *"storageClassName: my-sc"* ]]
  [[ "$output" == *"Storage Class: my-sc"* ]]

  # --- RWO access mode ---
  [[ "$output" == *"Access Mode: ReadWriteOnce"* ]]
  [[ "$output" == *"ReadWriteOnce"* ]]
  [[ "$output" != *"ReadWriteMany"* ]]

  # --- No-snapshot DataSource clone ---
  [[ "$output" == *"Skipping base DataVolume creation"* ]]
  [[ "$output" == *"sourceRef"* ]]
  [[ "$output" == *"kind: DataSource"* ]]
  [[ "$output" != *"kind: VolumeSnapshot"* ]]
}

# ---------------------------------------------------------------
# COMBO-2: --storage-class + --snapshot-class + --access-mode=ReadWriteOnce
# ---------------------------------------------------------------
@test "combo: storage-class + snapshot-class + RWO in snapshot path" {
  run bash "$VSTORM" -n --batch-id=cmb002 --datasource=rhel9 --storage-class=my-rbd \
    --snapshot-class=my-snap --access-mode=ReadWriteOnce --vms=2 --namespaces=1
  [ "$status" -eq 0 ]

  # --- Custom storage class ---
  [[ "$output" == *"storageClassName: my-rbd"* ]]

  # --- Custom snapshot class ---
  [[ "$output" == *"volumeSnapshotClassName: my-snap"* ]]

  # --- RWO access mode ---
  [[ "$output" == *"Access Mode: ReadWriteOnce"* ]]
  [[ "$output" == *"ReadWriteOnce"* ]]
  [[ "$output" != *"ReadWriteMany"* ]]

  # --- Snapshot mode enabled ---
  [[ "$output" == *"Snapshot mode: enabled"* ]]
  [[ "$output" == *"kind: VolumeSnapshot"* ]]
  [[ "$output" == *"smartCloneFromExistingSnapshot"* ]]
}

# ---------------------------------------------------------------
# COMBO-3: --storage-class + --access-mode=ReadWriteOnce + --dv-url
# ---------------------------------------------------------------
@test "combo: storage-class + RWO + dv-url on URL import path" {
  run bash "$VSTORM" -n --batch-id=cmb003 --storage-class=my-sc --access-mode=ReadWriteOnce \
    --dv-url=http://example.com/disk.qcow2 --vms=2 --namespaces=1
  [ "$status" -eq 0 ]

  # --- Custom storage class on base DV and VM ---
  [[ "$output" == *"storageClassName: my-sc"* ]]

  # --- RWO access mode ---
  [[ "$output" == *"Access Mode: ReadWriteOnce"* ]]
  [[ "$output" == *"ReadWriteOnce"* ]]
  [[ "$output" != *"ReadWriteMany"* ]]

  # --- URL import DV ---
  [[ "$output" == *"http://example.com/disk.qcow2"* ]]
  [[ "$output" == *"kind: DataVolume"* ]]
}

# ---------------------------------------------------------------
# COMBO-4: --storage-class + --storage-size + --dv-url
# ---------------------------------------------------------------
@test "combo: storage-class + storage-size + dv-url" {
  run bash "$VSTORM" -n --batch-id=cmb004 --storage-class=my-sc \
    --storage-size=50Gi --dv-url=http://example.com/disk.qcow2 \
    --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  # --- Custom storage class ---
  [[ "$output" == *"storageClassName: my-sc"* ]]

  # --- Custom size on base DV ---
  [[ "$output" == *"storage: 50Gi"* ]]

  # --- URL import ---
  [[ "$output" == *"http://example.com/disk.qcow2"* ]]
}

# ---------------------------------------------------------------
# COMBO-5: --storage-size + --no-snapshot
# ---------------------------------------------------------------
@test "combo: storage-size + no-snapshot on DataSource inline DV" {
  run bash "$VSTORM" -n --batch-id=cmb005 --datasource=rhel9 --storage-size=50Gi \
    --no-snapshot --vms=2 --namespaces=1
  [ "$status" -eq 0 ]

  # --- Custom size in inline DV ---
  [[ "$output" == *"storage: 50Gi"* ]]

  # --- No base DV ---
  [[ "$output" == *"Skipping base DataVolume creation"* ]]

  # --- DataSource clone ---
  [[ "$output" == *"sourceRef"* ]]
  [[ "$output" == *"kind: DataSource"* ]]
}

# ---------------------------------------------------------------
# COMBO-6: --storage-size + --snapshot
# ---------------------------------------------------------------
@test "combo: storage-size + snapshot on base DV and snapshot flow" {
  run bash "$VSTORM" -n --batch-id=cmb006 --datasource=rhel9 --storage-size=50Gi \
    --snapshot-class=ocs-storagecluster-rbdplugin-snapclass --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  # --- Custom size on base DV ---
  [[ "$output" == *"storage: 50Gi"* ]]

  # --- Snapshot flow ---
  [[ "$output" == *"Snapshot mode: enabled"* ]]
  [[ "$output" == *"kind: VolumeSnapshot"* ]]
  [[ "$output" == *"Creating DataVolumes"* ]]
}

# ---------------------------------------------------------------
# COMBO-7: --access-mode=ReadWriteMany + --dv-url + --snapshot
# ---------------------------------------------------------------
@test "combo: RWX + dv-url + snapshot" {
  run bash "$VSTORM" -n --batch-id=cmb007 --datasource=rhel9 --access-mode=ReadWriteMany \
    --dv-url=http://example.com/disk.qcow2 --snapshot-class=ocs-storagecluster-rbdplugin-snapclass --vms=2 --namespaces=1
  [ "$status" -eq 0 ]

  # --- RWX access mode ---
  [[ "$output" == *"Access Mode: ReadWriteMany"* ]]
  [[ "$output" == *"ReadWriteMany"* ]]

  # --- URL import with snapshots ---
  [[ "$output" == *"http://example.com/disk.qcow2"* ]]
  [[ "$output" == *"Snapshot mode: enabled"* ]]
  [[ "$output" == *"kind: VolumeSnapshot"* ]]
  [[ "$output" == *"smartCloneFromExistingSnapshot"* ]]
}

# ---------------------------------------------------------------
# COMBO-8: --access-mode=ReadWriteOnce + --storage-class + --no-snapshot + --storage-size
# ---------------------------------------------------------------
@test "combo: all storage options on DataSource clone path" {
  run bash "$VSTORM" -n --batch-id=cmb008 --datasource=rhel9 --access-mode=ReadWriteOnce --storage-class=my-sc \
    --no-snapshot --storage-size=50Gi --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  # --- All storage options applied ---
  [[ "$output" == *"storageClassName: my-sc"* ]]
  [[ "$output" == *"ReadWriteOnce"* ]]
  [[ "$output" == *"storage: 50Gi"* ]]
  [[ "$output" != *"ReadWriteMany"* ]]

  # --- DataSource direct clone ---
  [[ "$output" == *"Skipping base DataVolume creation"* ]]
  [[ "$output" == *"sourceRef"* ]]
}

# ---------------------------------------------------------------
# COMBO-9: --access-mode=ReadWriteOnce + --storage-class + --snapshot-class
# ---------------------------------------------------------------
@test "combo: long-form access-mode + storage-class + snapshot-class" {
  run bash "$VSTORM" -n --batch-id=cmb009 --datasource=rhel9 --access-mode=ReadWriteOnce \
    --storage-class=my-rbd --snapshot-class=my-snap --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  # --- Long-form access mode ---
  [[ "$output" == *"Access Mode: ReadWriteOnce"* ]]
  [[ "$output" == *"ReadWriteOnce"* ]]
  [[ "$output" != *"ReadWriteMany"* ]]

  # --- Custom classes ---
  [[ "$output" == *"storageClassName: my-rbd"* ]]
  [[ "$output" == *"volumeSnapshotClassName: my-snap"* ]]

  # --- Snapshot mode enabled ---
  [[ "$output" == *"Snapshot mode: enabled"* ]]
}

# ===============================================================
# Category 2: Clone Path x Cloud-init (combos 10-14)
# ===============================================================

# ---------------------------------------------------------------
# COMBO-10: --dv-url + --snapshot + --cloudinit
# ---------------------------------------------------------------
@test "combo: dv-url + snapshot + custom cloudinit" {
  run bash "$VSTORM" -n --batch-id=cmb010 --datasource=rhel9 \
    --dv-url=http://example.com/disk.qcow2 --snapshot-class=ocs-storagecluster-rbdplugin-snapclass \
    --cloudinit=workload/stress-ng/cloudinit-stress-ng-workload.yaml --vms=2 --namespaces=1
  [ "$status" -eq 0 ]

  # --- URL import ---
  [[ "$output" == *"http://example.com/disk.qcow2"* ]]

  # --- Snapshot mode ---
  [[ "$output" == *"kind: VolumeSnapshot"* ]]
  [[ "$output" == *"smartCloneFromExistingSnapshot"* ]]

  # --- Custom cloud-init Secret ---
  [[ "$output" == *"kind: Secret"* ]]
  [[ "$output" == *"cloudInitNoCloud"* ]]
  [[ "$output" == *"secretRef"* ]]

  # --- NOT auto-applied ---
  [[ "$output" != *"applying default cloud-init"* ]]
}

# ---------------------------------------------------------------
# COMBO-11: --dv-url + --no-snapshot + --cloudinit
# ---------------------------------------------------------------
@test "combo: dv-url + no-snapshot + custom cloudinit" {
  run bash "$VSTORM" -n --batch-id=cmb011 --datasource=rhel9 \
    --dv-url=http://example.com/disk.qcow2 --no-snapshot \
    --cloudinit=workload/stress-ng/cloudinit-stress-ng-workload.yaml --vms=2 --namespaces=1
  [ "$status" -eq 0 ]

  # --- URL import with PVC clone ---
  [[ "$output" == *"http://example.com/disk.qcow2"* ]]
  [[ "$output" == *"pvc:"* ]]
  [[ "$output" != *"kind: VolumeSnapshot"* ]]

  # --- Cloud-init Secret ---
  [[ "$output" == *"kind: Secret"* ]]
  [[ "$output" == *"cloudInitNoCloud"* ]]
  [[ "$output" == *"secretRef"* ]]

  # --- NOT auto-applied (URL mode) ---
  [[ "$output" != *"applying default cloud-init"* ]]
}

# ---------------------------------------------------------------
# COMBO-12: --no-snapshot + --cloudinit + --namespaces=3
# ---------------------------------------------------------------
@test "combo: no-snapshot + cloudinit + 3 namespaces (Secret per ns)" {
  run bash "$VSTORM" -n --batch-id=cmb012 --datasource=rhel9 --no-snapshot \
    --cloudinit=workload/stress-ng/cloudinit-stress-ng-workload.yaml \
    --vms=6 --namespaces=3
  [ "$status" -eq 0 ]

  # --- 3 namespaces ---
  [[ "$output" == *"name: cmb012-ns-1"* ]]
  [[ "$output" == *"name: cmb012-ns-2"* ]]
  [[ "$output" == *"name: cmb012-ns-3"* ]]

  # --- 3 Secrets (one per namespace) ---
  local secret_count
  secret_count=$(echo "$output" | grep -c "kind: Secret")
  [ "$secret_count" -eq 3 ]

  # --- DataSource clone ---
  [[ "$output" == *"Skipping base DataVolume creation"* ]]
  [[ "$output" == *"sourceRef"* ]]
}

# ---------------------------------------------------------------
# COMBO-13: --dv-url + --snapshot (no --cloudinit) → default cloud-init
# ---------------------------------------------------------------
@test "combo: dv-url + snapshot without cloudinit applies default cloud-init" {
  run bash "$VSTORM" -n --batch-id=cmb013 --datasource=rhel9 \
    --dv-url=http://example.com/disk.qcow2 --snapshot-class=ocs-storagecluster-rbdplugin-snapclass \
    --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  # --- URL + snapshot mode ---
  [[ "$output" == *"http://example.com/disk.qcow2"* ]]
  [[ "$output" == *"kind: VolumeSnapshot"* ]]

  # --- Default cloud-init ---
  [[ "$output" == *"applying default cloud-init"* ]]
  [[ "$output" == *"kind: Secret"* ]]
  [[ "$output" == *"cloudInitNoCloud"* ]]
}

# ---------------------------------------------------------------
# COMBO-14: --no-snapshot + --basename=fedora + --cloudinit
# ---------------------------------------------------------------
@test "combo: no-snapshot + custom basename + cloudinit" {
  run bash "$VSTORM" -n --batch-id=cmb014 --datasource=rhel9 --no-snapshot --basename=fedora \
    --cloudinit=workload/stress-ng/cloudinit-stress-ng-workload.yaml --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  # --- Custom basename in Secret name ---
  [[ "$output" == *"name: fedora-cloudinit"* ]]

  # --- Custom basename in VM name ---
  [[ "$output" == *"name: fedora-cmb014-1"* ]]

  # --- DataSource clone ---
  [[ "$output" == *"sourceRef"* ]]
  [[ "$output" == *"kind: DataSource"* ]]

  # --- Cloud-init ---
  [[ "$output" == *"kind: Secret"* ]]
  [[ "$output" == *"cloudInitNoCloud"* ]]
  [[ "$output" == *"secretRef"* ]]
}

# ===============================================================
# Category 3: Clone Path x VM Resource Requests (combos 15-18)
# ===============================================================

# ---------------------------------------------------------------
# COMBO-15: --request-cpu + --request-memory + --snapshot
# ---------------------------------------------------------------
@test "combo: request-cpu + request-memory in snapshot path" {
  run bash "$VSTORM" -n --batch-id=cmb015 --datasource=rhel9 --request-cpu=2 --request-memory=4Gi \
    --snapshot-class=ocs-storagecluster-rbdplugin-snapclass --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  # --- Resource requests in vm-snap.yaml output ---
  [[ "$output" == *"resources:"* ]]
  [[ "$output" == *"requests:"* ]]
  [[ "$output" == *"cpu: 2"* ]]
  [[ "$output" == *"memory: 4Gi"* ]]

  # --- Snapshot mode ---
  [[ "$output" == *"smartCloneFromExistingSnapshot"* ]]
  [[ "$output" == *"kind: VolumeSnapshot"* ]]
}

# ---------------------------------------------------------------
# COMBO-16: --request-cpu + --request-memory + --dv-url + --no-snapshot
# ---------------------------------------------------------------
@test "combo: request-cpu + request-memory in URL PVC clone path" {
  run bash "$VSTORM" -n --batch-id=cmb016 --datasource=rhel9 --request-cpu=2 --request-memory=4Gi \
    --dv-url=http://example.com/disk.qcow2 --no-snapshot --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  # --- Resource requests in vm-clone.yaml output ---
  [[ "$output" == *"resources:"* ]]
  [[ "$output" == *"requests:"* ]]
  [[ "$output" == *"cpu: 2"* ]]
  [[ "$output" == *"memory: 4Gi"* ]]

  # --- URL PVC clone ---
  [[ "$output" == *"http://example.com/disk.qcow2"* ]]
  [[ "$output" == *"pvc:"* ]]
}

# ---------------------------------------------------------------
# COMBO-17: --cores + --memory + --request-cpu + --request-memory (snapshot)
# ---------------------------------------------------------------
@test "combo: cores + memory + request-cpu + request-memory in snapshot path" {
  run bash "$VSTORM" -n --batch-id=cmb017 --datasource=rhel9 --cores=4 --memory=8Gi \
    --request-cpu=2 --request-memory=4Gi --snapshot-class=ocs-storagecluster-rbdplugin-snapclass --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  # --- CPU/memory limits ---
  [[ "$output" == *"cores: 4"* ]]
  [[ "$output" == *"guest: 8Gi"* ]]

  # --- CPU/memory requests ---
  [[ "$output" == *"resources:"* ]]
  [[ "$output" == *"requests:"* ]]
  [[ "$output" == *"cpu: 2"* ]]
  [[ "$output" == *"memory: 4Gi"* ]]
}

# ---------------------------------------------------------------
# COMBO-18: --cores + --memory + --request-cpu + --request-memory (no-snapshot)
# ---------------------------------------------------------------
@test "combo: cores + memory + request-cpu + request-memory in DataSource clone" {
  run bash "$VSTORM" -n --batch-id=cmb018 --datasource=rhel9 --cores=4 --memory=8Gi \
    --request-cpu=2 --request-memory=4Gi --no-snapshot --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  # --- CPU/memory limits ---
  [[ "$output" == *"cores: 4"* ]]
  [[ "$output" == *"guest: 8Gi"* ]]

  # --- CPU/memory requests ---
  [[ "$output" == *"resources:"* ]]
  [[ "$output" == *"requests:"* ]]
  [[ "$output" == *"cpu: 2"* ]]
  [[ "$output" == *"memory: 4Gi"* ]]

  # --- DataSource clone ---
  [[ "$output" == *"sourceRef"* ]]
  [[ "$output" == *"kind: DataSource"* ]]
}

# ===============================================================
# Category 4: Clone Path x VM Lifecycle (combos 19-24)
# ===============================================================

# ---------------------------------------------------------------
# COMBO-19: --run-strategy=Halted + --snapshot-class
# ---------------------------------------------------------------
@test "combo: stop + snapshot sets Halted in snapshot path" {
  run bash "$VSTORM" -n --batch-id=cmb019 --datasource=rhel9 --run-strategy=Halted --snapshot-class=ocs-storagecluster-rbdplugin-snapclass \
    --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  [[ "$output" == *"runStrategy: Halted"* ]]
  [[ "$output" == *"Snapshot mode: enabled"* ]]
  [[ "$output" == *"smartCloneFromExistingSnapshot"* ]]
}

# ---------------------------------------------------------------
# COMBO-20: --run-strategy=Halted + --dv-url + --no-snapshot
# ---------------------------------------------------------------
@test "combo: stop + dv-url + no-snapshot sets Halted in URL clone" {
  run bash "$VSTORM" -n --batch-id=cmb020 --datasource=rhel9 --run-strategy=Halted \
    --dv-url=http://example.com/disk.qcow2 --no-snapshot \
    --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  [[ "$output" == *"runStrategy: Halted"* ]]
  [[ "$output" == *"http://example.com/disk.qcow2"* ]]
  [[ "$output" == *"pvc:"* ]]
}

# ---------------------------------------------------------------
# COMBO-21: --run-strategy=Always + --no-snapshot
# ---------------------------------------------------------------
@test "combo: start + no-snapshot sets Always in DataSource clone" {
  run bash "$VSTORM" -n --batch-id=cmb021 --datasource=rhel9 --run-strategy=Always --no-snapshot \
    --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  [[ "$output" == *"runStrategy: Always"* ]]
  [[ "$output" == *"Skipping base DataVolume creation"* ]]
  [[ "$output" == *"sourceRef"* ]]
}

# ---------------------------------------------------------------
# COMBO-22: --run-strategy=Manual + --snapshot
# ---------------------------------------------------------------
@test "combo: run-strategy Manual + snapshot" {
  run bash "$VSTORM" -n --batch-id=cmb022 --datasource=rhel9 --run-strategy=Manual --snapshot-class=ocs-storagecluster-rbdplugin-snapclass \
    --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  [[ "$output" == *"runStrategy: Manual"* ]]
  [[ "$output" == *"Snapshot mode: enabled"* ]]
  [[ "$output" == *"smartCloneFromExistingSnapshot"* ]]
}

# ---------------------------------------------------------------
# COMBO-23: --run-strategy=Manual + --no-snapshot
# ---------------------------------------------------------------
@test "combo: run-strategy Manual + no-snapshot DataSource clone" {
  run bash "$VSTORM" -n --batch-id=cmb023 --datasource=rhel9 --run-strategy=Manual --no-snapshot \
    --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  [[ "$output" == *"runStrategy: Manual"* ]]
  [[ "$output" == *"Skipping base DataVolume creation"* ]]
  [[ "$output" == *"sourceRef"* ]]
}

# ---------------------------------------------------------------
# COMBO-24: --run-strategy=Manual + --dv-url + --no-snapshot
# ---------------------------------------------------------------
@test "combo: run-strategy Manual + dv-url + no-snapshot" {
  run bash "$VSTORM" -n --batch-id=cmb024 --datasource=rhel9 --run-strategy=Manual \
    --dv-url=http://example.com/disk.qcow2 --no-snapshot \
    --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  [[ "$output" == *"runStrategy: Manual"* ]]
  [[ "$output" == *"http://example.com/disk.qcow2"* ]]
  [[ "$output" == *"pvc:"* ]]
}

# ---------------------------------------------------------------
# COMBO-25: --storage-class + --volume-mode=Filesystem + --access-mode=ReadWriteMany
# ---------------------------------------------------------------
@test "combo: NFS storage-class + Filesystem volume-mode + RWX" {
  run bash "$VSTORM" -n --batch-id=cmb025 --datasource=rhel9 --storage-class=my-nfs-sc \
    --volume-mode=Filesystem --access-mode=ReadWriteMany \
    --vms=2 --namespaces=1
  [ "$status" -eq 0 ]

  [[ "$output" == *"storageClassName: my-nfs-sc"* ]]
  [[ "$output" == *"Volume Mode: Filesystem"* ]]
  [[ "$output" == *"volumeMode: Filesystem"* ]]
  [[ "$output" != *"volumeMode: Block"* ]]
  [[ "$output" == *"Access Mode: ReadWriteMany"* ]]
  [[ "$output" == *"ReadWriteMany"* ]]
  [[ "$output" == *"Snapshot mode: disabled (direct DataSource clone)"* ]]
  [[ "$output" != *"kind: VolumeSnapshot"* ]]
}

# ---------------------------------------------------------------
# COMBO-26: --data-disk-size (opt-in blank vdb; omit/0 = none)
# ---------------------------------------------------------------
@test "combo: default has no blank data disk" {
  run bash "$VSTORM" -n --batch-id=cmb026 --datasource=rhel9 \
    --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  [[ "$output" != *"Data disk:"* ]]
  [[ "$output" != *"name: vdb"* ]]
  [[ "$output" != *"blank: {}"* ]]
  [[ "$output" == *"name: vda"* ]]
}

@test "combo: --data-disk-size=50Gi attaches blank vdb" {
  run bash "$VSTORM" -n --batch-id=cmb026b --datasource=rhel9 --data-disk-size=50Gi \
    --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  [[ "$output" == *"Data disk:     50Gi (blank vdb)"* ]]
  [[ "$output" == *"blank: {}"* ]]
  [[ "$output" == *"50Gi"* ]]
  [[ "$output" == *"name: vdb"* ]]
  [[ "$output" == *"-data"* ]]
  # Blank data DV carries batch-id (quoted) so collector can list it with other DVs.
  [[ "$output" == *"batch-id: \"cmb026b\""* ]] || [[ "$output" == *"batch-id: cmb026b"* ]]
}

@test "combo: numeric batch-id on data disk is YAML-quoted" {
  run bash "$VSTORM" -n --batch-id=625156 --datasource=rhel9 --data-disk-size=20G \
    --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  [[ "$output" == *"batch-id: \"625156\""* ]]
}

@test "combo: --data-disk-size=0 disables blank vdb" {
  run bash "$VSTORM" -n --batch-id=cmb027 --datasource=rhel9 --data-disk-size=0 \
    --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  [[ "$output" != *"blank: {}"* ]]
  [[ "$output" != *"name: vdb"* ]]
  [[ "$output" != *"Data disk:"* ]]
}

@test "combo: --data-disk-size=20G attaches blank vdb with expected DV name" {
  run bash "$VSTORM" -n --batch-id=cmb028 --datasource=rhel9 --data-disk-size=20G \
    --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  [[ "$output" == *"Data disk:     20G (blank vdb)"* ]]
  [[ "$output" == *"Data disk enabled: 20G blank volume as vdb"* ]]
  [[ "$output" == *"blank: {}"* ]]
  [[ "$output" == *"name: vdb"* ]]
  [[ "$output" == *"name: rhel9-cmb028-1-data"* ]] || [[ "$output" == *"rhel9-cmb028-1-data"* ]]
  [[ "$output" == *"batch-id: \"cmb028\""* ]]
}

@test "combo: containerdisk with --data-disk-size gets blank vdb only" {
  run bash "$VSTORM" -n --batch-id=cmb029 --containerdisk --data-disk-size=10G \
    --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  [[ "$output" == *"containerDisk:"* ]]
  [[ "$output" == *"Data disk:     10G (blank vdb)"* ]]
  [[ "$output" == *"blank: {}"* ]]
  [[ "$output" == *"name: vdb"* ]]
  [[ "$output" == *"kind: DataVolume"* ]]
  [[ "$output" != *"Creating VolumeSnapshots"* ]]
}

@test "combo: invalid --data-disk-size is rejected" {
  run bash "$VSTORM" -n --batch-id=cmb030 --datasource=rhel9 --data-disk-size=bogus \
    --vms=1 --namespaces=1
  [ "$status" -ne 0 ]
  [[ "$output" == *"Invalid --data-disk-size"* ]]
}

@test "combo: vstorm-prefixed batch-id on data disk stays quoted" {
  run bash "$VSTORM" -n --batch-id=vstorm-f9f39c --datasource=rhel9 --data-disk-size=20G \
    --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  [[ "$output" == *"batch-id: \"vstorm-f9f39c\""* ]]
  [[ "$output" == *"name: vstorm-f9f39c-ns-1"* ]]
  [[ "$output" == *"blank: {}"* ]]
}

