#!/usr/bin/env bats

# Unit tests for vstorm UDN (User Defined Network) feature
# Run with: bats tests/14-udn.bats

load 'helpers'

VSTORM="./vstorm"

setup_file() {
    setup_oc_mock
}

# ===============================================================
# Category 14: Standalone VM Service
# ===============================================================

# ---------------------------------------------------------------
# Standalone --service without --udn-l2
# ---------------------------------------------------------------
@test "UDN: --service works without --udn-l2" {
  run bash "$VSTORM" -n --batch-id=udnsvc1 --service --vms=1 --namespaces=1
  [ "$status" -eq 0 ]
  [[ "$output" == *"kind: Service"* ]]
  [[ "$output" == *"Service: enabled (NodePort"* ]]
}

# ===============================================================
# Category 14: Validation / error handling (ERR-UDN-2 through ERR-UDN-7)
# ===============================================================

# ---------------------------------------------------------------
# ERR-UDN-2: invalid --service value
# ---------------------------------------------------------------
@test "ERR: invalid --service value rejected" {
  run bash "$VSTORM" -n --batch-id=udnerr2 --udn-l2 --service=invalid \
    --vms=1 --namespaces=1
  [ "$status" -ne 0 ]
  [[ "$output" == *"Invalid --service value 'invalid'"* ]]
  [[ "$output" == *"use TYPE[:PORT[:TARGET_PORT]]"* ]]
}

# ---------------------------------------------------------------
# ERR-UDN-2b: invalid --service port
# ---------------------------------------------------------------
@test "ERR: invalid --service port rejected" {
  run bash "$VSTORM" -n --batch-id=udnerr2b --udn-l2 --service=nodeport:70000 \
    --vms=1 --namespaces=1
  [ "$status" -ne 0 ]
  [[ "$output" == *"Invalid port '70000'"* ]]
}

# ---------------------------------------------------------------
# ERR-UDN-3: invalid --udn-l2 CIDR format
# ---------------------------------------------------------------
@test "ERR: invalid --udn-l2 CIDR format rejected" {
  run bash "$VSTORM" -n --batch-id=udnerr3 --udn-l2=not-a-cidr \
    --vms=1 --namespaces=1
  [ "$status" -ne 0 ]
  [[ "$output" == *"Invalid --udn-l2='not-a-cidr'"* ]]
}

# ---------------------------------------------------------------
# ERR-UDN-4: --udn-l2 prefix out of range
# ---------------------------------------------------------------
@test "ERR: --udn-l2 prefix out of range rejected" {
  run bash "$VSTORM" -n --batch-id=udnerr4 --udn-l2=10.0.0.0/33 \
    --vms=1 --namespaces=1
  [ "$status" -ne 0 ]
  [[ "$output" == *"Invalid --udn-l2='10.0.0.0/33'"* ]]
}

# ---------------------------------------------------------------
# ERR-UDN-5: missing udn-l2 template
# ---------------------------------------------------------------
@test "ERR: missing udn-l2 template fails with --udn-l2" {
  local tmpdir
  tmpdir=$(mktemp -d)
  cp "$BATS_TEST_DIRNAME/../vstorm" "$tmpdir/vstorm"
  chmod +x "$tmpdir/vstorm"
  mkdir "$tmpdir/templates"
  cp templates/namespace.yaml templates/vm-clone.yaml templates/dv.yaml \
    "$tmpdir/templates/"
  run bash "$tmpdir/vstorm" -n --batch-id=udnerr5 --udn-l2 \
    --vms=1 --namespaces=1 --dv-url=http://example.com/disk.qcow --no-snapshot
  [ "$status" -ne 0 ]
  [[ "$output" == *"No udn-l2 template found"* ]]
  rm -rf "$tmpdir"
}

# ---------------------------------------------------------------
# ERR-UDN-6: missing vm-udn template
# ---------------------------------------------------------------
@test "ERR: missing vm-udn template fails with --udn-l2" {
  local tmpdir
  tmpdir=$(mktemp -d)
  cp "$BATS_TEST_DIRNAME/../vstorm" "$tmpdir/vstorm"
  chmod +x "$tmpdir/vstorm"
  mkdir "$tmpdir/templates"
  cp templates/namespace.yaml templates/udn-l2.yaml templates/vm-clone.yaml \
    templates/dv.yaml "$tmpdir/templates/"
  run bash "$tmpdir/vstorm" -n --batch-id=udnerr6 --udn-l2 \
    --vms=1 --namespaces=1 --dv-url=http://example.com/disk.qcow --no-snapshot
  [ "$status" -ne 0 ]
  [[ "$output" == *"No vm-udn template found"* ]]
  rm -rf "$tmpdir"
}

# ---------------------------------------------------------------
# ERR-UDN-7: missing service template
# ---------------------------------------------------------------
@test "ERR: missing service template fails with --service" {
  local tmpdir
  tmpdir=$(mktemp -d)
  cp "$BATS_TEST_DIRNAME/../vstorm" "$tmpdir/vstorm"
  chmod +x "$tmpdir/vstorm"
  mkdir "$tmpdir/templates"
  cp templates/namespace.yaml templates/udn-l2.yaml templates/vm-clone.yaml \
    templates/vm-clone-udn.yaml templates/dv.yaml "$tmpdir/templates/"
  run bash "$tmpdir/vstorm" -n --batch-id=udnerr7 --service \
    --vms=1 --namespaces=1 --dv-url=http://example.com/disk.qcow --no-snapshot
  [ "$status" -ne 0 ]
  [[ "$output" == *"No vm-service template found"* ]]
  rm -rf "$tmpdir"
}

# ===============================================================
# Category 14: Core UDN L2 YAML (UDN-1 through UDN-6)
# ===============================================================

# ---------------------------------------------------------------
# UDN-1: --udn-l2 creates UserDefinedNetwork per namespace
# ---------------------------------------------------------------
@test "UDN: creates UserDefinedNetwork per namespace with default subnet" {
  run bash "$VSTORM" -n --batch-id=udn001 --udn-l2 --vms=2 --namespaces=2
  [ "$status" -eq 0 ]

  local udn_count
  udn_count=$(echo "$output" | grep -c "kind: UserDefinedNetwork")
  [ "$udn_count" -eq 2 ]

  [[ "$output" == *"topology: Layer2"* ]]
  [[ "$output" == *"role: Primary"* ]]
  [[ "$output" == *'subnets: ["10.132.10.0/16"]'* ]]
  [[ "$output" == *"k8s.ovn.org/primary-user-defined-network"* ]]
  [[ "$output" == *"name: l2-network-udn001"* ]]
  [[ "$output" == *"UDN L2: enabled (subnet: 10.132.10.0/16)"* ]]
}

# ---------------------------------------------------------------
# UDN-2: custom --udn-l2 CIDR
# ---------------------------------------------------------------
@test "UDN: custom --udn-l2 CIDR appears in UDN CR and summary" {
  run bash "$VSTORM" -n --batch-id=udn002 --udn-l2=10.200.0.0/16 \
    --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  [[ "$output" == *'subnets: ["10.200.0.0/16"]'* ]]
  [[ "$output" == *"UDN L2: enabled (subnet: 10.200.0.0/16)"* ]]
}

# ---------------------------------------------------------------
# UDN-3: VM uses l2bridge interface, not masquerade
# ---------------------------------------------------------------
@test "UDN: VM uses l2bridge interface instead of masquerade" {
  run bash "$VSTORM" -n --batch-id=udn003 --udn-l2 --vms=2 --namespaces=2
  [ "$status" -eq 0 ]

  [[ "$output" == *"name: l2bridge"* ]]
  [[ "$output" == *"primary-udn-net"* ]]
  [[ "$output" != *"masquerade"* ]]
}

# ---------------------------------------------------------------
# UDN-4: --udn-l2 with containerdisk
# ---------------------------------------------------------------
@test "UDN: containerdisk mode uses UDN VM template" {
  run bash "$VSTORM" -n --batch-id=udn004 --udn-l2 --containerdisk \
    --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  [[ "$output" == *"kind: UserDefinedNetwork"* ]]
  [[ "$output" == *"name: l2bridge"* ]]
  [[ "$output" == *"containerDisk:"* ]]
  # Root is containerDisk; blank data disk is opt-in via --data-disk-size
  [[ "$output" != *"blank: {}"* ]]
  [[ "$output" != *"name: vdb"* ]]
}

# ---------------------------------------------------------------
# UDN-5: --udn-l2 with direct DataSource clone (no snapshot)
# ---------------------------------------------------------------
@test "UDN: no-snapshot DataSource clone uses UDN VM template" {
  run bash "$VSTORM" -n --batch-id=udn005 --udn-l2 --no-snapshot \
    --datasource=rhel9 --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  [[ "$output" == *"kind: UserDefinedNetwork"* ]]
  [[ "$output" == *"name: l2bridge"* ]]
  [[ "$output" == *"sourceRef"* ]]
  [[ "$output" == *"kind: DataSource"* ]]
  [[ "$output" != *"kind: VolumeSnapshot"* ]]
}

# ---------------------------------------------------------------
# UDN-6: without UDN flags, default networking is unchanged
# ---------------------------------------------------------------
@test "UDN: without --udn-l2, default masquerade networking is used" {
  run bash "$VSTORM" -n --batch-id=udn006 --datasource=rhel9 \
    --vms=1 --namespaces=1 --no-snapshot
  [ "$status" -eq 0 ]

  [[ "$output" != *"kind: UserDefinedNetwork"* ]]
  [[ "$output" != *"l2bridge"* ]]
  [[ "$output" == *"masquerade"* ]]
  [[ "$output" == *"UDN L2: disabled"* ]]
}

# ===============================================================
# Category 14: Cloud-init networkData (UDN-7 through UDN-9)
# ===============================================================

# ---------------------------------------------------------------
# UDN-7: auto cloud-init with containerdisk includes networkData
# ---------------------------------------------------------------
@test "UDN: auto cloud-init includes DHCP networkData" {
  run bash "$VSTORM" -n --batch-id=udn007 --udn-l2 --containerdisk \
    --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  [[ "$output" == *"networkData:"* ]]
  [[ "$output" == *"dhcp4: true"* ]]
  [[ "$output" == *"name: e* # Matches eth0"* ]]
}

# ---------------------------------------------------------------
# UDN-8: explicit cloud-init with UDN includes networkData
# ---------------------------------------------------------------
@test "UDN: explicit cloud-init includes DHCP networkData" {
  run bash "$VSTORM" -n --batch-id=udn008 --udn-l2 \
    --cloudinit=workload/stress-ng/cloudinit-stress-ng-workload.yaml \
    --datasource=rhel9 --no-snapshot --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  [[ "$output" == *"networkData:"* ]]
  [[ "$output" == *"dhcp4: true"* ]]
  [[ "$output" == *"stress-ng"* ]]
}

# ---------------------------------------------------------------
# UDN-9: dv-url without --cloudinit still gets default profile + UDN networkData
# ---------------------------------------------------------------
@test "UDN: dv-url without cloud-init applies default profile with networkData" {
  run bash "$VSTORM" -n --batch-id=udn009 --udn-l2 \
    --dv-url=http://example.com/disk.qcow --no-snapshot \
    --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  [[ "$output" == *"name: l2bridge"* ]]
  [[ "$output" == *"applying default cloud-init"* ]]
  [[ "$output" == *"networkData:"* ]]
  [[ "$output" == *"dhcp4: true"* ]]
}

# ===============================================================
# Category 14: UDN services (UDN-10 through UDN-15)
# ===============================================================

# ---------------------------------------------------------------
# UDN-10: NodePort services per namespace (default port 22)
# ---------------------------------------------------------------
@test "UDN: NodePort service created per namespace with default port 22" {
  run bash "$VSTORM" -n --batch-id=udn010 --udn-l2 --service \
    --vms=2 --namespaces=2
  [ "$status" -eq 0 ]

  local svc_count
  svc_count=$(echo "$output" | grep -c "kind: Service")
  [ "$svc_count" -eq 2 ]

  [[ "$output" == *"type: NodePort"* ]]
  [[ "$output" == *"port: 22"* ]]
  [[ "$output" == *"targetPort: 22"* ]]
  [[ "$output" == *"nodePort: 32222"* ]]
  [[ "$output" == *"nodePort: 32223"* ]]
  [[ "$output" == *"kubevirt.io/domain: udn010"* ]]
  [[ "$output" == *"Creating NodePort Service"* ]]
  [[ "$output" == *"Service: enabled (NodePort, port 22"* ]]
}

# ---------------------------------------------------------------
# UDN-11: ClusterIP service (default port 22)
# ---------------------------------------------------------------
@test "UDN: ClusterIP service has no nodePort" {
  run bash "$VSTORM" -n --batch-id=udn011 --udn-l2 --service=clusterip \
    --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  [[ "$output" == *"type: ClusterIP"* ]]
  [[ "$output" == *"name: svc-clusterip-udn011"* ]]
  [[ "$output" == *"port: 22"* ]]
  [[ "$output" == *"Creating ClusterIP Service"* ]]
  [[ "$output" == *"Service: enabled (ClusterIP, port 22)"* ]]
  [[ "$output" != *"nodePort:"* ]]
}

# ---------------------------------------------------------------
# UDN-12: NodePort allocation logged per namespace
# ---------------------------------------------------------------
@test "UDN: NodePort service ports auto-increment per namespace" {
  run bash "$VSTORM" -n --batch-id=udn012 --udn-l2 --service \
    --vms=2 --namespaces=2
  [ "$status" -eq 0 ]

  [[ "$output" == *"Creating NodePort Service svc-nodeport-udn012 on nodePort 32222 (port 22)"* ]]
  [[ "$output" == *"Creating NodePort Service svc-nodeport-udn012 on nodePort 32223 (port 22)"* ]]
}

# ---------------------------------------------------------------
# UDN-13: ClusterIP service naming matches in-cluster hostname pattern
# ---------------------------------------------------------------
@test "UDN: ClusterIP service name matches in-cluster hostname pattern" {
  run bash "$VSTORM" -n --batch-id=udn013 --udn-l2 --service=clusterip \
    --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  [[ "$output" == *"name: svc-clusterip-udn013"* ]]
  [[ "$output" == *"namespace: udn013-ns-1"* ]]
  [[ "$output" == *"Creating ClusterIP Service svc-clusterip-udn013"* ]]
}

# ---------------------------------------------------------------
# UDN-14: without --service, no Service resources
# ---------------------------------------------------------------
@test "UDN: without --service, no Service is created" {
  run bash "$VSTORM" -n --batch-id=udn014 --udn-l2 --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  [[ "$output" != *"kind: Service"* ]]
  [[ "$output" == *"Service: disabled"* ]]
}

# ---------------------------------------------------------------
# UDN-15: custom service port
# ---------------------------------------------------------------
@test "UDN: custom --service port appears in Service spec" {
  run bash "$VSTORM" -n --batch-id=udn015 --udn-l2 --service=nodeport:8080 \
    --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  [[ "$output" == *"port: 8080"* ]]
  [[ "$output" == *"targetPort: 8080"* ]]
  [[ "$output" == *"Service: enabled (NodePort, port 8080"* ]]
}

# ---------------------------------------------------------------
# UDN-16: service port and targetPort differ
# ---------------------------------------------------------------
@test "UDN: --service=nodeport:22:2222 sets port and targetPort separately" {
  run bash "$VSTORM" -n --batch-id=udn016 --udn-l2 --service=nodeport:22:2222 \
    --vms=1 --namespaces=1
  [ "$status" -eq 0 ]

  [[ "$output" == *"port: 22"* ]]
  [[ "$output" == *"targetPort: 2222"* ]]
  [[ "$output" == *"Service: enabled (NodePort, port 22 -> targetPort 2222"* ]]
  [[ "$output" == *"port 22 -> targetPort 2222"* ]]
}
