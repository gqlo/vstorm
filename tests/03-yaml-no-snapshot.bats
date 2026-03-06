#!/usr/bin/env bats

# Unit tests for vstorm
# Run with: bats tests/

load 'helpers'

VSTORM="./vstorm"

setup_file() {
    setup_oc_mock
}

# ===============================================================
# YAML structure validation
# ===============================================================

# ---------------------------------------------------------------
# DataSource DV template structure
# ---------------------------------------------------------------
@test "DataSource DV uses storage API with explicit size" {
  run bash "$VSTORM" -n --batch-id=yaml01 --datasource=rhel9 --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  # Uses storage: (not pvc:)
  [[ "$output" == *"storage:"* ]]
  [[ "$output" == *"accessModes:"* ]]
  [[ "$output" == *"ReadWriteMany"* ]]
  [[ "$output" == *"volumeMode: Block"* ]]
  [[ "$output" == *"storageClassName:"* ]]
  # Explicit size included for WFFC compatibility
  [[ "$output" == *"storage: 32Gi"* ]]
}

# ---------------------------------------------------------------
# URL DV template structure
# ---------------------------------------------------------------
@test "URL DV uses source.http.url with explicit storage size" {
  run bash "$VSTORM" -n --batch-id=yaml02 --vms=1 --namespaces=1 \
    --dv-url=http://example.com/disk.qcow2 --storage-size=50Gi
  [ "$status" -eq 0 ]

  [[ "$output" == *"url: http://example.com/disk.qcow2"* ]]
  [[ "$output" == *"storage: 50Gi"* ]]
}

# ---------------------------------------------------------------
# VM YAML structure
# ---------------------------------------------------------------
@test "VM YAML contains all expected sections" {
  run bash "$VSTORM" -n --batch-id=yaml03 --datasource=rhel9 --vms=1 --namespaces=1 \
    --cores=4 --memory=8Gi
  [ "$status" -eq 0 ]

  # VM metadata
  [[ "$output" == *"kind: VirtualMachine"* ]]
  [[ "$output" == *"name: rhel9-yaml03-1"* ]]
  [[ "$output" == *"namespace: vm-yaml03-ns-1"* ]]

  # Spec
  [[ "$output" == *"runStrategy: Always"* ]]
  [[ "$output" == *"dataVolumeTemplates"* ]]

  # CPU and memory from flags
  [[ "$output" == *"cores: 4"* ]]
  [[ "$output" == *"guest: 8Gi"* ]]

  # Devices
  [[ "$output" == *"disk:"* ]]
  [[ "$output" == *"bus: virtio"* ]]
  [[ "$output" == *"masquerade"* ]]
  [[ "$output" == *"networkInterfaceMultiqueue: true"* ]]
  [[ "$output" == *"rng: {}"* ]]

  # Firmware
  [[ "$output" == *"efi:"* ]]
  [[ "$output" == *"secureBoot: false"* ]]

  # Scheduling
  [[ "$output" == *"evictionStrategy: LiveMigrate"* ]]

  # Volumes
  [[ "$output" == *"dataVolume:"* ]]
  [[ "$output" == *"name: vda"* ]]
}

# ---------------------------------------------------------------
# --stop sets run strategy to Halted
# ---------------------------------------------------------------
@test "--stop sets runStrategy to Halted" {
  run bash "$VSTORM" -n --batch-id=yaml04 --datasource=rhel9 --vms=1 --namespaces=1 --stop
  [ "$status" -eq 0 ]

  [[ "$output" == *"runStrategy: Halted"* ]]
}

# ---------------------------------------------------------------
# VolumeSnapshot YAML structure
# ---------------------------------------------------------------
@test "VolumeSnapshot YAML is well-formed" {
  run bash "$VSTORM" -n --batch-id=yaml05 --datasource=rhel9 --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  [[ "$output" == *"apiVersion: snapshot.storage.k8s.io/v1"* ]]
  [[ "$output" == *"kind: VolumeSnapshot"* ]]
  [[ "$output" == *"name: rhel9-vm-yaml05-ns-1"* ]]
  [[ "$output" == *"namespace: vm-yaml05-ns-1"* ]]
  [[ "$output" == *"volumeSnapshotClassName:"* ]]
  [[ "$output" == *"persistentVolumeClaimName: rhel9-base"* ]]
}

# ---------------------------------------------------------------
# Namespace YAML structure
# ---------------------------------------------------------------
@test "Namespace YAML is well-formed" {
  run bash "$VSTORM" -n --batch-id=yaml06 --datasource=rhel9 --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  [[ "$output" == *"apiVersion: v1"* ]]
  [[ "$output" == *"kind: Namespace"* ]]
  [[ "$output" == *"name: vm-yaml06-ns-1"* ]]
  [[ "$output" == *'batch-id: "yaml06"'* ]]
}

# ---------------------------------------------------------------
# Cloud-init Secret YAML structure
# ---------------------------------------------------------------
@test "Cloud-init Secret YAML is well-formed" {
  run bash "$VSTORM" -n --batch-id=yaml07 --datasource=rhel9 --vms=1 --namespaces=1 \
    --cloudinit=workload/cloudinit-stress-ng-workload.yaml
  [ "$status" -eq 0 ]

  [[ "$output" == *"apiVersion: v1"* ]]
  [[ "$output" == *"kind: Secret"* ]]
  [[ "$output" == *"name: rhel9-cloudinit"* ]]
  [[ "$output" == *"namespace: vm-yaml07-ns-1"* ]]
  [[ "$output" == *"type: Opaque"* ]]
  [[ "$output" == *"userdata:"* ]]
  [[ "$output" == *'batch-id: "yaml07"'* ]]
  [[ "$output" == *'vm-basename: "rhel9"'* ]]
}

# ===============================================================
# --no-snapshot mode (direct PVC clone)
# ===============================================================

# ---------------------------------------------------------------
# NS-1: --no-snapshot skips VolumeSnapshots entirely
# ---------------------------------------------------------------
@test "no-snapshot: skips VolumeSnapshot creation" {
  run bash "$VSTORM" -n --batch-id=nosn01 --datasource=rhel9 --no-snapshot --vms=3 --namespaces=1
  [ "$status" -eq 0 ]

  # --- Snapshot info ---
  [[ "$output" == *"Snapshot mode: disabled (direct DataSource clone)"* ]]
  [[ "$output" == *"Skipping VolumeSnapshots"* ]]

  # --- No VolumeSnapshot YAML emitted ---
  [[ "$output" != *"kind: VolumeSnapshot"* ]]
  [[ "$output" != *"volumeSnapshotClassName"* ]]

  # --- No base DataVolume (direct DataSource clone) ---
  [[ "$output" == *"Skipping base DataVolume creation"* ]]

  # --- VMs still created (with inline DataVolumeTemplates) ---
  [[ "$output" == *"Creating VirtualMachines"* ]]
  [[ "$output" == *"kind: VirtualMachine"* ]]
  [[ "$output" == *"dataVolumeTemplates"* ]]

  # --- 3 VMs ---
  local vm_count
  vm_count=$(echo "$output" | grep -c "Creating VirtualMachine [0-9]")
  [ "$vm_count" -eq 3 ]
}

# ---------------------------------------------------------------
# NS-2: --no-snapshot VMs clone directly from DataSource
# ---------------------------------------------------------------
@test "no-snapshot: VMs clone from DataSource instead of snapshot" {
  run bash "$VSTORM" -n --batch-id=nosn02 --datasource=rhel9 --no-snapshot --vms=2 --namespaces=1
  [ "$status" -eq 0 ]

  # --- VM uses DataSource sourceRef (not PVC, not snapshot) ---
  [[ "$output" == *"sourceRef"* ]]
  [[ "$output" == *"kind: DataSource"* ]]
  [[ "$output" == *"name: rhel9"* ]]
  [[ "$output" == *"namespace: openshift-virtualization-os-images"* ]]

  # --- No base PVC reference ---
  [[ "$output" != *"name: rhel9-base"* ]]

  # --- No snapshot references ---
  [[ "$output" != *"smartCloneFromExistingSnapshot"* ]]
}

# ---------------------------------------------------------------
# NS-3: --no-snapshot with URL import
# ---------------------------------------------------------------
@test "no-snapshot: works with --dv-url" {
  run bash "$VSTORM" -n --batch-id=nosn03 --no-snapshot --vms=2 --namespaces=1 \
    --dv-url=http://example.com/disk.qcow2
  [ "$status" -eq 0 ]

  # --- DV imports from URL ---
  [[ "$output" == *"http://example.com/disk.qcow2"* ]]

  # --- No snapshots ---
  [[ "$output" != *"kind: VolumeSnapshot"* ]]
  [[ "$output" == *"Skipping VolumeSnapshots"* ]]

  # --- VMs clone from PVC ---
  [[ "$output" == *"pvc:"* ]]
  [[ "$output" != *"smartCloneFromExistingSnapshot"* ]]
}

# ---------------------------------------------------------------
# NS-4: --no-snapshot with custom cloud-init
# ---------------------------------------------------------------
@test "no-snapshot: works with custom cloud-init" {
  run bash "$VSTORM" -n --batch-id=nosn04 --datasource=rhel9 --no-snapshot --vms=2 --namespaces=1 \
    --cloudinit=workload/cloudinit-stress-ng-workload.yaml
  [ "$status" -eq 0 ]

  # --- Cloud-init Secret created ---
  [[ "$output" == *"kind: Secret"* ]]
  [[ "$output" == *"cloudInitNoCloud"* ]]
  [[ "$output" == *"secretRef"* ]]

  # --- No snapshots ---
  [[ "$output" != *"kind: VolumeSnapshot"* ]]
  [[ "$output" == *"Skipping VolumeSnapshots"* ]]

  # --- Direct DataSource clone ---
  [[ "$output" == *"Skipping base DataVolume creation"* ]]
  [[ "$output" == *"sourceRef"* ]]
}

# ---------------------------------------------------------------
# NS-5: --no-snapshot across multiple namespaces
# ---------------------------------------------------------------
@test "no-snapshot: multiple namespaces, 10 VMs" {
  run bash "$VSTORM" -n --batch-id=nosn05 --datasource=rhel9 --no-snapshot --vms=10 --namespaces=3
  [ "$status" -eq 0 ]

  # --- 3 namespaces ---
  [[ "$output" == *"name: vm-nosn05-ns-1"* ]]
  [[ "$output" == *"name: vm-nosn05-ns-2"* ]]
  [[ "$output" == *"name: vm-nosn05-ns-3"* ]]

  # --- 10 VMs ---
  local vm_count
  vm_count=$(echo "$output" | grep -c "Creating VirtualMachine [0-9]")
  [ "$vm_count" -eq 10 ]

  # --- No snapshots ---
  [[ "$output" != *"kind: VolumeSnapshot"* ]]
}

# ---------------------------------------------------------------
# NS-6: --storage-class option works
# ---------------------------------------------------------------
@test "storage-class option sets storage class on all resources" {
  run bash "$VSTORM" -n --batch-id=nosn06 --datasource=rhel9 --no-snapshot --vms=1 --namespaces=1 \
    --storage-class=my-custom-sc
  [ "$status" -eq 0 ]

  # --- Storage class appears in VM ---
  [[ "$output" == *"storageClassName: my-custom-sc"* ]]
  [[ "$output" == *"Storage Class: my-custom-sc"* ]]

  # --- No base DV (DataSource direct clone) ---
  [[ "$output" == *"Skipping base DataVolume creation"* ]]
}

# ---------------------------------------------------------------
# NS-7: --snapshot (default) still works as before
# ---------------------------------------------------------------
@test "explicit --snapshot produces snapshot-based flow" {
  run bash "$VSTORM" -n --batch-id=nosn07 --datasource=rhel9 --snapshot --vms=2 --namespaces=1
  [ "$status" -eq 0 ]

  # --- Snapshot mode enabled ---
  [[ "$output" == *"Snapshot mode: enabled"* ]]

  # --- VolumeSnapshot created ---
  [[ "$output" == *"Creating VolumeSnapshots"* ]]
  [[ "$output" == *"kind: VolumeSnapshot"* ]]

  # --- VMs clone from snapshot ---
  [[ "$output" == *"smartCloneFromExistingSnapshot"* ]]
}

# ---------------------------------------------------------------
# NS-8: vm-datasource.yaml template is well-formed
# ---------------------------------------------------------------
@test "no-snapshot: VM DataSource clone YAML is well-formed" {
  run bash "$VSTORM" -n --batch-id=nosn08 --datasource=rhel9 --no-snapshot --vms=1 --namespaces=1 \
    --cores=4 --memory=8Gi
  [ "$status" -eq 0 ]

  # VM metadata
  [[ "$output" == *"kind: VirtualMachine"* ]]
  [[ "$output" == *"name: rhel9-nosn08-1"* ]]
  [[ "$output" == *"namespace: vm-nosn08-ns-1"* ]]

  # Spec
  [[ "$output" == *"runStrategy: Always"* ]]
  [[ "$output" == *"dataVolumeTemplates"* ]]

  # DataSource sourceRef (not PVC clone)
  [[ "$output" == *"sourceRef"* ]]
  [[ "$output" == *"kind: DataSource"* ]]
  [[ "$output" == *"name: rhel9"* ]]
  [[ "$output" == *"namespace: openshift-virtualization-os-images"* ]]
  [[ "$output" != *"name: rhel9-base"* ]]

  # Storage spec on inline DV
  [[ "$output" == *"storage:"* ]]
  [[ "$output" == *"accessModes:"* ]]
  [[ "$output" == *"volumeMode: Block"* ]]
  [[ "$output" == *"storage: 32Gi"* ]]

  # CPU and memory from flags
  [[ "$output" == *"cores: 4"* ]]
  [[ "$output" == *"guest: 8Gi"* ]]

  # Standard VM features
  [[ "$output" == *"bus: virtio"* ]]
  [[ "$output" == *"masquerade"* ]]
  [[ "$output" == *"evictionStrategy: LiveMigrate"* ]]
  [[ "$output" == *"efi:"* ]]

  # Labels
  [[ "$output" == *'batch-id: "nosn08"'* ]]
  [[ "$output" == *'vm-basename: "rhel9"'* ]]
}

