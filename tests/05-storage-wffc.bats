#!/usr/bin/env bats

# Unit tests for vstorm
# Run with: bats tests/

load 'helpers'

VSTORM="./vstorm"

setup_file() {
    setup_oc_mock
}

# ---------------------------------------------------------------
# SP-1: StorageProfile returns RWO (e.g. LVMS)
# ---------------------------------------------------------------
@test "auto-detect: StorageProfile returns RWO for LVMS-like storage" {
  local mock_dir
  mock_dir=$(mktemp -d)
  _create_mock_oc "$mock_dir"

  export MOCK_ACCESS_MODE=ReadWriteOnce
  export PATH="$mock_dir:$PATH"

  run bash "$VSTORM" -n --batch-id=sp0001 --datasource=rhel9 --storage-class=lvms-nvme-sc \
    --no-snapshot --vms=1 --namespaces=1

  rm -rf "$mock_dir"
  rm -f logs/sp0001-dryrun.yaml

  [ "$status" -eq 0 ]
  [[ "$output" == *"Auto-detected access mode 'ReadWriteOnce' from StorageProfile for 'lvms-nvme-sc'"* ]]
  [[ "$output" == *"Access Mode: ReadWriteOnce"* ]]
}

# ---------------------------------------------------------------
# SP-2: StorageProfile returns RWX (e.g. OCS/Ceph)
# ---------------------------------------------------------------
@test "auto-detect: StorageProfile returns RWX for OCS-like storage" {
  local mock_dir
  mock_dir=$(mktemp -d)
  _create_mock_oc "$mock_dir"

  export MOCK_ACCESS_MODE=ReadWriteMany
  export PATH="$mock_dir:$PATH"

  run bash "$VSTORM" -n --batch-id=sp0002 --datasource=rhel9 --storage-class=ocs-rbd-virt \
    --no-snapshot --vms=1 --namespaces=1

  rm -rf "$mock_dir"
  rm -f logs/sp0002-dryrun.yaml

  [ "$status" -eq 0 ]
  [[ "$output" == *"Auto-detected access mode 'ReadWriteMany' from StorageProfile for 'ocs-rbd-virt'"* ]]
  [[ "$output" == *"Access Mode: ReadWriteMany"* ]]
}

# ---------------------------------------------------------------
# SP-3: StorageProfile unavailable → falls back to default RWX
# ---------------------------------------------------------------
@test "auto-detect: StorageProfile unavailable falls back to default RWX" {
  local mock_dir
  mock_dir=$(mktemp -d)
  _create_mock_oc "$mock_dir"

  # Do NOT export MOCK_ACCESS_MODE → mock exits 1 for storageprofile
  unset MOCK_ACCESS_MODE
  export PATH="$mock_dir:$PATH"

  run bash "$VSTORM" -n --batch-id=sp0003 --datasource=rhel9 --storage-class=unknown-sc \
    --no-snapshot --vms=1 --namespaces=1

  rm -rf "$mock_dir"
  rm -f logs/sp0003-dryrun.yaml

  [ "$status" -eq 0 ]
  [[ "$output" == *"Could not detect access mode from StorageProfile"* ]]
  [[ "$output" == *"using default: ReadWriteMany"* ]]
  [[ "$output" == *"Access Mode: ReadWriteMany"* ]]
}

# ---------------------------------------------------------------
# SP-4: explicit --access-mode=ReadWriteOnce overrides StorageProfile that says RWX
# ---------------------------------------------------------------
@test "auto-detect: explicit --access-mode=ReadWriteOnce overrides StorageProfile RWX" {
  local mock_dir
  mock_dir=$(mktemp -d)
  _create_mock_oc "$mock_dir"

  export MOCK_ACCESS_MODE=ReadWriteMany
  export PATH="$mock_dir:$PATH"

  run bash "$VSTORM" -n --batch-id=sp0004 --datasource=rhel9 --access-mode=ReadWriteOnce --storage-class=ocs-rbd-virt \
    --no-snapshot --vms=1 --namespaces=1

  rm -rf "$mock_dir"
  rm -f logs/sp0004-dryrun.yaml

  [ "$status" -eq 0 ]
  [[ "$output" == *"Access mode explicitly set to: ReadWriteOnce"* ]]
  [[ "$output" == *"Access Mode: ReadWriteOnce"* ]]
  [[ "$output" != *"Auto-detected"* ]]
}

# ---------------------------------------------------------------
# SP-5: explicit --access-mode=ReadWriteMany overrides StorageProfile that says RWO
# ---------------------------------------------------------------
@test "auto-detect: explicit --access-mode=ReadWriteMany overrides StorageProfile RWO" {
  local mock_dir
  mock_dir=$(mktemp -d)
  _create_mock_oc "$mock_dir"

  export MOCK_ACCESS_MODE=ReadWriteOnce
  export PATH="$mock_dir:$PATH"

  run bash "$VSTORM" -n --batch-id=sp0005 --datasource=rhel9 --access-mode=ReadWriteMany --storage-class=lvms-nvme-sc \
    --no-snapshot --vms=1 --namespaces=1

  rm -rf "$mock_dir"
  rm -f logs/sp0005-dryrun.yaml

  [ "$status" -eq 0 ]
  [[ "$output" == *"Access mode explicitly set to: ReadWriteMany"* ]]
  [[ "$output" == *"Access Mode: ReadWriteMany"* ]]
  [[ "$output" != *"Auto-detected"* ]]
}

# ===============================================================
# WaitForFirstConsumer handling
# ===============================================================

# ---------------------------------------------------------------
# WFFC-1: WFFC + DataSource + no-snapshot → no base DV at all
# ---------------------------------------------------------------
@test "wffc: DataSource no-snapshot skips base DV entirely for WFFC" {
  local mock_dir
  mock_dir=$(mktemp -d)
  _create_mock_oc "$mock_dir"

  export MOCK_ACCESS_MODE=ReadWriteOnce
  export MOCK_BIND_MODE=WaitForFirstConsumer
  export PATH="$mock_dir:$PATH"

  run bash "$VSTORM" -n --batch-id=wf0001 --datasource=rhel9 --storage-class=lvms-nvme-sc \
    --no-snapshot --vms=2 --namespaces=1

  rm -rf "$mock_dir"
  rm -f logs/wf0001-dryrun.yaml

  [ "$status" -eq 0 ]
  [[ "$output" == *"WaitForFirstConsumer"* ]]
  [[ "$output" == *"Skipping base DataVolume creation"* ]]
  [[ "$output" == *"Creating VirtualMachines"* ]]
}

# ---------------------------------------------------------------
# WFFC-2: WFFC + URL import → skip DV wait, proceed to VM creation
# ---------------------------------------------------------------
@test "wffc: skips DataVolume wait for WaitForFirstConsumer with URL import" {
  local mock_dir
  mock_dir=$(mktemp -d)
  _create_mock_oc "$mock_dir"

  export MOCK_ACCESS_MODE=ReadWriteOnce
  export MOCK_BIND_MODE=WaitForFirstConsumer
  export PATH="$mock_dir:$PATH"

  run bash "$VSTORM" -n --batch-id=wf0002 --datasource=rhel9 --storage-class=lvms-nvme-sc \
    --no-snapshot --vms=2 --namespaces=1 \
    --dv-url=http://example.com/disk.qcow2

  rm -rf "$mock_dir"
  rm -f logs/wf0002-dryrun.yaml

  [ "$status" -eq 0 ]
  [[ "$output" == *"WaitForFirstConsumer"* ]]
  [[ "$output" == *"Auto-detected access mode 'ReadWriteOnce'"* ]]
  [[ "$output" == *"Creating VirtualMachines"* ]]
}

# ---------------------------------------------------------------
# WFFC-3: Immediate binding + URL import → normal DV wait (no skip)
# ---------------------------------------------------------------
@test "wffc: normal DV wait for Immediate binding with URL import" {
  local mock_dir
  mock_dir=$(mktemp -d)
  _create_mock_oc "$mock_dir"

  export MOCK_ACCESS_MODE=ReadWriteOnce
  export MOCK_BIND_MODE=Immediate
  export PATH="$mock_dir:$PATH"

  run bash "$VSTORM" -n --batch-id=wf0003 --datasource=rhel9 --storage-class=lvms-nvme-sc-imm \
    --no-snapshot --vms=1 --namespaces=1 \
    --dv-url=http://example.com/disk.qcow2

  rm -rf "$mock_dir"
  rm -f logs/wf0003-dryrun.yaml

  [ "$status" -eq 0 ]
  [[ "$output" != *"WaitForFirstConsumer"* ]]
  [[ "$output" == *"Creating VirtualMachines"* ]]
}

# ---------------------------------------------------------------
# WFFC-4: WFFC + explicit --snapshot-class → auto-disables snapshots
# ---------------------------------------------------------------
@test "wffc: snapshot mode auto-disabled for WFFC storage" {
  local mock_dir
  mock_dir=$(mktemp -d)
  _create_mock_oc "$mock_dir"

  export MOCK_ACCESS_MODE=ReadWriteOnce
  export MOCK_BIND_MODE=WaitForFirstConsumer
  export PATH="$mock_dir:$PATH"

  run bash "$VSTORM" -n --batch-id=wf0004 --datasource=rhel9 --storage-class=lvms-nvme-sc \
    --snapshot-class=my-snap --vms=2 --namespaces=1

  rm -rf "$mock_dir"
  rm -f logs/wf0004-dryrun.yaml

  [ "$status" -eq 0 ]
  # Snapshot mode was auto-disabled
  [[ "$output" == *"Disabling snapshot mode"* ]]
  [[ "$output" == *"WFFC storage won't bind"* ]]
  [[ "$output" == *"Falling back to direct DataSource clone"* ]]
  # No VolumeSnapshot created
  [[ "$output" != *"Creating VolumeSnapshots"* ]]
  # Direct DataSource clone used instead
  [[ "$output" == *"Skipping base DataVolume creation"* ]]
  [[ "$output" == *"Creating VirtualMachines"* ]]
}

# ---------------------------------------------------------------
# WFFC-5: WFFC detection works in dry-run
# ---------------------------------------------------------------
@test "wffc: dry-run shows WFFC warning with mock oc" {
  local mock_dir
  mock_dir=$(mktemp -d)
  _create_mock_oc "$mock_dir"

  export MOCK_ACCESS_MODE=ReadWriteOnce
  export MOCK_BIND_MODE=WaitForFirstConsumer
  export PATH="$mock_dir:$PATH"

  run bash "$VSTORM" -n --batch-id=wf0005 --datasource=rhel9 --storage-class=lvms-nvme-sc \
    --no-snapshot --vms=1 --namespaces=1

  rm -rf "$mock_dir"
  rm -f logs/wf0005-dryrun.yaml

  [ "$status" -eq 0 ]
  [[ "$output" == *"WaitForFirstConsumer"* ]]
  [[ "$output" == *"Access Mode: ReadWriteOnce"* ]]
}

# ===============================================================
# Missing option coverage
# ===============================================================

# ---------------------------------------------------------------
# OPT-1: --pvc-base-name sets the VolumeSnapshot PVC source name
# ---------------------------------------------------------------
@test "option: --pvc-base-name changes VolumeSnapshot PVC source" {
  run bash "$VSTORM" -n --batch-id=opt001 --datasource=rhel9 --pvc-base-name=custom-base \
    --snapshot-class=ocs-storagecluster-rbdplugin-snapclass --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  # --- VolumeSnapshot references the custom PVC name ---
  [[ "$output" == *"persistentVolumeClaimName: custom-base"* ]]

  # --- Default name should not appear ---
  [[ "$output" != *"persistentVolumeClaimName: rhel9-base"* ]]
}

# ---------------------------------------------------------------
# OPT-2: --request-cpu sets CPU request in VM spec
# ---------------------------------------------------------------
@test "option: --request-cpu adds CPU request to VM spec" {
  run bash "$VSTORM" -n --batch-id=opt002 --datasource=rhel9 --request-cpu=500m --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  # --- resources.requests.cpu appears in VM spec ---
  [[ "$output" == *"resources:"* ]]
  [[ "$output" == *"requests:"* ]]
  [[ "$output" == *"cpu: 500m"* ]]
}

# ---------------------------------------------------------------
# OPT-3: --request-memory sets memory request in VM spec
# ---------------------------------------------------------------
@test "option: --request-memory adds memory request to VM spec" {
  run bash "$VSTORM" -n --batch-id=opt003 --datasource=rhel9 --request-memory=512Mi --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  # --- resources.requests.memory appears in VM spec ---
  [[ "$output" == *"resources:"* ]]
  [[ "$output" == *"requests:"* ]]
  [[ "$output" == *"memory: 512Mi"* ]]
}

# ---------------------------------------------------------------
# OPT-4: --request-cpu and --request-memory together
# ---------------------------------------------------------------
@test "option: --request-cpu and --request-memory together" {
  run bash "$VSTORM" -n --batch-id=opt004 --datasource=rhel9 --request-cpu=2 --request-memory=4Gi \
    --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  # --- Both CPU and memory requests present ---
  [[ "$output" == *"resources:"* ]]
  [[ "$output" == *"requests:"* ]]
  [[ "$output" == *"cpu: 2"* ]]
  [[ "$output" == *"memory: 4Gi"* ]]
}

# ---------------------------------------------------------------
# OPT-5: --vms-per-namespace calculates total VMs correctly
# ---------------------------------------------------------------
@test "option: --vms-per-namespace calculates total VMs" {
  run bash "$VSTORM" -n --batch-id=opt005 --datasource=rhel9 --vms-per-namespace=3 --namespaces=2
  [ "$status" -eq 0 ]

  # --- Total VMs = 3 * 2 = 6 ---
  [[ "$output" == *"Total VMs: 6"* ]]

  local vm_count
  vm_count=$(echo "$output" | grep -c "Creating VirtualMachine [0-9]")
  [ "$vm_count" -eq 6 ]

  # --- 3 per namespace ---
  local ns1_count ns2_count
  ns1_count=$(echo "$output" | grep -c "Creating VirtualMachine.*for namespace: vm-opt005-ns-1")
  ns2_count=$(echo "$output" | grep -c "Creating VirtualMachine.*for namespace: vm-opt005-ns-2")
  [ "$ns1_count" -eq 3 ]
  [ "$ns2_count" -eq 3 ]
}

# ---------------------------------------------------------------
# OPT-6: --run-strategy sets custom run strategy
# ---------------------------------------------------------------
@test "option: --run-strategy sets custom run strategy" {
  run bash "$VSTORM" -n --batch-id=opt006 --datasource=rhel9 --run-strategy=RerunOnFailure \
    --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  [[ "$output" == *"runStrategy: RerunOnFailure"* ]]
}

# ---------------------------------------------------------------
# OPT-7: --run-strategy=Always sets runStrategy to Always
# ---------------------------------------------------------------
@test "option: --run-strategy=Always sets runStrategy to Always" {
  run bash "$VSTORM" -n --batch-id=opt007 --datasource=rhel9 --run-strategy=Always --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  [[ "$output" == *"runStrategy: Always"* ]]
}

# ---------------------------------------------------------------
# OPT-8: --wait is accepted (dry-run does not actually wait)
# ---------------------------------------------------------------
@test "option: --wait is accepted without error" {
  run bash "$VSTORM" -n --batch-id=opt008 --datasource=rhel9 --wait --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  # --- Dry-run succeeds; --wait doesn't affect YAML output ---
  [[ "$output" == *"kind: VirtualMachine"* ]]
}

# ---------------------------------------------------------------
# OPT-9: --wait=false is accepted (dry-run does not wait by default)
# ---------------------------------------------------------------
@test "option: --wait=false is accepted without error" {
  run bash "$VSTORM" -n --batch-id=opt009 --datasource=rhel9 --wait=false --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  [[ "$output" == *"kind: VirtualMachine"* ]]
}

# ---------------------------------------------------------------
# OPT-10: --create-existing-vm is accepted
# ---------------------------------------------------------------
@test "option: --create-existing-vm is accepted without error" {
  run bash "$VSTORM" -n --batch-id=opt010 --datasource=rhel9 --create-existing-vm --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  [[ "$output" == *"kind: VirtualMachine"* ]]
}

# ---------------------------------------------------------------
# OPT-12: -h shows usage/help text
# ---------------------------------------------------------------
@test "option: -h displays help text" {
  run bash "$VSTORM" -h
  [ "$status" -eq 0 ]

  [[ "$output" == *"Usage:"* ]]
  [[ "$output" == *"options:"* ]]
  [[ "$output" == *"--vms=N"* ]]
  [[ "$output" == *"--namespaces=N"* ]]
}

# ---------------------------------------------------------------
# OPT-13: positional arguments set VMs and namespaces
# ---------------------------------------------------------------
@test "option: positional arguments set VMs and namespaces" {
  run bash "$VSTORM" -n --batch-id=opt013 --datasource=rhel9 8 3
  [ "$status" -eq 0 ]

  # --- 8 VMs across 3 namespaces ---
  [[ "$output" == *"Total VMs: 8"* ]]
  [[ "$output" == *"Namespaces: 3"* ]]

  local vm_count
  vm_count=$(echo "$output" | grep -c "Creating VirtualMachine [0-9]")
  [ "$vm_count" -eq 8 ]

  # --- 3 namespaces created ---
  [[ "$output" == *"name: vm-opt013-ns-1"* ]]
  [[ "$output" == *"name: vm-opt013-ns-2"* ]]
  [[ "$output" == *"name: vm-opt013-ns-3"* ]]
  [[ "$output" != *"vm-opt013-ns-4"* ]]
}

