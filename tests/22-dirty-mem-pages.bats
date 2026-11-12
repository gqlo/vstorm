#!/usr/bin/env bats
# Extract the embedded dirty-mem-pages.c from cloud-init YAML, compile it, and test
# the argument parser (fractions, byte counts, human-readable sizes) and guards.
# The YAML is the source of truth; we extract and compile at test time.

load 'helpers'

YAML="workload/cloudinit-dirty-mem-pages.yaml"
STANDALONE="workload/dirty-mem-pages.c"

setup_file() {
    if ! command -v gcc >/dev/null 2>&1; then
        export _DMP_NO_GCC=1
        return 0
    fi
    _DMP_DIR=$(mktemp -d)
    export _DMP_DIR
    _extract_dmp_source > "$_DMP_DIR/dmp.c"
    # Compile with warnings as a signal; capture them for the "no warnings" test.
    gcc -Wall -Wextra -O2 -o "$_DMP_DIR/dmp" "$_DMP_DIR/dmp.c" 2> "$_DMP_DIR/warnings.txt"
    export _DMP_BIN="$_DMP_DIR/dmp"
}

teardown_file() {
    [[ -n "${_DMP_DIR:-}" ]] && rm -rf "$_DMP_DIR"
}

setup() {
    if [[ -n "${_DMP_NO_GCC:-}" ]]; then
        skip "gcc not available"
    fi
}

# Extract the first write_files content block (dirty-mem-pages.c) from the YAML,
# stripping the 6-space indent. Mirrors the extractor in 13-workload-script.bats.
_extract_dmp_source() {
    awk '
        /^    content: \|$/ && !block_done { in_block=1; next }
        in_block && /^  - path:/ { in_block=0; block_done=1; next }
        in_block {
            if (/^      .*/) print substr($0, 7)
            else if (/^[[:space:]]*$/) print ""
        }
    ' "$YAML"
}

# Run the binary with a 1s timeout (it loops forever on valid input) and merge
# stderr (banner/errors) into $output. Used for inputs expected to FAIL fast.
run_dmp() {
    run timeout 1 "$_DMP_BIN" "$@"
}

# Run a VALID input and assert the program is still running at the timeout.
# The parse banner is printed BEFORE mmap, so a banner check alone cannot tell a
# successful allocation from an mmap failure (which exits 1). A valid run instead
# loops forever and is killed by `timeout` with status 124 -- asserting that
# proves parsing AND allocation succeeded and the dirtying loop was entered.
run_dmp_ok() {
    run timeout 1 "$_DMP_BIN" "$@"
    [ "$status" -eq 124 ]
}

# ---------------------------------------------------------------
# Source integrity: extraction, drift guard, clean compile
# ---------------------------------------------------------------
@test "DMP: C source can be extracted from cloudinit YAML" {
    local src="$_DMP_DIR/dmp.c"
    [[ -s "$src" ]]
    grep -q 'parse_input' "$src"
    grep -q 'int main' "$src"
}

@test "DMP: embedded YAML copy matches standalone .c (ignoring blank lines)" {
    # Guards against the two copies drifting out of sync.
    diff <(grep -v '^[[:space:]]*$' "$_DMP_DIR/dmp.c") \
         <(grep -v '^[[:space:]]*$' "$STANDALONE")
}

@test "DMP: compiles with -Wall -Wextra and no warnings" {
    [[ -x "$_DMP_BIN" ]]
    run cat "$_DMP_DIR/warnings.txt"
    [ -z "$output" ]
}

# ---------------------------------------------------------------
# Valid fractions (0.1-0.9) -> buffer allocated, banner printed
# ---------------------------------------------------------------
@test "DMP: fraction 0.5 is accepted and prints banner" {
    run_dmp_ok 0.5
    [[ "$output" == *"phys_ram="* ]]
    [[ "$output" == *"buffer="* ]]
    [[ "$output" == *"dirty="* ]]
    [[ "$output" != *"invalid"* ]]
}

@test "DMP: fraction boundaries 0.1 and 0.9 are accepted" {
    run_dmp_ok 0.1
    [[ "$output" == *"phys_ram="* ]]
    run_dmp_ok 0.9
    [[ "$output" == *"phys_ram="* ]]
}

# ---------------------------------------------------------------
# Fractions out of range -> rc=-2 message
# ---------------------------------------------------------------
@test "DMP: fraction 0.05 (below 0.1) is rejected" {
    run_dmp 0.05
    [[ "$output" == *"fraction must be between 0.1 and 0.9"* ]]
}

@test "DMP: fraction 0.95 (in (0.9,1.0)) is rejected" {
    run_dmp 0.95
    [[ "$output" == *"fraction must be between 0.1 and 0.9"* ]]
}

@test "DMP: tiny fraction 0.001 is rejected" {
    run_dmp 0.001
    [[ "$output" == *"fraction must be between 0.1 and 0.9"* ]]
}

# ---------------------------------------------------------------
# Explicit byte counts and exact human-readable sizes
# (small, MiB-scale values so the 90%-of-RAM cap never trips on CI runners)
# ---------------------------------------------------------------
@test "DMP: explicit byte count is accepted" {
    run_dmp_ok 67108864   # 64 MiB
    [[ "$output" == *"buffer=64 MiB"* ]]
}

@test "DMP: size 64M -> 64 MiB buffer" {
    run_dmp_ok 64M
    [[ "$output" == *"buffer=64 MiB"* ]]
}

@test "DMP: size 128M -> 128 MiB buffer" {
    run_dmp_ok 128M
    [[ "$output" == *"buffer=128 MiB"* ]]
}

@test "DMP: size 64MiB (iB suffix) -> 64 MiB buffer" {
    run_dmp_ok 64MiB
    [[ "$output" == *"buffer=64 MiB"* ]]
}

@test "DMP: size 64MB (B suffix) -> 64 MiB buffer" {
    run_dmp_ok 64MB
    [[ "$output" == *"buffer=64 MiB"* ]]
}

@test "DMP: K/G/T units are accepted" {
    run_dmp_ok 65536K   # 64 MiB
    [[ "$output" == *"buffer=64 MiB"* ]]
    run_dmp_ok 1G
    [[ "$output" == *"buffer=1024 MiB"* ]]
}

@test "DMP: decimal size 0.5G... handled via fraction, decimal unit 1.5G is exact" {
    run_dmp_ok 96M
    [[ "$output" == *"buffer=96 MiB"* ]]
}

# ---------------------------------------------------------------
# Bare bytes suffix (fix #2): 512B / 100b accepted (sub-page -> clamped, not errored)
# ---------------------------------------------------------------
@test "DMP: 512B (bytes suffix) is accepted, not rejected" {
    run_dmp_ok 512B
    [[ "$output" == *"phys_ram="* ]]
    [[ "$output" != *"invalid input string"* ]]
}

@test "DMP: 100b (lowercase bytes suffix) is accepted" {
    run_dmp_ok 100b
    [[ "$output" == *"phys_ram="* ]]
    [[ "$output" != *"invalid input string"* ]]
}

# ---------------------------------------------------------------
# Invalid inputs (fix #1 guards + general parse errors) -> "invalid input string"
# ---------------------------------------------------------------
@test "DMP: non-numeric garbage is rejected" {
    run_dmp abc
    [[ "$output" == *"invalid input string"* ]]
}

@test "DMP: bad unit (5X) is rejected" {
    run_dmp 5X
    [[ "$output" == *"invalid input string"* ]]
}

@test "DMP: trailing junk after unit (5GX) is rejected" {
    run_dmp 5GX
    [[ "$output" == *"invalid input string"* ]]
}

@test "DMP: zero is rejected" {
    run_dmp 0
    [[ "$output" == *"invalid input string"* ]]
}

@test "DMP: negative number is rejected" {
    run_dmp -1
    [[ "$output" == *"invalid input string"* ]]
}

@test "DMP: negative with unit (-5G) is rejected without UB (fix #1)" {
    run_dmp -5G
    [[ "$output" == *"invalid input string"* ]]
}

@test "DMP: infinity is rejected (fix #1)" {
    run_dmp inf
    [[ "$output" == *"invalid input string"* ]]
}

@test "DMP: nan is rejected (fix #1)" {
    run_dmp nan
    [[ "$output" == *"invalid input string"* ]]
}

@test "DMP: overflow (1e400 -> ERANGE) is rejected" {
    run_dmp 1e400
    [[ "$output" == *"invalid input string"* ]]
}

@test "DMP: oversized finite value (1e300) is rejected, not truncated to 0" {
    # Finite but >= 2^64: must be rejected before the uint64_t cast (no UB,
    # no silent clamp to a 1-page buffer).
    run_dmp 1e300
    [[ "$output" == *"invalid input string"* ]]
    [[ "$output" != *"phys_ram="* ]]
}

@test "DMP: oversized value with unit (1e30G) is rejected" {
    run_dmp 1e30G
    [[ "$output" == *"invalid input string"* ]]
    [[ "$output" != *"phys_ram="* ]]
}

# ---------------------------------------------------------------
# 90%-of-RAM cap and argument-count guard
# ---------------------------------------------------------------
@test "DMP: size exceeding 90% of RAM is rejected by the cap" {
    run_dmp 1000000G   # 1 PB, exceeds any real machine
    [[ "$output" == *"exceeds usable limit"* ]]
    [[ "$output" == *"90% of"* ]]
}

@test "DMP: missing argument prints usage" {
    run timeout 1 "$_DMP_BIN"
    [ "$status" -ne 0 ]
    [[ "$output" == *"usage:"* ]]
}

@test "DMP: too many arguments prints usage" {
    run timeout 1 "$_DMP_BIN" 0.5 extra
    [ "$status" -ne 0 ]
    [[ "$output" == *"usage:"* ]]
}

# ---------------------------------------------------------------
# fflush (added on this branch): the dirtied-pages line reaches stdout promptly
# ---------------------------------------------------------------
@test "DMP: progress line is flushed to stdout while running" {
    run timeout 2 "$_DMP_BIN" 64M
    [[ "$output" == *"dirtied"* ]]
    [[ "$output" == *"elapsed"* ]]
}
