#!/usr/bin/env bats
# Compile the dirty-mem-pages C source and test the argument parser (fractions,
# byte counts, human-readable sizes) and guards. The standalone
# workload/dirty-mem/dirty-mem-pages.c is the source of truth; vstorm splices it into the
# cloud-init YAML at runtime via {DIRTY_MEM_SOURCE}.

load 'helpers'

YAML="workload/dirty-mem/cloudinit-dirty-mem-pages.yaml"
STANDALONE="workload/dirty-mem/dirty-mem-pages.c"

setup_file() {
    if ! command -v gcc >/dev/null 2>&1; then
        export _DMP_NO_GCC=1
        return 0
    fi
    _DMP_DIR=$(mktemp -d)
    export _DMP_DIR
    cp "$STANDALONE" "$_DMP_DIR/dmp.c"
    # Compile with warnings as a signal; capture them for the "no warnings" test.
    gcc -Wall -Wextra -O2 -o "$_DMP_DIR/dmp" "$_DMP_DIR/dmp.c" 2> "$_DMP_DIR/warnings.txt"
    export _DMP_BIN="$_DMP_DIR/dmp"
}

teardown_file() {
    [[ -n "${_DMP_DIR:-}" ]] && rm -rf "$_DMP_DIR"
}

setup() {
    # The splice test runs `vstorm -n`, which queries oc during access-mode
    # detection -- mock it so tests never touch a real cluster.
    setup_oc_mock
    if [[ -n "${_DMP_NO_GCC:-}" ]]; then
        skip "gcc not available"
    fi
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
@test "DMP: standalone C source is the source of truth and compiles" {
    [[ -s "$STANDALONE" ]]
    grep -q 'parse_input' "$STANDALONE"
    grep -q 'int main' "$STANDALONE"
}

@test "DMP: profile uses placeholders, not an embedded C source or service" {
    # Source + service are spliced in at runtime, not embedded byte-for-byte.
    grep -qE '^[[:space:]]*\{DIRTY_MEM_SOURCE\}[[:space:]]*$' "$YAML"
    grep -qE '^[[:space:]]*\{DIRTY_MEM_WORKLOAD_SERVICE\}[[:space:]]*$' "$YAML"
    # `run` + status: a bare `! grep` is exempt from bats' errexit and would not
    # fail the test if the embedded source/unit were present.
    run grep -q 'int main' "$YAML"
    [ "$status" -ne 0 ]
    run grep -q 'ExecStart=/usr/local/bin/dirty-mem-pages' "$YAML"
    [ "$status" -ne 0 ]
}

# vstorm splices the standalone C source + unit into the Secret byte-for-byte
# (checks the spliced text, not a compile).
@test "DMP: vstorm splices C source and service into cloud-init userdata byte-for-byte" {
    assert_spliced_matches "$YAML" "path: /usr/local/src/dirty-mem-pages.c" "$STANDALONE"
    assert_spliced_matches "$YAML" "path: /etc/systemd/system/dirty-mem-pages.service" \
        "workload/dirty-mem/dirty-mem-pages.service"
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
