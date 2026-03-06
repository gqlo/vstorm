#!/usr/bin/env bats

# Unit tests for vstorm
# Run with: bats tests/

load 'helpers'

VSTORM="./vstorm"

setup_file() {
    setup_oc_mock
}

# ===============================================================
# Category 5: Scale x Clone Path (combos 25-29)
# ===============================================================

# ---------------------------------------------------------------
# COMBO-25: --vms-per-namespace + --namespaces + --no-snapshot
# ---------------------------------------------------------------
@test "combo: vms-per-namespace + namespaces + no-snapshot DataSource clone" {
  run bash "$VSTORM" -n --batch-id=cmb025 --datasource=rhel9 --vms-per-namespace=3 --namespaces=2 \
    --no-snapshot
  [ "$status" -eq 0 ]

  # --- Total VMs = 3 * 2 = 6 ---
  [[ "$output" == *"Total VMs: 6"* ]]

  local vm_count
  vm_count=$(echo "$output" | grep -c "Creating VirtualMachine [0-9]")
  [ "$vm_count" -eq 6 ]

  # --- DataSource direct clone ---
  [[ "$output" == *"Skipping base DataVolume creation"* ]]
  [[ "$output" == *"sourceRef"* ]]

  # --- 2 namespaces ---
  [[ "$output" == *"name: vm-cmb025-ns-1"* ]]
  [[ "$output" == *"name: vm-cmb025-ns-2"* ]]
}

# ---------------------------------------------------------------
# COMBO-26: --vms-per-namespace + --namespaces + --snapshot
# ---------------------------------------------------------------
@test "combo: vms-per-namespace + namespaces + snapshot" {
  run bash "$VSTORM" -n --batch-id=cmb026 --datasource=rhel9 --vms-per-namespace=3 --namespaces=2 \
    --snapshot
  [ "$status" -eq 0 ]

  # --- Total VMs = 3 * 2 = 6 ---
  [[ "$output" == *"Total VMs: 6"* ]]

  local vm_count
  vm_count=$(echo "$output" | grep -c "Creating VirtualMachine [0-9]")
  [ "$vm_count" -eq 6 ]

  # --- Snapshot flow ---
  [[ "$output" == *"Snapshot mode: enabled"* ]]
  [[ "$output" == *"kind: VolumeSnapshot"* ]]
  [[ "$output" == *"smartCloneFromExistingSnapshot"* ]]

  # --- 2 VolumeSnapshots (one per namespace) ---
  local snap_count
  snap_count=$(echo "$output" | grep -c "kind: VolumeSnapshot")
  [ "$snap_count" -eq 2 ]
}

# ---------------------------------------------------------------
# COMBO-27: --vms-per-namespace + --namespaces + --cloudinit
# ---------------------------------------------------------------
@test "combo: vms-per-namespace + namespaces + cloudinit (Secret per ns)" {
  run bash "$VSTORM" -n --batch-id=cmb027 --datasource=rhel9 --vms-per-namespace=4 --namespaces=3 \
    --cloudinit=workload/cloudinit-stress-ng-workload.yaml
  [ "$status" -eq 0 ]

  # --- Total VMs = 4 * 3 = 12 ---
  [[ "$output" == *"Total VMs: 12"* ]]

  local vm_count
  vm_count=$(echo "$output" | grep -c "Creating VirtualMachine [0-9]")
  [ "$vm_count" -eq 12 ]

  # --- 3 cloud-init Secrets (one per namespace) ---
  local secret_count
  secret_count=$(echo "$output" | grep -c "kind: Secret")
  [ "$secret_count" -eq 3 ]
}

# ---------------------------------------------------------------
# COMBO-28: positional 7 3 + --no-snapshot + --cloudinit
# ---------------------------------------------------------------
@test "combo: positional args + no-snapshot + cloudinit" {
  run bash "$VSTORM" -n --batch-id=cmb028 --datasource=rhel9 --no-snapshot \
    --cloudinit=workload/cloudinit-stress-ng-workload.yaml 7 3
  [ "$status" -eq 0 ]

  # --- 7 VMs across 3 namespaces ---
  [[ "$output" == *"Total VMs: 7"* ]]
  [[ "$output" == *"Namespaces: 3"* ]]

  local vm_count
  vm_count=$(echo "$output" | grep -c "Creating VirtualMachine [0-9]")
  [ "$vm_count" -eq 7 ]

  # --- DataSource clone ---
  [[ "$output" == *"Skipping base DataVolume creation"* ]]

  # --- 3 Secrets ---
  local secret_count
  secret_count=$(echo "$output" | grep -c "kind: Secret")
  [ "$secret_count" -eq 3 ]
}

# ---------------------------------------------------------------
# COMBO-29: positional 5 2 + --cores + --memory
# ---------------------------------------------------------------
@test "combo: positional args + cores + memory" {
  run bash "$VSTORM" -n --batch-id=cmb029 --datasource=rhel9 --cores=4 --memory=8Gi 5 2
  [ "$status" -eq 0 ]

  # --- 5 VMs across 2 namespaces ---
  [[ "$output" == *"Total VMs: 5"* ]]
  [[ "$output" == *"Namespaces: 2"* ]]

  local vm_count
  vm_count=$(echo "$output" | grep -c "Creating VirtualMachine [0-9]")
  [ "$vm_count" -eq 5 ]

  # --- Custom CPU/memory ---
  [[ "$output" == *"cores: 4"* ]]
  [[ "$output" == *"guest: 8Gi"* ]]
}

# ===============================================================
# Category 6: Naming x Clone Path (combos 30-34)
# ===============================================================

# ---------------------------------------------------------------
# COMBO-30: --basename + --pvc-base-name + --snapshot
# ---------------------------------------------------------------
@test "combo: basename + pvc-base-name + snapshot (both naming options)" {
  run bash "$VSTORM" -n --batch-id=cmb030 --datasource=rhel9 --basename=myvm \
    --pvc-base-name=myvm-base --snapshot --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  # --- VM name uses basename ---
  [[ "$output" == *"name: myvm-cmb030-1"* ]]

  # --- VolumeSnapshot references pvc-base-name ---
  [[ "$output" == *"persistentVolumeClaimName: myvm-base"* ]]

  # --- DV base name uses VM_BASENAME pattern ---
  [[ "$output" == *"name: myvm-base"* ]]

  # --- Labels use basename ---
  [[ "$output" == *'vm-basename: "myvm"'* ]]
}

# ---------------------------------------------------------------
# COMBO-31: --basename=myvm + --snapshot (default pvc-base-name)
# ---------------------------------------------------------------
@test "combo: basename + snapshot with default pvc-base-name" {
  run bash "$VSTORM" -n --batch-id=cmb031 --datasource=rhel9 --basename=myvm --snapshot \
    --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  # --- VM name uses custom basename ---
  [[ "$output" == *"name: myvm-cmb031-1"* ]]

  # --- VolumeSnapshot PVC references the auto-derived pvc-base-name (myvm-base) ---
  [[ "$output" == *"persistentVolumeClaimName: myvm-base"* ]]

  # --- DV base name also uses VM_BASENAME ---
  # The DV is named {VM_BASENAME}-base = myvm-base
  [[ "$output" == *"name: myvm-base"* ]]

  # --- Labels ---
  [[ "$output" == *'vm-basename: "myvm"'* ]]
}

# ---------------------------------------------------------------
# COMBO-32: --datasource=fedora + --basename=custom-vm + --no-snapshot
# ---------------------------------------------------------------
@test "combo: datasource + different basename + no-snapshot" {
  run bash "$VSTORM" -n --batch-id=cmb032 --datasource=fedora \
    --basename=custom-vm --no-snapshot --vms=2 --namespaces=1
  [ "$status" -eq 0 ]

  # --- Uses fedora DataSource ---
  [[ "$output" == *"name: fedora"* ]]
  [[ "$output" == *"kind: DataSource"* ]]

  # --- VM uses custom basename ---
  [[ "$output" == *"name: custom-vm-cmb032-1"* ]]
  [[ "$output" == *"name: custom-vm-cmb032-2"* ]]

  # --- Labels use custom basename ---
  [[ "$output" == *'vm-basename: "custom-vm"'* ]]
}

# ---------------------------------------------------------------
# COMBO-33: --basename=myvm + --no-snapshot + --namespaces=2
# ---------------------------------------------------------------
@test "combo: basename + no-snapshot + multiple namespaces" {
  run bash "$VSTORM" -n --batch-id=cmb033 --datasource=rhel9 --basename=myvm --no-snapshot \
    --vms=4 --namespaces=2
  [ "$status" -eq 0 ]

  # --- VM names use custom basename ---
  [[ "$output" == *"name: myvm-cmb033-1"* ]]
  [[ "$output" == *"name: myvm-cmb033-2"* ]]
  [[ "$output" == *"name: myvm-cmb033-3"* ]]
  [[ "$output" == *"name: myvm-cmb033-4"* ]]

  # --- 2 namespaces ---
  [[ "$output" == *"name: vm-cmb033-ns-1"* ]]
  [[ "$output" == *"name: vm-cmb033-ns-2"* ]]

  # --- DataSource clone ---
  [[ "$output" == *"Skipping base DataVolume creation"* ]]
}

# ---------------------------------------------------------------
# COMBO-34: --basename=myvm + --dv-url + --no-snapshot
# ---------------------------------------------------------------
@test "combo: basename + dv-url + no-snapshot" {
  run bash "$VSTORM" -n --batch-id=cmb034 --datasource=rhel9 --basename=myvm \
    --dv-url=http://example.com/disk.qcow2 --no-snapshot \
    --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  # --- VM name uses custom basename ---
  [[ "$output" == *"name: myvm-cmb034-1"* ]]

  # --- Base DV uses custom basename ---
  [[ "$output" == *"name: myvm-base"* ]]

  # --- URL import ---
  [[ "$output" == *"http://example.com/disk.qcow2"* ]]

  # --- PVC clone ---
  [[ "$output" == *"pvc:"* ]]
}

# ---------------------------------------------------------------
# COMBO-34a: --basename=myvm + --dv-url + --snapshot
#   The exact bug scenario: BASE_PVC_NAME must be derived from
#   VM_BASENAME even when DATASOURCE is empty (--dv-url).
# ---------------------------------------------------------------
@test "combo: basename + dv-url + snapshot" {
  run bash "$VSTORM" -n --batch-id=cmb034a --datasource=rhel9 --basename=myvm \
    --dv-url=http://example.com/disk.qcow2 --snapshot \
    --vms=2 --namespaces=1
  [ "$status" -eq 0 ]

  # --- VolumeSnapshot references auto-derived PVC name (myvm-base) ---
  [[ "$output" == *"persistentVolumeClaimName: myvm-base"* ]]

  # --- VM snapshot source points to the per-namespace snapshot ---
  [[ "$output" == *"name: myvm-vm-cmb034a-ns-1"* ]]

  # --- Base DV is named myvm-base ---
  [[ "$output" == *"name: myvm-base"* ]]

  # --- The old broken default must NOT appear ---
  [[ "$output" != *"persistentVolumeClaimName: vm-base"* ]]

  # --- URL import ---
  [[ "$output" == *"http://example.com/disk.qcow2"* ]]

  # --- Two VMs ---
  [[ "$output" == *"name: myvm-cmb034a-1"* ]]
  [[ "$output" == *"name: myvm-cmb034a-2"* ]]
}

# ---------------------------------------------------------------
# COMBO-34b: --dv-url + --snapshot (default basename=vm)
#   Verifies the default VM_BASENAME=vm still produces a matching
#   BASE_PVC_NAME=vm-base.
# ---------------------------------------------------------------
@test "combo: dv-url + snapshot with default basename" {
  run bash "$VSTORM" -n --batch-id=cmb034b --datasource=rhel9 \
    --dv-url=http://example.com/disk.qcow2 --snapshot \
    --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  # --- VolumeSnapshot references vm-base (default) ---
  [[ "$output" == *"persistentVolumeClaimName: vm-base"* ]]

  # --- Base DV named vm-base ---
  [[ "$output" == *"name: vm-base"* ]]

  # --- VM uses snapshot clone path ---
  [[ "$output" == *"snapshot:"* ]]
  [[ "$output" == *"name: vm-vm-cmb034b-ns-1"* ]]
}

# ---------------------------------------------------------------
# COMBO-34c: --basename=myvm + --dv-url + --snapshot + 2 namespaces
#   Per-namespace consistency: each ns gets its own DV, snapshot,
#   and VMs, all using the custom basename.
# ---------------------------------------------------------------
@test "combo: basename + dv-url + snapshot + multiple namespaces" {
  run bash "$VSTORM" -n --batch-id=cmb034c --datasource=rhel9 --basename=myvm \
    --dv-url=http://example.com/disk.qcow2 --snapshot \
    --vms=4 --namespaces=2
  [ "$status" -eq 0 ]

  # --- VolumeSnapshot in each ns references myvm-base ---
  [[ "$output" == *"persistentVolumeClaimName: myvm-base"* ]]

  # --- 2 base DataVolumes ---
  local dv_count
  dv_count=$(echo "$output" | grep -c "kind: DataVolume")
  # 2 base DVs + 4 inline DataVolumeTemplates = but we just check base DVs
  # appear in both namespaces
  [[ "$output" == *"namespace: vm-cmb034c-ns-1"* ]]
  [[ "$output" == *"namespace: vm-cmb034c-ns-2"* ]]

  # --- 2 VolumeSnapshots ---
  local snap_count
  snap_count=$(echo "$output" | grep -c "kind: VolumeSnapshot")
  [ "$snap_count" -eq 2 ]

  # --- 4 VMs ---
  local vm_count
  vm_count=$(echo "$output" | grep -c "kind: VirtualMachine")
  [ "$vm_count" -eq 4 ]

  # --- VM names use myvm- prefix ---
  [[ "$output" == *"name: myvm-cmb034c-1"* ]]
  [[ "$output" == *"name: myvm-cmb034c-2"* ]]
  [[ "$output" == *"name: myvm-cmb034c-3"* ]]
  [[ "$output" == *"name: myvm-cmb034c-4"* ]]

  # --- The old broken default must NOT appear ---
  [[ "$output" != *"persistentVolumeClaimName: vm-base"* ]]
}

# ===============================================================
# Category 7: Option Precedence and Conflicts (combos 35-42)
# ===============================================================

# ---------------------------------------------------------------
# COMBO-35: --vms-per-namespace overrides --vms
# ---------------------------------------------------------------
@test "combo: vms-per-namespace overrides vms flag" {
  run bash "$VSTORM" -n --batch-id=cmb035 --datasource=rhel9 --vms-per-namespace=3 --vms=10 \
    --namespaces=2
  [ "$status" -eq 0 ]

  # --- vms-per-namespace wins: total = 3 * 2 = 6, not 10 ---
  [[ "$output" == *"Total VMs: 6"* ]]

  local vm_count
  vm_count=$(echo "$output" | grep -c "Creating VirtualMachine [0-9]")
  [ "$vm_count" -eq 6 ]
}

# ---------------------------------------------------------------
# COMBO-36: --vms=10 + positional arg 5 → positional overrides
# ---------------------------------------------------------------
@test "combo: positional arg overrides --vms flag" {
  run bash "$VSTORM" -n --batch-id=cmb036 --datasource=rhel9 --vms=10 5
  [ "$status" -eq 0 ]

  # --- Positional arg 5 overrides --vms=10 ---
  [[ "$output" == *"Total VMs: 5"* ]]

  local vm_count
  vm_count=$(echo "$output" | grep -c "Creating VirtualMachine [0-9]")
  [ "$vm_count" -eq 5 ]
}

# ---------------------------------------------------------------
# COMBO-37: --snapshot-class + --no-snapshot
# ---------------------------------------------------------------
@test "combo: snapshot-class + no-snapshot (explicit no-snapshot wins)" {
  run bash "$VSTORM" -n --batch-id=cmb037 --datasource=rhel9 --snapshot-class=my-snap \
    --no-snapshot --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  # --- Explicit --no-snapshot wins over --snapshot-class ---
  [[ "$output" == *"Snapshot mode: disabled"* ]]
  [[ "$output" != *"kind: VolumeSnapshot"* ]]
}

# ---------------------------------------------------------------
# COMBO-38: --snapshot-class alone (no --storage-class)
# ---------------------------------------------------------------
@test "combo: snapshot-class alone keeps snapshot mode on" {
  run bash "$VSTORM" -n --batch-id=cmb038 --datasource=rhel9 --snapshot-class=my-snap \
    --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  # --- Snapshot mode stays enabled ---
  [[ "$output" == *"Snapshot mode: enabled"* ]]
  [[ "$output" == *"kind: VolumeSnapshot"* ]]
  [[ "$output" == *"volumeSnapshotClassName: my-snap"* ]]
}

# ---------------------------------------------------------------
# COMBO-39: --stop + --wait (dry-run; Halted VMs won't run)
# ---------------------------------------------------------------
@test "combo: stop + wait accepted without error in dry-run" {
  run bash "$VSTORM" -n --batch-id=cmb039 --datasource=rhel9 --stop --wait \
    --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  # --- Both flags accepted ---
  [[ "$output" == *"runStrategy: Halted"* ]]
  [[ "$output" == *"kind: VirtualMachine"* ]]
}

# ---------------------------------------------------------------
# COMBO-40: --dv-url + --datasource (dv-url clears datasource)
# ---------------------------------------------------------------
@test "combo: dv-url overrides datasource" {
  run bash "$VSTORM" -n --batch-id=cmb040 --datasource=rhel9 \
    --datasource=fedora --dv-url=http://example.com/disk.qcow2 \
    --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  # --- URL import used, not DataSource ---
  [[ "$output" == *"http://example.com/disk.qcow2"* ]]
  [[ "$output" != *"sourceRef"* ]]
  [[ "$output" != *"kind: DataSource"* ]]

  # --- DV source is URL, not DataSource ---
  [[ "$output" == *"Disk source: URL"* ]]
}

# ---------------------------------------------------------------
# COMBO-41: --start + --stop (last one wins)
# ---------------------------------------------------------------
@test "combo: start then stop — last flag wins" {
  run bash "$VSTORM" -n --batch-id=cmb041 --datasource=rhel9 --start --stop \
    --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  # --- --stop is last, so Halted ---
  [[ "$output" == *"runStrategy: Halted"* ]]
}

# ---------------------------------------------------------------
# COMBO-42: --run-strategy=Halted + --start (start overrides)
# ---------------------------------------------------------------
@test "combo: run-strategy Halted then start — start overrides" {
  run bash "$VSTORM" -n --batch-id=cmb042 --datasource=rhel9 --run-strategy=Halted --start \
    --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  # --- --start is last, so Always ---
  [[ "$output" == *"runStrategy: Always"* ]]
}

