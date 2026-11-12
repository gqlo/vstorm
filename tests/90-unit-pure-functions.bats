#!/usr/bin/env bats

# Fast unit tests that *source* vstorm and call individual functions directly,
# with no subprocess spawn and no mock-oc PATH shim. This is possible because
# vstorm guards its dispatch behind `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]`,
# so sourcing defines every function without parsing argv or touching a cluster.

setup() {
    # Sourcing runs vstorm's top-level env setup (globals, batch-id, colors)
    # but NOT run_cli, thanks to the source guard.
    source "$BATS_TEST_DIRNAME/../vstorm"
}

# ---------------------------------------------------------------
# join_name
# ---------------------------------------------------------------
@test "join_name joins non-empty parts with dashes" {
    run join_name a b c
    [ "$status" -eq 0 ]
    [ "$output" = "a-b-c" ]
}

@test "join_name skips empty parts (no leading/doubled dashes)" {
    run join_name "" base ""
    [ "$status" -eq 0 ]
    [ "$output" = "base" ]
}

@test "join_name of all-empty yields empty string" {
    run join_name "" ""
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

# ---------------------------------------------------------------
# validate_subnet
# ---------------------------------------------------------------
@test "validate_subnet accepts a valid IPv4 CIDR" {
    run validate_subnet "10.132.10.0/16"
    [ "$status" -eq 0 ]
}

@test "validate_subnet rejects a missing prefix length" {
    run validate_subnet "10.132.10.0"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Invalid --udn-l2"* ]]
}

@test "validate_subnet rejects an out-of-range prefix length" {
    run validate_subnet "10.0.0.0/33"
    [ "$status" -ne 0 ]
}

@test "validate_subnet rejects an empty value" {
    run validate_subnet ""
    [ "$status" -ne 0 ]
    [[ "$output" == *"non-empty IPv4 CIDR"* ]]
}

# ---------------------------------------------------------------
# validate_service_port
# ---------------------------------------------------------------
@test "validate_service_port accepts 22 and 65535" {
    run validate_service_port 22
    [ "$status" -eq 0 ]
    run validate_service_port 65535
    [ "$status" -eq 0 ]
}

@test "validate_service_port rejects 0, 65536, and non-numeric" {
    run validate_service_port 0
    [ "$status" -ne 0 ]
    run validate_service_port 65536
    [ "$status" -ne 0 ]
    run validate_service_port abc
    [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------
# parse_service_value (mutates globals)
# ---------------------------------------------------------------
@test "parse_service_value defaults to nodeport:22:22" {
    parse_service_value ""
    [ "$VM_SERVICE" -eq 1 ]
    [ "$VM_SERVICE_TYPE" = "nodeport" ]
    [ "$VM_SERVICE_PORT" -eq 22 ]
    [ "$VM_SERVICE_TARGET_PORT" -eq 22 ]
}

@test "parse_service_value parses clusterip:8080:80" {
    parse_service_value "clusterip:8080:80"
    [ "$VM_SERVICE_TYPE" = "clusterip" ]
    [ "$VM_SERVICE_PORT" -eq 8080 ]
    [ "$VM_SERVICE_TARGET_PORT" -eq 80 ]
}

@test "parse_service_value defaults target port to service port" {
    parse_service_value "nodeport:2222"
    [ "$VM_SERVICE_PORT" -eq 2222 ]
    [ "$VM_SERVICE_TARGET_PORT" -eq 2222 ]
}

@test "parse_service_value rejects an unknown type" {
    run parse_service_value "loadbalancer"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Invalid --service value"* ]]
}

# ---------------------------------------------------------------
# is_protected_delete_namespace
# ---------------------------------------------------------------
@test "is_protected_delete_namespace protects system namespaces" {
    for ns in kube-system kube-public default openshift-cnv kube-whatever; do
	run is_protected_delete_namespace "$ns"
	[ "$status" -eq 0 ]
    done
}

@test "is_protected_delete_namespace allows a user namespace" {
    run is_protected_delete_namespace "vstorm-abc123-ns-1"
    [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------
# is_vstorm_batch_namespace
# ---------------------------------------------------------------
@test "is_vstorm_batch_namespace matches current and legacy layouts" {
    run is_vstorm_batch_namespace "vstorm-abc123" "vstorm-abc123-ns-2"
    [ "$status" -eq 0 ]
    run is_vstorm_batch_namespace "4b2d1f" "vm-4b2d1f-ns-1"
    [ "$status" -eq 0 ]
}

@test "is_vstorm_batch_namespace rejects a non-matching namespace" {
    run is_vstorm_batch_namespace "vstorm-abc123" "other-ns-1"
    [ "$status" -ne 0 ]
    run is_vstorm_batch_namespace "" "vstorm-abc123-ns-1"
    [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------
# parse_bool_flag
# ---------------------------------------------------------------
@test "parse_bool_flag treats a bare flag (empty value) as true" {
    local v=9
    parse_bool_flag v "" "--wait"
    [ "$v" -eq 1 ]
}

@test "parse_bool_flag accepts truthy synonyms" {
    local v
    for syn in 1 true yes on TRUE Yes ON; do
	v=0; parse_bool_flag v "$syn" "--wait"; [ "$v" -eq 1 ]
    done
}

@test "parse_bool_flag accepts falsy synonyms" {
    local v
    for syn in 0 false no off FALSE No OFF; do
	v=1; parse_bool_flag v "$syn" "--wait"; [ "$v" -eq 0 ]
    done
}

@test "parse_bool_flag rejects an invalid value with the flag name" {
    local v
    run parse_bool_flag v "bogus" "--wait"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Invalid --wait value 'bogus'"* ]]
}

# ---------------------------------------------------------------
# derive_defaults (basename/pvc derivation)
# ---------------------------------------------------------------
@test "derive_defaults derives basename and pvc name from datasource" {
    DATASOURCE="rhel9"
    BASENAME_SET=0
    PVC_BASE_NAME_SET=0
    derive_defaults
    [ "$VM_BASENAME" = "rhel9" ]
    [ "$BASE_PVC_NAME" = "rhel9-base" ]
}

@test "derive_defaults derives basename from containerdisk image" {
    CONTAINERDISK_IMAGE="quay.io/containerdisks/fedora:latest"
    DATASOURCE=""
    BASENAME_SET=0
    derive_defaults
    [ "$VM_BASENAME" = "fedora" ]
}
