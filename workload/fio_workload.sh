#!/bin/bash
# One-shot fio workload: run a single job with boot-time FIO_* params, then exit.
# Optional RESULT_SERVER_URL: POST one result JSON when the job finishes.
# Override via env: WORKLOAD_TYPE, FIO_DIRECTORY, FIO_SIZE, FIO_BS, FIO_IODEPTH,
#   FIO_NUMJOBS, FIO_TIME_BASED, FIO_RUNTIME, FIO_DIRECT, FIO_RW, FIO_CUSTOM_OPTS.
# Result sync: RESULT_SERVER_URL, RESULT_SERVER_TOKEN, RESULT_RETRY, RESULT_TIMEOUT,
#   VSTORM_BATCH_ID, VSTORM_VM_NAME — see docs/workload-result-sync-and-dashboard.md
# Use /etc/default/fio-workload or systemd Environment= to customize.

set -euo pipefail

# Install fio if not already present
if ! command -v fio &> /dev/null; then
    echo "fio not found, installing..."
    if command -v dnf &> /dev/null; then
        dnf install -y epel-release 2>/dev/null || true
        dnf install -y fio
    elif command -v yum &> /dev/null; then
        yum install -y epel-release 2>/dev/null || true
        yum install -y fio
    elif command -v apt-get &> /dev/null; then
        apt-get update && apt-get install -y fio
    else
        echo "Error: no supported package manager found."
        exit 1
    fi
    if ! command -v fio &> /dev/null; then
        echo "Error: failed to install fio."
        exit 1
    fi
fi

WORKLOAD_TYPE="${WORKLOAD_TYPE:-randrw}"
case "$WORKLOAD_TYPE" in
    randread)  _rw=randread;  _bs=4k; _rwmix=50 ;;
    randwrite) _rw=randwrite; _bs=4k; _rwmix=50 ;;
    randrw)    _rw=randrw;    _bs=4k; _rwmix=50 ;;
    seqwrite)  _rw=write;     _bs=4k; _rwmix=50 ;;
    seqread)   _rw=read;      _bs=4k; _rwmix=50 ;;
    *)         _rw=randrw;    _bs=4k; _rwmix=50 ;;
esac

FIO_DIRECTORY="${FIO_DIRECTORY:-/root/data}"
FIO_SIZE="${FIO_SIZE:-1G}"
FIO_BS="${FIO_BS:-$_bs}"
FIO_IODEPTH="${FIO_IODEPTH:-16}"
FIO_NUMJOBS="${FIO_NUMJOBS:-1}"
FIO_TIME_BASED="${FIO_TIME_BASED:-0}"
FIO_RUNTIME="${FIO_RUNTIME:-60}"
FIO_DIRECT="${FIO_DIRECT:-1}"
FIO_RW="${FIO_RW:-$_rw}"
FIO_RWMIXREAD="${FIO_RWMIXREAD:-$_rwmix}"
RESULT_RETRY="${RESULT_RETRY:-3}"
RESULT_TIMEOUT="${RESULT_TIMEOUT:-30}"
# Optional blank data disk from vstorm --data-disk-size (usually /dev/vdb).
# Format once, mount, and add /etc/fstab so the mount survives reboot.
# NOTE: do not use bare `findmnt --target $dir` to decide whether to mount —
# that succeeds for paths on `/` even when vdb is not mounted there.
FIO_DATA_DEVICE="${FIO_DATA_DEVICE:-/dev/vdb}"

if [[ -b "$FIO_DATA_DEVICE" ]]; then
    if ! blkid "$FIO_DATA_DEVICE" &>/dev/null; then
        echo "Formatting data disk $FIO_DATA_DEVICE for $FIO_DIRECTORY..."
        if command -v mkfs.xfs &>/dev/null; then
            mkfs.xfs -f "$FIO_DATA_DEVICE"
        else
            mkfs.ext4 -F "$FIO_DATA_DEVICE"
        fi
    fi
    mkdir -p "$FIO_DIRECTORY"
    _fio_uuid=$(blkid -s UUID -o value "$FIO_DATA_DEVICE" 2>/dev/null || true)
    _fio_fstype=$(blkid -s TYPE -o value "$FIO_DATA_DEVICE" 2>/dev/null || echo auto)
    if [[ -n "$_fio_uuid" ]]; then
        _fio_fspec="UUID=${_fio_uuid}"
    else
        _fio_fspec="$FIO_DATA_DEVICE"
    fi
    if ! grep -qE "^[^#].*[[:space:]]${FIO_DIRECTORY}[[:space:]]" /etc/fstab 2>/dev/null; then
        echo "${_fio_fspec} ${FIO_DIRECTORY} ${_fio_fstype} defaults,nofail 0 2" >> /etc/fstab
        echo "Added ${_fio_fspec} -> ${FIO_DIRECTORY} to /etc/fstab"
    fi
    _fio_src=$(findmnt -n -o SOURCE --target "$FIO_DIRECTORY" 2>/dev/null || true)
    _fio_already=0
    if [[ -n "$_fio_src" ]]; then
        if [[ "$_fio_src" == "$FIO_DATA_DEVICE" || "$_fio_src" == "/dev/disk/by-uuid/${_fio_uuid}" ]]; then
            _fio_already=1
        elif [[ -n "$_fio_uuid" ]] && [[ "$_fio_src" == *"$_fio_uuid"* ]]; then
            _fio_already=1
        else
            # Resolve SOURCE to a real block device (e.g. /dev/vdb) if possible
            _fio_src_real=$(readlink -f "$_fio_src" 2>/dev/null || true)
            _fio_dev_real=$(readlink -f "$FIO_DATA_DEVICE" 2>/dev/null || true)
            if [[ -n "$_fio_src_real" && -n "$_fio_dev_real" && "$_fio_src_real" == "$_fio_dev_real" ]]; then
                _fio_already=1
            fi
        fi
    fi
    if ((_fio_already == 0)); then
        if mount "$FIO_DIRECTORY" 2>/dev/null || mount "$FIO_DATA_DEVICE" "$FIO_DIRECTORY"; then
            echo "Mounted $FIO_DATA_DEVICE on $FIO_DIRECTORY"
        else
            echo "ERROR: failed to mount $FIO_DATA_DEVICE on $FIO_DIRECTORY" >&2
            exit 1
        fi
    else
        echo "Data disk already mounted: $_fio_src -> $FIO_DIRECTORY"
    fi
    # Refuse to run fio if the directory is still on the root filesystem.
    _fio_src=$(findmnt -n -o SOURCE --target "$FIO_DIRECTORY" 2>/dev/null || true)
    _fio_dev_real=$(readlink -f "$FIO_DATA_DEVICE" 2>/dev/null || echo "$FIO_DATA_DEVICE")
    _fio_src_real=$(readlink -f "$_fio_src" 2>/dev/null || echo "$_fio_src")
    _fio_ok=0
    if [[ -n "$_fio_src" ]]; then
        if [[ "$_fio_src_real" == "$_fio_dev_real" || "$_fio_src" == "$FIO_DATA_DEVICE" ]]; then
            _fio_ok=1
        elif [[ -n "$_fio_uuid" && "$_fio_src" == *"${_fio_uuid}"* ]]; then
            _fio_ok=1
        fi
    fi
    if ((_fio_ok == 0)); then
        echo "ERROR: $FIO_DIRECTORY is not on $FIO_DATA_DEVICE (SOURCE=${_fio_src:-none}); refusing to fill the root disk" >&2
        exit 1
    fi
fi

mkdir -p "$FIO_DIRECTORY/results"
FIO_FILENAME="${FIO_DIRECTORY}/fio-job.dat"
JOB_NAME="job1"

# Boot timestamp is written by vstorm-boot-timestamp.service (/root/timestamp.txt).
# Fio only reads it for result payloads (standalone fallback: create once if missing).
SERVICE_START_UNIX=$(date -u +%s)
BOOT_TIMESTAMP_FILE="${RESULT_TIMESTAMP_FILE:-/root/timestamp.txt}"
if [[ ! -f "$BOOT_TIMESTAMP_FILE" ]]; then
    _ts_human=$(date -u -d "@$SERVICE_START_UNIX" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
        || date -u '+%Y-%m-%dT%H:%M:%SZ')
    if ! mkdir -p "$(dirname "$BOOT_TIMESTAMP_FILE")" 2>/dev/null \
        || ! printf '%s, %s\n' "$SERVICE_START_UNIX" "$_ts_human" > "$BOOT_TIMESTAMP_FILE"; then
        BOOT_TIMESTAMP_FILE="${FIO_DIRECTORY}/timestamp.txt"
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
if [[ -z "$BOOT_TIMESTAMP_UNIX" ]]; then
    echo "WARN: no numeric boot unix in $BOOT_TIMESTAMP_FILE; using service start" >&2
    BOOT_TIMESTAMP_UNIX="$SERVICE_START_UNIX"
fi

report_result() {
    local fio_rc="$1" started_at="$2" stopped_at="$3" fio_json="$4"
    shift 4
    local -a cmd_argv=("$@")

    [[ -n "${RESULT_SERVER_URL:-}" ]] || return 0
    if ! command -v python3 &>/dev/null; then
        echo "Cannot build result payload (python3 missing)"
        return 0
    fi
    if ! command -v curl &>/dev/null; then
        echo "Cannot POST result payload (curl missing)"
        return 0
    fi

    local payload_file="${FIO_DIRECTORY}/results/${JOB_NAME}-payload.json"
    local pending_dir="${FIO_DIRECTORY}/results/pending"
    mkdir -p "$pending_dir"
    local status="ok" error_message=""
    if [[ "$fio_rc" -ne 0 ]]; then
        status="fio_error"
        error_message="fio exited with status ${fio_rc}"
    fi
    if [[ ! -f "$fio_json" ]]; then
        if [[ "$status" == "ok" ]]; then
            status="missing_fio_json"
        fi
        error_message="${error_message:+$error_message; }fio JSON output missing: ${fio_json}"
    fi

    local vm_name="${VSTORM_VM_NAME:-$(hostname -s 2>/dev/null || hostname || echo unknown)}"
    local hostname_s
    hostname_s=$(hostname -s 2>/dev/null || hostname || echo unknown)
    local cpu_count mem_total_kb reported_at_unix cmd_json
    cpu_count=$(nproc 2>/dev/null || echo 0)
    mem_total_kb=$(awk '/MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
    reported_at_unix=$(date -u +%s)
    cmd_json=$(printf '%s\n' "${cmd_argv[@]}" | python3 -c 'import json,sys; print(json.dumps([l.rstrip("\n") for l in sys.stdin]))')

    if [[ -z "${VSTORM_BATCH_ID:-}" ]]; then
        echo "WARN: VSTORM_BATCH_ID unset; collector will reject result POSTs" >&2
    fi

    if ! RESULT_CMD_JSON="$cmd_json" RESULT_STATUS="$status" RESULT_ERROR_MESSAGE="$error_message" \
    python3 - "${fio_json:-}" "$payload_file" \
        "$reported_at_unix" "$started_at" "$stopped_at" \
        "$BOOT_TIMESTAMP_UNIX" \
        "$hostname_s" "${VSTORM_BATCH_ID:-}" "$vm_name" \
        "$cpu_count" "$mem_total_kb" "$fio_rc" \
        "$WORKLOAD_TYPE" "$FIO_SIZE" "$FIO_BS" "$FIO_IODEPTH" "$FIO_NUMJOBS" "$FIO_DIRECT" "$FIO_RW" \
        "$JOB_NAME" "$SERVICE_START_UNIX" <<'PY'
import json, os, sys
from datetime import datetime, timezone

def parse_unix(val, default=0):
    try:
        return int(str(val).strip() or default)
    except (TypeError, ValueError):
        return int(default)

def fmt_utc(unix):
    return datetime.fromtimestamp(int(unix), tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

fio_path, out_path = sys.argv[1], sys.argv[2]
reported_at_unix = parse_unix(sys.argv[3])
fio_start_unix = parse_unix(sys.argv[4])
fio_stop_unix = parse_unix(sys.argv[5])
boot_unix = parse_unix(sys.argv[6])
hostname, batch_id, vm_name = sys.argv[7], sys.argv[8], sys.argv[9]
cpu_count, mem_total_kb, fio_rc = map(parse_unix, sys.argv[10:13])
wtype, fsize, fbs, fiodepth, fnumjobs, fdirect, frw = sys.argv[13:20]
job_name = sys.argv[20]
service_start_unix = parse_unix(sys.argv[21])
status = os.environ.get("RESULT_STATUS") or "ok"
error_message = os.environ.get("RESULT_ERROR_MESSAGE") or ""
fio = None
if fio_path and os.path.isfile(fio_path):
    try:
        with open(fio_path, encoding="utf-8") as f:
            fio = json.load(f)
    except (OSError, json.JSONDecodeError) as exc:
        status = "fio_json_error" if status == "ok" else status
        extra = f"failed to parse fio JSON: {exc}"
        error_message = f"{error_message}; {extra}" if error_message else extra
try:
    cmd = json.loads(os.environ.get("RESULT_CMD_JSON") or "[]")
except json.JSONDecodeError:
    cmd = []
payload = {
    "schema_version": 1,
    "record_type": "result",
    "source": "guest",
    "workload_kind": "fio",
    "status": status,
    "error_message": error_message or None,
    "fio_start": fmt_utc(fio_start_unix),
    "fio_stop": fmt_utc(fio_stop_unix),
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
    "fio_command": cmd,
    "fio_rc": fio_rc,
    "fio_group_reporting": fio,
    "workload": {
        "WORKLOAD_TYPE": wtype,
        "FIO_SIZE": fsize,
        "FIO_BS": fbs,
        "FIO_IODEPTH": fiodepth,
        "FIO_NUMJOBS": fnumjobs,
        "FIO_DIRECT": fdirect,
        "FIO_RW": frw,
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
            sleep $((attempt < 4 ? attempt * 2 : 8))
            ((attempt++)) || true
        done
        return 1
    }

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
        # Keep results/${JOB_NAME}-payload.json for local inspection; only clear pending spool copy.
        rm -f "${pending_dir}/${JOB_NAME}-payload.json"
        return 0
    fi

    if ! cp -f "$payload_file" "${pending_dir}/${JOB_NAME}-payload.json"; then
        echo "ERROR: failed to spool $payload_file into $pending_dir" >&2
    fi
    local conn_err_file="${FIO_DIRECTORY}/results/${JOB_NAME}-post-error.json"
    python3 - "$conn_err_file" \
        "$hostname_s" "${VSTORM_BATCH_ID:-}" "$vm_name" \
        "$JOB_NAME" "$RESULT_SERVER_URL" <<'PY'
import json, sys
from datetime import datetime, timezone
out, hostname, batch_id, vm_name, job_name, url = sys.argv[1:7]
now = datetime.now(tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
payload = {
    "schema_version": 1,
    "record_type": "error",
    "source": "guest",
    "workload_kind": "fio",
    "status": "post_error",
    "error_message": f"failed to POST result payload to {url} after retries; left in guest pending spool",
    "reported_at": now,
    "hostname": hostname,
    "batch_id": batch_id,
    "vm_name": vm_name,
    "cycle": 1,
    "job_name": job_name,
}
with open(out, "w", encoding="utf-8") as f:
    json.dump(payload, f)
    f.write("\n")
PY
    if ! _post_payload_file "$conn_err_file" "Result post_error"; then
        cp -f "$conn_err_file" "${pending_dir}/${JOB_NAME}-post-error.json"
        echo "Collector unreachable; payloads spooled under $pending_dir"
    fi
}

# Dashboard "Workload status" is driven by agent_state on heartbeats.
# One-shot fio does not poll policy, so tell the collector when the job starts.
post_agent_heartbeat() {
    local state="$1"
    [[ -n "${RESULT_SERVER_URL:-}" ]] || return 0
    command -v python3 &>/dev/null || return 0
    command -v curl &>/dev/null || return 0
    local vm_name="${VSTORM_VM_NAME:-$(hostname -s 2>/dev/null || hostname || echo unknown)}"
    local hostname_s hb_file
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
    "workload_kind": "fio",
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
    local attempt=1 http_code
    local -a auth_args=()
    [[ -n "${RESULT_SERVER_TOKEN:-}" ]] && auth_args+=(-H "Authorization: Bearer ${RESULT_SERVER_TOKEN}")
    while (( attempt <= RESULT_RETRY )); do
        http_code=$(curl -sS -X POST -H "Content-Type: application/json" \
            --data-binary @"$hb_file" \
            --connect-timeout "$RESULT_TIMEOUT" \
            --max-time "$RESULT_TIMEOUT" \
            "${auth_args[@]}" \
            -o /dev/null -w '%{http_code}' \
            "$RESULT_SERVER_URL" 2>/dev/null) || true
        if [[ "$http_code" =~ ^2[0-9][0-9]$ ]]; then
            echo "Agent heartbeat ($state) posted"
            rm -f "$hb_file"
            return 0
        fi
        sleep $((attempt < 4 ? attempt : 4))
        ((attempt++)) || true
    done
    echo "WARN: agent heartbeat ($state) POST failed (HTTP ${http_code:-000})" >&2
    rm -f "$hb_file"
    return 1
}

echo "=========================================="
echo "Starting fio workload (one-shot)"
echo "WORKLOAD_TYPE=$WORKLOAD_TYPE"
echo "FIO_RW=$FIO_RW FIO_SIZE=$FIO_SIZE FIO_BS=$FIO_BS FIO_IODEPTH=$FIO_IODEPTH FIO_NUMJOBS=$FIO_NUMJOBS"
echo "FIO_DIRECT=$FIO_DIRECT FIO_TIME_BASED=$FIO_TIME_BASED FIO_RUNTIME=$FIO_RUNTIME"
echo "FIO_DIRECTORY=$FIO_DIRECTORY"
[[ -n "${FIO_CUSTOM_OPTS:-}" ]] && echo "FIO_CUSTOM_OPTS is set: using CUSTOM-OPTS branch"
if [[ -n "${RESULT_SERVER_URL:-}" ]]; then
    echo "RESULT_SERVER_URL=$RESULT_SERVER_URL (heartbeat at start; result POST after job)"
else
    echo "RESULT_SERVER_URL unset: run locally only (no POST)"
fi
echo "Job name: $JOB_NAME"
echo "=========================================="
echo ""

post_agent_heartbeat running || true

fio_json="${FIO_DIRECTORY}/results/${JOB_NAME}.json"
started_at=$(date -u +%s)
fio_rc=0
set +e
if [[ -n "${FIO_CUSTOM_OPTS:-}" ]]; then
    if [[ "$FIO_TIME_BASED" == "1" ]]; then
        echo "CUSTOM-OPTS - Running fio for ${FIO_RUNTIME}s..."
        # shellcheck disable=SC2086
        fio $FIO_CUSTOM_OPTS --name="$JOB_NAME" --output-format=json --output="$fio_json" \
            --time_based --runtime="$FIO_RUNTIME"
        fio_rc=$?
    else
        echo "CUSTOM-OPTS - Running fio (no runtime limit)..."
        # shellcheck disable=SC2086
        fio $FIO_CUSTOM_OPTS --name="$JOB_NAME" --output-format=json --output="$fio_json"
        fio_rc=$?
    fi
    report_result "$fio_rc" "$started_at" "$(date -u +%s)" "$fio_json" fio $FIO_CUSTOM_OPTS --name="$JOB_NAME"
else
    if [[ "$FIO_TIME_BASED" == "1" ]]; then
        echo "ACTIVE - Running fio ($FIO_RW, bs=$FIO_BS) for ${FIO_RUNTIME}s..."
    else
        echo "ACTIVE - Running fio ($FIO_RW, bs=$FIO_BS) until size=$FIO_SIZE completes..."
    fi
    fio_args=(
        --name="$JOB_NAME"
        --filename="$FIO_FILENAME"
        --rw="$FIO_RW"
        --bs="$FIO_BS"
        --iodepth="$FIO_IODEPTH"
        --size="$FIO_SIZE"
        --numjobs="$FIO_NUMJOBS"
        --direct="$FIO_DIRECT"
        --ioengine=libaio
        --group_reporting
        --output-format=json
        --output="$fio_json"
    )
    if [[ "$FIO_RW" == "randrw" ]]; then
        fio_args+=(--rwmixread="$FIO_RWMIXREAD")
    fi
    if [[ "$FIO_TIME_BASED" == "1" ]]; then
        fio_args+=(--time_based --runtime="$FIO_RUNTIME")
    fi
    fio "${fio_args[@]}"
    fio_rc=$?
    stopped_at=$(date -u +%s)
    report_result "$fio_rc" "$started_at" "$stopped_at" "$fio_json" fio "${fio_args[@]}"
fi
set -e

if [[ "$fio_rc" -ne 0 ]]; then
    echo "fio exited with status $fio_rc"
else
    echo "fio completed successfully"
fi
echo "One-shot workload finished."
exit "$fio_rc"
