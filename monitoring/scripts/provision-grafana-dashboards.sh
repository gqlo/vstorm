#!/usr/bin/env bash
# Provision Grafana dashboards from ConfigMaps so they persist across pod restarts.
# Usage: provision-grafana-dashboards.sh [namespace] [dashboard1.json [dashboard2.json ...]]
#   namespace  Optional first arg if it does not end in .json. Default: dittybopper
#   *.json     Optional. Create one ConfigMap from all and mount at provisioning path.

set -e

DEPLOYMENT="dittybopper"
CONTAINER="dittybopper"
PROVIDER_NAME="grafana-dashboards-provider"
DASHBOARDS_CM="grafana-dashboards-default"
PROVIDER_MOUNT="/etc/grafana/provisioning/dashboards"
DEFAULT_MOUNT="/etc/grafana/provisioning/dashboards/default"

# Parse args: [namespace] [file1.json [file2.json ...]]
NAMESPACE="dittybopper"
FILES=()
if [[ $# -gt 0 && "$1" != *.json ]]; then
  NAMESPACE="$1"
  shift
fi
FILES=("$@")

has_volume() {
  oc get "deployment/${DEPLOYMENT}" -n "${NAMESPACE}" -o jsonpath='{.spec.template.spec.volumes[*].name}' \
    | tr ' ' '\n' | grep -q "^${1}$"
}

# Check if any container already has this mount path (e.g. from a previous run with different volume name)
has_mount_path() {
  oc get "deployment/${DEPLOYMENT}" -n "${NAMESPACE}" -o jsonpath='{.spec.template.spec.containers[*].volumeMounts[*].mountPath}' \
    | tr ' ' '\n' | grep -q "^${1}$"
}

# Get the volume name that is mounted at the given path (so we can remove it regardless of name)
volume_name_for_mount_path() {
  oc get "deployment/${DEPLOYMENT}" -n "${NAMESPACE}" -o json \
    | jq -r --arg path "$1" '
        .spec.template.spec.containers[]? | select(.volumeMounts != null) | .volumeMounts[] | select(.mountPath == $path) | .name
      ' | head -1
}

# 1. Provider ConfigMap
oc apply -f - << EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${PROVIDER_NAME}
  namespace: ${NAMESPACE}
data:
  dashboards.yaml: |
    apiVersion: 1
    providers:
      - name: 'default'
        orgId: 1
        folder: ''
        type: file
        options:
          path: ${DEFAULT_MOUNT}
EOF

# 2. Add provider volume if missing
if ! has_volume "${PROVIDER_NAME}"; then
  oc set volume "deployment/${DEPLOYMENT}" -n "${NAMESPACE}" \
    --add --name="${PROVIDER_NAME}" --type=configmap \
    --configmap-name="${PROVIDER_NAME}" --mount-path="${PROVIDER_MOUNT}" -c "${CONTAINER}"
fi

# 3. Optional: create dashboards ConfigMap from JSON file(s) and add volume
DASHBOARDS_UPDATED=false
if [[ ${#FILES[@]} -gt 0 ]]; then
  for f in "${FILES[@]}"; do
    [[ -f "$f" ]] || { echo "Not a file: $f" >&2; exit 1; }
  done
  # Remove previous mount and ConfigMap so we use the new one cleanly (remove by mount path in case volume has a different name)
  existing_vol=$(volume_name_for_mount_path "${DEFAULT_MOUNT}")
  if [[ -n "${existing_vol}" ]]; then
    oc set volume "deployment/${DEPLOYMENT}" -n "${NAMESPACE}" --remove --name="${existing_vol}"
  fi
  oc delete configmap "${DASHBOARDS_CM}" -n "${NAMESPACE}" --ignore-not-found
  # Create new ConfigMap from JSON file(s)
  from_file_args=()
  for f in "${FILES[@]}"; do from_file_args+=(--from-file="$f"); done
  oc create configmap "${DASHBOARDS_CM}" "${from_file_args[@]}" -n "${NAMESPACE}" --dry-run=client -o yaml | oc apply -f -
  DASHBOARDS_UPDATED=true
  # Add volume for the new ConfigMap
  oc set volume "deployment/${DEPLOYMENT}" -n "${NAMESPACE}" \
    --add --name="${DASHBOARDS_CM}" --type=configmap --configmap-name="${DASHBOARDS_CM}" \
    --mount-path="${DEFAULT_MOUNT}" -c "${CONTAINER}"
fi

# When ConfigMap was updated, restart deployment so the pod picks up the new dashboard JSON
if [[ "${DASHBOARDS_UPDATED}" == true ]]; then
  oc rollout restart "deployment/${DEPLOYMENT}" -n "${NAMESPACE}"
fi
oc rollout status "deployment/${DEPLOYMENT}" -n "${NAMESPACE}" --timeout=120s
