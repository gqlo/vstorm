#!/usr/bin/env bats
# Test the HammerDB workload: splice wiring, JSON emission, and result-sync POST.
# The standalone workload/hammerdb/*.{sh,tcl,service} files are the source of
# truth; vstorm splices them into the cloud-init YAML via {HAMMERDB_*}.

load 'helpers'

YAML="workload/hammerdb/cloudinit-hammerdb-workload.yaml"
SCRIPT="workload/hammerdb/hammerdb_workload.sh"
SERVICE="workload/hammerdb/hammerdb-workload.service"
BUILD_TCL="workload/hammerdb/build.tcl"
RUN_TCL="workload/hammerdb/run.tcl"

setup_file() {
    # Splice tests run `vstorm -n`, which queries oc -- mock it.
    setup_oc_mock
    # Mock binaries the workload script calls. hammerdbcli is invoked as
    # `./hammerdbcli` after `cd "$HDB_HOME"`, so it lives in the same dir we
    # point HDB_HOME at; the DB tools are invoked by name from PATH.
    _HDB_MOCK_BIN=$(mktemp -d)
    export _HDB_MOCK_BIN
    cat > "$_HDB_MOCK_BIN/hammerdbcli" << 'MOCKEOF'
#!/bin/bash
# Usage: hammerdbcli auto <script>. Emulate a 6.0+ build/run: the build log must
# show "schema complete" with no error words; the run prints the NOPM/TPM result
# line and writes the `jobs save` JSON report under $TMP, echoing its path.
script="${2:-}"
case "$script" in
    *build*) echo "${HDB_MOCK_BUILD_OUT:-Vuser 1:Schema complete}" ;;
    *run*)
        echo "Vuser 1:TEST RESULT : System achieved 12345 NOPM from 67890 PostgreSQL TPM"
        jobfile="${TMP:-/tmp}/hdb_ABC123DEF.json"
        printf '%s\n' '{"jobid":"ABC123DEF","tproc-c":{"nopm":12345,"tpm":67890}}' > "$jobfile"
        echo "Saved job report JSON to $jobfile"
        ;;
esac
exit 0
MOCKEOF
    for _b in postgresql-setup systemctl sudo psql; do
        printf '#!/bin/bash\nexit 0\n' > "$_HDB_MOCK_BIN/$_b"
    done
    chmod +x "$_HDB_MOCK_BIN"/*
    export PATH="$_HDB_MOCK_BIN:$PATH"
}

teardown_file() {
    [[ -n "${_HDB_MOCK_BIN:-}" ]] && rm -rf "$_HDB_MOCK_BIN"
}

# Set up per-test temp paths and point the overridable script paths at them so the
# script runs end-to-end without touching /opt, /var/lib, or /root.
_hdb_prepare() {
    _HDB_WORK=$(mktemp -d)
    export HDB_HOME="$_HDB_MOCK_BIN"
    export PGDATA="$_HDB_WORK/pgdata"
    mkdir -p "$PGDATA"
    export HDB_BUILD_TCL="$PWD/$BUILD_TCL"
    export HDB_RUN_TCL="$PWD/$RUN_TCL"
    export HDB_BUILD_MARKER="$_HDB_WORK/build.done"
    export HDB_BUILD_LOG="$_HDB_WORK/build.log"
    export HDB_RESULT_TXT="$_HDB_WORK/result.txt"
    export HDB_RESULTS_DIR="$_HDB_WORK/results"
    export RESULT_TIMESTAMP_FILE="$_HDB_WORK/timestamp.txt"
    export HDB_RAMPUP=0 HDB_DURATION=0 HDB_WAREHOUSES=1 HDB_VU=1
    unset RESULT_SERVER_URL
}

_hdb_cleanup() {
    [[ -n "${_HDB_WORK:-}" ]] && rm -rf "$_HDB_WORK"
}

# ===================================================================
# Splice: standalone files are the source of truth
# ===================================================================

@test "HDB: profile carries placeholders, not embedded script/tcl bodies" {
    [[ -s "$SCRIPT" && -s "$BUILD_TCL" && -s "$RUN_TCL" && -s "$SERVICE" ]]
    grep -qE '^[[:space:]]*\{HAMMERDB_BUILD_TCL\}[[:space:]]*$' "$YAML"
    grep -qE '^[[:space:]]*\{HAMMERDB_RUN_TCL\}[[:space:]]*$' "$YAML"
    grep -qE '^[[:space:]]*\{HAMMERDB_WORKLOAD_SCRIPT\}[[:space:]]*$' "$YAML"
    grep -qE '^[[:space:]]*\{HAMMERDB_WORKLOAD_SERVICE\}[[:space:]]*$' "$YAML"
    # Body not re-embedded in the profile.
    run grep -q 'report_result' "$YAML"
    [ "$status" -ne 0 ]
}

@test "HDB: vstorm splices scripts, tcl, and unit into userdata byte-for-byte" {
    assert_spliced_matches "$YAML" "path: /opt/hammerdb_workload.sh" "$SCRIPT"
    assert_spliced_matches "$YAML" "path: /opt/hammerdb/build.tcl" "$BUILD_TCL"
    assert_spliced_matches "$YAML" "path: /opt/hammerdb/run.tcl" "$RUN_TCL"
    assert_spliced_matches "$YAML" "path: /etc/systemd/system/hammerdb-workload.service" "$SERVICE"
}

# ===================================================================
# JSON emission: run.tcl uses the 6.0+ jobs interface, not deprecated commands
# ===================================================================

@test "HDB: run.tcl emits JSON via the jobs interface (no deprecated commands)" {
    grep -q 'jobs format JSON' "$RUN_TCL"
    grep -q 'jobs \$jobid save' "$RUN_TCL"
    grep -q 'set jobid \[vurun\]' "$RUN_TCL"
    # No deprecated command invocation (comments mentioning it are fine; anchor to
    # command position at the start of a line).
    run grep -qE '^[[:space:]]*runtimer' "$RUN_TCL"
    [ "$status" -ne 0 ]
}

@test "HDB: build.tcl drops deprecated waittocomplete" {
    grep -q 'buildschema' "$BUILD_TCL"
    run grep -qE '^[[:space:]]*waittocomplete' "$BUILD_TCL"
    [ "$status" -ne 0 ]
}

@test "HDB: workload script has valid bash syntax" {
    run bash -n "$SCRIPT"
    [ "$status" -eq 0 ]
}

@test "HDB: systemd unit is oneshot ordered after boot-timestamp" {
    grep -q 'Type=oneshot' "$SERVICE"
    grep -q 'After=.*vstorm-boot-timestamp.service' "$SERVICE"
}

# ===================================================================
# End-to-end run under mocks
# ===================================================================

@test "HDB: run parses NOPM/TPM, writes JSON report, finishes locally without POST" {
    _hdb_prepare
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"NOPM=12345"* ]]
    [[ "$output" == *"TPM=67890"* ]]
    [[ "$output" == *"HammerDB run finished"* ]]
    # jobs-save JSON report landed in the results dir, result text kept for humans.
    [[ -f "$HDB_RESULTS_DIR/hdb_ABC123DEF.json" ]]
    grep -q 'System achieved 12345 NOPM' "$HDB_RESULT_TXT"
    # No RESULT_SERVER_URL -> no canonical payload built.
    [[ ! -f "$HDB_RESULTS_DIR/tproc-c-payload.json" ]]
    _hdb_cleanup
}

@test "HDB: build guard accepts the 6.0+ completion marker without 'schema complete'" {
    _hdb_prepare
    export HDB_MOCK_BUILD_OUT="Vuser 1:ALL VIRTUAL USERS COMPLETE"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"HammerDB run finished"* ]]
    _hdb_cleanup
}

@test "HDB: build guard does not abort on benign 'error' text in the log" {
    _hdb_prepare
    export HDB_MOCK_BUILD_OUT=$'Vuser 1:Schema complete\nVuser 1:0 errors reported'
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"HammerDB run finished"* ]]
    _hdb_cleanup
}

@test "HDB: builds canonical result payload and spools when collector unreachable" {
    _hdb_prepare
    export RESULT_SERVER_URL="http://127.0.0.1:1/v1/results"
    export VSTORM_BATCH_ID="hdbtest"
    export RESULT_RETRY=1 RESULT_TIMEOUT=1
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"POST failed"* || "$output" == *"Collector unreachable"* ]]
    local payload="$HDB_RESULTS_DIR/tproc-c-payload.json"
    local pending="$HDB_RESULTS_DIR/pending/tproc-c-payload.json"
    [[ -f "$payload" ]]
    grep -q '"record_type": "result"' "$payload"
    grep -q '"workload_kind": "hammerdb"' "$payload"
    grep -q '"batch_id": "hdbtest"' "$payload"
    grep -q '"nopm": 12345' "$payload"
    grep -q '"tpm": 67890' "$payload"
    grep -q '"hammerdb_report"' "$payload"
    [[ -f "$pending" ]]
    _hdb_cleanup
}
