#!/usr/bin/env bats

# Unit tests for vstorm
# Run with: bats tests/

load 'helpers'

VSTORM="./vstorm"

setup_file() {
    setup_oc_mock
}

# ===============================================================
# Quick start commands (README)
# ===============================================================

# ---------------------------------------------------------------
# QS-1: ./vstorm --cores=4 --memory=8Gi --vms=10 --namespaces=2
#   Default DataSource (rhel9), 10 VMs with custom CPU/memory
# ---------------------------------------------------------------
@test "QS: default DataSource, 4 cores 8Gi, 10 VMs across 2 namespaces" {
  run bash "$VSTORM" -n --batch-id=qs0001 --datasource=rhel9 --cores=4 --memory=8Gi --vms=10 --namespaces=2
  [ "$status" -eq 0 ]

  # --- Namespaces ---
  [[ "$output" == *"name: vm-qs0001-ns-1"* ]]
  [[ "$output" == *"name: vm-qs0001-ns-2"* ]]
  [[ "$output" != *"vm-qs0001-ns-3"* ]]

  # --- DataVolume clones from rhel9 DataSource ---
  [[ "$output" == *"Creating DataVolumes"* ]]
  [[ "$output" == *"kind: DataVolume"* ]]
  [[ "$output" == *"sourceRef"* ]]
  [[ "$output" == *"kind: DataSource"* ]]
  [[ "$output" == *"name: rhel9"* ]]
  [[ "$output" == *"namespace: openshift-virtualization-os-images"* ]]

  # --- DV has explicit storage size ---
  [[ "$output" == *"storage: 32Gi"* ]]

  # --- VolumeSnapshots ---
  [[ "$output" == *"Creating VolumeSnapshots"* ]]
  [[ "$output" == *"kind: VolumeSnapshot"* ]]
  [[ "$output" == *"name: rhel9-vm-qs0001-ns-1"* ]]
  [[ "$output" == *"name: rhel9-vm-qs0001-ns-2"* ]]

  # --- VMs clone from snapshot ---
  [[ "$output" == *"Creating VirtualMachines"* ]]
  [[ "$output" == *"kind: VirtualMachine"* ]]
  [[ "$output" == *"smartCloneFromExistingSnapshot"* ]]

  # --- 10 VMs total: 5 per namespace ---
  local vm_count
  vm_count=$(echo "$output" | grep -c "Creating VirtualMachine [0-9]")
  [ "$vm_count" -eq 10 ]

  # --- Default cloud-init auto-applied ---
  [[ "$output" == *"applying default cloud-init"* ]]
  [[ "$output" == *"kind: Secret"* ]]
  [[ "$output" == *"secretRef"* ]]
  [[ "$output" == *"cloudInitNoCloud"* ]]

  # --- VM spec: custom CPU and memory ---
  [[ "$output" == *"cores: 4"* ]]
  [[ "$output" == *"guest: 8Gi"* ]]

  # --- VM spec structure ---
  [[ "$output" == *"runStrategy: Always"* ]]
  [[ "$output" == *"bus: virtio"* ]]
  [[ "$output" == *"masquerade"* ]]
  [[ "$output" == *"evictionStrategy: LiveMigrate"* ]]

  # --- Log messages reflect custom CPU/memory ---
  [[ "$output" == *"VM CPU cores:  4"* ]]
  [[ "$output" == *"VM memory:     8Gi"* ]]

  # --- Labels on all resources ---
  [[ "$output" == *'batch-id: "qs0001"'* ]]
  [[ "$output" == *'vm-basename: "rhel9"'* ]]
}

# ---------------------------------------------------------------
# QS-2: ./vstorm --datasource=fedora --vms=5 --namespaces=1
#   Different DataSource (fedora)
# ---------------------------------------------------------------
@test "QS: fedora DataSource, 5 VMs in 1 namespace" {
  run bash "$VSTORM" -n --batch-id=qs0002 --datasource=fedora --vms=5 --namespaces=1
  [ "$status" -eq 0 ]

  # --- Single namespace ---
  [[ "$output" == *"name: vm-qs0002-ns-1"* ]]
  [[ "$output" != *"vm-qs0002-ns-2"* ]]

  # --- DV references fedora DataSource ---
  [[ "$output" == *"sourceRef"* ]]
  [[ "$output" == *"kind: DataSource"* ]]
  [[ "$output" == *"name: fedora"* ]]
  [[ "$output" == *"namespace: openshift-virtualization-os-images"* ]]

  # --- VolumeSnapshot created ---
  [[ "$output" == *"kind: VolumeSnapshot"* ]]

  # --- 5 VMs ---
  local vm_count
  vm_count=$(echo "$output" | grep -c "Creating VirtualMachine [0-9]")
  [ "$vm_count" -eq 5 ]

  # --- VMs clone from snapshot ---
  [[ "$output" == *"smartCloneFromExistingSnapshot"* ]]

  # --- Default cloud-init auto-applied ---
  [[ "$output" == *"applying default cloud-init"* ]]
  [[ "$output" == *"kind: Secret"* ]]
}

# ---------------------------------------------------------------
# QS-3: ./vstorm --dv-url=http://myhost:8000/rhel9-disk.qcow2 --vms=10 --namespaces=2
#   URL import mode
# ---------------------------------------------------------------
@test "QS: URL import, 10 VMs across 2 namespaces" {
  run bash "$VSTORM" -n --batch-id=qs0003 --vms=10 --namespaces=2 \
    --dv-url=http://myhost:8000/rhel9-disk.qcow2
  [ "$status" -eq 0 ]

  # --- 2 namespaces ---
  [[ "$output" == *"name: vm-qs0003-ns-1"* ]]
  [[ "$output" == *"name: vm-qs0003-ns-2"* ]]

  # --- DV imports from URL (not DataSource) ---
  [[ "$output" == *"kind: DataVolume"* ]]
  [[ "$output" == *"http://myhost:8000/rhel9-disk.qcow2"* ]]
  [[ "$output" != *"sourceRef"* ]]
  [[ "$output" != *"kind: DataSource"* ]]

  # --- DV uses explicit storage size ---
  [[ "$output" == *"storage: 32Gi"* ]]

  # --- VolumeSnapshots ---
  [[ "$output" == *"Creating VolumeSnapshots"* ]]
  [[ "$output" == *"kind: VolumeSnapshot"* ]]
  [[ "$output" == *"name: vm-vm-qs0003-ns-1"* ]]
  [[ "$output" == *"name: vm-vm-qs0003-ns-2"* ]]

  # --- 10 VMs ---
  local vm_count
  vm_count=$(echo "$output" | grep -c "Creating VirtualMachine [0-9]")
  [ "$vm_count" -eq 10 ]

  # --- No auto cloud-init in URL mode ---
  [[ "$output" != *"applying default cloud-init"* ]]
  [[ "$output" != *"kind: Secret"* ]]
  [[ "$output" != *"cloudInitNoCloud"* ]]

  # --- VMs clone from snapshot ---
  [[ "$output" == *"smartCloneFromExistingSnapshot"* ]]
}

# ---------------------------------------------------------------
# QS-4: ./vstorm --cloudinit=workload/cloudinit-stress-ng-workload.yaml --vms=10 --namespaces=2
#   Custom cloud-init workload
# ---------------------------------------------------------------
@test "QS: custom cloud-init stress-ng workload, 10 VMs across 2 namespaces" {
  run bash "$VSTORM" -n --batch-id=qs0004 --datasource=rhel9 --vms=10 --namespaces=2 \
    --cloudinit=workload/cloudinit-stress-ng-workload.yaml
  [ "$status" -eq 0 ]

  # --- DataSource mode (default) ---
  [[ "$output" == *"sourceRef"* ]]
  [[ "$output" == *"kind: DataSource"* ]]
  [[ "$output" == *"name: rhel9"* ]]

  # --- Cloud-init Secret created per namespace ---
  local secret_count
  secret_count=$(echo "$output" | grep -c "kind: Secret")
  [ "$secret_count" -eq 2 ]

  # --- Secret references correct name ---
  [[ "$output" == *"name: rhel9-cloudinit"* ]]

  # --- VM volumes use secretRef ---
  [[ "$output" == *"cloudInitNoCloud"* ]]
  [[ "$output" == *"secretRef"* ]]
  [[ "$output" != *"userDataBase64"* ]]

  # --- 10 VMs ---
  local vm_count
  vm_count=$(echo "$output" | grep -c "Creating VirtualMachine [0-9]")
  [ "$vm_count" -eq 10 ]

  # --- Explicit cloud-init, not auto-applied ---
  [[ "$output" != *"applying default cloud-init"* ]]
}

# ---------------------------------------------------------------
# QS-4b: ./vstorm --cloudinit=workload/cloudinit-stress-ng-workload.yaml --vms=5 --namespaces=1
#   Custom cloud-init stress-ng workload (same file, different run)
# ---------------------------------------------------------------
@test "QS: custom cloud-init stress-ng workload, 5 VMs in 1 namespace" {
  run bash "$VSTORM" -n --batch-id=qs004b --datasource=rhel9 --vms=5 --namespaces=1 \
    --cloudinit=workload/cloudinit-stress-ng-workload.yaml
  [ "$status" -eq 0 ]
  [[ "$output" == *"sourceRef"* ]]
  [[ "$output" == *"cloudInitNoCloud"* ]]
  [[ "$output" == *"secretRef"* ]]
  local vm_count
  vm_count=$(echo "$output" | grep -c "Creating VirtualMachine [0-9]")
  [ "$vm_count" -eq 5 ]
}

# ---------------------------------------------------------------
# QS-5: ./vstorm --datasource=centos-stream9 --vms=5 --namespaces=1
#   Different DataSource with default cloud-init auto-applied
# ---------------------------------------------------------------
@test "QS: centos-stream9 DataSource with default cloud-init" {
  run bash "$VSTORM" -n --batch-id=qs0005 --datasource=centos-stream9 --vms=5 --namespaces=1
  [ "$status" -eq 0 ]

  # --- DV references centos-stream9 DataSource ---
  [[ "$output" == *"sourceRef"* ]]
  [[ "$output" == *"kind: DataSource"* ]]
  [[ "$output" == *"name: centos-stream9"* ]]
  [[ "$output" == *"namespace: openshift-virtualization-os-images"* ]]

  # --- DV + snapshot + clone flow ---
  [[ "$output" == *"Creating DataVolumes"* ]]
  [[ "$output" == *"Creating VolumeSnapshots"* ]]
  [[ "$output" == *"smartCloneFromExistingSnapshot"* ]]

  # --- 5 VMs ---
  local vm_count
  vm_count=$(echo "$output" | grep -c "Creating VirtualMachine [0-9]")
  [ "$vm_count" -eq 5 ]

  # --- Default cloud-init auto-applied (not explicit) ---
  [[ "$output" == *"applying default cloud-init"* ]]
  [[ "$output" == *"kind: Secret"* ]]
  [[ "$output" == *"secretRef"* ]]
  [[ "$output" == *"cloudInitNoCloud"* ]]
}

# ---------------------------------------------------------------
# QS-6: ./vstorm --storage-class=my-nfs-sc --vms=10 --namespaces=2
#   Non-OCS storage class (snapshots auto-disabled)
# ---------------------------------------------------------------
@test "QS: non-OCS storage class auto-disables snapshots, 10 VMs across 2 namespaces" {
  run bash "$VSTORM" -n --batch-id=qs0006 --datasource=rhel9 --storage-class=my-nfs-sc --vms=10 --namespaces=2
  [ "$status" -eq 0 ]

  # --- 2 namespaces ---
  [[ "$output" == *"name: vm-qs0006-ns-1"* ]]
  [[ "$output" == *"name: vm-qs0006-ns-2"* ]]

  # --- Snapshots auto-disabled ---
  [[ "$output" == *"Snapshot mode: disabled (direct DataSource clone)"* ]]
  [[ "$output" == *"Skipping VolumeSnapshots"* ]]
  [[ "$output" != *"kind: VolumeSnapshot"* ]]

  # --- No base DV (direct DataSource clone) ---
  [[ "$output" == *"Skipping base DataVolume creation"* ]]

  # --- Storage class applied ---
  [[ "$output" == *"storageClassName: my-nfs-sc"* ]]
  [[ "$output" == *"Storage Class: my-nfs-sc"* ]]

  # --- VMs clone directly from DataSource ---
  [[ "$output" == *"sourceRef"* ]]
  [[ "$output" == *"kind: DataSource"* ]]
  [[ "$output" != *"smartCloneFromExistingSnapshot"* ]]

  # --- 10 VMs ---
  local vm_count
  vm_count=$(echo "$output" | grep -c "Creating VirtualMachine [0-9]")
  [ "$vm_count" -eq 10 ]

  # --- Default cloud-init auto-applied ---
  [[ "$output" == *"applying default cloud-init"* ]]
  [[ "$output" == *"kind: Secret"* ]]
}

# ---------------------------------------------------------------
# QS-7: ./vstorm --storage-class=my-rbd-sc --snapshot-class=my-rbd-snap --vms=10 --namespaces=2
#   Custom storage + snapshot class pair (snapshots enabled)
# ---------------------------------------------------------------
@test "QS: custom storage and snapshot class pair, 10 VMs across 2 namespaces" {
  run bash "$VSTORM" -n --batch-id=qs0007 --datasource=rhel9 --storage-class=my-rbd-sc \
    --snapshot-class=my-rbd-snap --vms=10 --namespaces=2
  [ "$status" -eq 0 ]

  # --- 2 namespaces ---
  [[ "$output" == *"name: vm-qs0007-ns-1"* ]]
  [[ "$output" == *"name: vm-qs0007-ns-2"* ]]

  # --- Snapshots enabled (both classes provided) ---
  [[ "$output" == *"Snapshot mode: enabled"* ]]
  [[ "$output" == *"Creating VolumeSnapshots"* ]]
  [[ "$output" == *"kind: VolumeSnapshot"* ]]

  # --- Uses provided classes ---
  [[ "$output" == *"storageClassName: my-rbd-sc"* ]]
  [[ "$output" == *"volumeSnapshotClassName: my-rbd-snap"* ]]

  # --- VMs clone from snapshot ---
  [[ "$output" == *"smartCloneFromExistingSnapshot"* ]]

  # --- 10 VMs ---
  local vm_count
  vm_count=$(echo "$output" | grep -c "Creating VirtualMachine [0-9]")
  [ "$vm_count" -eq 10 ]
}

# ---------------------------------------------------------------
# QS-8: ./vstorm --no-snapshot --vms=10 --namespaces=2
#   Explicit no-snapshot mode
# ---------------------------------------------------------------
@test "QS: explicit no-snapshot, 10 VMs across 2 namespaces" {
  run bash "$VSTORM" -n --batch-id=qs0008 --datasource=rhel9 --no-snapshot --vms=10 --namespaces=2
  [ "$status" -eq 0 ]

  # --- 2 namespaces ---
  [[ "$output" == *"name: vm-qs0008-ns-1"* ]]
  [[ "$output" == *"name: vm-qs0008-ns-2"* ]]

  # --- Snapshots disabled (DataSource direct clone) ---
  [[ "$output" == *"Snapshot mode: disabled (direct DataSource clone)"* ]]
  [[ "$output" == *"Skipping VolumeSnapshots"* ]]
  [[ "$output" != *"kind: VolumeSnapshot"* ]]

  # --- No base DV, VMs clone directly from DataSource ---
  [[ "$output" == *"Skipping base DataVolume creation"* ]]
  [[ "$output" == *"sourceRef"* ]]
  [[ "$output" == *"kind: DataSource"* ]]
  [[ "$output" != *"smartCloneFromExistingSnapshot"* ]]

  # --- 10 VMs ---
  local vm_count
  vm_count=$(echo "$output" | grep -c "Creating VirtualMachine [0-9]")
  [ "$vm_count" -eq 10 ]

  # --- Default cloud-init auto-applied ---
  [[ "$output" == *"applying default cloud-init"* ]]
  [[ "$output" == *"kind: Secret"* ]]
}

# ---------------------------------------------------------------
# QS-9: ./vstorm -n --vms=10 --namespaces=2
#   Dry-run mode (same as QS-1 but verifying dry-run behavior)
# ---------------------------------------------------------------
@test "QS: dry-run does not emit oc apply commands" {
  run bash "$VSTORM" -n --batch-id=qs0009 --datasource=rhel9 --vms=10 --namespaces=2
  [ "$status" -eq 0 ]

  # --- Outputs YAML ---
  [[ "$output" == *"apiVersion:"* ]]
  [[ "$output" == *"kind: Namespace"* ]]
  [[ "$output" == *"kind: DataVolume"* ]]
  [[ "$output" == *"kind: VolumeSnapshot"* ]]
  [[ "$output" == *"kind: VirtualMachine"* ]]

  # --- Does not print "oc apply" (dry-run skips actual commands) ---
  [[ "$output" != *"oc apply"* ]]

  # --- Does not print completion message (only printed when doit=1) ---
  [[ "$output" != *"Resource creation completed successfully"* ]]

  # --- Dry-run YAML file saved ---
  [[ "$output" == *"Dry-run YAML saved to: logs/qs0009-dryrun.yaml"* ]]

  # cleanup
  rm -f logs/qs0009-dryrun.yaml
}

# ---------------------------------------------------------------
# Dry-run YAML file tests
# ---------------------------------------------------------------
@test "dry-run: saves YAML file with all resources" {
  run bash "$VSTORM" -n --batch-id=dry001 --datasource=rhel9 --vms=3 --namespaces=1
  [ "$status" -eq 0 ]

  # --- File exists ---
  [ -f logs/dry001-dryrun.yaml ]

  # --- File contains all resource types ---
  local content
  content=$(cat logs/dry001-dryrun.yaml)
  [[ "$content" == *"kind: Namespace"* ]]
  [[ "$content" == *"kind: DataVolume"* ]]
  [[ "$content" == *"kind: VolumeSnapshot"* ]]
  [[ "$content" == *"kind: VirtualMachine"* ]]

  # --- File contains document separators ---
  local separator_count
  separator_count=$(grep -c "^---$" logs/dry001-dryrun.yaml)
  [ "$separator_count" -ge 4 ]

  # --- Message printed to stdout ---
  [[ "$output" == *"Dry-run YAML saved to: logs/dry001-dryrun.yaml"* ]]

  # cleanup
  rm -f logs/dry001-dryrun.yaml
}

@test "dry-run: YAML file has correct batch ID and namespaces" {
  run bash "$VSTORM" -n --batch-id=dry002 --datasource=rhel9 --vms=2 --namespaces=2
  [ "$status" -eq 0 ]

  [ -f logs/dry002-dryrun.yaml ]

  local content
  content=$(cat logs/dry002-dryrun.yaml)

  # --- Batch ID substituted ---
  [[ "$content" == *'batch-id: "dry002"'* ]]

  # --- Both namespaces present ---
  [[ "$content" == *"name: vm-dry002-ns-1"* ]]
  [[ "$content" == *"name: vm-dry002-ns-2"* ]]

  # --- VM names ---
  [[ "$content" == *"name: rhel9-dry002-1"* ]]
  [[ "$content" == *"name: rhel9-dry002-2"* ]]

  # cleanup
  rm -f logs/dry002-dryrun.yaml
}

@test "dry-run: no-snapshot mode saves DataSource clone YAML" {
  run bash "$VSTORM" -n --batch-id=dry003 --datasource=rhel9 --no-snapshot --vms=2 --namespaces=1
  [ "$status" -eq 0 ]

  [ -f logs/dry003-dryrun.yaml ]

  local content
  content=$(cat logs/dry003-dryrun.yaml)

  # --- DataSource clone, not PVC clone, not snapshot ---
  [[ "$content" == *"sourceRef"* ]]
  [[ "$content" == *"kind: DataSource"* ]]
  [[ "$content" != *"smartCloneFromExistingSnapshot"* ]]
  [[ "$content" != *"kind: VolumeSnapshot"* ]]
  # --- No standalone DataVolume (only in VM dataVolumeTemplates) ---
  [[ "$content" != *"name: rhel9-base"* ]]

  # cleanup
  rm -f logs/dry003-dryrun.yaml
}

@test "dry-run: quiet mode does not create YAML file" {
  run bash "$VSTORM" -q --batch-id=dry004 --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  # --- No YAML file created ---
  [ ! -f logs/dry004-dryrun.yaml ]

  # --- No "saved to" message ---
  [[ "$output" != *"Dry-run YAML saved to"* ]]
}

# ---------------------------------------------------------------
# QS-10: ./vstorm --delete=a3f7b2
#   Delete batch
# ---------------------------------------------------------------
@test "QS: delete batch dry-run shows correct oc delete command" {
  run bash "$VSTORM" -n --delete=a3f7b2
  [ "$status" -eq 0 ]

  [[ "$output" == *"dry-run"* ]]
  [[ "$output" == *"a3f7b2"* ]]
  [[ "$output" == *"oc delete ns -l batch-id=a3f7b2"* ]]
}

