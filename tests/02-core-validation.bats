#!/usr/bin/env bats

# Unit tests for vstorm
# Run with: bats tests/

load 'helpers'

VSTORM="./vstorm"

setup_file() {
    setup_oc_mock
}

# ===============================================================
# Core functionality
# ===============================================================

# ---------------------------------------------------------------
# Batch ID auto-generation
# ---------------------------------------------------------------
@test "auto-generates a 6-character hex batch ID" {
  run bash "$VSTORM" -q --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  local batch_id
  batch_id=$(echo "$output" | grep "Batch ID:" | head -1 | awk '{print $NF}')
  [[ "$batch_id" =~ ^[0-9a-f]{6}$ ]]
}

# ---------------------------------------------------------------
# Namespace naming
# ---------------------------------------------------------------
@test "namespaces follow vm-{batch}-ns-{N} pattern" {
  run bash "$VSTORM" -q --batch-id=ff0011 --vms=4 --namespaces=3
  [ "$status" -eq 0 ]

  [[ "$output" == *"vm-ff0011-ns-1"* ]]
  [[ "$output" == *"vm-ff0011-ns-2"* ]]
  [[ "$output" == *"vm-ff0011-ns-3"* ]]
  [[ "$output" != *"vm-ff0011-ns-4"* ]]
}

# ---------------------------------------------------------------
# VM distribution
# ---------------------------------------------------------------
@test "VMs are distributed evenly with remainder in first namespaces" {
  run bash "$VSTORM" -q --batch-id=aabb11 --vms=5 --namespaces=2
  [ "$status" -eq 0 ]

  local ns1_count ns2_count
  ns1_count=$(echo "$output" | grep -c "Creating VirtualMachine.*for namespace: vm-aabb11-ns-1")
  ns2_count=$(echo "$output" | grep -c "Creating VirtualMachine.*for namespace: vm-aabb11-ns-2")

  [ "$ns1_count" -eq 3 ]
  [ "$ns2_count" -eq 2 ]
}

# ===============================================================
# Validation / error handling
# ===============================================================

@test "--delete without a value fails with helpful error" {
  run bash "$VSTORM" -n --delete
  [ "$status" -ne 0 ]
  [[ "$output" == *"--delete requires a batch ID"* ]]
}

@test "non-numeric first positional argument is rejected" {
  run bash "$VSTORM" -n abc123
  [ "$status" -ne 0 ]
  [[ "$output" == *"Invalid argument"* ]]
  [[ "$output" == *"expected a number for total VMs"* ]]
}

@test "non-numeric second positional argument is rejected" {
  run bash "$VSTORM" -n 5 abc
  [ "$status" -ne 0 ]
  [[ "$output" == *"Invalid argument"* ]]
  [[ "$output" == *"expected a number for namespaces"* ]]
}

@test "--cloudinit with missing file fails" {
  run bash "$VSTORM" -n --batch-id=err001 --vms=1 --namespaces=1 \
    --cloudinit=nonexistent-file.yaml
  [ "$status" -ne 0 ]
  [[ "$output" == *"Cloud-init file not found"* ]]
}

@test "--dv-url with empty DATASOURCE requires URL" {
  # --dv-url clears DATASOURCE; omitting URL value should fail
  run bash "$VSTORM" -n --batch-id=err002 --vms=1 --namespaces=1 --dv-url=
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------
# ERR-1: --vms=0 rejected as non-positive
# ---------------------------------------------------------------
@test "ERR: --vms=0 rejected as non-positive" {
  run bash "$VSTORM" -n --batch-id=err010 --vms=0 --namespaces=1
  [ "$status" -ne 0 ]
  [[ "$output" == *"Number of VMs must be a positive integer"* ]]
}

# ---------------------------------------------------------------
# ERR-2: --namespaces=0 rejected as non-positive
# ---------------------------------------------------------------
@test "ERR: --namespaces=0 rejected as non-positive" {
  run bash "$VSTORM" -n --batch-id=err011 --vms=1 --namespaces=0
  [ "$status" -ne 0 ]
  [[ "$output" == *"Number of namespaces must be a positive integer"* ]]
}

# ---------------------------------------------------------------
# ERR-3: VMs fewer than namespaces is rejected
# ---------------------------------------------------------------
@test "ERR: --vms=2 --namespaces=5 fails (VMs < namespaces)" {
  run bash "$VSTORM" -n --batch-id=err012 --vms=2 --namespaces=5
  [ "$status" -ne 0 ]
  [[ "$output" == *"Number of VMs must be greater than or equal to number of namespaces"* ]]
}

# ---------------------------------------------------------------
# ERR-4: too many positional arguments rejected with diagnostic
# ---------------------------------------------------------------
@test "ERR: three positional arguments rejected with count" {
  run bash "$VSTORM" -n --batch-id=err013 10 2 3
  [ "$status" -ne 0 ]
  [[ "$output" == *"too many positional arguments"* ]]
  [[ "$output" == *"got 3"* ]]
}

# ---------------------------------------------------------------
# ERR-5: negative number as positional arg rejected
# ---------------------------------------------------------------
@test "ERR: negative positional arg rejected as non-numeric" {
  run bash "$VSTORM" -n --batch-id=err014 -- -5
  [ "$status" -ne 0 ]
  [[ "$output" == *"Invalid argument"* ]]
}

# ---------------------------------------------------------------
# ERR-6: unknown long option shows error with option name
# ---------------------------------------------------------------
@test "ERR: unknown long option rejected with name" {
  run bash "$VSTORM" -n --batch-id=err015 --nonexistent-option
  [ "$status" -ne 0 ]
  [[ "$output" == *"unrecognized option"* ]]
  [[ "$output" == *"--nonexistent-option"* ]]
  [[ "$output" == *"-h"* ]]
}

# ---------------------------------------------------------------
# ERR-7: unknown short option shows error with option name
# ---------------------------------------------------------------
@test "ERR: unknown short option rejected with name" {
  run bash "$VSTORM" -nZ
  [ "$status" -ne 0 ]
  [[ "$output" == *"unrecognized option"* ]]
  [[ "$output" == *"-Z"* ]]
  [[ "$output" == *"-h"* ]]
}

# ---------------------------------------------------------------
# ERR-8: --delete= with empty string fails
# ---------------------------------------------------------------
@test "ERR: --delete with empty value fails" {
  run bash "$VSTORM" -n "--delete="
  [ "$status" -ne 0 ]
  [[ "$output" == *"--delete requires a batch ID"* ]]
}

# ---------------------------------------------------------------
# ERR-9: --cloudinit pointing to a directory instead of a file
# ---------------------------------------------------------------
@test "ERR: --cloudinit with directory instead of file fails" {
  run bash "$VSTORM" -n --batch-id=err016 --vms=1 --namespaces=1 \
    --cloudinit=/tmp
  [ "$status" -ne 0 ]
  [[ "$output" == *"Cloud-init file not found"* ]]
}

# ---------------------------------------------------------------
# ERR-10: missing namespace template
# ---------------------------------------------------------------
@test "ERR: missing namespace template fails" {
  local tmpdir
  tmpdir=$(mktemp -d)
  run env CREATE_VM_PATH="$tmpdir" bash "$VSTORM" -n --batch-id=err017 --vms=1 --namespaces=1
  [ "$status" -ne 0 ]
  [[ "$output" == *"No namespace template found"* ]]
  rm -rf "$tmpdir"
}

# ---------------------------------------------------------------
# ERR-11: missing dv template in snapshot+datasource mode
# ---------------------------------------------------------------
@test "ERR: missing dv template fails in snapshot+datasource mode" {
  local tmpdir
  tmpdir=$(mktemp -d)
  cp templates/namespace.yaml "$tmpdir/"
  cp templates/volumesnap.yaml "$tmpdir/"
  cp templates/vm-snap.yaml "$tmpdir/"
  run env CREATE_VM_PATH="$tmpdir" bash "$VSTORM" -n --batch-id=err018 \
    --vms=1 --namespaces=1 --snapshot-class=my-snap
  [ "$status" -ne 0 ]
  [[ "$output" == *"No dv template found"* ]]
  rm -rf "$tmpdir"
}

# ---------------------------------------------------------------
# ERR-12: missing dv template in URL mode
# ---------------------------------------------------------------
@test "ERR: missing dv template fails in URL mode" {
  local tmpdir
  tmpdir=$(mktemp -d)
  cp templates/namespace.yaml "$tmpdir/"
  cp templates/vm-clone.yaml "$tmpdir/"
  run env CREATE_VM_PATH="$tmpdir" bash "$VSTORM" -n --batch-id=err019 \
    --vms=1 --namespaces=1 --dv-url=http://example.com/disk.qcow2 --no-snapshot
  [ "$status" -ne 0 ]
  [[ "$output" == *"No dv template found"* ]]
  rm -rf "$tmpdir"
}

# ---------------------------------------------------------------
# ERR-13: missing vm template in snapshot mode
# ---------------------------------------------------------------
@test "ERR: missing vm template fails in snapshot mode" {
  local tmpdir
  tmpdir=$(mktemp -d)
  cp templates/namespace.yaml "$tmpdir/"
  cp templates/volumesnap.yaml "$tmpdir/"
  cp templates/dv-datasource.yaml "$tmpdir/"
  run env CREATE_VM_PATH="$tmpdir" bash "$VSTORM" -n --batch-id=err020 \
    --vms=1 --namespaces=1 --snapshot-class=my-snap
  [ "$status" -ne 0 ]
  [[ "$output" == *"No vm template found"* ]]
  rm -rf "$tmpdir"
}

# ---------------------------------------------------------------
# ERR-14: missing vm template in no-snapshot datasource mode
# ---------------------------------------------------------------
@test "ERR: missing vm template fails in no-snapshot datasource mode" {
  local tmpdir
  tmpdir=$(mktemp -d)
  cp templates/namespace.yaml "$tmpdir/"
  run env CREATE_VM_PATH="$tmpdir" bash "$VSTORM" -n --batch-id=err021 \
    --vms=1 --namespaces=1 --no-snapshot
  [ "$status" -ne 0 ]
  [[ "$output" == *"No vm template found"* ]]
  rm -rf "$tmpdir"
}

# ---------------------------------------------------------------
# ERR-15: missing vm template in URL no-snapshot mode
# ---------------------------------------------------------------
@test "ERR: missing vm template fails in URL no-snapshot mode" {
  local tmpdir
  tmpdir=$(mktemp -d)
  cp templates/namespace.yaml "$tmpdir/"
  cp templates/dv.yaml "$tmpdir/"
  run env CREATE_VM_PATH="$tmpdir" bash "$VSTORM" -n --batch-id=err022 \
    --vms=1 --namespaces=1 --dv-url=http://example.com/disk.qcow2 --no-snapshot
  [ "$status" -ne 0 ]
  [[ "$output" == *"No vm template found"* ]]
  rm -rf "$tmpdir"
}

# ---------------------------------------------------------------
# ERR-16: --snapshot-class then --no-snapshot (last wins = no-snapshot)
# ---------------------------------------------------------------
@test "ERR: --snapshot-class then --no-snapshot uses no-snapshot mode" {
  run bash "$VSTORM" -n --batch-id=err023 --vms=2 --namespaces=1 \
    --snapshot-class=my-snap --no-snapshot
  [ "$status" -eq 0 ]
  [[ "$output" != *"Creating VolumeSnapshots"* ]]
  [[ "$output" != *"kind: VolumeSnapshot"* ]]
}

# ---------------------------------------------------------------
# ERR-17: --no-snapshot then --snapshot-class (last wins = snapshot)
# ---------------------------------------------------------------
@test "ERR: --no-snapshot then --snapshot-class uses snapshot mode" {
  run bash "$VSTORM" -n --batch-id=err024 --vms=2 --namespaces=1 \
    --no-snapshot --snapshot-class=my-snap
  [ "$status" -eq 0 ]
  [[ "$output" == *"Creating VolumeSnapshots"* ]]
  [[ "$output" == *"kind: VolumeSnapshot"* ]]
}

# ---------------------------------------------------------------
# ERR-18: --access-mode=ReadWriteOnce then ReadWriteMany (last wins = ReadWriteMany)
# ---------------------------------------------------------------
@test "ERR: --access-mode RWO then RWX uses ReadWriteMany" {
  run bash "$VSTORM" -n --batch-id=err025 --vms=1 --namespaces=1 \
    --access-mode=ReadWriteOnce --access-mode=ReadWriteMany
  [ "$status" -eq 0 ]
  [[ "$output" == *"ReadWriteMany"* ]]
  [[ "$output" != *"ReadWriteOnce"* ]]
}

# ---------------------------------------------------------------
# ERR-19: --access-mode=ReadWriteMany then ReadWriteOnce (last wins = ReadWriteOnce)
# ---------------------------------------------------------------
@test "ERR: --access-mode RWX then RWO uses ReadWriteOnce" {
  run bash "$VSTORM" -n --batch-id=err026 --vms=1 --namespaces=1 \
    --access-mode=ReadWriteMany --access-mode=ReadWriteOnce
  [ "$status" -eq 0 ]
  [[ "$output" == *"ReadWriteOnce"* ]]
}

# ---------------------------------------------------------------
# ERR-20: --dv-url overrides --datasource
# ---------------------------------------------------------------
@test "ERR: --dv-url overrides --datasource" {
  run bash "$VSTORM" -n --batch-id=err027 --vms=1 --namespaces=1 \
    --datasource=fedora --dv-url=http://example.com/disk.qcow2 --no-snapshot
  [ "$status" -eq 0 ]
  [[ "$output" == *"http://example.com/disk.qcow2"* ]]
  # DataSource should not be referenced
  [[ "$output" != *"sourceRef"* ]]
}

# ---------------------------------------------------------------
# ERR-21: --vms=-1 rejected as non-positive
# ---------------------------------------------------------------
@test "ERR: --vms=-1 rejected as non-positive" {
  run bash "$VSTORM" -n --batch-id=err028 --vms=-1 --namespaces=1
  [ "$status" -ne 0 ]
  [[ "$output" == *"Number of VMs must be a positive integer"* ]]
}

# ---------------------------------------------------------------
# ERR-22: --namespaces=-1 rejected as non-positive
# ---------------------------------------------------------------
@test "ERR: --namespaces=-1 rejected as non-positive" {
  run bash "$VSTORM" -n --batch-id=err029 --namespaces=-1 --vms=1
  [ "$status" -ne 0 ]
  [[ "$output" == *"Number of namespaces must be a positive integer"* ]]
}

# ---------------------------------------------------------------
# ERR-22a: invalid --run-strategy rejected
# ---------------------------------------------------------------
@test "ERR: invalid --run-strategy rejected" {
  run bash "$VSTORM" -n --batch-id=err029a --run-strategy=Invalid --vms=1 --namespaces=1
  [ "$status" -ne 0 ]
  [[ "$output" == *"Invalid --run-strategy 'Invalid'"* ]]
  [[ "$output" == *"Always, Halted, Manual, RerunOnFailure"* ]]
}

# ---------------------------------------------------------------
# ERR-22b: invalid --wait value rejected
# ---------------------------------------------------------------
@test "ERR: invalid --wait value rejected" {
  run bash "$VSTORM" -n --batch-id=err029b --wait=maybe --vms=1 --namespaces=1
  [ "$status" -ne 0 ]
  [[ "$output" == *"Invalid --wait value 'maybe'"* ]]
}

# ---------------------------------------------------------------
# ERR-22c: invalid --access-mode rejected
# ---------------------------------------------------------------
@test "ERR: invalid --access-mode rejected" {
  run bash "$VSTORM" -n --batch-id=err029c --access-mode=ReadWriteX --vms=1 --namespaces=1
  [ "$status" -ne 0 ]
  [[ "$output" == *"Invalid --access-mode 'ReadWriteX'"* ]]
  [[ "$output" == *"ReadWriteOnce, ReadWriteMany, ReadOnlyMany"* ]]
}

# ---------------------------------------------------------------
# ERR-23: option placed after positional arg is detected
# ---------------------------------------------------------------
@test "ERR: option after positional arg detected" {
  run bash "$VSTORM" -n 10 --cores=4
  [ "$status" -ne 0 ]
  [[ "$output" == *"Misplaced option '--cores=4'"* ]]
  [[ "$output" == *"before positional arguments"* ]]
}

# ---------------------------------------------------------------
# ERR-24: option sandwiched between valid option and positional
# ---------------------------------------------------------------
@test "ERR: trailing option after positional arg detected" {
  run bash "$VSTORM" -n --cores=4 10 --memory=2Gi
  [ "$status" -ne 0 ]
  [[ "$output" == *"Misplaced option '--memory=2Gi'"* ]]
}

# ---------------------------------------------------------------
# ERR-25: multiple misplaced options (first one is reported)
# ---------------------------------------------------------------
@test "ERR: first misplaced option is reported" {
  run bash "$VSTORM" -n 10 --cores=4 --memory=2Gi
  [ "$status" -ne 0 ]
  [[ "$output" == *"Misplaced option '--cores=4'"* ]]
}

# ---------------------------------------------------------------
# ERR-26: misplaced --delete after positional arg
# ---------------------------------------------------------------
@test "ERR: misplaced --delete after positional arg detected" {
  run bash "$VSTORM" -n 5 --delete=abc123
  [ "$status" -ne 0 ]
  [[ "$output" == *"Misplaced option '--delete=abc123'"* ]]
}

# ---------------------------------------------------------------
# ERR-27: -- end-of-options marker still works (not a false positive)
# ---------------------------------------------------------------
@test "ERR: -- end-of-options does not trigger misplaced option check" {
  run bash "$VSTORM" -n --batch-id=err030 --vms=1 --namespaces=1 -- 5
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------
# ERR-28: oc whoami timeout produces network connectivity error
# ---------------------------------------------------------------
@test "ERR: oc whoami timeout reports network connectivity error" {
  local tmpdir
  tmpdir=$(mktemp -d)
  cat > "$tmpdir/oc" << 'SLOWMOCK'
#!/bin/bash
sleep 999
SLOWMOCK
  chmod +x "$tmpdir/oc"
  run env PATH="$tmpdir:$PATH" OC_CONNECT_TIMEOUT=1 \
    bash "$VSTORM" --batch-id=err031 --vms=1 --namespaces=1
  rm -rf "$tmpdir"
  [ "$status" -ne 0 ]
  [[ "$output" == *"timed out reaching OpenShift cluster"* ]]
  [[ "$output" == *"check network connectivity"* ]]
}

# ===============================================================
# Option coverage: --env (guest env injection)
# ===============================================================

# ---------------------------------------------------------------
# OPT: --env documented in help
# ---------------------------------------------------------------
@test "OPT: --env documented in help" {
  run bash "$VSTORM" -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"--env"* ]]
  [[ "$output" == *"KEY=VAL"* ]]
  [[ "$output" == *"vstorm-guest-env"* ]]
}

# ---------------------------------------------------------------
# OPT: --env with cloud-init that has placeholder injects vars into Secret
# ---------------------------------------------------------------
@test "OPT: --env injects KEY=VAL into cloud-init Secret userdata" {
  run bash "$VSTORM" -n --batch-id=env01 --datasource=rhel9 --vms=1 --namespaces=1 \
    --cloudinit=workload/cloudinit-stress-ng-workload.yaml \
    --env FOO=bar --env=BAZ=qux
  [ "$status" -eq 0 ]
  [[ "$output" == *"kind: Secret"* ]]
  [[ "$output" == *"userdata:"* ]]

  userdata_b64=$(echo "$output" | grep "userdata:" | head -1 | sed 's/.*userdata: *//')
  [ -n "$userdata_b64" ]
  decoded=$(echo "$userdata_b64" | base64 -d 2>/dev/null)
  [[ "$decoded" == *"  FOO=bar"* ]]
  [[ "$decoded" == *"  BAZ=qux"* ]]
  [[ "$decoded" != *"{VSTORM_GUEST_ENV}"* ]]
}

# ---------------------------------------------------------------
# OPT: --env space-separated form (--env KEY=VAL)
# ---------------------------------------------------------------
@test "OPT: --env space-separated form accepted" {
  run bash "$VSTORM" -n --batch-id=env02 --datasource=rhel9 --vms=1 --namespaces=1 \
    --cloudinit=workload/cloudinit-stress-ng-workload.yaml \
    --env X=1 --env Y=2
  [ "$status" -eq 0 ]
  userdata_b64=$(echo "$output" | grep "userdata:" | head -1 | sed 's/.*userdata: *//')
  decoded=$(echo "$userdata_b64" | base64 -d 2>/dev/null)
  [[ "$decoded" == *"  X=1"* ]]
  [[ "$decoded" == *"  Y=2"* ]]
}

# ---------------------------------------------------------------
# OPT: --env without --cloudinit does not crash (default cloud-init has no placeholder)
# ---------------------------------------------------------------
@test "OPT: --env without custom cloud-init runs successfully" {
  run bash "$VSTORM" -n --batch-id=env03 --datasource=rhel9 --vms=1 --namespaces=1 \
    --env EXTRA=value
  [ "$status" -eq 0 ]
  [[ "$output" == *"kind: Secret"* ]]
}

# ---------------------------------------------------------------
# OPT: no --env replaces placeholder with comment in userdata when file has it
# ---------------------------------------------------------------
@test "OPT: no --env replaces placeholder with comment in cloud-init userdata when present in file" {
  run bash "$VSTORM" -n --batch-id=env04 --datasource=rhel9 --vms=1 --namespaces=1 \
    --cloudinit=workload/cloudinit-stress-ng-workload.yaml
  [ "$status" -eq 0 ]
  userdata_b64=$(echo "$output" | grep "userdata:" | head -1 | sed 's/.*userdata: *//')
  decoded=$(echo "$userdata_b64" | base64 -d 2>/dev/null)
  # Placeholder is always replaced (with env lines or with comment) so YAML stays valid
  [[ "$decoded" == *"# no --env passed"* ]]
  [[ "$decoded" != *"{VSTORM_GUEST_ENV}"* ]]
}

# ---------------------------------------------------------------
# OPT: dirty-rate cloud-init includes systemd unit and env injection
# ---------------------------------------------------------------
@test "OPT: cloudinit-dirty-mem-pages.yaml with --env DIRTY_RATE_FRACTION" {
  run bash "$VSTORM" -n --batch-id=env05 --datasource=rhel9 --vms=1 --namespaces=1 \
    --cloudinit=workload/cloudinit-dirty-mem-pages.yaml \
    --env DIRTY_RATE_FRACTION=0.4
  [ "$status" -eq 0 ]
  [[ "$output" == *"kind: Secret"* ]]
  [[ "$output" == *"userdata:"* ]]
  userdata_b64=$(echo "$output" | grep "userdata:" | head -1 | sed 's/.*userdata: *//')
  [ -n "$userdata_b64" ]
  decoded=$(echo "$userdata_b64" | base64 -d 2>/dev/null)
  [[ "$decoded" == *"DIRTY_RATE_FRACTION=0.4"* ]]
  [[ "$decoded" == *"dirty-mem-pages.service"* ]]
  [[ "$decoded" != *"{VSTORM_GUEST_ENV}"* ]]
}

