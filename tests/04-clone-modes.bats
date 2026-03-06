#!/usr/bin/env bats

# Unit tests for vstorm
# Run with: bats tests/

load 'helpers'

VSTORM="./vstorm"

setup_file() {
    setup_oc_mock
}

# ===============================================================
# Direct DataSource clone (no-snapshot + DataSource)
# ===============================================================

# ---------------------------------------------------------------
# DC-1: Custom DataSource name propagates into each VM's inline DV
# ---------------------------------------------------------------
@test "datasource-clone: custom DataSource name in inline DV" {
  run bash "$VSTORM" -n --batch-id=dc0001 --no-snapshot --datasource=fedora \
    --vms=2 --namespaces=1
  [ "$status" -eq 0 ]

  # --- Skips base DV ---
  [[ "$output" == *"Skipping base DataVolume creation"* ]]

  # --- Each VM's DV references fedora DataSource ---
  [[ "$output" == *"sourceRef"* ]]
  [[ "$output" == *"kind: DataSource"* ]]
  [[ "$output" == *"name: fedora"* ]]
  [[ "$output" == *"namespace: openshift-virtualization-os-images"* ]]

  # --- No fedora-base PVC ---
  [[ "$output" != *"name: fedora-base"* ]]
}

# ---------------------------------------------------------------
# DC-2: Default DataSource namespace appears in each VM's inline DV
# ---------------------------------------------------------------
@test "datasource-clone: DataSource namespace in inline DV" {
  run bash "$VSTORM" -n --batch-id=dc0002 --no-snapshot --datasource=win2k22 \
    --basename=win2k22 --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  # --- DataSource references correct name and default namespace ---
  [[ "$output" == *"name: win2k22"* ]]
  [[ "$output" == *"namespace: openshift-virtualization-os-images"* ]]

  # --- VM basename set to match DataSource ---
  [[ "$output" == *'vm-basename: "win2k22"'* ]]
  [[ "$output" == *"name: win2k22-dc0002-1"* ]]

  # --- No base DV ---
  [[ "$output" == *"Skipping base DataVolume creation"* ]]
}

# ---------------------------------------------------------------
# DC-3: Custom storage size propagates into inline DV
# ---------------------------------------------------------------
@test "datasource-clone: --storage-size in inline DV" {
  run bash "$VSTORM" -n --batch-id=dc0003 --datasource=rhel9 --no-snapshot \
    --storage-size=50Gi --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  # --- Inline DV has the custom storage size ---
  [[ "$output" == *"storage: 50Gi"* ]]

  # --- Still direct DataSource clone ---
  [[ "$output" == *"Skipping base DataVolume creation"* ]]
  [[ "$output" == *"sourceRef"* ]]
}

# ---------------------------------------------------------------
# DC-4: Each VM gets a uniquely named DV (not rhel9-base)
# ---------------------------------------------------------------
@test "datasource-clone: per-VM unique DV names" {
  run bash "$VSTORM" -n --batch-id=dc0004 --datasource=rhel9 --no-snapshot --vms=3 --namespaces=1
  [ "$status" -eq 0 ]

  # --- Each VM's DV has a unique name ---
  [[ "$output" == *"name: rhel9-dc0004-1"* ]]
  [[ "$output" == *"name: rhel9-dc0004-2"* ]]
  [[ "$output" == *"name: rhel9-dc0004-3"* ]]

  # --- No base DV name ---
  [[ "$output" != *"name: rhel9-base"* ]]
}

# ---------------------------------------------------------------
# DC-5: Multiple namespaces — no base PVC per namespace
# ---------------------------------------------------------------
@test "datasource-clone: multi-namespace has no per-namespace base DV" {
  run bash "$VSTORM" -n --batch-id=dc0005 --datasource=rhel9 --no-snapshot --vms=4 --namespaces=2
  [ "$status" -eq 0 ]

  # --- 2 namespaces ---
  [[ "$output" == *"name: vm-dc0005-ns-1"* ]]
  [[ "$output" == *"name: vm-dc0005-ns-2"* ]]

  # --- No base DV for any namespace ---
  [[ "$output" == *"Skipping base DataVolume creation"* ]]
  [[ "$output" != *"name: rhel9-base"* ]]

  # --- All 4 VMs created ---
  local vm_count
  vm_count=$(echo "$output" | grep -c "Creating VirtualMachine [0-9]")
  [ "$vm_count" -eq 4 ]

  # --- Each VM references the DataSource ---
  # Count sourceRef occurrences (one per VM)
  local ds_count
  ds_count=$(echo "$output" | grep -c "kind: DataSource")
  [ "$ds_count" -eq 4 ]
}

# ---------------------------------------------------------------
# DC-6: URL import + no-snapshot still creates base DV
# ---------------------------------------------------------------
@test "datasource-clone: URL import still creates base DV (not direct clone)" {
  run bash "$VSTORM" -n --batch-id=dc0006 --no-snapshot \
    --dv-url=http://example.com/disk.qcow2 --vms=2 --namespaces=1
  [ "$status" -eq 0 ]

  # --- Base DV IS created (URL import path) ---
  [[ "$output" == *"Creating DataVolumes"* ]]
  [[ "$output" == *"kind: DataVolume"* ]]
  [[ "$output" == *"name: vm-base"* ]]
  [[ "$output" != *"Skipping base DataVolume creation"* ]]

  # --- Snapshot mode shows PVC clone (not DataSource clone) ---
  [[ "$output" == *"Snapshot mode: disabled (direct PVC clone)"* ]]

  # --- VMs clone from base PVC ---
  [[ "$output" == *"pvc:"* ]]
  [[ "$output" == *"name: vm-base"* ]]
}

# ---------------------------------------------------------------
# DC-7: Snapshot mode + DataSource still creates base DV
# ---------------------------------------------------------------
@test "datasource-clone: snapshot mode still creates base DV" {
  run bash "$VSTORM" -n --batch-id=dc0007 --datasource=rhel9 --snapshot --vms=2 --namespaces=1
  [ "$status" -eq 0 ]

  # --- Base DV IS created ---
  [[ "$output" == *"Creating DataVolumes"* ]]
  [[ "$output" == *"name: rhel9-base"* ]]
  [[ "$output" != *"Skipping base DataVolume creation"* ]]

  # --- VolumeSnapshot from base DV ---
  [[ "$output" == *"kind: VolumeSnapshot"* ]]
  [[ "$output" == *"persistentVolumeClaimName: rhel9-base"* ]]

  # --- VMs clone from snapshot ---
  [[ "$output" == *"smartCloneFromExistingSnapshot"* ]]
}

# ---------------------------------------------------------------
# DC-8: Access mode applies to inline DV in vm-datasource.yaml
# ---------------------------------------------------------------
@test "datasource-clone: --rwo access mode on inline DV" {
  run bash "$VSTORM" -n --batch-id=dc0008 --datasource=rhel9 --no-snapshot --rwo --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  # --- Access mode in summary ---
  [[ "$output" == *"Access Mode: ReadWriteOnce"* ]]

  # --- RWO in inline DV (no RWX anywhere) ---
  [[ "$output" == *"ReadWriteOnce"* ]]
  [[ "$output" != *"ReadWriteMany"* ]]

  # --- Still direct DataSource clone ---
  [[ "$output" == *"sourceRef"* ]]
  [[ "$output" == *"kind: DataSource"* ]]
}

# ---------------------------------------------------------------
# DC-9: Auto-detect RWO + no base DVs (mock oc)
# ---------------------------------------------------------------
@test "datasource-clone: auto-detect RWO with no base DVs" {
  local mock_dir
  mock_dir=$(mktemp -d)
  _create_mock_oc "$mock_dir"

  export MOCK_ACCESS_MODE=ReadWriteOnce
  export PATH="$mock_dir:$PATH"

  run bash "$VSTORM" -n --batch-id=dc0009 --datasource=rhel9 --storage-class=lvms-nvme-sc \
    --no-snapshot --vms=2 --namespaces=1

  rm -rf "$mock_dir"
  rm -f logs/dc0009-dryrun.yaml

  [ "$status" -eq 0 ]
  [[ "$output" == *"Auto-detected access mode 'ReadWriteOnce'"* ]]
  [[ "$output" == *"Skipping base DataVolume creation"* ]]
}

# ---------------------------------------------------------------
# DC-10: --stop with direct DataSource clone
# ---------------------------------------------------------------
@test "datasource-clone: --stop sets Halted runStrategy" {
  run bash "$VSTORM" -n --batch-id=dc0010 --datasource=rhel9 --no-snapshot --stop --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  [[ "$output" == *"runStrategy: Halted"* ]]
  [[ "$output" == *"sourceRef"* ]]
  [[ "$output" == *"kind: DataSource"* ]]
}

# ===============================================================
# Auto-detection: --storage-class without --snapshot-class
# ===============================================================

# ---------------------------------------------------------------
# AD-1: custom storage class auto-disables snapshots
# ---------------------------------------------------------------
@test "auto-detect: custom storage-class without snapshot-class disables snapshots" {
  run bash "$VSTORM" -n --batch-id=auto01 --datasource=rhel9 --storage-class=my-nfs-sc --vms=3 --namespaces=1
  [ "$status" -eq 0 ]

  # --- Auto-detected no-snapshot mode ---
  [[ "$output" == *"Snapshot mode: disabled (direct DataSource clone)"* ]]
  [[ "$output" == *"Skipping VolumeSnapshots"* ]]

  # --- No VolumeSnapshot YAML emitted ---
  [[ "$output" != *"kind: VolumeSnapshot"* ]]
  [[ "$output" != *"volumeSnapshotClassName"* ]]

  # --- No base DV (direct DataSource clone) ---
  [[ "$output" == *"Skipping base DataVolume creation"* ]]

  # --- Storage class applied to resources ---
  [[ "$output" == *"storageClassName: my-nfs-sc"* ]]
  [[ "$output" == *"Storage Class: my-nfs-sc"* ]]

  # --- VMs use DataSource clone ---
  [[ "$output" == *"sourceRef"* ]]
  [[ "$output" == *"kind: DataSource"* ]]
  [[ "$output" != *"smartCloneFromExistingSnapshot"* ]]

  # --- 3 VMs still created ---
  local vm_count
  vm_count=$(echo "$output" | grep -c "Creating VirtualMachine [0-9]")
  [ "$vm_count" -eq 3 ]
}

# ---------------------------------------------------------------
# AD-2: custom storage-class + snapshot-class keeps snapshots
# ---------------------------------------------------------------
@test "auto-detect: custom storage-class with snapshot-class keeps snapshots enabled" {
  run bash "$VSTORM" -n --batch-id=auto02 --datasource=rhel9 --storage-class=my-rbd-sc \
    --snapshot-class=my-rbd-snap --vms=2 --namespaces=1
  [ "$status" -eq 0 ]

  # --- Snapshot mode enabled ---
  [[ "$output" == *"Snapshot mode: enabled"* ]]
  [[ "$output" == *"Creating VolumeSnapshots"* ]]
  [[ "$output" == *"kind: VolumeSnapshot"* ]]

  # --- Uses the provided snapshot class ---
  [[ "$output" == *"volumeSnapshotClassName: my-rbd-snap"* ]]

  # --- Uses the provided storage class ---
  [[ "$output" == *"storageClassName: my-rbd-sc"* ]]

  # --- VMs clone from snapshot ---
  [[ "$output" == *"smartCloneFromExistingSnapshot"* ]]
}

# ---------------------------------------------------------------
# AD-3: custom storage-class + explicit --snapshot overrides
# ---------------------------------------------------------------
@test "auto-detect: custom storage-class with explicit --snapshot keeps snapshots" {
  run bash "$VSTORM" -n --batch-id=auto03 --datasource=rhel9 --storage-class=my-ceph-sc \
    --snapshot --vms=2 --namespaces=1
  [ "$status" -eq 0 ]

  # --- Snapshot mode enabled (explicit override) ---
  [[ "$output" == *"Snapshot mode: enabled"* ]]
  [[ "$output" == *"Creating VolumeSnapshots"* ]]
  [[ "$output" == *"kind: VolumeSnapshot"* ]]

  # --- Storage class applied ---
  [[ "$output" == *"storageClassName: my-ceph-sc"* ]]
}

# ---------------------------------------------------------------
# AD-4: default storage class (no --storage-class flag) keeps snapshots
# ---------------------------------------------------------------
@test "auto-detect: default storage class keeps snapshots enabled" {
  run bash "$VSTORM" -n --batch-id=auto04 --datasource=rhel9 --vms=2 --namespaces=1
  [ "$status" -eq 0 ]

  # --- Snapshot mode enabled (default) ---
  [[ "$output" == *"Snapshot mode: enabled"* ]]
  [[ "$output" == *"Creating VolumeSnapshots"* ]]
  [[ "$output" == *"kind: VolumeSnapshot"* ]]
  [[ "$output" == *"smartCloneFromExistingSnapshot"* ]]
}

# ===============================================================
# Access mode options (--access-mode, --rwo, --rwx)
# ===============================================================

# ---------------------------------------------------------------
# AM-1: default access mode is ReadWriteMany
# ---------------------------------------------------------------
@test "access-mode: default is ReadWriteMany" {
  run bash "$VSTORM" -n --batch-id=am0001 --datasource=rhel9 --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  [[ "$output" == *"Access Mode: ReadWriteMany"* ]]
  [[ "$output" == *"ReadWriteMany"* ]]
}

# ---------------------------------------------------------------
# AM-2: --rwo shortcut sets ReadWriteOnce on all resources
# ---------------------------------------------------------------
@test "access-mode: --rwo sets ReadWriteOnce on DV and VM" {
  run bash "$VSTORM" -n --batch-id=am0002 --datasource=rhel9 --rwo --no-snapshot --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  [[ "$output" == *"Access Mode: ReadWriteOnce"* ]]
  [[ "$output" == *"ReadWriteOnce"* ]]
  [[ "$output" != *"ReadWriteMany"* ]]
}

# ---------------------------------------------------------------
# AM-3: --access-mode=ReadWriteOnce
# ---------------------------------------------------------------
@test "access-mode: --access-mode=ReadWriteOnce" {
  run bash "$VSTORM" -n --batch-id=am0003 --datasource=rhel9 --access-mode=ReadWriteOnce --no-snapshot --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  [[ "$output" == *"Access Mode: ReadWriteOnce"* ]]
  [[ "$output" == *"ReadWriteOnce"* ]]
  [[ "$output" != *"ReadWriteMany"* ]]
}

# ---------------------------------------------------------------
# AM-4: --rwx shortcut sets ReadWriteMany
# ---------------------------------------------------------------
@test "access-mode: --rwx sets ReadWriteMany" {
  run bash "$VSTORM" -n --batch-id=am0004 --datasource=rhel9 --rwx --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  [[ "$output" == *"Access Mode: ReadWriteMany"* ]]
  [[ "$output" == *"ReadWriteMany"* ]]
}

# ---------------------------------------------------------------
# AM-5: --rwo with snapshot mode (VMs also get RWO)
# ---------------------------------------------------------------
@test "access-mode: --rwo applies to snapshot-based VMs too" {
  run bash "$VSTORM" -n --batch-id=am0005 --datasource=rhel9 --rwo --snapshot --vms=2 --namespaces=1
  [ "$status" -eq 0 ]

  [[ "$output" == *"Access Mode: ReadWriteOnce"* ]]
  [[ "$output" == *"ReadWriteOnce"* ]]
  [[ "$output" != *"ReadWriteMany"* ]]
}

# ---------------------------------------------------------------
# AM-6: --rwo with URL import mode
# ---------------------------------------------------------------
@test "access-mode: --rwo with URL import" {
  run bash "$VSTORM" -n --batch-id=am0006 --rwo --no-snapshot --vms=1 --namespaces=1 \
    --dv-url=http://example.com/disk.qcow2
  [ "$status" -eq 0 ]

  [[ "$output" == *"Access Mode: ReadWriteOnce"* ]]
  [[ "$output" == *"ReadWriteOnce"* ]]
  [[ "$output" != *"ReadWriteMany"* ]]
}

