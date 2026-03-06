#!/usr/bin/env bats

# Tests for --custom-templates option
# Run with: bats tests/12-custom-templates.bats

load 'helpers'

VSTORM="./vstorm"

setup_file() {
    setup_oc_mock
}

# ===============================================================
# Custom templates: directory path
# ===============================================================

# ---------------------------------------------------------------
# CT-1: --custom-templates with a directory uses templates from it
# ---------------------------------------------------------------
@test "CT: custom templates directory used for VM creation" {
  run bash "$VSTORM" -n --custom-templates=templates --batch-id=ct0001 \
    --vms=2 --namespaces=1
  [ "$status" -eq 0 ]
  [[ "$output" == *"kind: Namespace"* ]]
  [[ "$output" == *"kind: VirtualMachine"* ]]
  [[ "$output" == *'batch-id: "ct0001"'* ]]

  local vm_count
  vm_count=$(echo "$output" | grep -c "Creating VirtualMachine [0-9]")
  [ "$vm_count" -eq 2 ]
}

# ===============================================================
# Custom templates: single file path
# ===============================================================

# ---------------------------------------------------------------
# CT-2: --custom-templates with a single file finds template by content
# ---------------------------------------------------------------
@test "CT: single file custom template found by content" {
  local tmpdir
  tmpdir=$(mktemp -d)
  cp templates/vm-containerdisk.yaml "$tmpdir/my-custom-vm.yaml"
  run bash "$VSTORM" -n --custom-templates="$tmpdir/my-custom-vm.yaml" \
    --batch-id=ct0002 --containerdisk --vms=1 --namespaces=1
  [ "$status" -eq 0 ]
  [[ "$output" == *"kind: VirtualMachine"* ]]
  [[ "$output" == *"containerDisk"* ]]
  rm -rf "$tmpdir"
}

# ===============================================================
# Custom templates: mixed file and directory
# ===============================================================

# ---------------------------------------------------------------
# CT-3: mixed file and directory paths work with colon separator
# ---------------------------------------------------------------
@test "CT: mixed file and directory custom templates work" {
  local tmpdir
  tmpdir=$(mktemp -d)
  cp templates/vm-datasource.yaml "$tmpdir/my-vm.yaml"
  run bash "$VSTORM" -n \
    --custom-templates="$tmpdir/my-vm.yaml:templates" \
    --batch-id=ct0003 --no-snapshot --vms=1 --namespaces=1
  [ "$status" -eq 0 ]
  [[ "$output" == *"kind: Namespace"* ]]
  [[ "$output" == *"kind: VirtualMachine"* ]]
  rm -rf "$tmpdir"
}

# ===============================================================
# Custom templates: custom-named files discovered by content
# ===============================================================

# ---------------------------------------------------------------
# CT-4: custom-named templates work when content matches
# ---------------------------------------------------------------
@test "CT: custom-named files detected by content, not filename" {
  local tmpdir
  tmpdir=$(mktemp -d)
  cp templates/namespace.yaml "$tmpdir/my-ns.yaml"
  cp templates/vm-datasource.yaml "$tmpdir/fedora-vm.yaml"
  run bash "$VSTORM" -n --custom-templates="$tmpdir" \
    --batch-id=ct0004 --no-snapshot --vms=2 --namespaces=1
  [ "$status" -eq 0 ]
  [[ "$output" == *"kind: Namespace"* ]]
  [[ "$output" == *"kind: VirtualMachine"* ]]

  local vm_count
  vm_count=$(echo "$output" | grep -c "Creating VirtualMachine [0-9]")
  [ "$vm_count" -eq 2 ]
  rm -rf "$tmpdir"
}

# ===============================================================
# Custom templates: built-in templates work (content matches)
# ===============================================================

# ---------------------------------------------------------------
# CT-5: built-in templates/ directory works with content detection
# ---------------------------------------------------------------
@test "CT: built-in templates detected by content" {
  run bash "$VSTORM" -n --batch-id=ct0005 --datasource=rhel9 --vms=3 --namespaces=1
  [ "$status" -eq 0 ]
  [[ "$output" == *"kind: Namespace"* ]]
  [[ "$output" == *"kind: DataVolume"* ]]
  [[ "$output" == *"kind: VolumeSnapshot"* ]]
  [[ "$output" == *"kind: VirtualMachine"* ]]

  local vm_count
  vm_count=$(echo "$output" | grep -c "Creating VirtualMachine [0-9]")
  [ "$vm_count" -eq 3 ]
}

# ===============================================================
# Partial custom templates (fallback to built-in)
# ===============================================================

# ---------------------------------------------------------------
# CT-6: partial custom -- only VM template, built-in used for the rest
# ---------------------------------------------------------------
@test "CT: partial custom -- VM template only, built-in for Namespace/DV/snapshot" {
  local tmpdir
  tmpdir=$(mktemp -d)
  cp templates/vm-snap.yaml "$tmpdir/custom-vm.yaml"
  run bash "$VSTORM" -n --custom-templates="$tmpdir" \
    --batch-id=ct0006 --vms=2 --namespaces=1 --snapshot
  [ "$status" -eq 0 ]

  # Built-in templates used for Namespace, DV, VolumeSnapshot
  [[ "$output" == *"kind: Namespace"* ]]
  [[ "$output" == *"kind: DataVolume"* ]]
  [[ "$output" == *"kind: VolumeSnapshot"* ]]
  [[ "$output" == *"kind: VirtualMachine"* ]]
  rm -rf "$tmpdir"
}

# ===============================================================
# Custom templates: missing template errors
# ===============================================================

# ---------------------------------------------------------------
# CT-7: CREATE_VM_PATH with no matching template fails
# ---------------------------------------------------------------
@test "CT: custom path with no matching template fails" {
  local tmpdir
  tmpdir=$(mktemp -d)
  echo "not-a-yaml-template" > "$tmpdir/junk.yaml"
  run env CREATE_VM_PATH="$tmpdir" bash "$VSTORM" -n \
    --batch-id=ct0007 --containerdisk --vms=1 --namespaces=1
  [ "$status" -ne 0 ]
  [[ "$output" == *"No namespace template found"* ]]
  rm -rf "$tmpdir"
}

# ---------------------------------------------------------------
# CT-8: snapshot mode with missing VolumeSnapshot template fails
# ---------------------------------------------------------------
@test "CT: snapshot mode missing VolumeSnapshot template fails" {
  local tmpdir
  tmpdir=$(mktemp -d)
  cp templates/namespace.yaml "$tmpdir/"
  cp templates/vm-snap.yaml "$tmpdir/"
  cp templates/dv-datasource.yaml "$tmpdir/"
  # No volumesnap.yaml -- should fail
  run env CREATE_VM_PATH="$tmpdir" bash "$VSTORM" -n --batch-id=ct0008 \
    --vms=1 --namespaces=1 --snapshot
  [ "$status" -ne 0 ]
  [[ "$output" == *"No volumesnapshot template found"* ]]
  rm -rf "$tmpdir"
}

# ---------------------------------------------------------------
# CT-9: nonexistent path silently skipped, built-in used as fallback
# ---------------------------------------------------------------
@test "CT: nonexistent custom-templates path falls back to built-in" {
  run bash "$VSTORM" -n \
    --custom-templates="/nonexistent/file.yaml" \
    --batch-id=ct0009 --containerdisk --vms=1 --namespaces=1
  [ "$status" -eq 0 ]
  [[ "$output" == *"kind: VirtualMachine"* ]]
}

# ===============================================================
# Literal template values
# ===============================================================

# ---------------------------------------------------------------
# CT-10: template with literal batch-id and no --batch-id keeps literal
# ---------------------------------------------------------------
@test "CT: template with literal batch-id used when no --batch-id" {
  local tmpdir
  tmpdir=$(mktemp -d)
  # Create a namespace template with a literal batch-id
  cat > "$tmpdir/ns.yaml" <<'TMPL'
apiVersion: v1
kind: Namespace
metadata:
  name: {vm-ns}
  labels:
    batch-id: "literal1"
TMPL
  run bash "$VSTORM" -n --custom-templates="$tmpdir" \
    --containerdisk --vms=1 --namespaces=1
  [ "$status" -eq 0 ]
  [[ "$output" == *'batch-id: "literal1"'* ]]
  rm -rf "$tmpdir"
}

# ---------------------------------------------------------------
# CT-11: template with literal batch-id and --batch-id=xyz replaces it
# ---------------------------------------------------------------
@test "CT: template literal batch-id replaced by --batch-id" {
  local tmpdir
  tmpdir=$(mktemp -d)
  cat > "$tmpdir/ns.yaml" <<'TMPL'
apiVersion: v1
kind: Namespace
metadata:
  name: {vm-ns}
  labels:
    batch-id: "literal2"
TMPL
  run bash "$VSTORM" -n --custom-templates="$tmpdir" \
    --batch-id=xyz999 --containerdisk --vms=1 --namespaces=1
  [ "$status" -eq 0 ]
  [[ "$output" == *'batch-id: "xyz999"'* ]]
  [[ "$output" != *'batch-id: "literal2"'* ]]
  rm -rf "$tmpdir"
}

# ===============================================================
# Precedence
# ===============================================================

# ---------------------------------------------------------------
# CT-12: --custom-templates takes precedence over CREATE_VM_PATH env
# ---------------------------------------------------------------
@test "CT: --custom-templates overrides CREATE_VM_PATH env var" {
  local tmpdir
  tmpdir=$(mktemp -d)
  cp templates/namespace.yaml "$tmpdir/"
  cp templates/vm-containerdisk.yaml "$tmpdir/"
  run env CREATE_VM_PATH="/nonexistent/path" bash "$VSTORM" -n \
    --custom-templates="$tmpdir" \
    --batch-id=ct0012 --containerdisk --vms=1 --namespaces=1
  [ "$status" -eq 0 ]
  [[ "$output" == *"kind: VirtualMachine"* ]]
  rm -rf "$tmpdir"
}
