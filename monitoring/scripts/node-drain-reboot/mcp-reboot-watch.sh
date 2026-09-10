#!/usr/bin/env bash
# Trigger MCP reboot/drain and poll worker nodes until each node completes drain/reboot.
#
# Two independent tracks (polled every INTERVAL seconds; ACTIVE_INTERVAL during drain):
#
# Node track (drives CSV rows):
#   drain_seconds  — cordon until drain done (NodeNotSchedulable → NodeNotReady)
#   boot_seconds   — drain done until boot done (NodeNotReady → NodeSchedulable)
#   per_node_total_duration_seconds — cordoned_ts → boot_done_ts
#   node_start_time / node_end_time — cordoned_ts / boot_done_ts
#   CSV row written as soon as all three poll milestones exist (no MCN gate).
#
# MCP track (exit gate):
#   Wait until mcp/$MCP has Updating=False, Updated=True, and updatedMachineCount≥machineCount.
#
# MCN track (logged only; does not gate CSV or exit):
#   Rollout start when desired≠current or Updated=False; completion on UPDATED=True.
#
# Pool summary (ALL_NODES row): earliest/latest node_start_time / node_end_time across CSV rows.
# data_source per row: observed | inferred | mixed (poll); evt_* columns from cluster events.
# All timestamp columns and log prefixes use UTC (RFC3339 Z).
#
# Phase timestamps are collected two ways: node-object polling (primary CSV columns) and
# Kubernetes Node/MCD events (evt_* columns). Raw events append to EVENTS_FILE (TSV, deduped
# by uid+timestamp; K8s recycles Event uids when the same reason fires again on a node).
# Rook ceph-operator pod logs append to CEPH_OPERATOR_LOG_FILE (new lines only per poll).
#
# Auth: by default the script applies mcp-reboot-watch-rbac.yaml (first run needs
# oc login with cluster-admin), mints a long-lived SA token, and writes
# mcp-reboot-watch.kubeconfig beside this script. Override with MCP_WATCH_USE_ENV_KUBECONFIG=1.
#
# Usage:
#   ./mcp-reboot-watch.sh
#   MCP=worker INTERVAL=5 ./mcp-reboot-watch.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

readonly MCP="${MCP:-worker}"
readonly INTERVAL="${INTERVAL:-5}"
readonly ACTIVE_INTERVAL="${ACTIVE_INTERVAL:-2}"
readonly RUN_TS="$(date -u +%Y%m%d-%H%M%S)"
LOG_FILE="${LOG_FILE:-mcp-reboot-watch-${MCP}-${RUN_TS}.log}"
CSV_FILE="${CSV_FILE:-mcp-reboot-watch-${MCP}-${RUN_TS}.csv}"
EVENTS_FILE="${EVENTS_FILE:-mcp-reboot-watch-${MCP}-${RUN_TS}.events.tsv}"
CEPH_OPERATOR_LOG_FILE="${CEPH_OPERATOR_LOG_FILE:-mcp-reboot-watch-${MCP}-${RUN_TS}.ceph-operator.log}"
readonly CEPH_OPERATOR_LOGS="${CEPH_OPERATOR_LOGS:-1}"
readonly CEPH_NAMESPACE="${CEPH_NAMESPACE:-openshift-storage}"
readonly CEPH_POD_LABEL="${CEPH_POD_LABEL:-app=rook-ceph-operator}"
readonly SA_NAMESPACE="${SA_NAMESPACE:-vstorm-node-drain}"
readonly SA_NAME="${SA_NAME:-mcp-reboot-watch}"
readonly SA_TOKEN_DURATION="${SA_TOKEN_DURATION:-168h}"
readonly RBAC_FILE="${RBAC_FILE:-${SCRIPT_DIR}/mcp-reboot-watch-rbac.yaml}"
readonly SA_KUBECONFIG="${SA_KUBECONFIG:-${SCRIPT_DIR}/mcp-reboot-watch.kubeconfig}"

declare -A node_csv_written=()
declare -A node_phase_tracking_init=()
declare -A mcn_start_epoch=()
declare -A mcn_finished=()
declare -A node_milestone_iso=()
declare -A node_milestone_source=()
declare -A node_event_milestone_iso=()
declare -A node_duration_secs=()
declare -A node_end_epoch=()
declare -A node_drain_secs=()
declare -A node_boot_secs=()
declare -A node_prev_unschedulable=()
declare -A node_prev_ready=()
declare -A node_initial_unschedulable=()
declare -A seen_event_keys=()
declare -A ceph_operator_pod_lines=()
declare -A ceph_operator_previous_saved=()
declare -a worker_nodes=()

TARGET_CFG=""
ceph_operator_current_pod=""

# All persisted timestamps (CSV, events TSV, milestones) use UTC (RFC3339 Z).

now_utc_iso() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

epoch_to_iso() {
  date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -r "$1" '+%Y-%m-%dT%H:%M:%SZ'
}

iso_to_epoch() {
  date -u -d "$1" +%s 2>/dev/null
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  exec > >(tee -a "$LOG_FILE") 2>&1
  printf '%s Logging to %s\n' "$(now_utc_iso)" "$LOG_FILE"
  printf '%s Per-node timing CSV: %s\n' "$(now_utc_iso)" "$CSV_FILE"
  printf '%s Node events TSV: %s\n' "$(now_utc_iso)" "$EVENTS_FILE"
  if [[ "$CEPH_OPERATOR_LOGS" == "1" ]]; then
    printf '%s Ceph operator log: %s\n' "$(now_utc_iso)" "$CEPH_OPERATOR_LOG_FILE"
  fi
fi

require_jq() {
  if ! command -v jq &>/dev/null; then
    printf '%s ERROR: jq is required\n' "$(now_utc_iso)"
    exit 1
  fi
}

require_oc() {
  if ! command -v oc &>/dev/null; then
    printf '%s ERROR: oc is required\n' "$(now_utc_iso)"
    exit 1
  fi
}

oc_auth_can_i() {
  local verb="$1" resource="$2" namespace="${3:-}" answer

  if [[ -n "$namespace" ]]; then
    answer="$(oc auth can-i "$verb" "$resource" -n "$namespace" 2>/dev/null || true)"
  else
    answer="$(oc auth can-i "$verb" "$resource" 2>/dev/null || true)"
  fi
  [[ "$answer" == yes ]]
}

verify_sa_permissions() {
  local missing=()

  oc_auth_can_i get machineconfigpools || missing+=('get machineconfigpools')
  oc_auth_can_i patch machineconfigpools || missing+=('patch machineconfigpools')
  oc_auth_can_i get machineconfignodes || missing+=('get machineconfignodes')
  oc_auth_can_i get machineconfigs || missing+=('get machineconfigs')
  oc_auth_can_i create machineconfigs || missing+=('create machineconfigs')
  oc_auth_can_i get nodes || missing+=('get nodes')
  oc_auth_can_i list events || missing+=('list events')

  if [[ "$CEPH_OPERATOR_LOGS" == "1" ]]; then
    oc_auth_can_i get pods "$CEPH_NAMESPACE" || missing+=("get pods -n ${CEPH_NAMESPACE}")
    oc_auth_can_i get pods/log "$CEPH_NAMESPACE" || missing+=("get pods/log -n ${CEPH_NAMESPACE}")
  fi

  if (( ${#missing[@]} > 0 )); then
    printf '%s ERROR: missing API permissions: %s\n' "$(now_utc_iso)" "${missing[*]}"
    return 1
  fi
  return 0
}

verify_oc_session() {
  if oc whoami &>/dev/null; then
    return 0
  fi
  printf '%s ERROR: API credentials expired — re-run script (oc login admin refreshes SA token)\n' \
    "$(now_utc_iso)"
  exit 1
}

create_sa_token() {
  local duration="$1" token

  token="$(oc create token "$SA_NAME" -n "$SA_NAMESPACE" --duration="$duration" 2>/dev/null || true)"
  [[ -n "$token" ]] || return 1
  printf '%s' "$token"
}

cluster_ca_pem_to_data() {
  local ca_pem="$1"

  [[ -n "$ca_pem" ]] || return 1
  if printf '%s' "$ca_pem" | base64 -w0 2>/dev/null; then
    return 0
  fi
  printf '%s' "$ca_pem" | base64 | tr -d '\n'
}

cluster_ca_from_api() {
  local ca_pem ns

  for ns in openshift-config-managed kube-public; do
    ca_pem="$(oc get configmap kube-root-ca.crt -n "$ns" -o jsonpath='{.data.ca\.crt}' 2>/dev/null || true)"
    [[ -n "$ca_pem" ]] || continue
    cluster_ca_pem_to_data "$ca_pem"
    return 0
  done
  return 1
}

cluster_ca_from_kubeconfig() {
  local ca_data ca_file insecure cluster_name

  cluster_name="$(oc config view --minify -o jsonpath='{.contexts[0].context.cluster}' 2>/dev/null || true)"
  if [[ -n "$cluster_name" ]]; then
    ca_data="$(oc config view --raw -o jsonpath="{.clusters[?(@.name==\"${cluster_name}\")].cluster.certificate-authority-data}" 2>/dev/null | head -1 || true)"
    if [[ -n "$ca_data" ]]; then
      printf '%s' "$ca_data"
      return 0
    fi

    ca_file="$(oc config view --raw -o jsonpath="{.clusters[?(@.name==\"${cluster_name}\")].cluster.certificate-authority}" 2>/dev/null | head -1 || true)"
    if [[ -n "$ca_file" && -r "$ca_file" ]]; then
      if base64 -w0 "$ca_file" 2>/dev/null; then
        return 0
      fi
      base64 "$ca_file" | tr -d '\n'
      return 0
    fi

    insecure="$(oc config view --raw -o jsonpath="{.clusters[?(@.name==\"${cluster_name}\")].cluster.insecure-skip-tls-verify}" 2>/dev/null | head -1 || true)"
    if [[ "$insecure" == "true" ]]; then
      printf 'INSECURE'
      return 0
    fi
  fi

  ca_data="$(oc config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' 2>/dev/null || true)"
  if [[ -n "$ca_data" ]]; then
    printf '%s' "$ca_data"
    return 0
  fi

  ca_file="$(oc config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority}' 2>/dev/null || true)"
  if [[ -n "$ca_file" && -r "$ca_file" ]]; then
    if base64 -w0 "$ca_file" 2>/dev/null; then
      return 0
    fi
    base64 "$ca_file" | tr -d '\n'
    return 0
  fi

  insecure="$(oc config view --minify --raw -o jsonpath='{.clusters[0].cluster.insecure-skip-tls-verify}' 2>/dev/null || true)"
  if [[ "$insecure" == "true" ]]; then
    printf 'INSECURE'
    return 0
  fi

  cluster_ca_from_api
}

write_sa_kubeconfig() {
  local token="$1" server ca_data tmp cluster_block

  server="$(oc whoami --show-server 2>/dev/null || true)"
  ca_data="$(cluster_ca_from_kubeconfig || true)"
  if [[ -z "$server" || -z "$token" ]]; then
    printf '%s ERROR: cannot build SA kubeconfig (server=%s token=%s)\n' \
      "$(now_utc_iso)" "${server:-missing}" "$([[ -n "$token" ]] && printf present || printf missing)"
    return 1
  fi
  if [[ -z "$ca_data" ]]; then
    printf '%s ERROR: no cluster CA found (kubeconfig has no CA; kube-root-ca.crt lookup failed)\n' \
      "$(now_utc_iso)"
    return 1
  fi

  if [[ "$ca_data" == "INSECURE" ]]; then
    cluster_block="$(cat <<EOF
    server: ${server}
    insecure-skip-tls-verify: true
EOF
)"
  else
    cluster_block="$(cat <<EOF
    server: ${server}
    certificate-authority-data: ${ca_data}
EOF
)"
  fi

  tmp="$(mktemp)"
  cat >"$tmp" <<EOF
apiVersion: v1
kind: Config
clusters:
- name: cluster
  cluster:
${cluster_block}
users:
- name: ${SA_NAME}
  user:
    token: ${token}
contexts:
- name: ${SA_NAME}
  context:
    cluster: cluster
    user: ${SA_NAME}
    namespace: ${SA_NAMESPACE}
current-context: ${SA_NAME}
EOF
  if ! install -m 600 "$tmp" "$SA_KUBECONFIG"; then
    rm -f "$tmp"
    printf '%s ERROR: install failed writing %s (check directory permissions)\n' \
      "$(now_utc_iso)" "$SA_KUBECONFIG"
    return 1
  fi
  rm -f "$tmp"
  return 0
}

bootstrap_sa_kubeconfig() {
  local duration token durations tried=()

  if [[ ! -f "$RBAC_FILE" ]]; then
    printf '%s ERROR: RBAC manifest missing: %s\n' "$(now_utc_iso)" "$RBAC_FILE"
    exit 1
  fi

  printf '%s Applying RBAC: %s\n' "$(now_utc_iso)" "$RBAC_FILE"
  if ! oc apply -f "$RBAC_FILE"; then
    printf '%s ERROR: oc apply failed — cluster-admin required for first-time setup\n' \
      "$(now_utc_iso)"
    exit 1
  fi

  token=""
  for duration in "$SA_TOKEN_DURATION" 168h 72h 24h 8h 1h; do
    tried+=("$duration")
    if token="$(create_sa_token "$duration")"; then
      printf '%s Minted SA token for %s/%s (duration=%s)\n' \
        "$(now_utc_iso)" "$SA_NAMESPACE" "$SA_NAME" "$duration"
      break
    fi
  done

  if [[ -z "$token" ]]; then
    printf '%s ERROR: oc create token failed (tried durations: %s)\n' \
      "$(now_utc_iso)" "${tried[*]}"
    exit 1
  fi

  if ! write_sa_kubeconfig "$token"; then
    exit 1
  fi

  export KUBECONFIG="$SA_KUBECONFIG"
  if ! verify_sa_permissions; then
    exit 1
  fi
  printf '%s SA kubeconfig ready: %s (%s)\n' \
    "$(now_utc_iso)" "$SA_KUBECONFIG" "$(oc whoami)"
}

setup_oc_auth() {
  local default_kubeconfig="$HOME/.kube/config"
  local bootstrap_kubeconfig="${KUBECONFIG:-$default_kubeconfig}"

  if [[ "${MCP_WATCH_USE_ENV_KUBECONFIG:-0}" == "1" ]]; then
    if ! oc whoami &>/dev/null; then
      printf '%s ERROR: MCP_WATCH_USE_ENV_KUBECONFIG=1 but oc whoami failed\n' "$(now_utc_iso)"
      exit 1
    fi
    if ! verify_sa_permissions; then
      exit 1
    fi
    printf '%s Using environment KUBECONFIG (%s)\n' "$(now_utc_iso)" "$(oc whoami)"
    return 0
  fi

  if [[ -f "$SA_KUBECONFIG" ]]; then
    KUBECONFIG="$SA_KUBECONFIG"
    if oc whoami &>/dev/null && verify_sa_permissions; then
      export KUBECONFIG="$SA_KUBECONFIG"
      printf '%s Using SA kubeconfig: %s (%s)\n' \
        "$(now_utc_iso)" "$SA_KUBECONFIG" "$(oc whoami)"
      return 0
    fi
    printf '%s SA kubeconfig expired or insufficient — re-minting\n' "$(now_utc_iso)"
  else
    printf '%s No SA kubeconfig at %s — bootstrapping\n' "$(now_utc_iso)" "$SA_KUBECONFIG"
  fi

  if [[ "$bootstrap_kubeconfig" == "$SA_KUBECONFIG" ]]; then
    bootstrap_kubeconfig="$default_kubeconfig"
  fi
  KUBECONFIG="$bootstrap_kubeconfig"
  if ! oc whoami &>/dev/null; then
    printf '%s ERROR: oc login required to apply RBAC and mint SA token\n' "$(now_utc_iso)"
    exit 1
  fi
  printf '%s Bootstrapping SA with login identity: %s\n' "$(now_utc_iso)" "$(oc whoami)"
  bootstrap_sa_kubeconfig
}

format_duration() {
  local secs="$1"
  printf '%dm %ds (%ds total)' $((secs / 60)) $((secs % 60)) "$secs"
}

duration_between_iso() {
  local start_iso="$1" end_iso="$2" start_epoch end_epoch diff

  [[ -z "$start_iso" || -z "$end_iso" ]] && return 0
  start_epoch="$(iso_to_epoch "$start_iso")" || return 0
  end_epoch="$(iso_to_epoch "$end_iso")" || return 0
  diff="$((end_epoch - start_epoch))"
  (( diff < 0 )) && return 0
  printf '%s' "$diff"
}

milestone_key() {
  printf '%s|%s' "$1" "$2"
}

milestone_iso() {
  local node="$1" name="$2" key

  key="$(milestone_key "$node" "$name")"
  if [[ -v node_milestone_iso["$key"] ]]; then
    printf '%s' "${node_milestone_iso["$key"]}"
  fi
}

event_milestone_iso() {
  local node="$1" name="$2" key

  key="$(milestone_key "$node" "$name")"
  if [[ -v node_event_milestone_iso["$key"] ]]; then
    printf '%s' "${node_event_milestone_iso["$key"]}"
  fi
}

set_event_milestone_first() {
  local node="$1" name="$2" iso="$3" key

  [[ -z "$iso" ]] && return 0
  key="$(milestone_key "$node" "$name")"
  [[ -v node_event_milestone_iso["$key"] ]] && return 0
  node_event_milestone_iso["$key"]="$iso"
}

set_event_milestone_earliest() {
  local node="$1" name="$2" iso="$3" key existing existing_epoch new_epoch

  [[ -z "$iso" ]] && return 0
  new_epoch="$(iso_to_epoch "$iso")" || return 0
  key="$(milestone_key "$node" "$name")"
  existing="${node_event_milestone_iso["$key"]:-}"
  if [[ -n "$existing" ]]; then
    existing_epoch="$(iso_to_epoch "$existing")" || return 0
    (( new_epoch >= existing_epoch )) && return 0
  fi
  node_event_milestone_iso["$key"]="$iso"
}

event_dedup_key() {
  local uid="$1" node="$2" event_time="$3" reason="$4" message="$5"

  # Event objects keep the same metadata.uid when lastTimestamp is updated for the
  # same involvedObject+reason; key must include event_time so a new rollout is seen.
  if [[ -n "$uid" ]]; then
    printf 'uid:%s|%s' "$uid" "$event_time"
  else
    printf 'sig:%s|%s|%s|%s' "$node" "$event_time" "$reason" "${message:0:120}"
  fi
}

apply_rollout_event() {
  local node="$1" event_time="$2" reason="$3" message="$4"
  local event_epoch reboot_iso rebooted_iso cordoned_iso cordoned_epoch boot_iso

  event_epoch="$(iso_to_epoch "$event_time")" || return 0
  (( event_epoch < start_epoch )) && return 0

  reboot_iso="$(event_milestone_iso "$node" reboot)"
  rebooted_iso="$(event_milestone_iso "$node" rebooted)"
  cordoned_iso="$(event_milestone_iso "$node" cordoned)"

  case "$reason" in
    Reboot)
      [[ -n "$TARGET_CFG" && "$message" != *"$TARGET_CFG"* ]] && return 0
      set_event_milestone_first "$node" "reboot" "$event_time"
      ;;
    Rebooted)
      set_event_milestone_first "$node" "rebooted" "$event_time"
      ;;
    NodeNotSchedulable)
      if [[ -n "$reboot_iso" ]] && (( event_epoch >= $(iso_to_epoch "$reboot_iso") )); then
        return 0
      fi
      set_event_milestone_earliest "$node" "cordoned" "$event_time"
      ;;
    NodeNotReady)
      [[ -z "$cordoned_iso" ]] && return 0
      cordoned_epoch="$(iso_to_epoch "$cordoned_iso")" || return 0
      (( event_epoch < cordoned_epoch )) && return 0
      # Drain NotReady often arrives after MCD Reboot; only skip post-reboot NotReady.
      if [[ -n "$rebooted_iso" ]] && (( event_epoch >= $(iso_to_epoch "$rebooted_iso") )); then
        return 0
      fi
      boot_iso="$(event_milestone_iso "$node" boot_done)"
      if [[ -n "$boot_iso" ]] && (( event_epoch >= $(iso_to_epoch "$boot_iso") )); then
        return 0
      fi
      set_event_milestone_earliest "$node" "drain_done" "$event_time"
      ;;
    Uncordon)
      [[ -n "$TARGET_CFG" && "$message" != *"$TARGET_CFG"* ]] && return 0
      [[ -z "$reboot_iso" && -z "$rebooted_iso" ]] && return 0
      if [[ -n "$reboot_iso" ]] && (( event_epoch < $(iso_to_epoch "$reboot_iso") )); then
        return 0
      fi
      set_event_milestone_first "$node" "boot_done" "$event_time"
      ;;
    NodeSchedulable)
      [[ -n "$(event_milestone_iso "$node" boot_done)" ]] && return 0
      [[ -z "$reboot_iso" && -z "$rebooted_iso" ]] && return 0
      if [[ -n "$reboot_iso" ]] && (( event_epoch < $(iso_to_epoch "$reboot_iso") )); then
        return 0
      fi
      set_event_milestone_first "$node" "boot_done" "$event_time"
      ;;
  esac
}

event_phases_complete() {
  local node="$1"

  [[ -n "$(event_milestone_iso "$node" cordoned)" \
    && -n "$(event_milestone_iso "$node" drain_done)" \
    && -n "$(event_milestone_iso "$node" boot_done)" ]]
}

node_poll_phases_complete() {
  local node="$1"

  [[ -n "$(milestone_iso "$node" cordoned)" \
    && -n "$(milestone_iso "$node" drain_done)" \
    && -n "$(milestone_iso "$node" boot_done)" ]]
}

milestone_source() {
  local node="$1" name="$2" key

  key="$(milestone_key "$node" "$name")"
  if [[ -v node_milestone_source["$key"] ]]; then
    printf '%s' "${node_milestone_source["$key"]}"
  fi
}

normalize_phase_source() {
  case "$1" in
    observed) printf 'observed' ;;
    "tracking-start backfill"|seed) printf 'seed' ;;
    "completion backfill"|completion) printf 'completion' ;;
    *) printf '%s' "$1" ;;
  esac
}

store_milestone_source() {
  local node="$1" name="$2" source="$3"

  node_milestone_source["$(milestone_key "$node" "$name")"]="$(normalize_phase_source "$source")"
}

node_data_source() {
  local node="$1" name src observed=0 backfill=0

  for name in cordoned drain_done boot_done; do
    src="$(milestone_source "$node" "$name")"
    [[ -z "$src" ]] && continue
    if [[ "$src" == "observed" ]]; then
      observed=1
    else
      backfill=1
    fi
  done

  if [[ "$observed" -eq 1 && "$backfill" -eq 1 ]]; then
    printf 'mixed'
  elif [[ "$observed" -eq 1 ]]; then
    printf 'observed'
  elif [[ "$backfill" -eq 1 ]]; then
    printf 'inferred'
  fi
}

reset_node_tracking() {
  local node="$1"

  unset "node_milestone_iso[$(milestone_key "$node" "cordoned")]"
  unset "node_milestone_iso[$(milestone_key "$node" "drain_done")]"
  unset "node_milestone_iso[$(milestone_key "$node" "boot_done")]"
  unset "node_milestone_source[$(milestone_key "$node" "cordoned")]"
  unset "node_milestone_source[$(milestone_key "$node" "drain_done")]"
  unset "node_milestone_source[$(milestone_key "$node" "boot_done")]"
  unset "node_event_milestone_iso[$(milestone_key "$node" "cordoned")]"
  unset "node_event_milestone_iso[$(milestone_key "$node" "drain_done")]"
  unset "node_event_milestone_iso[$(milestone_key "$node" "boot_done")]"
  unset "node_event_milestone_iso[$(milestone_key "$node" "reboot")]"
  unset "node_event_milestone_iso[$(milestone_key "$node" "rebooted")]"
  unset "node_prev_unschedulable[\"$node\"]"
  unset "node_prev_ready[\"$node\"]"
  unset "node_initial_unschedulable[\"$node\"]"
}

record_milestone() {
  local node="$1" name="$2" now="$3" source="${4:-observed}" key

  key="$(milestone_key "$node" "$name")"
  [[ -v node_milestone_iso["$key"] ]] && return 0

  node_milestone_iso["$key"]="$(epoch_to_iso "$now")"
  store_milestone_source "$node" "$name" "$source"
  case "$name" in
    cordoned)   label="NodeNotSchedulable" ;;
    drain_done) label="NodeNotReady" ;;
    boot_done)  label="NodeSchedulable" ;;
    *)          label="$name" ;;
  esac
  printf '%s node/%s %s @ %s\n' "$(now_utc_iso)" "$node" "$label" "$(epoch_to_iso "$now")"
}

set_milestone_iso() {
  local node="$1" name="$2" iso="$3" source="${4:-}"
  local key label

  [[ -z "$iso" ]] && return 0
  key="$(milestone_key "$node" "$name")"
  [[ -v node_milestone_iso["$key"] ]] && return 0

  node_milestone_iso["$key"]="$iso"
  store_milestone_source "$node" "$name" "$source"
  case "$name" in
    cordoned)   label="NodeNotSchedulable" ;;
    drain_done) label="NodeNotReady" ;;
    boot_done)  label="NodeSchedulable" ;;
    *)          label="$name" ;;
  esac
  if [[ -n "$source" ]]; then
    printf '%s node/%s %s @ %s (%s)\n' "$(now_utc_iso)" "$node" "$label" "$iso" "$source"
  else
    printf '%s node/%s %s @ %s\n' "$(now_utc_iso)" "$node" "$label" "$iso"
  fi
}

node_is_cordoned_for_drain() {
  local node="$1"

  [[ -n "$(milestone_iso "$node" cordoned)" ]] && return 0
  [[ "${node_initial_unschedulable["$node"]:-false}" == "true" ]] && return 0
  return 1
}

seed_initial_milestones() {
  local node="$1" now="$2" nodes_json="$3" ready

  if [[ "${node_initial_unschedulable["$node"]:-false}" == "true" ]]; then
    record_milestone "$node" "cordoned" "$now" "seed"
    printf '%s   (already cordoned when tracking started)\n' "$(now_utc_iso)"
  fi

  ready="$(node_field_from_json "$nodes_json" "$node" 'ready')"
  if node_is_cordoned_for_drain "$node" \
      && [[ "$ready" == "False" || "$ready" == "Unknown" ]]; then
    record_milestone "$node" "drain_done" "$now" "seed"
    printf '%s   (already NotReady when tracking started)\n' "$(now_utc_iso)"
  fi
}

backfill_boot_at_completion() {
  local node="$1" now="$2" nodes_json="$3"
  local unsched ready

  unsched="$(node_field_from_json "$nodes_json" "$node" 'unschedulable')"
  ready="$(node_field_from_json "$nodes_json" "$node" 'ready')"

  if [[ -z "$(milestone_iso "$node" boot_done)" \
      && "$unsched" != "true" && "$ready" == "True" \
      && -n "$(milestone_iso "$node" drain_done)" ]]; then
    set_milestone_iso "$node" "boot_done" "$(epoch_to_iso "$now")" "completion"
  fi
}

node_field_from_json() {
  local nodes_json="$1" node="$2" field="$3"

  jq -r --arg node "$node" --arg field "$field" '
    .items[] | select(.metadata.name == $node)
    | if $field == "unschedulable" then (.spec.unschedulable // false | tostring)
      elif $field == "ready" then (.status.conditions[]? | select(.type == "Ready") | .status) // "Unknown"
      else empty end
  ' <<<"$nodes_json"
}

fetch_nodes_json() {
  oc get nodes -o json 2>/dev/null
}

init_events_log() {
  printf '%s\n' \
    'captured_at	event_time	node	namespace	reason	source	message	uid' \
    > "$EVENTS_FILE"
}

save_rollout_events() {
  local events_json captured_at node_names_json dedup_key new_count=0

  [[ ${#worker_nodes[@]} -eq 0 ]] && return 0

  events_json="$(oc get events -A --field-selector involvedObject.kind=Node -o json 2>/dev/null)" \
    || return 0
  [[ -z "$events_json" ]] && return 0

  captured_at="$(now_utc_iso)"
  node_names_json="$(printf '%s\n' "${worker_nodes[@]}" | jq -R . | jq -s .)"

  while IFS=$'\t' read -r event_time node namespace reason source message uid; do
    [[ -z "$node" || -z "$event_time" ]] && continue
    dedup_key="$(event_dedup_key "$uid" "$node" "$event_time" "$reason" "$message")"
    [[ -v seen_event_keys["$dedup_key"] ]] && continue
    seen_event_keys["$dedup_key"]=1
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$captured_at" "$event_time" "$node" "$namespace" "$reason" "$source" "$message" "$uid" \
      >> "$EVENTS_FILE"
    apply_rollout_event "$node" "$event_time" "$reason" "$message"
    new_count="$((new_count + 1))"
  done < <(jq -r --argjson nodes "$node_names_json" '
    .items
    | sort_by(.lastTimestamp // .eventTime // .firstTimestamp // "")
    | .[]
    | select(.involvedObject.name as $n | $nodes | index($n))
    | [
        (.lastTimestamp // .eventTime // .firstTimestamp // ""),
        .involvedObject.name,
        (.metadata.namespace // ""),
        (.reason // ""),
        (.source.component // .reportingComponent // ""),
        (.message // "" | gsub("\t"; " ") | gsub("\r?\n"; " ")),
        (.metadata.uid // "")
      ] | @tsv
  ' <<<"$events_json")

  if (( new_count > 0 )); then
    printf '%s appended %d new node event(s) to %s\n' \
      "$(now_utc_iso)" "$new_count" "$EVENTS_FILE"
  fi
}

ceph_operator_pod() {
  oc get pods -n "$CEPH_NAMESPACE" -l "$CEPH_POD_LABEL" \
    -o jsonpath='{.items[?(@.status.phase=="Running")].metadata.name}' 2>/dev/null \
    | awk '{print $1}'
}

init_ceph_operator_log() {
  printf '%s\n' \
    '# rook-ceph-operator logs captured during mcp-reboot-watch (append-only, no duplicate lines)' \
    > "$CEPH_OPERATOR_LOG_FILE"
}

append_ceph_operator_previous() {
  local pod="$1" tmp added

  [[ -v ceph_operator_previous_saved["$pod"] ]] && return 0

  tmp="$(mktemp)"
  if oc logs -n "$CEPH_NAMESPACE" "$pod" --previous --timestamps --tail=-1 >"$tmp" 2>/dev/null \
      && [[ -s "$tmp" ]]; then
    {
      printf '\n### %s previous container pod/%s\n' "$(now_utc_iso)" "$pod"
      cat "$tmp"
    } >>"$CEPH_OPERATOR_LOG_FILE"
    added="$(wc -l <"$tmp")"
    printf '%s saved %d previous ceph-operator line(s) for pod/%s\n' \
      "$(now_utc_iso)" "$added" "$pod"
  fi
  rm -f "$tmp"
  ceph_operator_previous_saved["$pod"]=1
}

save_ceph_operator_logs() {
  local pod tmp old_lines new_lines added

  [[ "$CEPH_OPERATOR_LOGS" == "1" ]] || return 0

  pod="$(ceph_operator_pod)"
  if [[ -z "$pod" ]]; then
    return 0
  fi

  if [[ "$pod" != "$ceph_operator_current_pod" ]]; then
    if [[ -n "$ceph_operator_current_pod" ]]; then
      printf '\n### %s switched ceph-operator pod %s -> %s\n' \
        "$(now_utc_iso)" "$ceph_operator_current_pod" "$pod" >>"$CEPH_OPERATOR_LOG_FILE"
    else
      printf '\n### %s tracking ceph-operator pod/%s\n' "$(now_utc_iso)" "$pod" \
        >>"$CEPH_OPERATOR_LOG_FILE"
    fi
    ceph_operator_current_pod="$pod"
    append_ceph_operator_previous "$pod"
  fi

  tmp="$(mktemp)"
  if ! oc logs -n "$CEPH_NAMESPACE" "$pod" --timestamps --tail=-1 >"$tmp" 2>&1; then
    printf '%s ceph-operator oc logs failed for pod/%s\n' "$(now_utc_iso)" "$pod"
    rm -f "$tmp"
    return 0
  fi

  old_lines="${ceph_operator_pod_lines["$pod"]:-0}"
  new_lines="$(wc -l <"$tmp")"

  if (( new_lines > old_lines )); then
    added="$((new_lines - old_lines))"
    tail -n +"$((old_lines + 1))" "$tmp" >>"$CEPH_OPERATOR_LOG_FILE"
    ceph_operator_pod_lines["$pod"]="$new_lines"
    printf '%s appended %d ceph-operator line(s) to %s (pod/%s total %d)\n' \
      "$(now_utc_iso)" "$added" "$CEPH_OPERATOR_LOG_FILE" "$pod" "$new_lines"
  elif (( new_lines < old_lines )); then
    {
      printf '\n### %s ceph-operator log shrank for pod/%s (%d -> %d); snapshot follows\n' \
        "$(now_utc_iso)" "$pod" "$old_lines" "$new_lines"
      cat "$tmp"
    } >>"$CEPH_OPERATOR_LOG_FILE"
    ceph_operator_pod_lines["$pod"]="$new_lines"
  fi

  rm -f "$tmp"
}

init_node_watch_state() {
  local node="$1" nodes_json="$2"

  node_initial_unschedulable["$node"]="$(node_field_from_json "$nodes_json" "$node" 'unschedulable')"
  node_prev_unschedulable["$node"]="${node_initial_unschedulable["$node"]}"
  node_prev_ready["$node"]="$(node_field_from_json "$nodes_json" "$node" 'ready')"
}

capture_node_milestones() {
  local node="$1" now="$2" nodes_json="$3"
  local unsched ready prev_unsched prev_ready

  [[ -v node_csv_written["$node"] ]] && return 0

  unsched="$(node_field_from_json "$nodes_json" "$node" 'unschedulable')"
  ready="$(node_field_from_json "$nodes_json" "$node" 'ready')"
  prev_unsched="${node_prev_unschedulable["$node"]:-false}"
  prev_ready="${node_prev_ready["$node"]:-}"

  # NodeNotSchedulable: cordon transition (pre-cordoned nodes are seeded at tracking start).
  if [[ "$unsched" == "true" && "$prev_unsched" != "true" \
      && "${node_initial_unschedulable["$node"]:-false}" != "true" ]]; then
    record_milestone "$node" "cordoned" "$now"
  fi

  # NodeNotReady: drain finished (Ready=False while cordoned or pre-cordoned).
  if [[ -z "$(milestone_iso "$node" drain_done)" ]] && node_is_cordoned_for_drain "$node"; then
    if [[ "$ready" == "False" || "$ready" == "Unknown" ]]; then
      record_milestone "$node" "drain_done" "$now"
    fi
  fi

  # Cordon+drain in one step if we missed the cordon transition.
  if [[ -z "$(milestone_iso "$node" drain_done)" \
      && "$unsched" == "true" \
      && "$prev_ready" == "True" \
      && ( "$ready" == "False" || "$ready" == "Unknown" ) ]]; then
    [[ -z "$(milestone_iso "$node" cordoned)" ]] && record_milestone "$node" "cordoned" "$now"
    record_milestone "$node" "drain_done" "$now"
  fi

  # NodeSchedulable: boot finished (uncordoned, node accepting workloads again).
  if [[ -z "$(milestone_iso "$node" boot_done)" ]]; then
    if [[ "$unsched" != "true" && "$prev_unsched" == "true" ]]; then
      record_milestone "$node" "boot_done" "$now"
    elif [[ -n "$(milestone_iso "$node" drain_done)" \
        && "$unsched" != "true" && "$ready" == "True" ]]; then
      record_milestone "$node" "boot_done" "$now"
    fi
  fi

  node_prev_unschedulable["$node"]="$unsched"
  node_prev_ready["$node"]="$ready"
}

latest_milestone() {
  local node="$1"

  [[ -n "$(milestone_iso "$node" boot_done)" ]] && printf 'NodeSchedulable' && return 0
  [[ -n "$(milestone_iso "$node" drain_done)" ]] && printf 'NodeNotReady' && return 0
  [[ -n "$(milestone_iso "$node" cordoned)" ]] && printf 'NodeNotSchedulable' && return 0
  printf 'waiting'
}

node_in_active_drain() {
  local node="$1" milestone

  [[ -v node_csv_written["$node"] ]] && return 1

  milestone="$(latest_milestone "$node")"
  [[ "$milestone" == "NodeNotSchedulable" || "$milestone" == "NodeNotReady" ]]
}

current_poll_interval() {
  local node

  for node in "${worker_nodes[@]}"; do
    if node_in_active_drain "$node"; then
      printf '%s' "$ACTIVE_INTERVAL"
      return 0
    fi
  done
  printf '%s' "$INTERVAL"
}

nodes_list() {
  if [[ $# -eq 0 ]]; then
    printf 'none'
    return 0
  fi
  local IFS=', '
  printf '%s' "$*"
}

print_tracking_status() {
  local node now updating=() waiting=() finished=() milestone phase_start_epoch phase_elapsed

  now="$(date +%s)"
  for node in "${worker_nodes[@]}"; do
    if [[ -v node_csv_written["$node"] ]]; then
      finished+=("$node")
    elif [[ "$(latest_milestone "$node")" != "waiting" ]]; then
      updating+=("$node")
    else
      waiting+=("$node")
    fi
  done

  printf '%s --- tracking status (%s/%s node phases in CSV) ---\n' \
    "$(now_utc_iso)" "${#finished[@]}" "${#worker_nodes[@]}"
  if [[ -n "$TARGET_CFG" ]]; then
    printf '  rollout config: %s\n' "$TARGET_CFG"
  else
    printf '  rollout config: (detecting...)\n'
  fi
  printf '  %s\n' "$(mcp_status_summary)"
  printf '  mcn finished: %s/%s\n' "$mcn_finished_count" "${#worker_nodes[@]}"
  printf '  node phases in CSV: %s/%s\n' "$nodes_phases_done" "${#worker_nodes[@]}"
  printf '  in progress (%s): %s\n' "${#updating[@]}" "$(nodes_list "${updating[@]}")"
  printf '  waiting     (%s): %s\n' "${#waiting[@]}" "$(nodes_list "${waiting[@]}")"
  printf '  csv written (%s): %s\n' "${#finished[@]}" "$(nodes_list "${finished[@]}")"

  for node in "${updating[@]}"; do
    milestone="$(latest_milestone "$node")"
    phase_start_epoch="$(iso_to_epoch "$(milestone_iso "$node" cordoned)" 2>/dev/null || true)"
    phase_elapsed="${start_epoch}"
    if [[ -n "$phase_start_epoch" ]]; then
      phase_elapsed="$((now - phase_start_epoch))"
    else
      phase_elapsed="$((now - start_epoch))"
    fi
    printf '    %s: in progress %s (last: %s)\n' \
      "$node" "$(format_duration "$phase_elapsed")" "$milestone"
  done
}

fetch_mcp_json() {
  oc get mcp "$MCP" -o json
}

mcp_updating() {
  [[ "$(jq -r '.status.conditions[]? | select(.type=="Updating") | .status' <<<"$(fetch_mcp_json)")" == "True" ]]
}

# Pool rollout finished: not updating, pool Updated=True, all machines updated.
mcp_rollout_complete() {
  local mcp_json updating updated machine_count updated_count

  mcp_json="$(fetch_mcp_json)"
  updating="$(jq -r '.status.conditions[]? | select(.type=="Updating") | .status' <<<"$mcp_json")"
  updated="$(jq -r '.status.conditions[]? | select(.type=="Updated") | .status' <<<"$mcp_json")"
  machine_count="$(jq -r '.status.machineCount // 0' <<<"$mcp_json")"
  updated_count="$(jq -r '.status.updatedMachineCount // 0' <<<"$mcp_json")"

  [[ "$updating" != "True" \
    && "$updated" == "True" \
    && "$machine_count" -gt 0 \
    && "$updated_count" -ge "$machine_count" ]]
}

mcp_status_summary() {
  local mcp_json updating updated machine_count updated_count ready_count degraded

  mcp_json="$(fetch_mcp_json)"
  updating="$(jq -r '.status.conditions[]? | select(.type=="Updating") | .status' <<<"$mcp_json")"
  updated="$(jq -r '.status.conditions[]? | select(.type=="Updated") | .status' <<<"$mcp_json")"
  degraded="$(jq -r '.status.conditions[]? | select(.type=="Degraded") | .status' <<<"$mcp_json")"
  machine_count="$(jq -r '.status.machineCount // 0' <<<"$mcp_json")"
  updated_count="$(jq -r '.status.updatedMachineCount // 0' <<<"$mcp_json")"
  ready_count="$(jq -r '.status.readyMachineCount // 0' <<<"$mcp_json")"

  printf 'mcp/%s updating=%s updated=%s degraded=%s machines=%s updated=%s ready=%s' \
    "$MCP" "${updating:-Unknown}" "${updated:-Unknown}" "${degraded:-Unknown}" \
    "$machine_count" "$updated_count" "$ready_count"
}

mcn_available() {
  oc api-resources --api-group=machineconfiguration.openshift.io -o name 2>/dev/null \
    | grep -qx 'machineconfignodes.machineconfiguration.openshift.io'
}

mcn_pool_nodes() {
  oc get machineconfignode -o jsonpath="{range .items[?(@.spec.pool.name=='${MCP}')]}{.metadata.name}{'\n'}{end}"
}

fetch_mcn_json() {
  oc get machineconfignode -o json
}

detect_rollout_config() {
  local mcn_json="$1" cfg=""

  cfg="$(jq -r --arg p "$MCP" '
    [.items[]
      | select(.spec.pool.name == $p)
      | select(
          ([.status.conditions[]?
            | select(.type == "Updated" and .status == "False")] | length) > 0
          or (.status.configVersion.desired // "") != (.status.configVersion.current // "")
        )
      | .status.configVersion.desired // empty
    ] | unique | .[0] // empty
  ' <<<"$mcn_json")"

  if [[ -z "$cfg" ]]; then
    cfg="$(jq -r --arg p "$MCP" '
      [.items[]
        | select(.spec.pool.name == $p)
        | .status.configVersion.desired // empty
      ] | unique | if length == 1 then .[0] else empty end
    ' <<<"$mcn_json")"
  fi

  if [[ -n "$cfg" && "$cfg" != "$TARGET_CFG" ]]; then
    if [[ -z "$TARGET_CFG" ]]; then
      printf '%s Rollout rendered config: %s\n' "$(now_utc_iso)" "$cfg"
    else
      printf '%s Rollout rendered config changed: %s -> %s\n' \
        "$(now_utc_iso)" "$TARGET_CFG" "$cfg"
    fi
    TARGET_CFG="$cfg"
  fi
}

# True when MCO has assigned this node to the rollout (respects maxUnavailable batching).
node_mcn_updating() {
  local node="$1" mcn_json="$2"

  jq -e --arg node "$node" '
    .items[] | select(.metadata.name == $node)
    | select(
        (.status.configVersion.desired // "") != (.status.configVersion.current // "")
        or ([.status.conditions[]?
          | select(.type == "Updated" and .status == "False")] | length) > 0
      )
  ' <<<"$mcn_json" >/dev/null
}

node_updated_for_rollout() {
  local node="$1" mcn_json="$2"

  if [[ -z "$TARGET_CFG" ]]; then
    jq -e --arg node "$node" '
      .items[] | select(.metadata.name == $node)
      | .status.conditions[]? | select(.type == "Updated" and .status == "True")
    ' <<<"$mcn_json" >/dev/null
    return
  fi

  jq -e --arg node "$node" --arg cfg "$TARGET_CFG" '
    .items[] | select(.metadata.name == $node)
    | select(.status.configVersion.current == $cfg)
    | .status.conditions[]? | select(.type == "Updated" and .status == "True")
  ' <<<"$mcn_json" >/dev/null
}

ensure_node_phase_tracking() {
  local node="$1" now="$2" nodes_json="$3"

  [[ -v node_phase_tracking_init["$node"] ]] && return 0
  node_phase_tracking_init["$node"]=1
  init_node_watch_state "$node" "$nodes_json"
  seed_initial_milestones "$node" "$now" "$nodes_json"
}

record_mcn_start() {
  local node="$1" now="$2"

  [[ -v mcn_start_epoch["$node"] ]] && return 0

  mcn_start_epoch["$node"]="$now"
  printf '%s machineconfignode/%s rollout started (MCN desired≠current or Updated=False)\n' \
    "$(now_utc_iso)" "$node"
}

write_node_phase_csv_row() {
  local node="$1"
  local cord drained boot drain_secs boot_secs start_epoch end_epoch duration
  local evt_cord evt_drained evt_boot evt_drain_secs evt_boot_secs evt_complete

  cord="$(milestone_iso "$node" cordoned)"
  drained="$(milestone_iso "$node" drain_done)"
  boot="$(milestone_iso "$node" boot_done)"

  evt_cord="$(event_milestone_iso "$node" cordoned)"
  evt_drained="$(event_milestone_iso "$node" drain_done)"
  evt_boot="$(event_milestone_iso "$node" boot_done)"

  drain_secs="$(duration_between_iso "$cord" "$drained")"
  boot_secs="$(duration_between_iso "$drained" "$boot")"
  evt_drain_secs="$(duration_between_iso "$evt_cord" "$evt_drained")"
  evt_boot_secs="$(duration_between_iso "$evt_drained" "$evt_boot")"
  if event_phases_complete "$node"; then
    evt_complete="yes"
  else
    evt_complete="no"
  fi

  start_epoch="$(iso_to_epoch "$cord")"
  end_epoch="$(iso_to_epoch "$boot")"
  duration="$(duration_between_iso "$cord" "$boot")"

  node_duration_secs["$node"]="$duration"
  node_end_epoch["$node"]="$end_epoch"
  node_drain_secs["$node"]="${drain_secs:-0}"
  node_boot_secs["$node"]="${boot_secs:-0}"

  {
    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
      "$node" \
      "${drain_secs:-}" \
      "${boot_secs:-}" \
      "$duration" \
      "$cord" \
      "$boot" \
      "$cord" \
      "$drained" \
      "$boot" \
      "${TARGET_CFG:-}" \
      "$(node_data_source "$node")" \
      "$evt_cord" \
      "$evt_drained" \
      "$evt_boot" \
      "${evt_drain_secs:-}" \
      "${evt_boot_secs:-}" \
      "$evt_complete"
  } >> "$CSV_FILE"
}

try_write_node_phase_csv() {
  local node="$1" now="$2" nodes_json="$3" elapsed

  [[ -v node_csv_written["$node"] ]] && return 0
  node_poll_phases_complete "$node" || return 0

  backfill_boot_at_completion "$node" "$now" "$nodes_json"
  node_poll_phases_complete "$node" || return 0

  node_csv_written["$node"]=1
  nodes_phases_done="$((nodes_phases_done + 1))"
  write_node_phase_csv_row "$node"
  elapsed="$((now - start_epoch))"
  printf '%s node/%s drain/reboot phases complete — CSV row written (%s/%s), %s since pool started\n' \
    "$(now_utc_iso)" "$node" "$nodes_phases_done" "${#worker_nodes[@]}" \
    "$(format_duration "$elapsed")"
  printf '%s   node phases (poll): drain=%ss boot=%ss total=%ss data_source=%s\n' \
    "$(now_utc_iso)" \
    "$(duration_between_iso "$(milestone_iso "$node" cordoned)" "$(milestone_iso "$node" drain_done)")" \
    "$(duration_between_iso "$(milestone_iso "$node" drain_done)" "$(milestone_iso "$node" boot_done)")" \
    "$(duration_between_iso "$(milestone_iso "$node" cordoned)" "$(milestone_iso "$node" boot_done)")" \
    "$(node_data_source "$node")"
  printf '%s   node phases (events): drain=%ss boot=%ss evt_complete=%s\n' \
    "$(now_utc_iso)" \
    "$(duration_between_iso "$(event_milestone_iso "$node" cordoned)" "$(event_milestone_iso "$node" drain_done)")" \
    "$(duration_between_iso "$(event_milestone_iso "$node" drain_done)" "$(event_milestone_iso "$node" boot_done)")" \
    "$(event_phases_complete "$node" && printf yes || printf no)"
}

try_record_mcn_completion() {
  local node="$1" now="$2" mcn_json="$3" duration updated_count

  [[ -v mcn_finished["$node"] ]] && return 0
  [[ ! -v mcn_start_epoch["$node"] ]] && return 0
  node_updated_for_rollout "$node" "$mcn_json" || return 0

  duration="$((now - mcn_start_epoch[$node]))"
  mcn_finished["$node"]=1
  mcn_finished_count="$((mcn_finished_count + 1))"
  updated_count="$(oc get mcp "$MCP" -o jsonpath='{.status.updatedMachineCount}')"
  printf '%s machineconfignode/%s UPDATED=True — mcn finished %s (%s/%s MCP updated, %s/%s mcn tracked)\n' \
    "$(now_utc_iso)" "$node" \
    "$(format_duration "$duration")" \
    "$updated_count" "$machine_count" \
    "$mcn_finished_count" "${#worker_nodes[@]}"
}

init_csv() {
  printf '%s\n' \
    'node,drain_seconds,boot_seconds,per_node_total_duration_seconds,node_start_time,node_end_time,cordoned_ts,drain_done_ts,boot_done_ts,rendered_config,data_source,evt_cordoned_ts,evt_drain_done_ts,evt_boot_done_ts,evt_drain_seconds,evt_boot_seconds,evt_phases_complete' \
    > "$CSV_FILE"
}

append_csv_summary() {
  local pool_end="$1" node empty_cols earliest_epoch latest_epoch pool_duration cord_iso

  earliest_epoch=""
  latest_epoch=""
  for node in "${worker_nodes[@]}"; do
    [[ -v node_csv_written["$node"] ]] || continue
    cord_iso="$(milestone_iso "$node" cordoned)"
    if [[ -n "$cord_iso" ]]; then
      if [[ -z "$earliest_epoch" ]] \
          || (( $(iso_to_epoch "$cord_iso") < earliest_epoch )); then
        earliest_epoch="$(iso_to_epoch "$cord_iso")"
      fi
    fi
    if [[ -v node_end_epoch["$node"] ]]; then
      if [[ -z "$latest_epoch" || "${node_end_epoch["$node"]}" -gt "$latest_epoch" ]]; then
        latest_epoch="${node_end_epoch["$node"]}"
      fi
    fi
  done

  earliest_epoch="${earliest_epoch:-$start_epoch}"
  latest_epoch="${latest_epoch:-$pool_end}"
  pool_duration="$((latest_epoch - earliest_epoch))"

  empty_cols="$(printf ',%.0s' {1..11})"
  {
    printf '%s,%s,%s,%s,%s,%s%s\n' \
      "ALL_NODES" \
      "" \
      "" \
      "$pool_duration" \
      "$(epoch_to_iso "$earliest_epoch")" \
      "$(epoch_to_iso "$latest_epoch")" \
      "$empty_cols"
  } >> "$CSV_FILE"
}

poll_rollout() {
  local node now mcn_json nodes_json

  now="$(date +%s)"
  mcn_json="$(fetch_mcn_json)"
  nodes_json="$(fetch_nodes_json)"
  detect_rollout_config "$mcn_json"
  save_rollout_events
  save_ceph_operator_logs

  for node in "${worker_nodes[@]}"; do
    ensure_node_phase_tracking "$node" "$now" "$nodes_json"
    capture_node_milestones "$node" "$now" "$nodes_json"
    try_write_node_phase_csv "$node" "$now" "$nodes_json"

    if node_mcn_updating "$node" "$mcn_json"; then
      record_mcn_start "$node" "$now"
    fi
    try_record_mcn_completion "$node" "$now" "$mcn_json"
  done
}

init_node_tracking() {
  local node now mcn_json nodes_json

  if ! mcn_available; then
    printf '%s ERROR: MachineConfigNode CRD not available — requires OpenShift 4.16+\n' "$(now_utc_iso)"
    exit 1
  fi

  require_jq

  machine_count="$(oc get mcp "$MCP" -o jsonpath='{.status.machineCount}')"
  worker_nodes=()
  nodes_phases_done=0
  mcn_finished_count=0
  now="$(date +%s)"
  mcn_json="$(fetch_mcn_json)"
  nodes_json="$(fetch_nodes_json)"
  detect_rollout_config "$mcn_json"

  while read -r node; do
    [[ -z "$node" ]] && continue
    worker_nodes+=("$node")
    ensure_node_phase_tracking "$node" "$now" "$nodes_json"
    if node_mcn_updating "$node" "$mcn_json"; then
      record_mcn_start "$node" "$now"
      printf '%s machineconfignode/%s already in rollout at timer start\n' "$(now_utc_iso)" "$node"
    fi
  done < <(mcn_pool_nodes)

  if [[ ${#worker_nodes[@]} -eq 0 ]]; then
    printf '%s ERROR: no MachineConfigNodes found for mcp/%s\n' "$(now_utc_iso)" "$MCP"
    exit 1
  fi

  poll_rollout
  printf '%s Tracking %s mcp/%s node(s); poll every %ss (%ss during active drain)\n' \
    "$(now_utc_iso)" "${#worker_nodes[@]}" "$MCP" "$INTERVAL" "$ACTIVE_INTERVAL"
  print_tracking_status
}

print_per_node_summary() {
  local pool_elapsed="$1"
  local node earliest_epoch="" latest_epoch=""

  if [[ "$nodes_phases_done" -eq 0 ]]; then
    return 0
  fi

  printf '\n%s Per-node per_node_total_duration_seconds (%s/%s node(s)):\n' \
    "$(now_utc_iso)" "$nodes_phases_done" "${#worker_nodes[@]}"

  for node in "${worker_nodes[@]}"; do
    [[ -v node_duration_secs["$node"] ]] || continue
    cord_iso="$(milestone_iso "$node" cordoned)"
    if [[ -n "$cord_iso" ]]; then
      if [[ -z "$earliest_epoch" ]] \
          || (( $(iso_to_epoch "$cord_iso") < earliest_epoch )); then
        earliest_epoch="$(iso_to_epoch "$cord_iso")"
      fi
    fi
    if [[ -v node_end_epoch["$node"] ]]; then
      if [[ -z "$latest_epoch" || "${node_end_epoch["$node"]}" -gt "$latest_epoch" ]]; then
        latest_epoch="${node_end_epoch["$node"]}"
      fi
    fi
    printf '  %s: drain=%ss boot=%ss per_node_total=%ss (%s)\n' \
      "$node" \
      "${node_drain_secs["$node"]:-0}" \
      "${node_boot_secs["$node"]:-0}" \
      "${node_duration_secs["$node"]}" \
      "$(format_duration "${node_duration_secs["$node"]}")"
  done

  earliest_epoch="${earliest_epoch:-$start_epoch}"
  latest_epoch="${latest_epoch:-$((start_epoch + pool_elapsed))}"
  printf '%s All nodes: pool_elapsed=%ss (%s), node_start_time=%s, node_end_time=%s\n' \
    "$(now_utc_iso)" \
    "$pool_elapsed" \
    "$(format_duration "$pool_elapsed")" \
    "$(epoch_to_iso "$earliest_epoch")" \
    "$(epoch_to_iso "$latest_epoch")"
}

finalize_rollout() {
  local pool_end pool_elapsed

  pool_end="$(date +%s)"
  pool_elapsed="$((pool_end - start_epoch))"
  printf '\n%s mcp/%s rollout complete — pool elapsed %s\n' \
    "$(now_utc_iso)" "$MCP" "$(format_duration "$pool_elapsed")"
  printf '%s   %s\n' "$(now_utc_iso)" "$(mcp_status_summary)"
  printf '%s node phases in CSV: %s/%s worker node(s)\n' \
    "$(now_utc_iso)" "$nodes_phases_done" "${#worker_nodes[@]}"
  if [[ "$nodes_phases_done" -lt ${#worker_nodes[@]} ]]; then
    printf '%s WARNING: MCP rollout finished before all node phase CSV rows were written (%s missing)\n' \
      "$(now_utc_iso)" "$(( ${#worker_nodes[@]} - nodes_phases_done ))"
  fi
  printf '%s MCN UPDATED=True on %s/%s node(s) (logged independently)\n' \
    "$(now_utc_iso)" "$mcn_finished_count" "${#worker_nodes[@]}"
  append_csv_summary "$pool_end"
  print_per_node_summary "$pool_elapsed"
  printf '%s Full log saved to %s\n' "$(now_utc_iso)" "$LOG_FILE"
  printf '%s Per-node timing CSV saved to %s\n' "$(now_utc_iso)" "$CSV_FILE"
  printf '%s Node events TSV saved to %s\n' "$(now_utc_iso)" "$EVENTS_FILE"
  if [[ "$CEPH_OPERATOR_LOGS" == "1" ]]; then
    printf '%s Ceph operator log saved to %s\n' "$(now_utc_iso)" "$CEPH_OPERATOR_LOG_FILE"
  fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  require_jq
  require_oc
  setup_oc_auth

  if mcp_updating; then
    printf '%s mcp/%s already Updating=True — skipping reboot trigger\n' "$(now_utc_iso)" "$MCP"
  else
    printf '%s Triggering reboot for mcp/%s\n' "$(now_utc_iso)" "$MCP"
    oc adm reboot-machine-config-pool "mcp/$MCP"
  fi

  printf '%s Waiting for mcp/%s Updating=True before starting timer (poll every %ss)\n' \
    "$(now_utc_iso)" "$MCP" "$INTERVAL"
  while ! mcp_updating; do
    printf '\n%s\n' "$(now_utc_iso)"
    oc get mcp -A
    sleep "$INTERVAL"
  done

  start_epoch="$(date +%s)"
  init_csv
  init_events_log
  if [[ "$CEPH_OPERATOR_LOGS" == "1" ]]; then
    init_ceph_operator_log
  fi
  init_node_tracking

  printf '\n%s mcp/%s Updating=True — timer started\n' "$(now_utc_iso)" "$MCP"
  oc get mcp -A
  oc get machineconfignode -o wide 2>/dev/null || true

  printf '%s Waiting for mcp/%s rollout to complete (Updating=False, Updated=True, all machines updated)\n' \
    "$(now_utc_iso)" "$MCP"
  print_tracking_status

  poll_count=0
  while ! mcp_rollout_complete; do
    sleep "$(current_poll_interval)"
    poll_count="$((poll_count + 1))"
    if (( poll_count % 60 == 0 )); then
      verify_oc_session
    fi
    poll_rollout
    print_tracking_status
    oc get mcp -A
  done

  finalize_rollout
fi
