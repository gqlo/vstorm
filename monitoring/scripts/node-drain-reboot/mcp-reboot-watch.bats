#!/usr/bin/env bats
# Unit tests for mcp-reboot-watch.sh node-phase CSV timing (independent of MCN).

load 'test-helpers'

setup() {
  mcp_watch_test_setup_dir
  mcp_watch_test_load_lib
  mcp_watch_write_mcp_json "False" "False" 1 0
  : >"$LOG_FILE"
}

teardown() {
  mcp_watch_test_teardown_dir
}

@test "mcp-watch: script has valid bash syntax" {
  bash -n "$MCP_WATCH_SCRIPT"
}

@test "mcp-watch: CSV row written when node phases complete without MCN UPDATED=True" {
  local node="nodea"

  mcp_watch_write_nodes_json "$node" false True
  mcp_watch_write_mcn_json "$node" "rendered-worker-new" "rendered-worker-old" "False"

  worker_nodes=("$node")
  init_csv

  set_milestone_iso "$node" "cordoned" "2026-09-07T00:08:09Z" "observed"
  set_milestone_iso "$node" "drain_done" "2026-09-07T00:14:25Z" "observed"
  set_milestone_iso "$node" "boot_done" "2026-09-07T00:19:22Z" "observed"

  try_write_node_phase_csv "$node" "$start_epoch" "$(fetch_nodes_json)"
  try_record_mcn_completion "$node" "$start_epoch" "$(fetch_mcn_json)"

  [[ "$(mcp_watch_csv_row_count)" -eq 1 ]]
  [[ ! -v mcn_finished["$node"] ]]
}

@test "mcp-watch: node_start_time and node_end_time match cordoned_ts and boot_done_ts" {
  local node="nodeb"
  local cord="2026-09-07T01:00:00Z" drain="2026-09-07T01:05:00Z" boot="2026-09-07T01:10:00Z"

  mcp_watch_write_nodes_json "$node" false True
  mcp_watch_write_mcn_json "$node" "rendered-worker-new" "rendered-worker-old" "False"

  worker_nodes=("$node")
  init_csv

  set_milestone_iso "$node" "cordoned" "$cord" "observed"
  set_milestone_iso "$node" "drain_done" "$drain" "observed"
  set_milestone_iso "$node" "boot_done" "$boot" "observed"
  try_write_node_phase_csv "$node" "$start_epoch" "$(fetch_nodes_json)"

  [[ "$(mcp_watch_csv_field "$node" 5)" == "$cord" ]]
  [[ "$(mcp_watch_csv_field "$node" 6)" == "$boot" ]]
  [[ "$(mcp_watch_csv_field "$node" 7)" == "$cord" ]]
  [[ "$(mcp_watch_csv_field "$node" 8)" == "$drain" ]]
  [[ "$(mcp_watch_csv_field "$node" 9)" == "$boot" ]]
  [[ "$(mcp_watch_csv_field "$node" 2)" == "300" ]]
  [[ "$(mcp_watch_csv_field "$node" 3)" == "300" ]]
  [[ "$(mcp_watch_csv_field "$node" 4)" == "600" ]]
}

@test "mcp-watch: no CSV row when only cordon and drain milestones exist" {
  local node="nodec"

  mcp_watch_write_nodes_json "$node" true False
  mcp_watch_write_mcn_json "$node" "rendered-worker-new" "rendered-worker-old" "False"

  worker_nodes=("$node")
  init_csv

  set_milestone_iso "$node" "cordoned" "2026-09-07T02:00:00Z" "observed"
  set_milestone_iso "$node" "drain_done" "2026-09-07T02:05:00Z" "observed"

  try_write_node_phase_csv "$node" "$start_epoch" "$(fetch_nodes_json)"

  [[ "$(mcp_watch_csv_row_count)" -eq 0 ]]
}

@test "mcp-watch: poll_rollout captures node transitions and writes CSV without MCN completion" {
  local node="noded"

  worker_nodes=("$node")
  init_csv

  mcp_watch_write_nodes_json "$node" false True
  mcp_watch_write_mcn_json "$node" "rendered-worker-new" "rendered-worker-old" "False"
  ensure_node_phase_tracking "$node" "$start_epoch" "$(fetch_nodes_json)"

  mcp_watch_write_nodes_json "$node" true True
  poll_rollout
  [[ -n "$(milestone_iso "$node" cordoned)" ]]

  mcp_watch_write_nodes_json "$node" true False
  poll_rollout
  [[ -n "$(milestone_iso "$node" drain_done)" ]]

  mcp_watch_write_nodes_json "$node" false True
  poll_rollout

  [[ "$(mcp_watch_csv_row_count)" -eq 1 ]]
  [[ ! -v mcn_finished["$node"] ]]
  [[ "$(mcp_watch_csv_field "$node" 7)" == "$(milestone_iso "$node" cordoned)" ]]
  [[ "$(mcp_watch_csv_field "$node" 9)" == "$(milestone_iso "$node" boot_done)" ]]
}

@test "mcp-watch: CSV row is not written twice on repeated poll_rollout" {
  local node="nodee"

  mcp_watch_write_nodes_json "$node" false True
  mcp_watch_write_mcn_json "$node" "rendered-worker-new" "rendered-worker-old" "False"

  worker_nodes=("$node")
  init_csv

  set_milestone_iso "$node" "cordoned" "2026-09-07T03:00:00Z" "observed"
  set_milestone_iso "$node" "drain_done" "2026-09-07T03:05:00Z" "observed"
  set_milestone_iso "$node" "boot_done" "2026-09-07T03:10:00Z" "observed"

  poll_rollout
  poll_rollout

  [[ "$(mcp_watch_csv_row_count)" -eq 1 ]]
  [[ "${nodes_phases_done}" -eq 1 ]]
}

@test "mcp-watch: MCN completion is logged independently and does not write CSV" {
  local node="nodef"

  mcp_watch_write_nodes_json "$node" false True
  mcp_watch_write_mcn_json "$node" "rendered-worker-testcfg" "rendered-worker-testcfg" "True"

  worker_nodes=("$node")
  init_csv
  mcn_start_epoch["$node"]="$start_epoch"

  oc() {
    if [[ "$1" == get && "$2" == mcp ]]; then
      echo "1"
      return 0
    fi
    command oc "$@"
  }

  try_record_mcn_completion "$node" "$((start_epoch + 120))" "$(fetch_mcn_json)"

  [[ -v mcn_finished["$node"] ]]
  [[ "$mcn_finished_count" -eq 1 ]]
  [[ "$(mcp_watch_csv_row_count)" -eq 0 ]]
}

@test "mcp-watch: mcp_rollout_complete when Updating=False Updated=True and all machines updated" {
  mcp_watch_write_mcp_json "False" "True" 3 3
  mcp_rollout_complete
}

@test "mcp-watch: mcp_rollout_complete is false while pool is still updating" {
  mcp_watch_write_mcp_json "True" "False" 3 1
  ! mcp_rollout_complete
}

@test "mcp-watch: mcp_rollout_complete is false when updatedMachineCount below machineCount" {
  mcp_watch_write_mcp_json "False" "True" 3 2
  ! mcp_rollout_complete
}
