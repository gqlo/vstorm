#!/usr/bin/env bash
# Poll QEMU dirty-rate (MB/s) for a running KubeVirt VMI by exec'ing virsh inside
# the virt-launcher pod. Same monitor JSON as dirty-page.sh (local libvirt).
#
# Requires: oc (or kubectl), jq, cluster credentials, a Running VMI.
#
# Usage:
#   ./kubevirt-dirty-rate.sh [-n namespace] <vmi-name>
#   ./kubevirt-dirty-rate.sh [-n namespace] virt-launcher-...   # pod name also accepted
#   KUBEVIRT_NAMESPACE=my-ns ./kubevirt-dirty-rate.sh my-vmi
#
# Optional env:
#   CALC_TIME   seconds for calc-dirty-rate window (default: 1)
#   SAMPLE_GAP  sleep seconds between samples (default: 1.5)

set -euo pipefail

KUBECTL=""
if command -v oc &>/dev/null; then
  KUBECTL="oc"
elif command -v kubectl &>/dev/null; then
  KUBECTL="kubectl"
else
  echo "error: need oc or kubectl in PATH" >&2
  exit 1
fi

if ! command -v jq &>/dev/null; then
  echo "error: jq is required" >&2
  exit 1
fi

NS="${KUBEVIRT_NAMESPACE:-}"
VMI=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--namespace)
      NS="$2"
      shift 2
      ;;
    -h|--help)
      cat <<'EOF'
Poll QEMU dirty-rate (MB/s) for a running KubeVirt VMI (virsh inside virt-launcher).

Usage: kubevirt-dirty-rate.sh [-n namespace] <vmi-name|virt-launcher-pod>
       KUBEVIRT_NAMESPACE=ns kubevirt-dirty-rate.sh <vmi-name>

  <vmi-name>           VirtualMachineInstance name (oc get vmi)
  virt-launcher-...    full virt-launcher pod name if you prefer

Requires: oc or kubectl, jq, cluster access, Running VMI.

Env: CALC_TIME (default 1), SAMPLE_GAP (default 1.5)
EOF
      exit 0
      ;;
    -*)
      echo "unknown option: $1" >&2
      exit 1
      ;;
    *)
      VMI="$1"
      shift
      ;;
  esac
done

if [[ -z "${NS}" ]]; then
  NS="$(${KUBECTL} config view --minify -o jsonpath='{.contexts[0].context.namespace}' 2>/dev/null || true)"
fi
if [[ -z "${NS}" ]]; then
  NS="default"
fi

if [[ -z "${VMI}" ]]; then
  echo "usage: $0 [-n namespace] <vmi-name>" >&2
  echo "   or: KUBEVIRT_NAMESPACE=ns $0 <vmi-name>" >&2
  exit 1
fi

CALC_TIME="${CALC_TIME:-1}"
SAMPLE_GAP="${SAMPLE_GAP:-1.5}"

POD=""
VMI_LABEL=""

if [[ "${VMI}" == virt-launcher-* ]]; then
  pod_json="$(${KUBECTL} get pod -n "${NS}" "${VMI}" -o json 2>/dev/null || true)"
  if [[ -z "${pod_json}" ]]; then
    echo "error: pod '${VMI}' not found in namespace '${NS}'" >&2
    exit 1
  fi
  if [[ "$(echo "${pod_json}" | jq -r '.metadata.labels["kubevirt.io"] // empty')" != "virt-launcher" ]]; then
    echo "error: '${VMI}' is not a virt-launcher pod (check name and -n namespace)" >&2
    exit 1
  fi
  POD="${VMI}"
  VMI_LABEL="$(echo "${pod_json}" | jq -r '.metadata.labels["kubevirt.io/domain"] // .metadata.labels["kubevirt.io/vmi-name"] // "?"')"
else
  # Match kubevirt.io/domain or kubevirt.io/vmi-name (KubeVirt versions differ).
  POD="$(${KUBECTL} get pods -n "${NS}" -l kubevirt.io=virt-launcher -o json 2>/dev/null \
    | jq -r --arg v "${VMI}" \
      '.items[]
       | select(.metadata.labels["kubevirt.io/domain"] == $v
             or .metadata.labels["kubevirt.io/vmi-name"] == $v)
       | .metadata.name' \
    | head -1)"
  VMI_LABEL="${VMI}"
fi

if [[ -z "${POD}" ]]; then
  echo "error: no virt-launcher pod for VMI '${VMI}' in namespace '${NS}'" >&2
  echo "hint: pass the VMI name from: oc get vmi -n ${NS}" >&2
  echo "      or the pod name from: oc get pods -n ${NS} -l kubevirt.io=virt-launcher" >&2
  exit 1
fi

DOMAIN="$(${KUBECTL} exec -n "${NS}" "${POD}" -c compute -- virsh list --name 2>/dev/null | head -1 || true)"
if [[ -z "${DOMAIN}" ]]; then
  echo "error: virsh list --name returned no domain in pod ${POD}" >&2
  exit 1
fi

echo "# namespace=${NS} vmi=${VMI_LABEL} pod=${POD} domain=${DOMAIN} calc_time=${CALC_TIME}s" >&2

calc_json="$(printf '{"execute":"calc-dirty-rate","arguments":{"calc-time":%s,"mode":"dirty-bitmap"}}' "${CALC_TIME}")"
query_json='{"execute":"query-dirty-rate"}'

while true; do
  ${KUBECTL} exec -n "${NS}" "${POD}" -c compute -- \
    virsh qemu-monitor-command "${DOMAIN}" "${calc_json}" >/dev/null 2>&1 || true
  sleep "${SAMPLE_GAP}"
  rate="$(${KUBECTL} exec -n "${NS}" "${POD}" -c compute -- \
    virsh qemu-monitor-command "${DOMAIN}" "${query_json}" 2>/dev/null \
    | jq -r '.return["dirty-rate"] // empty')"
  echo "$(date '+%H:%M:%S') | ${rate} MB/s"
done
