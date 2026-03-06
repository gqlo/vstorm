#!/usr/bin/env bats

# Unit tests for vstorm
# Run with: bats tests/

load 'helpers'

VSTORM="./vstorm"

setup_file() {
    setup_oc_mock
}

# ===============================================================
# Delete hardening -- batch ID validation
# ===============================================================

# ---------------------------------------------------------------
# ERR-10: --delete='*' rejected (wildcard not a valid batch ID)
# ---------------------------------------------------------------
@test "ERR: --delete with wildcard is rejected" {
  run bash "$VSTORM" -n "--delete=*"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Invalid batch ID"* ]]
}

# ---------------------------------------------------------------
# ERR-11: --delete='a,b' rejected (comma in batch ID)
# ---------------------------------------------------------------
@test "ERR: --delete with comma is rejected" {
  run bash "$VSTORM" -n "--delete=a,b"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Invalid batch ID"* ]]
}

# ---------------------------------------------------------------
# ERR-12: --delete with spaces rejected
# ---------------------------------------------------------------
@test "ERR: --delete with spaces is rejected" {
  run bash "$VSTORM" -n "--delete=abc 123"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Invalid batch ID"* ]]
}

# ---------------------------------------------------------------
# ERR-13: --delete with semicolons rejected
# ---------------------------------------------------------------
@test "ERR: --delete with semicolons is rejected" {
  run bash "$VSTORM" -n "--delete=abc;rm -rf /"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Invalid batch ID"* ]]
}

# ---------------------------------------------------------------
# ERR-14: --delete with value ending in hyphen rejected
# ---------------------------------------------------------------
@test "ERR: --delete with trailing hyphen is rejected" {
  run bash "$VSTORM" -n "--delete=abc-"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Invalid batch ID"* ]]
}

# ---------------------------------------------------------------
# ERR-15: --delete and --delete-all mutually exclusive
# ---------------------------------------------------------------
@test "ERR: --delete and --delete-all together rejected" {
  run bash "$VSTORM" -n --delete=abc123 --delete-all
  [ "$status" -ne 0 ]
  [[ "$output" == *"Cannot use --delete and --delete-all together"* ]]
}

# ---------------------------------------------------------------
# Valid batch IDs accepted by --delete
# ---------------------------------------------------------------
@test "delete: valid 6-char hex batch ID accepted" {
  run bash "$VSTORM" -n --delete=a3f7b2
  [ "$status" -eq 0 ]
  [[ "$output" == *"dry-run"* ]]
  [[ "$output" == *"a3f7b2"* ]]
}

@test "delete: alphanumeric batch ID accepted" {
  run bash "$VSTORM" -n --delete=mytest01
  [ "$status" -eq 0 ]
  [[ "$output" == *"dry-run"* ]]
}

@test "delete: batch ID with dots and hyphens accepted" {
  run bash "$VSTORM" -n --delete=test.run-1
  [ "$status" -eq 0 ]
  [[ "$output" == *"dry-run"* ]]
}

@test "delete: single-char batch ID accepted" {
  run bash "$VSTORM" -n --delete=a
  [ "$status" -eq 0 ]
  [[ "$output" == *"dry-run"* ]]
}

# ---------------------------------------------------------------
# --delete no longer matches fuzzy variants
# ---------------------------------------------------------------
@test "ERR: --deleteall as single token is unrecognized (use --delete-all)" {
  # Before the fix, delete*) would match deleteall.
  # Now delete) requires exact match and deleteall is its own case.
  # --deleteall (no value) should still be recognized as --delete-all.
  run bash "$VSTORM" -n --deleteall
  [ "$status" -eq 0 ]
  [[ "$output" == *"dry-run"* ]]
}

@test "ERR: --deletebatch is unrecognized option" {
  run bash "$VSTORM" -n "--deletebatch=abc123"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unrecognized option"* ]]
}

# ===============================================================
# --delete-all dry-run
# ===============================================================

# ---------------------------------------------------------------
# --delete-all shows dry-run info
# ---------------------------------------------------------------
@test "delete-all: dry-run shows discovery message" {
  run bash "$VSTORM" -n --delete-all
  [ "$status" -eq 0 ]
  [[ "$output" == *"dry-run"* ]]
  [[ "$output" == *"all vstorm batches"* ]]
}

@test "delete-all: dry-run with --yes accepted" {
  run bash "$VSTORM" -n --delete-all --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"dry-run"* ]]
}

@test "delete-all: dry-run with -y accepted" {
  run bash "$VSTORM" -ny --delete-all
  [ "$status" -eq 0 ]
  [[ "$output" == *"dry-run"* ]]
}

# ===============================================================
# --yes / -y option
# ===============================================================

@test "OPT: --yes accepted with --delete dry-run" {
  run bash "$VSTORM" -n --delete=abc123 --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"dry-run"* ]]
}

@test "OPT: -y short flag accepted with --delete dry-run" {
  run bash "$VSTORM" -ny --delete=abc123
  [ "$status" -eq 0 ]
  [[ "$output" == *"dry-run"* ]]
}

# ===============================================================
# --profile option
# ===============================================================

# ---------------------------------------------------------------
# PROF-1: --profile accepted in dry-run mode (default target: all)
# ---------------------------------------------------------------
@test "PROF: --profile dry-run shows profiling messages" {
  run bash "$VSTORM" -n --batch-id=prof01 --profile
  [ "$status" -eq 0 ]
  [[ "$output" == *"(dry-run) Would ensure cluster-profiler binary is available"* ]]
  [[ "$output" == *"(dry-run) Would check/enable ClusterProfiler feature gate"* ]]
  [[ "$output" == *"(dry-run) Would start profiling before VM creation"* ]]
  [[ "$output" == *"(dry-run) Would prompt to stop profiling and dump results"* ]]
}

# ---------------------------------------------------------------
# PROF-2: --profile=virt-controller accepted in dry-run
# ---------------------------------------------------------------
@test "PROF: --profile=virt-controller dry-run accepted" {
  run bash "$VSTORM" -n --batch-id=prof02 --profile=virt-controller
  [ "$status" -eq 0 ]
  [[ "$output" == *"(dry-run) Would start profiling before VM creation"* ]]
}

# ---------------------------------------------------------------
# PROF-3: --profile=virt-api accepted in dry-run
# ---------------------------------------------------------------
@test "PROF: --profile=virt-api dry-run accepted" {
  run bash "$VSTORM" -n --batch-id=prof03 --profile=virt-api
  [ "$status" -eq 0 ]
  [[ "$output" == *"(dry-run) Would start profiling before VM creation"* ]]
}

# ---------------------------------------------------------------
# PROF-4: --profile=virt-handler accepted in dry-run
# ---------------------------------------------------------------
@test "PROF: --profile=virt-handler dry-run accepted" {
  run bash "$VSTORM" -n --batch-id=prof04 --profile=virt-handler
  [ "$status" -eq 0 ]
  [[ "$output" == *"(dry-run) Would start profiling before VM creation"* ]]
}

# ---------------------------------------------------------------
# PROF-5: --profile=virt-operator accepted in dry-run
# ---------------------------------------------------------------
@test "PROF: --profile=virt-operator dry-run accepted" {
  run bash "$VSTORM" -n --batch-id=prof05 --profile=virt-operator
  [ "$status" -eq 0 ]
  [[ "$output" == *"(dry-run) Would start profiling before VM creation"* ]]
}

# ---------------------------------------------------------------
# PROF-6: --profile with invalid component name fails
# ---------------------------------------------------------------
@test "PROF: --profile=invalid fails with error" {
  run bash "$VSTORM" -n --batch-id=prof06 --profile=invalid
  [ "$status" -eq 1 ]
  [[ "$output" == *"Invalid --profile value"* ]]
}

# ---------------------------------------------------------------
# PROF-7: --profile + --delete fails
# ---------------------------------------------------------------
@test "PROF: --profile + --delete is rejected" {
  run bash "$VSTORM" -n --batch-id=prof07 --profile --delete=abc123
  [ "$status" -eq 1 ]
  [[ "$output" == *"Cannot use --profile with --delete or --delete-all"* ]]
}

# ---------------------------------------------------------------
# PROF-8: --profile + --delete-all fails
# ---------------------------------------------------------------
@test "PROF: --profile + --delete-all is rejected" {
  run bash "$VSTORM" -n --batch-id=prof08 --profile --delete-all
  [ "$status" -eq 1 ]
  [[ "$output" == *"Cannot use --profile with --delete or --delete-all"* ]]
}

# ---------------------------------------------------------------
# PROF-9: --profile=all dry-run shows normal VM creation output too
# ---------------------------------------------------------------
@test "PROF: --profile=all dry-run includes VM creation and profiling" {
  run bash "$VSTORM" -n --batch-id=prof09 --profile=all --vms=2 --namespaces=1
  [ "$status" -eq 0 ]
  [[ "$output" == *"(dry-run) Would start profiling before VM creation"* ]]
  [[ "$output" == *"Creating VirtualMachines"* ]]
  [[ "$output" == *"(dry-run) Would prompt to stop profiling and dump results"* ]]
}

