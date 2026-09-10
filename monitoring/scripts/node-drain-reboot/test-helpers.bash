# Helpers for mcp-reboot-watch.bats (source-only; not executed directly).

MCP_WATCH_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MCP_WATCH_SCRIPT="${MCP_WATCH_SCRIPT_DIR}/mcp-reboot-watch.sh"

mcp_watch_test_setup_dir() {
  MCP_WATCH_TEST_DIR=$(mktemp -d)
  export MCP_WATCH_TEST_DIR
  export CSV_FILE="${MCP_WATCH_TEST_DIR}/timing.csv"
  export LOG_FILE="${MCP_WATCH_TEST_DIR}/watch.log"
  export EVENTS_FILE="${MCP_WATCH_TEST_DIR}/events.tsv"
  export CEPH_OPERATOR_LOGS=0
  export MCP=worker
  : >"$LOG_FILE"
}

mcp_watch_test_teardown_dir() {
  [[ -n "${MCP_WATCH_TEST_DIR:-}" ]] && rm -rf "$MCP_WATCH_TEST_DIR"
  unset MCP_WATCH_TEST_DIR
}

mcp_watch_test_reset_state() {
  worker_nodes=()
  nodes_phases_done=0
  mcn_finished_count=0
  machine_count=1
  start_epoch=1700000000
  TARGET_CFG="rendered-worker-testcfg"

  unset node_csv_written node_phase_tracking_init mcn_start_epoch mcn_finished
  unset node_milestone_iso node_milestone_source node_event_milestone_iso
  unset node_duration_secs node_end_epoch node_drain_secs node_boot_secs
  unset node_prev_unschedulable node_prev_ready node_initial_unschedulable
  unset seen_event_keys

  declare -gA node_csv_written=()
  declare -gA node_phase_tracking_init=()
  declare -gA mcn_start_epoch=()
  declare -gA mcn_finished=()
  declare -gA node_milestone_iso=()
  declare -gA node_milestone_source=()
  declare -gA node_event_milestone_iso=()
  declare -gA node_duration_secs=()
  declare -gA node_end_epoch=()
  declare -gA node_drain_secs=()
  declare -gA node_boot_secs=()
  declare -gA node_prev_unschedulable=()
  declare -gA node_prev_ready=()
  declare -gA node_initial_unschedulable=()
  declare -gA seen_event_keys=()
}

mcp_watch_test_load_lib() {
  # shellcheck disable=SC1090
  source "$MCP_WATCH_SCRIPT"

  fetch_nodes_json() {
    cat "${MCP_WATCH_TEST_NODES_JSON:?set MCP_WATCH_TEST_NODES_JSON}"
  }
  fetch_mcn_json() {
    cat "${MCP_WATCH_TEST_MCN_JSON:?set MCP_WATCH_TEST_MCN_JSON}"
  }
  fetch_mcp_json() {
    cat "${MCP_WATCH_TEST_MCP_JSON:?set MCP_WATCH_TEST_MCP_JSON}"
  }
  save_rollout_events() { :; }
  save_ceph_operator_logs() { :; }

  mcp_watch_test_reset_state
}

mcp_watch_write_nodes_json() {
  local node="$1" unsched="$2" ready="$3" path="${MCP_WATCH_TEST_DIR}/nodes.json"

  cat >"$path" <<EOF
{
  "items": [{
    "metadata": {"name": "$node"},
    "spec": {"unschedulable": $unsched},
    "status": {
      "conditions": [{"type": "Ready", "status": "$ready"}]
    }
  }]
}
EOF
  export MCP_WATCH_TEST_NODES_JSON="$path"
}

mcp_watch_write_mcn_json() {
  local node="$1" desired="$2" current="$3" updated="$4" path="${MCP_WATCH_TEST_DIR}/mcn.json"

  cat >"$path" <<EOF
{
  "items": [{
    "metadata": {"name": "$node"},
    "spec": {"pool": {"name": "worker"}},
    "status": {
      "configVersion": {"desired": "$desired", "current": "$current"},
      "conditions": [{"type": "Updated", "status": "$updated"}]
    }
  }]
}
EOF
  export MCP_WATCH_TEST_MCN_JSON="$path"
}

# updating/updated: True or False; machine_count/updated_count: integers
mcp_watch_write_mcp_json() {
  local updating="${1:-True}" updated="${2:-False}" machine_count="${3:-1}" updated_count="${4:-0}"
  local path="${MCP_WATCH_TEST_DIR}/mcp.json"

  cat >"$path" <<EOF
{
  "status": {
    "machineCount": $machine_count,
    "updatedMachineCount": $updated_count,
    "readyMachineCount": $updated_count,
    "conditions": [
      {"type": "Updating", "status": "$updating"},
      {"type": "Updated", "status": "$updated"},
      {"type": "Degraded", "status": "False"}
    ]
  }
}
EOF
  export MCP_WATCH_TEST_MCP_JSON="$path"
}

mcp_watch_csv_data_rows() {
  [[ -f "$CSV_FILE" ]] || return 0
  tail -n +2 "$CSV_FILE" | grep -v '^ALL_NODES,' || true
}

mcp_watch_csv_row_count() {
  mcp_watch_csv_data_rows | grep -c . || true
}

mcp_watch_csv_field() {
  local node="$1" col="$2"
  mcp_watch_csv_data_rows | awk -F, -v n="$node" -v c="$col" '
    $1 == n { print $c; exit }
  '
}
