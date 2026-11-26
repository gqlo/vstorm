#!/bin/bash
# One-shot HammerDB TPROC-C workload: init the DB, build the schema once, run the
# timed benchmark, then emit a structured JSON result and (optionally) POST it.
# Optional RESULT_SERVER_URL: POST one result JSON when the run finishes.
# Override via env: HDB_DB, HDB_WAREHOUSES, HDB_VU, HDB_RAMPUP, HDB_DURATION.
# Result sync: RESULT_SERVER_URL, RESULT_SERVER_TOKEN, RESULT_RETRY, RESULT_TIMEOUT,
#   VSTORM_BATCH_ID, VSTORM_VM_NAME — see docs/workload-result-sync-and-dashboard.md
# Paths (defaults target a RHEL guest; tests override them): HDB_HOME, PGDATA,
#   HDB_BUILD_TCL, HDB_RUN_TCL, HDB_BUILD_MARKER, HDB_BUILD_LOG, HDB_RESULT_TXT,
#   HDB_RESULTS_DIR.

set -euo pipefail

export HDB_DB="${HDB_DB:-pg}"
export HDB_WAREHOUSES="${HDB_WAREHOUSES:-4}"
export HDB_VU="${HDB_VU:-4}"
export HDB_RAMPUP="${HDB_RAMPUP:-2}"
export HDB_DURATION="${HDB_DURATION:-5}"

# Overridable paths. Defaults match the pre-installed image layout; tests point
# these at temp dirs so the script runs end-to-end under mock binaries.
HDB_HOME="${HDB_HOME:-/opt/HammerDB}"
PGDATA="${PGDATA:-/var/lib/pgsql/data}"
HDB_BUILD_TCL="${HDB_BUILD_TCL:-/opt/hammerdb/build.tcl}"
HDB_RUN_TCL="${HDB_RUN_TCL:-/opt/hammerdb/run.tcl}"
BUILD_MARKER="${HDB_BUILD_MARKER:-/var/lib/vstorm-hammerdb-build.done}"
HDB_BUILD_LOG="${HDB_BUILD_LOG:-/root/hammerdb-build.log}"
HDB_RESULT_TXT="${HDB_RESULT_TXT:-/root/hammerdb-result.txt}"
HDB_RESULTS_DIR="${HDB_RESULTS_DIR:-/root/hammerdb-results}"

RESULT_RETRY="${RESULT_RETRY:-3}"
RESULT_TIMEOUT="${RESULT_TIMEOUT:-30}"
JOB_NAME="tproc-c"

mkdir -p "$HDB_RESULTS_DIR"

echo "Starting HammerDB TPROC-C: db=$HDB_DB warehouses=$HDB_WAREHOUSES vu=$HDB_VU"
if [[ -n "${RESULT_SERVER_URL:-}" ]]; then
    echo "RESULT_SERVER_URL=$RESULT_SERVER_URL (heartbeat at start; result POST after run)"
else
    echo "RESULT_SERVER_URL unset: run locally only (no POST)"
fi

# Boot timestamp is written by vstorm-boot-timestamp.service (/root/timestamp.txt).
# Only used to annotate result payloads (standalone fallback: create if missing).
SERVICE_START_UNIX=$(date -u +%s)
BOOT_TIMESTAMP_FILE="${RESULT_TIMESTAMP_FILE:-/root/timestamp.txt}"
if [[ ! -f "$BOOT_TIMESTAMP_FILE" ]]; then
    _ts_human=$(date -u -d "@$SERVICE_START_UNIX" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
        || date -u '+%Y-%m-%dT%H:%M:%SZ')
    if ! mkdir -p "$(dirname "$BOOT_TIMESTAMP_FILE")" 2>/dev/null \
        || ! printf '%s, %s\n' "$SERVICE_START_UNIX" "$_ts_human" > "$BOOT_TIMESTAMP_FILE"; then
        BOOT_TIMESTAMP_FILE="${HDB_RESULTS_DIR}/timestamp.txt"
        mkdir -p "$(dirname "$BOOT_TIMESTAMP_FILE")"
        printf '%s, %s\n' "$SERVICE_START_UNIX" "$_ts_human" > "$BOOT_TIMESTAMP_FILE"
    fi
fi
BOOT_TIMESTAMP_UNIX=""
while IFS=',' read -r _bu _bt || [[ -n "${_bu:-}" ]]; do
    _bu="${_bu//[[:space:]]/}"
    if [[ "$_bu" =~ ^[0-9]+$ ]]; then
        BOOT_TIMESTAMP_UNIX="$_bu"
        break
    fi
done < "$BOOT_TIMESTAMP_FILE"
[[ -n "$BOOT_TIMESTAMP_UNIX" ]] || BOOT_TIMESTAMP_UNIX="$SERVICE_START_UNIX"

# POST a payload file to the collector with retry. Mirrors workload/fio/fio_workload.sh.
_post_payload_file() {
    local file="$1" label="$2"
    local attempt=1 curl_err curl_body http_code
    local -a auth_args=()
    if [[ ! -s "$file" ]]; then
        echo "$label: missing or empty file $file"
        return 1
    fi
    [[ -n "${RESULT_SERVER_TOKEN:-}" ]] && auth_args+=(-H "Authorization: Bearer ${RESULT_SERVER_TOKEN}")
    while (( attempt <= RESULT_RETRY )); do
        curl_err=$(mktemp)
        curl_body=$(mktemp)
        http_code=$(curl -sS -X POST -H "Content-Type: application/json" \
            --data-binary @"$file" \
            --connect-timeout "$RESULT_TIMEOUT" \
            --max-time "$RESULT_TIMEOUT" \
            "${auth_args[@]}" \
            -o "$curl_body" -w '%{http_code}' \
            "$RESULT_SERVER_URL" 2>"$curl_err") || true
        if [[ "$http_code" =~ ^2[0-9][0-9]$ ]]; then
            rm -f "$curl_err" "$curl_body"
            echo "$label: posted to $RESULT_SERVER_URL"
            return 0
        fi
        echo "$label: POST failed attempt $attempt/$RESULT_RETRY: HTTP ${http_code:-000} curl=$(tr '\n' ' ' <"$curl_err") body=$(tr '\n' ' ' <"$curl_body" | head -c 500)"
        rm -f "$curl_err" "$curl_body"
        # No backoff after the final attempt -- it only delays the spool fallback.
        if (( attempt < RESULT_RETRY )); then
            sleep $((attempt < 4 ? attempt * 2 : 8))
        fi
        ((attempt++)) || true
    done
    return 1
}

post_agent_heartbeat() {
    local state="$1"
    [[ -n "${RESULT_SERVER_URL:-}" ]] || return 0
    command -v python3 &>/dev/null || return 0
    command -v curl &>/dev/null || return 0
    local vm_name hostname_s hb_file
    vm_name="${VSTORM_VM_NAME:-$(hostname -s 2>/dev/null || hostname || echo unknown)}"
    hostname_s=$(hostname -s 2>/dev/null || hostname || echo unknown)
    hb_file=$(mktemp)
    if ! HB_STATE="$state" python3 - "$hb_file" \
        "${VSTORM_BATCH_ID:-}" "$vm_name" "$hostname_s" <<'PY'
import json, os, sys
from datetime import datetime, timezone
out, batch_id, vm_name, hostname = sys.argv[1:5]
now = datetime.now(tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
payload = {
    "schema_version": 1,
    "record_type": "heartbeat",
    "source": "guest",
    "workload_kind": "hammerdb",
    "status": os.environ.get("HB_STATE") or "idle",
    "agent_state": os.environ.get("HB_STATE") or "idle",
    "reported_at": now,
    "hostname": hostname,
    "batch_id": batch_id,
    "vm_name": vm_name,
}
with open(out, "w", encoding="utf-8") as f:
    json.dump(payload, f)
    f.write("\n")
PY
    then
        rm -f "$hb_file"
        return 1
    fi
    if _post_payload_file "$hb_file" "Agent heartbeat ($state)"; then
        rm -f "$hb_file"
        return 0
    fi
    rm -f "$hb_file"
    return 1
}

# Build the canonical vstorm result payload and POST it (with pending spool).
report_result() {
    local run_rc="$1" started_at="$2" stopped_at="$3" hdb_json="$4" nopm="$5" tpm="$6"

    [[ -n "${RESULT_SERVER_URL:-}" ]] || return 0
    if ! command -v python3 &>/dev/null; then
        echo "Cannot build result payload (python3 missing)"
        return 0
    fi

    local payload_file="${HDB_RESULTS_DIR}/${JOB_NAME}-payload.json"
    local pending_dir="${HDB_RESULTS_DIR}/pending"
    mkdir -p "$pending_dir"

    local status="ok" error_message=""
    if [[ "$run_rc" -ne 0 ]]; then
        status="hammerdb_error"
        error_message="hammerdbcli exited with status ${run_rc}"
    fi
    if [[ -z "$nopm" || -z "$tpm" ]]; then
        [[ "$status" == "ok" ]] && status="missing_result"
        error_message="${error_message:+$error_message; }NOPM/TPM not found in run output"
    fi
    if [[ -n "$hdb_json" && ! -f "$hdb_json" ]]; then
        error_message="${error_message:+$error_message; }HammerDB JSON report missing: ${hdb_json}"
    fi

    local vm_name hostname_s cpu_count mem_total_kb reported_at_unix
    vm_name="${VSTORM_VM_NAME:-$(hostname -s 2>/dev/null || hostname || echo unknown)}"
    hostname_s=$(hostname -s 2>/dev/null || hostname || echo unknown)
    cpu_count=$(nproc 2>/dev/null || echo 0)
    mem_total_kb=$(awk '/MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
    reported_at_unix=$(date -u +%s)

    [[ -n "${VSTORM_BATCH_ID:-}" ]] || \
        echo "WARN: VSTORM_BATCH_ID unset; collector will reject result POSTs" >&2

    if ! RESULT_STATUS="$status" RESULT_ERROR_MESSAGE="$error_message" \
    python3 - "${hdb_json:-}" "$payload_file" \
        "$reported_at_unix" "$started_at" "$stopped_at" \
        "$BOOT_TIMESTAMP_UNIX" "$SERVICE_START_UNIX" \
        "$hostname_s" "${VSTORM_BATCH_ID:-}" "$vm_name" \
        "$cpu_count" "$mem_total_kb" "$run_rc" \
        "$nopm" "$tpm" \
        "$HDB_DB" "$HDB_WAREHOUSES" "$HDB_VU" "$HDB_RAMPUP" "$HDB_DURATION" \
        "$JOB_NAME" <<'PY'
import json, os, sys
from datetime import datetime, timezone

def parse_unix(val, default=0):
    try:
        return int(str(val).strip() or default)
    except (TypeError, ValueError):
        return int(default)

def parse_int(val):
    try:
        return int(str(val).strip())
    except (TypeError, ValueError):
        return None

def fmt_utc(unix):
    return datetime.fromtimestamp(int(unix), tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

hdb_path, out_path = sys.argv[1], sys.argv[2]
reported_at_unix = parse_unix(sys.argv[3])
started_unix = parse_unix(sys.argv[4])
stopped_unix = parse_unix(sys.argv[5])
boot_unix = parse_unix(sys.argv[6])
service_start_unix = parse_unix(sys.argv[7])
hostname, batch_id, vm_name = sys.argv[8], sys.argv[9], sys.argv[10]
cpu_count, mem_total_kb, run_rc = map(parse_unix, sys.argv[11:14])
nopm, tpm = parse_int(sys.argv[14]), parse_int(sys.argv[15])
db, warehouses, vu, rampup, duration = sys.argv[16:21]
job_name = sys.argv[21]
status = os.environ.get("RESULT_STATUS") or "ok"
error_message = os.environ.get("RESULT_ERROR_MESSAGE") or ""

hdb = None
if hdb_path and os.path.isfile(hdb_path):
    try:
        with open(hdb_path, encoding="utf-8") as f:
            hdb = json.load(f)
    except (OSError, json.JSONDecodeError) as exc:
        status = "hammerdb_json_error" if status == "ok" else status
        extra = f"failed to parse HammerDB JSON: {exc}"
        error_message = f"{error_message}; {extra}" if error_message else extra

payload = {
    "schema_version": 1,
    "record_type": "result",
    "source": "guest",
    "workload_kind": "hammerdb",
    "status": status,
    "error_message": error_message or None,
    "hdb_start": fmt_utc(started_unix),
    "hdb_stop": fmt_utc(stopped_unix),
    "reported_at": fmt_utc(reported_at_unix),
    "boot_timestamp": fmt_utc(boot_unix) if boot_unix else None,
    "service_start": fmt_utc(service_start_unix) if service_start_unix else None,
    "hostname": hostname,
    "batch_id": batch_id,
    "vm_name": vm_name,
    "cycle": 1,
    "job_name": job_name,
    "cpu_count": cpu_count,
    "mem_total_kb": mem_total_kb,
    "hdb_rc": run_rc,
    "nopm": nopm,
    "tpm": tpm,
    "hammerdb_report": hdb,
    "workload": {
        "HDB_DB": db,
        "HDB_WAREHOUSES": warehouses,
        "HDB_VU": vu,
        "HDB_RAMPUP": rampup,
        "HDB_DURATION": duration,
    },
}
with open(out_path, "w", encoding="utf-8") as f:
    json.dump(payload, f)
    f.write("\n")
PY
    then
        echo "ERROR: failed to build result payload JSON" >&2
        return 1
    fi
    if [[ ! -s "$payload_file" ]]; then
        echo "ERROR: result payload missing or empty: $payload_file" >&2
        return 1
    fi

    # Without curl we cannot POST, but the payload is already built -- spool it so
    # a later run (or manual collection) can still recover the result.
    if ! command -v curl &>/dev/null; then
        echo "curl missing; spooling result payload for later POST"
        cp -f "$payload_file" "${pending_dir}/${JOB_NAME}-payload.json" 2>/dev/null || \
            echo "ERROR: failed to spool $payload_file into $pending_dir" >&2
        return 0
    fi

    local pending
    shopt -s nullglob
    for pending in "$pending_dir"/*.json; do
        if _post_payload_file "$pending" "Pending $(basename "$pending")"; then
            rm -f "$pending"
        else
            break
        fi
    done
    shopt -u nullglob

    if _post_payload_file "$payload_file" "Result ($status)"; then
        rm -f "${pending_dir}/${JOB_NAME}-payload.json"
        return 0
    fi

    if ! cp -f "$payload_file" "${pending_dir}/${JOB_NAME}-payload.json"; then
        echo "ERROR: failed to spool $payload_file into $pending_dir" >&2
    fi
    echo "Collector unreachable; payload spooled under $pending_dir"
    return 0
}

post_agent_heartbeat running || true

# 1) Initialize and start PostgreSQL, then set up credentials.
# HammerDB connects over TCP (pg_host=localhost) as the superuser WITH a
# password, so the postgres role needs a password and pg_hba must allow
# password auth on loopback (default RHEL pg_hba uses ident/peer).
if [[ ! -d "$PGDATA/base" ]]; then
    postgresql-setup --initdb
fi
# pg_hba is first-match, and default RHEL ships loopback rules (ident/peer)
# that would win over an appended md5 rule. Drop any existing loopback host
# rules (IPv4 and IPv6) so our password rules take precedence, then append
# them. Idempotent: a re-run removes the rules we added and re-appends them.
sed -i -E '/^[[:space:]]*host[[:space:]].*[[:space:]](127\.0\.0\.1\/32|::1\/128)[[:space:]]/d' \
    "$PGDATA/pg_hba.conf"
printf 'host all all 127.0.0.1/32 md5\nhost all all ::1/128 md5\n' \
    >> "$PGDATA/pg_hba.conf"
systemctl enable --now postgresql
# pg_superuserpass in build.tcl must match this password.
sudo -u postgres psql -c "ALTER ROLE postgres WITH PASSWORD 'postgres';"
sudo -u postgres psql -tc "SELECT 1 FROM pg_roles WHERE rolname='tpcc'" \
    | grep -q 1 || sudo -u postgres psql -c \
    "CREATE ROLE tpcc WITH LOGIN SUPERUSER PASSWORD 'tpcc';"

# 2) HammerDB is pre-installed in the image at HDB_HOME.
cd "$HDB_HOME"

# 3) Build the schema once per configuration, then run the timed benchmark.
#    hammerdbcli can exit 0 even when the build logged an error, so capture
#    the build output and require a completion line (and no error lines)
#    before trusting it. The sentinel records the schema configuration so a
#    reboot skips the build only when it still matches; a changed
#    HDB_WAREHOUSES (or HDB_DB) rebuilds instead of running a stale schema.
#    The completion/error patterns are HammerDB-version-specific — validate
#    them against your release.
build_sig="db=$HDB_DB warehouses=$HDB_WAREHOUSES"
if [[ -f "$BUILD_MARKER" && "$(cat "$BUILD_MARKER")" == "$build_sig" ]]; then
    echo "Schema already built for [$build_sig]; skipping build"
else
    if [[ -f "$BUILD_MARKER" ]]; then
        echo "Schema config changed ($(cat "$BUILD_MARKER") -> $build_sig); rebuilding"
    fi
    # Drop any existing tpcc before (re)building so a changed config OR a
    # retry after a failed/partial first build (no marker yet) starts clean
    # instead of running buildschema against a half-built schema. DROP ...
    # IF EXISTS is a harmless no-op on a genuine first build, and touches
    # only tpcc. (PostgreSQL shown; use the DB-specific drop for
    # mysql/maria/mssql.)
    # Clear the marker before dropping: if the rebuild fails after the DROP, no
    # stale marker survives to skip the (now-missing) schema on the next run.
    rm -f "$BUILD_MARKER"
    sudo -u postgres psql -c "DROP DATABASE IF EXISTS tpcc;"
    ./hammerdbcli auto "$HDB_BUILD_TCL" 2>&1 | tee "$HDB_BUILD_LOG"
    # Trust the build only when it shows a completion marker (6.0+ prints
    # "Schema complete" and/or "ALL VIRTUAL USERS COMPLETE") and no real error
    # line. A broad 'error|failed' match false-positives on benign text; keep the
    # error patterns specific. These markers are HammerDB-version-specific --
    # validate them against your release.
    if ! grep -qiE 'schema complete|all virtual users complete' "$HDB_BUILD_LOG" \
        || grep -qiE 'error in virtual user|fatal error|could not|failed to' "$HDB_BUILD_LOG"; then
        echo "HammerDB build did not complete cleanly; not running benchmark" >&2
        exit 1
    fi
    mkdir -p "$(dirname "$BUILD_MARKER")"
    printf '%s\n' "$build_sig" > "$BUILD_MARKER"
fi

# Run the timed benchmark. Point HammerDB's TMP at HDB_RESULTS_DIR so `jobs save`
# (in run.tcl) writes hdb_<jobid>.json where we can find it.
started_at=$(date -u +%s)
run_rc=0
TMP="$HDB_RESULTS_DIR" TEMP="$HDB_RESULTS_DIR" \
    ./hammerdbcli auto "$HDB_RUN_TCL" > "$HDB_RESULT_TXT" 2>&1 || run_rc=$?
stopped_at=$(date -u +%s)
cat "$HDB_RESULT_TXT"

# Locate the JSON report `jobs save` wrote (parse its printed path; fall back to
# the newest hdb_*.json), and pull NOPM/TPM from the result line.
hdb_json=$(sed -n 's/.*Saved job report JSON to \(.*\)$/\1/p' "$HDB_RESULT_TXT" | tail -1)
if [[ -z "$hdb_json" || ! -f "$hdb_json" ]]; then
    hdb_json=$(ls -t "$HDB_RESULTS_DIR"/hdb_*.json 2>/dev/null | head -1 || true)
fi
nopm=$(sed -n 's/.*System achieved \([0-9]\+\) NOPM.*/\1/p' "$HDB_RESULT_TXT" | tail -1)
tpm=$(sed -n 's/.*NOPM from \([0-9]\+\) .*TPM.*/\1/p' "$HDB_RESULT_TXT" | tail -1)

echo "HammerDB run finished (rc=$run_rc, NOPM=${nopm:-?}, TPM=${tpm:-?}, json=${hdb_json:-none})."
report_result "$run_rc" "$started_at" "$stopped_at" "${hdb_json:-}" "${nopm:-}" "${tpm:-}" || true

exit "$run_rc"
