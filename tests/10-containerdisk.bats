#!/usr/bin/env bats

# Unit tests for vstorm
# Run with: bats tests/

load 'helpers'

VSTORM="./vstorm"

setup_file() {
    setup_oc_mock
}

# ===============================================================
# Category 10: Container Disk Mode (CDISK-1 through CDISK-9)
# ===============================================================

# ---------------------------------------------------------------
# CDISK-1: --containerdisk (default image) produces a VM with
#   a containerDisk volume, no DataVolume or VolumeSnapshot
# ---------------------------------------------------------------
@test "cdisk: default image produces containerDisk VM, no DV or snapshot" {
  run bash "$VSTORM" -n --batch-id=cdk001 --containerdisk --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  # --- correct disk source shown ---
  [[ "$output" == *"Disk source: ContainerDisk quay.io/containerdisks/fedora:latest"* ]]

  # --- no DataVolume or VolumeSnapshot created ---
  [[ "$output" != *"Creating DataVolumes"* ]]
  [[ "$output" != *"Creating VolumeSnapshots"* ]]
  [[ "$output" != *"kind: DataVolume"* ]]
  [[ "$output" != *"kind: VolumeSnapshot"* ]]

  # --- VM uses containerDisk volume ---
  [[ "$output" == *"kind: VirtualMachine"* ]]
  [[ "$output" == *"containerDisk:"* ]]
  [[ "$output" == *"image: quay.io/containerdisks/fedora:latest"* ]]

  # --- storage-related fields show N/A ---
  [[ "$output" == *"Storage Class: N/A (container disk)"* ]]
  [[ "$output" == *"Snapshot mode: N/A (container disk)"* ]]
}

# ---------------------------------------------------------------
# CDISK-2: --containerdisk=IMAGE uses the specified image
# ---------------------------------------------------------------
@test "cdisk: custom image URL is used in VM spec" {
  run bash "$VSTORM" -n --batch-id=cdk002 \
    --containerdisk=quay.io/containerdisks/centos-stream9:latest \
    --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  [[ "$output" == *"image: quay.io/containerdisks/centos-stream9:latest"* ]]
  [[ "$output" == *"Disk source: ContainerDisk quay.io/containerdisks/centos-stream9:latest"* ]]
}

# ---------------------------------------------------------------
# CDISK-3: VM basename is auto-derived from the image name
# ---------------------------------------------------------------
@test "cdisk: basename auto-derived from image name" {
  run bash "$VSTORM" -n --batch-id=cdk003 --containerdisk --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  # basename "fedora" derived from quay.io/containerdisks/fedora:latest
  [[ "$output" == *"VM Basename: fedora"* ]]
  [[ "$output" == *"name: fedora-cdk003-1"* ]]
}

# ---------------------------------------------------------------
# CDISK-4: --basename overrides auto-derived name
# ---------------------------------------------------------------
@test "cdisk: explicit --basename overrides auto-derived image name" {
  run bash "$VSTORM" -n --batch-id=cdk004 --containerdisk --basename=myvm \
    --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  [[ "$output" == *"VM Basename: myvm"* ]]
  [[ "$output" == *"name: myvm-cdk004-1"* ]]
}

# ---------------------------------------------------------------
# CDISK-5: default cloud-init is auto-applied (SSH access)
# ---------------------------------------------------------------
@test "cdisk: default cloud-init is auto-applied" {
  run bash "$VSTORM" -n --batch-id=cdk005 --containerdisk --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  [[ "$output" == *"applying default cloud-init"* ]]
  [[ "$output" == *"kind: Secret"* ]]
  [[ "$output" == *"cloudInitNoCloud:"* ]]
  [[ "$output" == *"secretRef:"* ]]
}

# ---------------------------------------------------------------
# CDISK-6: multiple VMs across multiple namespaces
# ---------------------------------------------------------------
@test "cdisk: multiple VMs across multiple namespaces" {
  run bash "$VSTORM" -n --batch-id=cdk006 --containerdisk --vms=4 --namespaces=2
  [ "$status" -eq 0 ]

  # --- two namespaces created ---
  [[ "$output" == *"name: vm-cdk006-ns-1"* ]]
  [[ "$output" == *"name: vm-cdk006-ns-2"* ]]
  [[ "$output" != *"vm-cdk006-ns-3"* ]]

  # --- 4 VMs total ---
  local vm_count
  vm_count=$(echo "$output" | grep -c "Creating VirtualMachine [0-9]")
  [ "$vm_count" -eq 4 ]

  # --- each VM has containerDisk volume ---
  local cd_count
  cd_count=$(echo "$output" | grep -c "containerDisk:")
  [ "$cd_count" -eq 4 ]
}

# ---------------------------------------------------------------
# CDISK-7: --containerdisk + --cores + --memory are applied
# ---------------------------------------------------------------
@test "cdisk: custom cores and memory applied to VM" {
  run bash "$VSTORM" -n --batch-id=cdk007 --containerdisk \
    --cores=4 --memory=8Gi --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  [[ "$output" == *"cores: 4"* ]]
  [[ "$output" == *"guest: 8Gi"* ]]
}

# ---------------------------------------------------------------
# CDISK-8 (ERR): --containerdisk + --datasource is rejected
# ---------------------------------------------------------------
@test "ERR: --containerdisk + --datasource is rejected" {
  run bash "$VSTORM" -n --batch-id=cdk008 \
    --containerdisk --datasource=rhel9 --vms=1 --namespaces=1
  [ "$status" -ne 0 ]
  [[ "$output" == *"--containerdisk cannot be combined with --datasource or --dv-url"* ]]
}

# ---------------------------------------------------------------
# CDISK-9 (ERR): --containerdisk + --dv-url is rejected
# ---------------------------------------------------------------
@test "ERR: --containerdisk + --dv-url is rejected" {
  run bash "$VSTORM" -n --batch-id=cdk009 \
    --containerdisk --dv-url=http://example.com/disk.qcow2 \
    --vms=1 --namespaces=1
  [ "$status" -ne 0 ]
  [[ "$output" == *"--containerdisk cannot be combined with --datasource or --dv-url"* ]]
}
