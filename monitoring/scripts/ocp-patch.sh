#!/usr/bin/env bash
set -euo pipefail

readonly HCO_NAMESPACE="openshift-cnv"
readonly HCO_RESOURCE="hyperconverged"
readonly HCO_NAME="kubevirt-hyperconverged"

readonly DESCHED_NAMESPACE="openshift-kube-descheduler-operator"
readonly DESCHED_RESOURCE="kubedescheduler"
readonly DESCHED_NAME="cluster"

usage() {
  cat <<'EOF'
Usage:
  ocp-patch.sh <command> [args]

Commands:
  live-migration-limit|lm [parallel_per_cluster] [parallel_outbound_per_node]
      Patch HyperConverged spec.liveMigrationConfig (default: 50 10).

  descheduler-eviction-limits|desched [evictions_per_node] [evictions_total]
      Patch KubeDescheduler spec.evictionLimits (default: 10 50).

  help|-h|--help
      Show this help.

Examples:
  ocp-patch.sh lm                      # defaults: cluster=50, node=10
  ocp-patch.sh lm 40 8                 # cluster=40, outbound per node=8
  ocp-patch.sh desched                 # defaults: node=10, total=50
  ocp-patch.sh desched 12 60           # node=12, total=60
EOF
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

is_positive_integer() {
  [[ "${1:-}" =~ ^[1-9][0-9]*$ ]]
}

require_positive_integer() {
  local value="$1"
  local name="$2"
  is_positive_integer "$value" || die "$name must be a positive integer, got '$value'"
}

require_arg_count() {
  local expected="$1"
  local actual="$2"
  local command="$3"

  [[ "$actual" -eq "$expected" ]] || {
    usage >&2
    die "'$command' expects $expected argument(s), got $actual"
  }
}

patch_live_migration_limit() {
  local parallel_per_cluster="${1:-50}"
  local parallel_outbound_per_node="${2:-10}"
  local current_cluster
  local current_node
  local updated_cluster
  local updated_node
  local payload

  require_positive_integer "$parallel_per_cluster" "parallel_per_cluster"
  require_positive_integer "$parallel_outbound_per_node" "parallel_outbound_per_node"
  (( parallel_outbound_per_node < parallel_per_cluster )) || {
    die "parallel_outbound_per_node ($parallel_outbound_per_node) must be less than parallel_per_cluster ($parallel_per_cluster)"
  }

  payload="$(cat <<EOF
{
  "spec": {
    "liveMigrationConfig": {
      "parallelMigrationsPerCluster": $parallel_per_cluster,
      "parallelOutboundMigrationsPerNode": $parallel_outbound_per_node
    }
  }
}
EOF
)"

  current_cluster="$(oc get "$HCO_RESOURCE" "$HCO_NAME" -n "$HCO_NAMESPACE" -o jsonpath='{.spec.liveMigrationConfig.parallelMigrationsPerCluster}')"
  current_node="$(oc get "$HCO_RESOURCE" "$HCO_NAME" -n "$HCO_NAMESPACE" -o jsonpath='{.spec.liveMigrationConfig.parallelOutboundMigrationsPerNode}')"
  printf 'Current liveMigrationConfig: cluster=%s node=%s\n' "$current_cluster" "$current_node"

  oc patch "$HCO_RESOURCE" "$HCO_NAME" \
    -n "$HCO_NAMESPACE" \
    --type=merge \
    -p "$payload"

  updated_cluster="$(oc get "$HCO_RESOURCE" "$HCO_NAME" -n "$HCO_NAMESPACE" -o jsonpath='{.spec.liveMigrationConfig.parallelMigrationsPerCluster}')"
  updated_node="$(oc get "$HCO_RESOURCE" "$HCO_NAME" -n "$HCO_NAMESPACE" -o jsonpath='{.spec.liveMigrationConfig.parallelOutboundMigrationsPerNode}')"
  printf 'Updated liveMigrationConfig: cluster=%s node=%s\n' "$updated_cluster" "$updated_node"
}

patch_descheduler_eviction_limits() {
  local evictions_per_node="${1:-10}"
  local evictions_total="${2:-50}"
  local current_node
  local current_total
  local updated_node
  local updated_total
  local payload

  require_positive_integer "$evictions_per_node" "evictions_per_node"
  require_positive_integer "$evictions_total" "evictions_total"

  payload="$(cat <<EOF
{
  "spec": {
    "evictionLimits": {
      "node": $evictions_per_node,
      "total": $evictions_total
    }
  }
}
EOF
)"

  current_node="$(oc get "$DESCHED_RESOURCE" "$DESCHED_NAME" -n "$DESCHED_NAMESPACE" -o jsonpath='{.spec.evictionLimits.node}')"
  current_total="$(oc get "$DESCHED_RESOURCE" "$DESCHED_NAME" -n "$DESCHED_NAMESPACE" -o jsonpath='{.spec.evictionLimits.total}')"
  printf 'Current evictionLimits: node=%s total=%s\n' "$current_node" "$current_total"

  oc patch "$DESCHED_RESOURCE" "$DESCHED_NAME" \
    -n "$DESCHED_NAMESPACE" \
    --type=merge \
    -p "$payload"

  updated_node="$(oc get "$DESCHED_RESOURCE" "$DESCHED_NAME" -n "$DESCHED_NAMESPACE" -o jsonpath='{.spec.evictionLimits.node}')"
  updated_total="$(oc get "$DESCHED_RESOURCE" "$DESCHED_NAME" -n "$DESCHED_NAMESPACE" -o jsonpath='{.spec.evictionLimits.total}')"
  printf 'Updated evictionLimits: node=%s total=%s\n' "$updated_node" "$updated_total"
}

main() {
  local command="${1:-}"
  shift || true

  case "$command" in
    live-migration-limit|lm)
      [[ "$#" -le 2 ]] || die "'$command' accepts at most 2 argument(s), got $#"
      # ${n-} avoids nounset failure when optional args are omitted after shift
      patch_live_migration_limit "${1-}" "${2-}"
      ;;
    descheduler-eviction-limits|desched)
      [[ "$#" -le 2 ]] || die "'$command' accepts at most 2 argument(s), got $#"
      patch_descheduler_eviction_limits "${1-}" "${2-}"
      ;;
    help|-h|--help)
      usage
      ;;
    "")
      usage >&2
      exit 1
      ;;
    *)
      usage >&2
      die "unknown command '$command'"
      ;;
  esac
}

main "$@"
