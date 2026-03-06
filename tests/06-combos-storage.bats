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
# COMBO-1: --storage-class + --rwo + --no-snapshot
# ---------------------------------------------------------------
@test "combo: storage-class + rwo + no-snapshot on DataSource clone" {
  run bash "$VSTORM" -n --batch-id=cmb001 --datasource=rhel9 --storage-class=my-sc --rwo \
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
# COMBO-2: --storage-class + --snapshot-class + --rwo
# ---------------------------------------------------------------
@test "combo: storage-class + snapshot-class + rwo in snapshot path" {
  run bash "$VSTORM" -n --batch-id=cmb002 --datasource=rhel9 --storage-class=my-rbd \
    --snapshot-class=my-snap --rwo --vms=2 --namespaces=1
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
# COMBO-3: --storage-class + --rwo + --dv-url
# ---------------------------------------------------------------
@test "combo: storage-class + rwo + dv-url on URL import path" {
  run bash "$VSTORM" -n --batch-id=cmb003 --storage-class=my-sc --rwo \
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
    --snapshot --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  # --- Custom size on base DV ---
  [[ "$output" == *"storage: 50Gi"* ]]

  # --- Snapshot flow ---
  [[ "$output" == *"Snapshot mode: enabled"* ]]
  [[ "$output" == *"kind: VolumeSnapshot"* ]]
  [[ "$output" == *"Creating DataVolumes"* ]]
}

# ---------------------------------------------------------------
# COMBO-7: --rwx + --dv-url + --snapshot
# ---------------------------------------------------------------
@test "combo: rwx + dv-url + snapshot" {
  run bash "$VSTORM" -n --batch-id=cmb007 --datasource=rhel9 --rwx \
    --dv-url=http://example.com/disk.qcow2 --snapshot --vms=2 --namespaces=1
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
# COMBO-8: --rwo + --storage-class + --no-snapshot + --storage-size
# ---------------------------------------------------------------
@test "combo: all storage options on DataSource clone path" {
  run bash "$VSTORM" -n --batch-id=cmb008 --datasource=rhel9 --rwo --storage-class=my-sc \
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
    --dv-url=http://example.com/disk.qcow2 --snapshot \
    --cloudinit=workload/cloudinit-stress-ng-workload.yaml --vms=2 --namespaces=1
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
    --cloudinit=workload/cloudinit-stress-ng-workload.yaml --vms=2 --namespaces=1
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
    --cloudinit=workload/cloudinit-stress-ng-workload.yaml \
    --vms=6 --namespaces=3
  [ "$status" -eq 0 ]

  # --- 3 namespaces ---
  [[ "$output" == *"name: vm-cmb012-ns-1"* ]]
  [[ "$output" == *"name: vm-cmb012-ns-2"* ]]
  [[ "$output" == *"name: vm-cmb012-ns-3"* ]]

  # --- 3 Secrets (one per namespace) ---
  local secret_count
  secret_count=$(echo "$output" | grep -c "kind: Secret")
  [ "$secret_count" -eq 3 ]

  # --- DataSource clone ---
  [[ "$output" == *"Skipping base DataVolume creation"* ]]
  [[ "$output" == *"sourceRef"* ]]
}

# ---------------------------------------------------------------
# COMBO-13: --dv-url + --snapshot (no --cloudinit) → no auto cloud-init
# ---------------------------------------------------------------
@test "combo: dv-url + snapshot without cloudinit has no auto cloud-init" {
  run bash "$VSTORM" -n --batch-id=cmb013 --datasource=rhel9 \
    --dv-url=http://example.com/disk.qcow2 --snapshot \
    --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  # --- URL + snapshot mode ---
  [[ "$output" == *"http://example.com/disk.qcow2"* ]]
  [[ "$output" == *"kind: VolumeSnapshot"* ]]

  # --- No cloud-init ---
  [[ "$output" != *"applying default cloud-init"* ]]
  [[ "$output" != *"kind: Secret"* ]]
  [[ "$output" != *"cloudInitNoCloud"* ]]
}

# ---------------------------------------------------------------
# COMBO-14: --no-snapshot + --basename=fedora + --cloudinit
# ---------------------------------------------------------------
@test "combo: no-snapshot + custom basename + cloudinit" {
  run bash "$VSTORM" -n --batch-id=cmb014 --datasource=rhel9 --no-snapshot --basename=fedora \
    --cloudinit=workload/cloudinit-stress-ng-workload.yaml --vms=1 --namespaces=1
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
    --snapshot --vms=1 --namespaces=1
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
    --request-cpu=2 --request-memory=4Gi --snapshot --vms=1 --namespaces=1
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
# COMBO-19: --stop + --snapshot
# ---------------------------------------------------------------
@test "combo: stop + snapshot sets Halted in snapshot path" {
  run bash "$VSTORM" -n --batch-id=cmb019 --datasource=rhel9 --stop --snapshot \
    --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  [[ "$output" == *"runStrategy: Halted"* ]]
  [[ "$output" == *"Snapshot mode: enabled"* ]]
  [[ "$output" == *"smartCloneFromExistingSnapshot"* ]]
}

# ---------------------------------------------------------------
# COMBO-20: --stop + --dv-url + --no-snapshot
# ---------------------------------------------------------------
@test "combo: stop + dv-url + no-snapshot sets Halted in URL clone" {
  run bash "$VSTORM" -n --batch-id=cmb020 --datasource=rhel9 --stop \
    --dv-url=http://example.com/disk.qcow2 --no-snapshot \
    --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  [[ "$output" == *"runStrategy: Halted"* ]]
  [[ "$output" == *"http://example.com/disk.qcow2"* ]]
  [[ "$output" == *"pvc:"* ]]
}

# ---------------------------------------------------------------
# COMBO-21: --start + --no-snapshot
# ---------------------------------------------------------------
@test "combo: start + no-snapshot sets Always in DataSource clone" {
  run bash "$VSTORM" -n --batch-id=cmb021 --datasource=rhel9 --start --no-snapshot \
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
  run bash "$VSTORM" -n --batch-id=cmb022 --datasource=rhel9 --run-strategy=Manual --snapshot \
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

