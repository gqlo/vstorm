#!/usr/bin/env bats
# Extract the embedded stress-ng script from cloud-init YAML and test it (syntax, startup output).
# No standalone script file: the YAML is the source of truth; we extract at test time.

load 'helpers'

YAML="workload/cloudinit-stress-ng-workload.yaml"

# The embedded script installs stress-ng when missing, then prints startup.
# CI/minimal runners often have no stress-ng and no working package install;
# prepend a no-op stress-ng so runtime tests see the banner and branch lines.
setup_file() {
    _WL_MOCK_STRESS_BIN=$(mktemp -d)
    cat > "$_WL_MOCK_STRESS_BIN/stress-ng" << 'MOCKEOF'
#!/bin/bash
exit 0
MOCKEOF
    chmod +x "$_WL_MOCK_STRESS_BIN/stress-ng"
    export PATH="$_WL_MOCK_STRESS_BIN:$PATH"
}

teardown_file() {
    [[ -n "${_WL_MOCK_STRESS_BIN:-}" ]] && rm -rf "$_WL_MOCK_STRESS_BIN"
}

# Extract the first write_files content block (the script) from the YAML.
# Output: script with leading 6-space indent stripped, to a temp file; echo path.
# Caller must not delete the file if they need it; we use it in the same test.
_extract_stress_script() {
    local out
    out=$(mktemp)
    # First write_files content block only (script); next "  - path:" ends it.
    awk '
        /^    content: \|$/ && !block_done { in_block=1; next }
        in_block && /^  - path:/ { in_block=0; block_done=1; next }
        in_block {
            if (/^      .*/) print substr($0, 7)
            else if (/^[[:space:]]*$/) print ""
        }
    ' "$YAML" > "$out"
    echo "$out"
}

# ---------------------------------------------------------------
# WL-1: Script can be extracted from cloud-init YAML
# ---------------------------------------------------------------
@test "WL: script can be extracted from cloudinit YAML" {
    local script_path
    script_path=$(_extract_stress_script)
    [[ -f "$script_path" ]]
    [[ -s "$script_path" ]]
    grep -q '#!/bin/bash' "$script_path"
    grep -q 'CPU_ACTIVE_PROBABILITY' "$script_path"
    grep -q 'random_range' "$script_path"
    rm -f "$script_path"
}

# ---------------------------------------------------------------
# WL-2: Extracted script has valid bash syntax
# ---------------------------------------------------------------
@test "WL: extracted script has valid bash syntax" {
    local script_path
    script_path=$(_extract_stress_script)
    run bash -n "$script_path"
    rm -f "$script_path"
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------
# WL-3: Extracted script runs and prints startup line (CPU_ACTIVE_PROBABILITY)
# ---------------------------------------------------------------
@test "WL: extracted script runs and prints startup with CPU_ACTIVE_PROBABILITY" {
    local script_path
    script_path=$(_extract_stress_script)
    # Run with timeout; script runs forever so we only need first second of output
    run timeout 2 bash "$script_path" 2>/dev/null || true
    rm -f "$script_path"
    # Expect startup banner (may be truncated by timeout)
    [[ "$output" == *"Starting workload simulation"* ]]
    [[ "$output" == *"CPU_ACTIVE_PROBABILITY"* ]]
}

# ---------------------------------------------------------------
# Branch coverage: force each if/else path via env (CPU/MEM_ACTIVE_PROBABILITY, STRESS_TOGETHER).
# Use short duration so first cycle completes within timeout.
# ---------------------------------------------------------------
@test "WL: branch IDLE - neither CPU nor memory active" {
    local script_path
    script_path=$(_extract_stress_script)
    export CPU_ACTIVE_PROBABILITY=0 MEM_ACTIVE_PROBABILITY=0 DURATION_MIN=1 DURATION_MAX=1
    run timeout 4 bash "$script_path" 2>/dev/null || true
    rm -f "$script_path"
    [[ "$output" == *"IDLE - Sleeping"* ]]
}

@test "WL: branch CPU only - CPU active, memory not" {
    local script_path
    script_path=$(_extract_stress_script)
    export CPU_ACTIVE_PROBABILITY=100 MEM_ACTIVE_PROBABILITY=0 DURATION_MIN=1 DURATION_MAX=1
    run timeout 5 bash "$script_path" 2>/dev/null || true
    rm -f "$script_path"
    [[ "$output" == *"CPU only"* ]]
    [[ "$output" == *"Running CPU stress"* ]]
}

@test "WL: branch MEM only - memory active, CPU not" {
    local script_path
    script_path=$(_extract_stress_script)
    export CPU_ACTIVE_PROBABILITY=0 MEM_ACTIVE_PROBABILITY=100 DURATION_MIN=1 DURATION_MAX=1
    run timeout 5 bash "$script_path" 2>/dev/null || true
    rm -f "$script_path"
    [[ "$output" == *"MEM only"* ]]
    [[ "$output" == *"Running memory stress"* ]]
}

@test "WL: branch both together - STRESS_TOGETHER=true" {
    local script_path
    script_path=$(_extract_stress_script)
    export CPU_ACTIVE_PROBABILITY=100 MEM_ACTIVE_PROBABILITY=100 STRESS_TOGETHER=true DURATION_MIN=1 DURATION_MAX=1
    run timeout 5 bash "$script_path" 2>/dev/null || true
    rm -f "$script_path"
    [[ "$output" == *"ACTIVE (together)"* ]]
    [[ "$output" == *"Running stress test"* ]]
}

@test "WL: branch both separate - STRESS_TOGETHER=false" {
    local script_path
    script_path=$(_extract_stress_script)
    export CPU_ACTIVE_PROBABILITY=100 MEM_ACTIVE_PROBABILITY=100 STRESS_TOGETHER=false DURATION_MIN=1 DURATION_MAX=1
    run timeout 5 bash "$script_path" 2>/dev/null || true
    rm -f "$script_path"
    [[ "$output" == *"ACTIVE (separate)"* ]]
    [[ "$output" == *"CPU "*"s, Memory "*"s"* ]]
}

# ---------------------------------------------------------------
# CUSTOM-OPTS: when STRESS_NG_CUSTOM_OPTS is set, active cycles use it
# ---------------------------------------------------------------
@test "WL: branch CUSTOM-OPTS when STRESS_NG_CUSTOM_OPTS is set" {
    local script_path
    script_path=$(_extract_stress_script)
    export STRESS_NG_CUSTOM_OPTS="--vm 1 --vm-bytes 10M --vm-hang 0"
    export CPU_ACTIVE_PROBABILITY=100 MEM_ACTIVE_PROBABILITY=100 DURATION_MIN=1 DURATION_MAX=1
    run timeout 5 bash "$script_path" 2>/dev/null || true
    rm -f "$script_path"
    [[ "$output" == *"CUSTOM-OPTS"* ]]
    [[ "$output" == *"Running stress-ng for"* ]]
}

@test "WL: CUSTOM-OPTS startup banner when STRESS_NG_CUSTOM_OPTS is set" {
    local script_path
    script_path=$(_extract_stress_script)
    export STRESS_NG_CUSTOM_OPTS="--vm 1 --vm-bytes 10M"
    run timeout 2 bash "$script_path" 2>/dev/null || true
    rm -f "$script_path"
    [[ "$output" == *"STRESS_NG_CUSTOM_OPTS is set"* ]]
    [[ "$output" == *"CUSTOM-OPTS branch"* ]]
}

@test "WL: CUSTOM-OPTS set but IDLE cycle still sleeps (no custom run)" {
    local script_path
    script_path=$(_extract_stress_script)
    export STRESS_NG_CUSTOM_OPTS="--vm 1 --vm-bytes 10M --vm-hang 0"
    export CPU_ACTIVE_PROBABILITY=0 MEM_ACTIVE_PROBABILITY=0 DURATION_MIN=1 DURATION_MAX=1
    run timeout 4 bash "$script_path" 2>/dev/null || true
    rm -f "$script_path"
    [[ "$output" == *"IDLE - Sleeping"* ]]
    # When IDLE we never run the custom stress-ng; cycle line is IDLE not CUSTOM-OPTS
    [[ "$output" != *"Cycle 1: CUSTOM-OPTS"* ]]
}

@test "WL: CUSTOM-OPTS unset uses normal CPU-only branch" {
    local script_path
    script_path=$(_extract_stress_script)
    unset STRESS_NG_CUSTOM_OPTS
    export CPU_ACTIVE_PROBABILITY=100 MEM_ACTIVE_PROBABILITY=0 DURATION_MIN=1 DURATION_MAX=1
    run timeout 5 bash "$script_path" 2>/dev/null || true
    rm -f "$script_path"
    [[ "$output" == *"CPU only"* ]]
    [[ "$output" != *"CUSTOM-OPTS"* ]]
}
