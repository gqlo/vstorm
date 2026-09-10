#!/usr/bin/env bats

# Regression coverage for --delete-all: stop all VMs cluster-wide, then delete
# all VM namespaces (excluding openshift/kube system namespaces).

load 'helpers'

VSTORM="./vstorm"

setup_file() {
    setup_oc_mock
    setup_virtctl_mock
}

teardown() {
    unset MOCK_NS_LINES MOCK_VM_LINES MOCK_NS_CALLS_FILE MOCK_CLEANUP_TICKS_FILE
    unset MOCK_LEFTOVER_NS MOCK_VIRTCTL_STOP_LOG DELETE_POLL_INTERVAL
}

@test "delete-all: discovers and deletes VM namespace" {
  ticks_file=$(mktemp)
  stop_log=$(mktemp)
  echo 1 > "$ticks_file"

  MOCK_VM_LINES=$'my-vm-ns tvm-manual-1 5m Stopped False' \
  MOCK_LEFTOVER_NS="my-vm-ns" \
  MOCK_CLEANUP_TICKS_FILE="$ticks_file" \
  MOCK_VIRTCTL_STOP_LOG="$stop_log" \
  DELETE_POLL_INTERVAL=0 \
    run bash "$VSTORM" --delete-all --yes
  [ "$status" -eq 0 ]

  [[ "$output" == *"Found VM namespaces:"* ]]
  [[ "$output" == *"my-vm-ns"* ]]
  [[ "$output" == *"Stopping 1 VM(s)"* ]]
  [[ "$output" == *"Deleting 1 VM namespace(s)"* ]]
  [[ "$output" == *"Monitoring cleanup for VM namespaces"* ]]
  [[ "$output" == *"All VM namespaces fully cleaned up"* ]]
  grep -qx 'my-vm-ns/tvm-manual-1' "$stop_log"

  rm -f "$ticks_file" "$stop_log"
}

@test "delete-all: skips openshift and kube system VM namespaces" {
  MOCK_VM_LINES=$'openshift-cnv virt-operator 5m Running True
kube-system test-vm 5m Running True
my-other-ns vm1 5m Stopped False' \
  MOCK_LEFTOVER_NS="my-other-ns" \
  MOCK_CLEANUP_TICKS_FILE="$(mktemp)" \
  DELETE_POLL_INTERVAL=0 \
    run bash "$VSTORM" --delete-all --yes
  [ "$status" -eq 0 ]

  [[ "$output" == *"Found VM namespaces:"* ]]
  [[ "$output" == *"my-other-ns"* ]]
  [[ "$output" != *"openshift-cnv"* ]]
  [[ "$output" != *"kube-system"* ]]

  rm -f "$MOCK_CLEANUP_TICKS_FILE"
}

@test "delete-all: stops VMs and deletes vstorm and manual namespaces together" {
  ticks_file=$(mktemp)
  stop_log=$(mktemp)
  echo 1 > "$ticks_file"

  MOCK_NS_LINES="delall1-ns-1" \
  MOCK_VM_LINES=$'delall1-ns-1 tvm-delall1-1 5m Stopped False
other-ns tvm-other-1 5m Stopped False' \
  MOCK_LEFTOVER_NS="delall1-ns-1" \
  MOCK_CLEANUP_TICKS_FILE="$ticks_file" \
  MOCK_VIRTCTL_STOP_LOG="$stop_log" \
  DELETE_POLL_INTERVAL=0 \
    run bash "$VSTORM" --delete-all --yes
  [ "$status" -eq 0 ]

  [[ "$output" == *"Found VM namespaces:"* ]]
  [[ "$output" == *"delall1-ns-1  (1 VMs)"* ]]
  [[ "$output" == *"other-ns  (1 VMs)"* ]]
  [[ "$output" == *"Total: 2 namespace(s), 2 VM(s)"* ]]
  [[ "$output" == *"Stopping 2 VM(s)"* ]]
  [[ "$output" == *"Deleting 2 VM namespace(s)"* ]]
  grep -qx 'delall1-ns-1/tvm-delall1-1' "$stop_log"
  grep -qx 'other-ns/tvm-other-1' "$stop_log"

  rm -f "$ticks_file" "$stop_log"
}

@test "delete-all: legacy vm-{batch}-ns namespaces are included" {
  ticks_file=$(mktemp)
  stop_log=$(mktemp)
  echo 1 > "$ticks_file"

  MOCK_NS_LINES="vm-legacy1-ns-1" \
  MOCK_VM_LINES=$'vm-legacy1-ns-1 tvm-legacy1-1 5m Stopped False' \
  MOCK_LEFTOVER_NS="vm-legacy1-ns-1" \
  MOCK_CLEANUP_TICKS_FILE="$ticks_file" \
  MOCK_VIRTCTL_STOP_LOG="$stop_log" \
  DELETE_POLL_INTERVAL=0 \
    run bash "$VSTORM" --delete-all --yes
  [ "$status" -eq 0 ]

  [[ "$output" == *"Found VM namespaces:"* ]]
  [[ "$output" == *"vm-legacy1-ns-1  (1 VMs)"* ]]
  [[ "$output" == *"Stopping 1 VM(s)"* ]]
  grep -qx 'vm-legacy1-ns-1/tvm-legacy1-1' "$stop_log"

  rm -f "$ticks_file" "$stop_log"
}
