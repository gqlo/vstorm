#!/usr/bin/env bats

# Unit tests for vstorm
# Run with: bats tests/
#
# Regression coverage for stop_batch_vms() and wait_for_batch_vms_stopped()
# (see delete_batch()): before `oc delete ns` tears down a batch's
# namespaces, vstorm gracefully stops every VM via parallel `virtctl stop`
# calls, then waits for each VM's printableStatus to actually reach Stopped
# before proceeding. This is best-effort throughout -- a missing virtctl
# binary, an individual VM stop failure, or a stop-wait timeout only logs a
# warning and never blocks the delete.
#
# The mock oc (helpers.bash) reuses the MOCK_NS_LINES / MOCK_NS_CALLS_FILE
# convergence trick from 19-delete-cleanup-watch.bats so the post-delete
# watch loop resolves immediately, letting these tests focus purely on the
# VM-stop step.

load 'helpers'

VSTORM="./vstorm"

setup_file() {
    setup_oc_mock
    setup_virtctl_mock
}

teardown() {
    unset MOCK_NS_LINES MOCK_VM_LINES MOCK_NS_CALLS_FILE
    unset MOCK_VIRTCTL_STOP_LOG MOCK_VIRTCTL_STOP_FAIL
    unset MOCK_VM_STATUS_TICKS_FILE MOCK_VM_LINES_STOPPED
    unset DELETE_POLL_INTERVAL STOP_WAIT_TIMEOUT
}

# ---------------------------------------------------------------
# Dry-run mentions the virtctl stop + wait-for-Stopped step
# ---------------------------------------------------------------
@test "delete: dry-run mentions virtctl stop and waiting for Stopped" {
  run bash "$VSTORM" -n --delete=delsv0
  [ "$status" -eq 0 ]
  [[ "$output" == *"virtctl stop <vm> -n <namespace>"* ]]
  [[ "$output" == *"in parallel"* ]]
  [[ "$output" == *"wait"* ]]
  [[ "$output" == *"all VMs to reach Stopped"* ]]
}

# ---------------------------------------------------------------
# Wet-run: stops all VMs, then waits until they report Stopped
# ---------------------------------------------------------------
@test "delete: wet-run stops all VMs and waits for them to reach Stopped" {
  ns_calls_file=$(mktemp)
  stop_log=$(mktemp)

  MOCK_NS_LINES="delsv1-ns-1" \
  MOCK_NS_CALLS_FILE="$ns_calls_file" \
  MOCK_VM_LINES=$'delsv1-ns-1 tvm-delsv1-1 5m Stopped False\ndelsv1-ns-1 tvm-delsv1-2 5m Stopped False' \
  MOCK_VIRTCTL_STOP_LOG="$stop_log" \
  DELETE_POLL_INTERVAL=0 \
    run bash "$VSTORM" --delete=delsv1 --yes
  [ "$status" -eq 0 ]

  [[ "$output" == *"Stopping 2 VM(s) (virtctl stop"* ]]
  [[ "$output" == *"Stop requests sent for 2 VM(s)"* ]]
  [[ "$output" == *"Waiting for 2 VM(s) to reach Stopped"* ]]
  [[ "$output" == *"2/2 VMs stopped"* ]]
  [[ "$output" == *"All 2 VM(s) are Stopped"* ]]
  # The stop wait must happen before namespaces are deleted.
  stopped_line=$(grep -n "All 2 VM(s) are Stopped" <<< "$output" | head -1 | cut -d: -f1)
  deleting_line=$(grep -n "Deleting namespaces for batch" <<< "$output" | head -1 | cut -d: -f1)
  [ -n "$stopped_line" ]
  [ -n "$deleting_line" ]
  [ "$stopped_line" -lt "$deleting_line" ]

  rm -f "$ns_calls_file" "$stop_log"
}

# ---------------------------------------------------------------
# Wet-run: VMs take a few polls to go Running -> Stopped; the wait loop
# must keep polling (not just check once) until they converge.
# ---------------------------------------------------------------
@test "delete: wet-run keeps polling until VMs that start Running become Stopped" {
  ns_calls_file=$(mktemp)
  vm_ticks_file=$(mktemp)
  echo 3 > "$vm_ticks_file"

  MOCK_NS_LINES="delsv4-ns-1" \
  MOCK_NS_CALLS_FILE="$ns_calls_file" \
  MOCK_VM_LINES=$'delsv4-ns-1 tvm-delsv4-1 5m Running True' \
  MOCK_VM_LINES_STOPPED=$'delsv4-ns-1 tvm-delsv4-1 5m Stopped False' \
  MOCK_VM_STATUS_TICKS_FILE="$vm_ticks_file" \
  DELETE_POLL_INTERVAL=0 \
    run bash "$VSTORM" --delete=delsv4 --yes
  [ "$status" -eq 0 ]

  [[ "$output" == *"Waiting for 1 VM(s) to reach Stopped"* ]]
  [[ "$output" == *"0/1 VMs stopped"* ]]
  [[ "$output" == *"1/1 VMs stopped"* ]]
  [[ "$output" == *"All 1 VM(s) are Stopped"* ]]
  [[ "$output" != *"Timed out"* ]]

  rm -f "$ns_calls_file" "$vm_ticks_file"
}

# ---------------------------------------------------------------
# Wet-run: a failed `virtctl stop` only warns, delete still proceeds
# ---------------------------------------------------------------
@test "delete: wet-run logs a warning (not a failure) when virtctl stop fails for a VM" {
  ns_calls_file=$(mktemp)

  MOCK_NS_LINES="delsv2-ns-1" \
  MOCK_NS_CALLS_FILE="$ns_calls_file" \
  MOCK_VM_LINES=$'delsv2-ns-1 tvm-delsv2-1 5m Stopped False' \
  MOCK_VIRTCTL_STOP_FAIL="tvm-delsv2-1" \
  DELETE_POLL_INTERVAL=0 \
    run bash "$VSTORM" --delete=delsv2 --yes
  [ "$status" -eq 0 ]

  [[ "$output" == *"WARNING:"* ]]
  [[ "$output" == *"virtctl stop failed for"* ]]
  [[ "$output" == *"delsv2-ns-1/tvm-delsv2-1"* ]]
  [[ "$output" == *"fully cleaned up"* ]]

  rm -f "$ns_calls_file"
}

# ---------------------------------------------------------------
# Wet-run: missing virtctl only warns and skips (no stop-wait attempted
# either), delete still proceeds
# ---------------------------------------------------------------
@test "delete: wet-run skips VM stop (and the Stopped wait) with a warning when virtctl is missing" {
  ns_calls_file=$(mktemp)

  MOCK_NS_LINES="delsv3-ns-1" \
  MOCK_NS_CALLS_FILE="$ns_calls_file" \
  MOCK_VM_LINES=$'delsv3-ns-1 tvm-delsv3-1 5m Running True' \
  DELETE_POLL_INTERVAL=0 \
  PATH="$_VSTORM_MOCK_OC_DIR:/usr/bin:/bin" \
    run bash "$VSTORM" --delete=delsv3 --yes
  [ "$status" -eq 0 ]

  [[ "$output" == *"virtctl not found; skipping graceful VM stop before delete"* ]]
  [[ "$output" != *"Waiting for"*"to reach Stopped"* ]]
  [[ "$output" == *"fully cleaned up"* ]]

  rm -f "$ns_calls_file"
}

# ---------------------------------------------------------------
# Wet-run: VMs never report Stopped -- the wait times out with a warning,
# but delete proceeds anyway instead of aborting the whole run.
# ---------------------------------------------------------------
@test "delete: wet-run times out waiting for Stopped but still proceeds with delete" {
  ns_calls_file=$(mktemp)

  MOCK_NS_LINES="delsv5-ns-1" \
  MOCK_NS_CALLS_FILE="$ns_calls_file" \
  MOCK_VM_LINES=$'delsv5-ns-1 tvm-delsv5-1 5m Running True' \
  DELETE_POLL_INTERVAL=0 \
  STOP_WAIT_TIMEOUT=0 \
    run bash "$VSTORM" --delete=delsv5 --yes
  [ "$status" -eq 0 ]

  [[ "$output" == *"Timed out after 0s waiting for VMs to stop"* ]]
  [[ "$output" == *"proceeding with namespace delete anyway"* ]]
  [[ "$output" == *"Deleting namespaces for batch"*"delsv5"* ]]
  [[ "$output" == *"fully cleaned up"* ]]

  rm -f "$ns_calls_file"
}
