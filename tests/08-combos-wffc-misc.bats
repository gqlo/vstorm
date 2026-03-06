#!/usr/bin/env bats

# Unit tests for vstorm
# Run with: bats tests/

load 'helpers'

VSTORM="./vstorm"

setup_file() {
    setup_oc_mock
}

# ===============================================================
# Category 8: WFFC x Other Options (combos 43-46, mock oc)
# ===============================================================

# ---------------------------------------------------------------
# COMBO-43: WFFC + --cloudinit + --no-snapshot
# ---------------------------------------------------------------
@test "combo-wffc: cloudinit + no-snapshot with WFFC storage" {
  local mock_dir
  mock_dir=$(mktemp -d)
  _create_mock_oc "$mock_dir"

  export MOCK_ACCESS_MODE=ReadWriteOnce
  export MOCK_BIND_MODE=WaitForFirstConsumer
  export PATH="$mock_dir:$PATH"

  run bash "$VSTORM" -n --batch-id=cmb043 --datasource=rhel9 --storage-class=lvms-nvme-sc \
    --no-snapshot --cloudinit=workload/cloudinit-stress-ng-workload.yaml \
    --vms=2 --namespaces=1

  rm -rf "$mock_dir"
  rm -f logs/cmb043-dryrun.yaml

  [ "$status" -eq 0 ]
  [[ "$output" == *"WaitForFirstConsumer"* ]]
  [[ "$output" == *"Skipping base DataVolume creation"* ]]

  # --- Cloud-init Secret still created ---
  [[ "$output" == *"Creating cloud-init Secret"* ]]
}

# ---------------------------------------------------------------
# COMBO-44: WFFC + --dv-url (auto-detected RWO)
# Note: explicit --rwo would skip detect_access_mode() entirely,
#       bypassing WFFC detection. So we let the mock auto-detect.
# ---------------------------------------------------------------
@test "combo-wffc: dv-url with WFFC storage (auto-detected RWO)" {
  local mock_dir
  mock_dir=$(mktemp -d)
  _create_mock_oc "$mock_dir"

  export MOCK_ACCESS_MODE=ReadWriteOnce
  export MOCK_BIND_MODE=WaitForFirstConsumer
  export PATH="$mock_dir:$PATH"

  run bash "$VSTORM" -n --batch-id=cmb044 --storage-class=lvms-nvme-sc \
    --no-snapshot --dv-url=http://example.com/disk.qcow2 \
    --vms=1 --namespaces=1

  rm -rf "$mock_dir"
  rm -f logs/cmb044-dryrun.yaml

  [ "$status" -eq 0 ]
  [[ "$output" == *"WaitForFirstConsumer"* ]]
  [[ "$output" == *"Auto-detected access mode 'ReadWriteOnce'"* ]]
}

# ---------------------------------------------------------------
# COMBO-45: WFFC + --vms-per-namespace + --namespaces
# ---------------------------------------------------------------
@test "combo-wffc: vms-per-namespace + namespaces with WFFC storage" {
  local mock_dir
  mock_dir=$(mktemp -d)
  _create_mock_oc "$mock_dir"

  export MOCK_ACCESS_MODE=ReadWriteOnce
  export MOCK_BIND_MODE=WaitForFirstConsumer
  export PATH="$mock_dir:$PATH"

  run bash "$VSTORM" -n --batch-id=cmb045 --datasource=rhel9 --storage-class=lvms-nvme-sc \
    --no-snapshot --vms-per-namespace=3 --namespaces=2

  rm -rf "$mock_dir"
  rm -f logs/cmb045-dryrun.yaml

  [ "$status" -eq 0 ]
  [[ "$output" == *"WaitForFirstConsumer"* ]]
  [[ "$output" == *"Skipping base DataVolume creation"* ]]

  # --- 6 VMs total ---
  [[ "$output" == *"Total VMs: 6"* ]]
}

# ---------------------------------------------------------------
# COMBO-46: WFFC + --snapshot + --cloudinit (auto-disables snapshot)
# ---------------------------------------------------------------
@test "combo-wffc: snapshot + cloudinit — WFFC auto-disables snapshot" {
  local mock_dir
  mock_dir=$(mktemp -d)
  _create_mock_oc "$mock_dir"

  export MOCK_ACCESS_MODE=ReadWriteOnce
  export MOCK_BIND_MODE=WaitForFirstConsumer
  export PATH="$mock_dir:$PATH"

  run bash "$VSTORM" -n --batch-id=cmb046 --datasource=rhel9 --storage-class=lvms-nvme-sc \
    --snapshot --cloudinit=workload/cloudinit-stress-ng-workload.yaml \
    --vms=2 --namespaces=1

  rm -rf "$mock_dir"
  rm -f logs/cmb046-dryrun.yaml

  [ "$status" -eq 0 ]

  # --- Snapshot auto-disabled ---
  [[ "$output" == *"Disabling snapshot mode"* ]]
  [[ "$output" == *"Falling back to direct DataSource clone"* ]]

  # --- Cloud-init still works ---
  [[ "$output" == *"Creating cloud-init Secret"* ]]
}

# ===============================================================
# Category 9: Dry-run / Quiet x Clone Path (combos 47-49)
# ===============================================================

# ---------------------------------------------------------------
# COMBO-47: -q + --no-snapshot
# ---------------------------------------------------------------
@test "combo: quiet mode + no-snapshot DataSource clone" {
  run bash "$VSTORM" -q --batch-id=cmb047 --datasource=rhel9 --no-snapshot --vms=3 --namespaces=1
  [ "$status" -eq 0 ]

  # --- Quiet mode: no YAML output ---
  [[ "$output" != *"apiVersion:"* ]]
  [[ "$output" != *"kind: VirtualMachine"* ]]

  # --- Log messages still appear ---
  [[ "$output" == *"Skipping base DataVolume creation"* ]]
  [[ "$output" == *"Skipping VolumeSnapshots"* ]]

  # --- No YAML file created ---
  [ ! -f logs/cmb047-dryrun.yaml ]
}

# ---------------------------------------------------------------
# COMBO-48: -q + --dv-url
# ---------------------------------------------------------------
@test "combo: quiet mode + dv-url URL import" {
  run bash "$VSTORM" -q --batch-id=cmb048 \
    --dv-url=http://example.com/disk.qcow2 --vms=2 --namespaces=1
  [ "$status" -eq 0 ]

  # --- Quiet mode: no YAML output ---
  [[ "$output" != *"apiVersion:"* ]]
  [[ "$output" != *"kind: VirtualMachine"* ]]

  # --- Log messages still appear ---
  [[ "$output" == *"Creating DataVolumes"* ]]
  [[ "$output" == *"Creating VirtualMachines"* ]]

  # --- No YAML file ---
  [ ! -f logs/cmb048-dryrun.yaml ]
}

# ---------------------------------------------------------------
# COMBO-49: -q + --delete
# ---------------------------------------------------------------
@test "combo: quiet mode + delete" {
  run bash "$VSTORM" -q --delete=abc123
  [ "$status" -eq 0 ]

  # --- Delete dry-run still shows info ---
  [[ "$output" == *"dry-run"* ]]
  [[ "$output" == *"abc123"* ]]
}

