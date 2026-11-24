#!/usr/bin/env bats
# Test the fio workload script (syntax, one-shot run, branch coverage).
# The standalone workload/fio_workload.sh is the source of truth; vstorm splices
# it into the cloud-init YAML at runtime via {FIO_WORKLOAD_SCRIPT}.

load 'helpers'

YAML="workload/cloudinit-fio-workload.yaml"
SCRIPT="workload/fio_workload.sh"
SERVICE="workload/fio-workload.service"

setup_file() {
    # The splice test runs `vstorm -n`, which queries oc during access-mode
    # detection -- mock it so tests never touch a real cluster.
    setup_oc_mock
    _WL_MOCK_FIO_BIN=$(mktemp -d)
    _WL_FIO_ARGS_FILE=$(mktemp)
    export _WL_FIO_ARGS_FILE
    cat > "$_WL_MOCK_FIO_BIN/fio" << MOCKEOF
#!/bin/bash
{
    printf '%s\n' "\$@"
    printf '\n---\n'
} >> "$_WL_FIO_ARGS_FILE"
out=""
args=("\$@")
for ((i=0; i<\${#args[@]}; i++)); do
    case "\${args[i]}" in
        --output=*) out="\${args[i]#--output=}" ;;
        --output)
            if (( i + 1 < \${#args[@]} )); then out="\${args[i+1]}"; fi
            ;;
    esac
done
if [[ -n "\$out" ]]; then
    mkdir -p "\$(dirname "\$out")"
    printf '%s\n' '{"jobs":[{"jobname":"mock","read":{"iops":1,"bw_bytes":1,"lat_ns":{"mean":1}},"write":{"iops":1,"bw_bytes":1,"lat_ns":{"mean":1}}}]}' > "\$out"
fi
exit 0
MOCKEOF
    chmod +x "$_WL_MOCK_FIO_BIN/fio"
    export PATH="$_WL_MOCK_FIO_BIN:$PATH"

    _WL_FIO_DIR=$(mktemp -d)
    export FIO_DIRECTORY="$_WL_FIO_DIR"
    export RESULT_TIMESTAMP_FILE="$_WL_FIO_DIR/timestamp.txt"
}

teardown_file() {
    [[ -n "${_WL_MOCK_FIO_BIN:-}" ]] && rm -rf "$_WL_MOCK_FIO_BIN"
    [[ -n "${_WL_FIO_DIR:-}" ]] && rm -rf "$_WL_FIO_DIR"
    [[ -n "${_WL_FIO_ARGS_FILE:-}" ]] && rm -f "$_WL_FIO_ARGS_FILE"
}

_extract_fio_script() {
    local out
    out=$(mktemp)
    cp "$SCRIPT" "$out"
    echo "$out"
}

_fio_args_reset() {
    : > "$_WL_FIO_ARGS_FILE"
}

_fio_args() {
    cat "$_WL_FIO_ARGS_FILE"
}

_fio_prepare() {
    unset RESULT_SERVER_URL
    _fio_args_reset
}

@test "FIO: standalone script is the source of truth and profile uses the placeholder" {
    [[ -f "$SCRIPT" ]]
    [[ -s "$SCRIPT" ]]
    grep -q '#!/bin/bash' "$SCRIPT"
    grep -q 'WORKLOAD_TYPE' "$SCRIPT"
    grep -q 'one-shot' "$SCRIPT"
    grep -q 'FIO_TIME_BASED' "$SCRIPT"
    # Profile carries placeholders (script + service), not embedded copies.
    grep -qE '^[[:space:]]*\{FIO_WORKLOAD_SCRIPT\}[[:space:]]*$' "$YAML"
    grep -qE '^[[:space:]]*\{FIO_WORKLOAD_SERVICE\}[[:space:]]*$' "$YAML"
    # `run` + status: a bare `! grep` is exempt from bats' errexit and would not
    # fail the test if the script body were re-embedded in the profile.
    run grep -q 'WORKLOAD_TYPE' "$YAML"
    [ "$status" -ne 0 ]
}

# vstorm splices the standalone script + unit into the Secret byte-for-byte.
@test "FIO: vstorm splices script and service into cloud-init userdata byte-for-byte" {
    assert_spliced_matches "$YAML" "path: /opt/fio_workload.sh" "$SCRIPT"
    assert_spliced_matches "$YAML" "path: /etc/systemd/system/fio-workload.service" "$SERVICE"
}

@test "FIO: extracted script has valid bash syntax" {
    local script_path
    script_path=$(_extract_fio_script)
    run bash -n "$script_path"
    rm -f "$script_path"
    [ "$status" -eq 0 ]
}

@test "FIO: extracted script runs and prints startup with WORKLOAD_TYPE" {
    local script_path
    script_path=$(_extract_fio_script)
    export FIO_RUNTIME=1
    _fio_prepare
    run bash "$script_path" 2>/dev/null
    rm -f "$script_path"
    [[ "$output" == *"Starting fio workload"* ]]
    [[ "$output" == *"one-shot"* ]]
    [[ "$output" == *"WORKLOAD_TYPE"* ]]
    [[ "$output" == *"One-shot workload finished"* ]]
}

@test "FIO: branch ACTIVE default randrw" {
    local script_path args
    script_path=$(_extract_fio_script)
    unset FIO_CUSTOM_OPTS WORKLOAD_TYPE FIO_RW FIO_TIME_BASED FIO_SIZE
    _fio_prepare
    run bash "$script_path" 2>/dev/null
    rm -f "$script_path"
    [[ "$output" == *"WORKLOAD_TYPE=randrw"* ]]
    [[ "$output" == *"ACTIVE - Running fio"* ]]
    [[ "$output" == *"until size="* ]]
    args=$(_fio_args)
    [[ "$args" == *"--rw=randrw"* ]]
    [[ "$args" == *"--size=1G"* ]]
    [[ "$args" == *"--name=job1"* ]]
    [[ "$args" != *"--time_based"* ]]
    [[ "$args" != *"--runtime="* ]]
}

@test "FIO: branch ACTIVE with WORKLOAD_TYPE=randread" {
    local script_path args
    script_path=$(_extract_fio_script)
    unset FIO_CUSTOM_OPTS FIO_TIME_BASED FIO_RW
    export WORKLOAD_TYPE=randread FIO_SIZE=512M
    _fio_prepare
    run bash "$script_path" 2>/dev/null
    rm -f "$script_path"
    [[ "$output" == *"WORKLOAD_TYPE=randread"* ]]
    [[ "$output" == *"ACTIVE - Running fio (randread"* ]]
    args=$(_fio_args)
    [[ "$args" == *"--rw=randread"* ]]
    [[ "$args" == *"--size=512M"* ]]
}

@test "FIO: branch ACTIVE with WORKLOAD_TYPE=randrw" {
    local script_path args
    script_path=$(_extract_fio_script)
    unset FIO_CUSTOM_OPTS FIO_TIME_BASED FIO_RW
    export WORKLOAD_TYPE=randrw FIO_SIZE=256M
    _fio_prepare
    run bash "$script_path" 2>/dev/null
    rm -f "$script_path"
    [[ "$output" == *"WORKLOAD_TYPE=randrw"* ]]
    args=$(_fio_args)
    [[ "$args" == *"--rw=randrw"* ]]
    [[ "$args" == *"--size=256M"* ]]
}

@test "FIO: branch ACTIVE with WORKLOAD_TYPE=seqwrite" {
    local script_path args
    script_path=$(_extract_fio_script)
    unset FIO_CUSTOM_OPTS FIO_TIME_BASED FIO_RW
    export WORKLOAD_TYPE=seqwrite FIO_SIZE=128M
    _fio_prepare
    run bash "$script_path" 2>/dev/null
    rm -f "$script_path"
    [[ "$output" == *"WORKLOAD_TYPE=seqwrite"* ]]
    [[ "$output" == *"ACTIVE - Running fio (write"* ]]
    args=$(_fio_args)
    [[ "$args" == *"--rw=write"* ]]
    [[ "$args" == *"--size=128M"* ]]
}

@test "FIO: branch ACTIVE with WORKLOAD_TYPE=seqread" {
    local script_path args
    script_path=$(_extract_fio_script)
    unset FIO_CUSTOM_OPTS FIO_TIME_BASED FIO_RW
    export WORKLOAD_TYPE=seqread FIO_SIZE=64M
    _fio_prepare
    run bash "$script_path" 2>/dev/null
    rm -f "$script_path"
    [[ "$output" == *"WORKLOAD_TYPE=seqread"* ]]
    [[ "$output" == *"ACTIVE - Running fio (read"* ]]
    args=$(_fio_args)
    [[ "$args" == *"--rw=read"* ]]
    [[ "$args" == *"--size=64M"* ]]
}

@test "FIO: branch CUSTOM-OPTS when FIO_CUSTOM_OPTS is set" {
    local script_path args
    script_path=$(_extract_fio_script)
    export FIO_CUSTOM_OPTS="--name=custom --rw=randread --bs=4k --size=1M"
    unset FIO_TIME_BASED
    _fio_prepare
    run bash "$script_path" 2>/dev/null
    rm -f "$script_path"
    [[ "$output" == *"CUSTOM-OPTS"* ]]
    [[ "$output" == *"Running fio (no runtime limit)"* ]]
    args=$(_fio_args)
    [[ "$args" == *"--rw=randread"* ]]
    [[ "$args" == *"--size=1M"* ]]
    [[ "$args" != *"--time_based"* ]]
}

@test "FIO: CUSTOM-OPTS with FIO_TIME_BASED=1 appends runtime" {
    local script_path args
    script_path=$(_extract_fio_script)
    export FIO_CUSTOM_OPTS="--name=custom --rw=randread --bs=4k --size=1M"
    export FIO_TIME_BASED=1 FIO_RUNTIME=1
    _fio_prepare
    run bash "$script_path" 2>/dev/null
    rm -f "$script_path"
    [[ "$output" == *"CUSTOM-OPTS"* ]]
    [[ "$output" == *"Running fio for"* ]]
    args=$(_fio_args)
    [[ "$args" == *"--time_based"* ]]
    [[ "$args" == *"--runtime=1"* ]]
}

@test "FIO: ACTIVE with FIO_TIME_BASED=1 adds time_based runtime" {
    local script_path args
    script_path=$(_extract_fio_script)
    unset FIO_CUSTOM_OPTS FIO_RW
    export WORKLOAD_TYPE=randwrite FIO_TIME_BASED=1 FIO_RUNTIME=7 FIO_SIZE=32M
    _fio_prepare
    run bash "$script_path" 2>/dev/null
    rm -f "$script_path"
    [[ "$output" == *"ACTIVE - Running fio (randwrite"* ]]
    [[ "$output" == *"for 7s"* ]]
    args=$(_fio_args)
    [[ "$args" == *"--rw=randwrite"* ]]
    [[ "$args" == *"--time_based"* ]]
    [[ "$args" == *"--runtime=7"* ]]
}

@test "FIO: CUSTOM-OPTS startup banner when FIO_CUSTOM_OPTS is set" {
    local script_path
    script_path=$(_extract_fio_script)
    export FIO_CUSTOM_OPTS="--name=custom --rw=randread"
    export FIO_RUNTIME=1
    _fio_prepare
    run bash "$script_path" 2>/dev/null
    rm -f "$script_path"
    [[ "$output" == *"FIO_CUSTOM_OPTS is set"* ]]
    [[ "$output" == *"CUSTOM-OPTS"* ]]
}

@test "FIO: CUSTOM-OPTS unset uses normal ACTIVE branch" {
    local script_path args
    script_path=$(_extract_fio_script)
    unset FIO_CUSTOM_OPTS FIO_TIME_BASED FIO_RW
    export WORKLOAD_TYPE=randwrite FIO_SIZE=16M
    _fio_prepare
    run bash "$script_path" 2>/dev/null
    rm -f "$script_path"
    [[ "$output" == *"ACTIVE - Running fio"* ]]
    [[ "$output" != *"CUSTOM-OPTS - Running fio"* ]]
    args=$(_fio_args)
    [[ "$args" == *"--rw=randwrite"* ]]
    [[ "$args" == *"--size=16M"* ]]
}

@test "FIO: uses fixed job1 name" {
    local script_path args
    script_path=$(_extract_fio_script)
    unset FIO_CUSTOM_OPTS FIO_TIME_BASED RESULT_SERVER_URL FIO_RW
    export WORKLOAD_TYPE=randrw FIO_SIZE=16M
    _fio_prepare
    run bash "$script_path" 2>/dev/null
    rm -f "$script_path"
    [[ "$output" == *"Job name: job1"* ]]
    args=$(_fio_args)
    [[ "$args" == *"--name=job1"* ]]
}

@test "FIO: timestamp file created on first start (standalone fallback)" {
    local script_path lines
    script_path=$(_extract_fio_script)
    unset FIO_CUSTOM_OPTS RESULT_SERVER_URL
    export FIO_SIZE=16M
    rm -f "$RESULT_TIMESTAMP_FILE"
    run bash "$script_path" 2>/dev/null
    [[ "$status" -eq 0 ]]
    rm -f "$script_path"
    [[ -f "$RESULT_TIMESTAMP_FILE" ]]
    lines=$(grep -cE '^[0-9]+,' "$RESULT_TIMESTAMP_FILE" || true)
    [[ "$lines" -ge 1 ]]
}

@test "FIO: skips non-numeric timestamp header when reading boot unix" {
    local script_path boot_line
    script_path=$(_extract_fio_script)
    unset FIO_CUSTOM_OPTS RESULT_SERVER_URL
    export FIO_SIZE=16M
    printf '%s\n' 'unix-timestamp, YYYY-MM-DDTHH:MM:SSZ' > "$RESULT_TIMESTAMP_FILE"
    run bash "$script_path" 2>/dev/null
    [[ "$status" -eq 0 ]]
    rm -f "$script_path"
    # Header alone: fio uses service start; does not fail
    [[ "$status" -eq 0 ]]
}

@test "FIO: boot timestamp unit is present and ordered before fio" {
    # Boot unit is referenced (placeholder path + runcmd enable) in the profile;
    # fio's unit orders itself after it (now in the standalone unit file).
    grep -q 'path: /opt/vstorm-boot-timestamp.sh' "$YAML"
    grep -q 'vstorm-boot-timestamp.service' "$YAML"
    grep -q 'After=.*vstorm-boot-timestamp.service' "$SERVICE"
}

@test "FIO: systemd unit is oneshot Restart=no" {
    grep -q 'Type=oneshot' "$SERVICE"
    grep -q 'Restart=no' "$SERVICE"
    # `run` + status: a bare `! grep` is exempt from bats' errexit and would not
    # fail the test if the unit were changed to Restart=always.
    run grep -q 'Restart=always' "$SERVICE"
    [ "$status" -ne 0 ]
}

@test "FIO: unreachable RESULT_SERVER_URL spools payload and still finishes" {
    local script_path pending payload
    script_path=$(_extract_fio_script)
    unset FIO_CUSTOM_OPTS FIO_TIME_BASED FIO_RW
    export WORKLOAD_TYPE=randrw FIO_SIZE=16M
    export RESULT_SERVER_URL="http://127.0.0.1:1/v1/results"
    export VSTORM_BATCH_ID="fiounreachable"
    export RESULT_RETRY=1
    export RESULT_TIMEOUT=1
    _fio_args_reset
    run bash "$script_path"
    rm -f "$script_path"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"One-shot workload finished"* ]]
    [[ "$output" == *"POST failed"* ]] || [[ "$output" == *"Collector unreachable"* ]]
    pending="$FIO_DIRECTORY/results/pending/job1-payload.json"
    payload="$FIO_DIRECTORY/results/job1-payload.json"
    [[ -f "$pending" ]]
    [[ -f "$payload" ]]
    grep -q '"record_type": "result"' "$pending"
    grep -q '"batch_id": "fiounreachable"' "$pending"
    # post_error notify may also be spooled when the collector stays down
    [[ -f "$FIO_DIRECTORY/results/job1-post-error.json" ]] || \
        [[ -f "$FIO_DIRECTORY/results/pending/job1-post-error.json" ]]
}

@test "FIO: unreachable RESULT_SERVER_URL does not prevent local fio success" {
    local script_path
    script_path=$(_extract_fio_script)
    unset FIO_CUSTOM_OPTS FIO_TIME_BASED FIO_RW
    export WORKLOAD_TYPE=randread FIO_SIZE=16M
    export RESULT_SERVER_URL="http://127.0.0.1:1/v1/results"
    export VSTORM_BATCH_ID="fiolocalok"
    export RESULT_RETRY=1
    export RESULT_TIMEOUT=1
    _fio_args_reset
    run bash "$script_path"
    rm -f "$script_path"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"fio completed successfully"* ]]
    [[ -f "$FIO_DIRECTORY/results/job1.json" ]]
}
