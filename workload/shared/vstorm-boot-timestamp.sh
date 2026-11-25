#!/bin/bash
# Shared guest boot timestamp: append /root/timestamp.txt and optionally POST a
# heartbeat with boot_timestamp when RESULT_SERVER_URL + VSTORM_BATCH_ID are set.
#
# Single source of truth for the guest boot agent. Cloud-init profiles carry a
# placeholder under write_files (path /opt/vstorm-boot-timestamp.sh); vstorm
# splices this file in at runtime (tests/15-boot-timestamp.bats checks the
# placeholder is present and the spliced output matches this file).
set -euo pipefail

BOOT_TIMESTAMP_FILE="${RESULT_TIMESTAMP_FILE:-/root/timestamp.txt}"
mkdir -p "$(dirname "$BOOT_TIMESTAMP_FILE")"

_ts_unix=$(date -u +%s)
_ts_human=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
if [[ -f "$BOOT_TIMESTAMP_FILE" ]]; then
    printf '%s, %s\n' "$_ts_unix" "$_ts_human" >> "$BOOT_TIMESTAMP_FILE"
else
    printf '%s, %s\n' "$_ts_unix" "$_ts_human" > "$BOOT_TIMESTAMP_FILE"
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
    BOOT_TIMESTAMP_UNIX="$_ts_unix"
fi

echo "vstorm-boot-timestamp: file=$BOOT_TIMESTAMP_FILE boot_unix=$BOOT_TIMESTAMP_UNIX service_unix=$_ts_unix"

[[ -n "${RESULT_SERVER_URL:-}" ]] || exit 0
if [[ -z "${VSTORM_BATCH_ID:-}" ]]; then
    echo "RESULT_SERVER_URL set but VSTORM_BATCH_ID unset; skip boot heartbeat POST" >&2
    exit 0
fi
if ! command -v python3 &>/dev/null; then
    echo "python3 missing; skip boot heartbeat POST" >&2
    exit 0
fi
if ! command -v curl &>/dev/null; then
    echo "curl missing; skip boot heartbeat POST" >&2
    exit 0
fi

vm_name="${VSTORM_VM_NAME:-$(hostname -s 2>/dev/null || hostname || echo unknown)}"
hostname_s=$(hostname -s 2>/dev/null || hostname || echo unknown)
payload_file=$(mktemp)
trap 'rm -f "$payload_file"' EXIT

python3 - "$payload_file" "$BOOT_TIMESTAMP_UNIX" "$_ts_unix" \
    "$hostname_s" "${VSTORM_BATCH_ID}" "$vm_name" <<'PY'
import json, sys
from datetime import datetime, timezone

def fmt_utc(unix):
    return datetime.fromtimestamp(int(unix), tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

out, boot_unix, service_unix, hostname, batch_id, vm_name = sys.argv[1:7]
boot_unix = int(boot_unix)
service_unix = int(service_unix)
now = service_unix
payload = {
    "schema_version": 1,
    "record_type": "heartbeat",
    "source": "guest",
    "workload_kind": "boot",
    "status": "booted",
    "agent_state": "booted",
    "boot_timestamp": fmt_utc(boot_unix),
    "service_start": fmt_utc(service_unix),
    "reported_at": fmt_utc(now),
    "hostname": hostname,
    "batch_id": batch_id,
    "vm_name": vm_name,
}
with open(out, "w", encoding="utf-8") as f:
    json.dump(payload, f)
    f.write("\n")
PY

RESULT_RETRY="${RESULT_RETRY:-3}"
RESULT_TIMEOUT="${RESULT_TIMEOUT:-30}"
auth_args=()
[[ -n "${RESULT_SERVER_TOKEN:-}" ]] && auth_args+=(-H "Authorization: Bearer ${RESULT_SERVER_TOKEN}")
attempt=1
while (( attempt <= RESULT_RETRY )); do
    http_code=$(curl -sS -X POST -H "Content-Type: application/json" \
        --data-binary @"$payload_file" \
        --connect-timeout "$RESULT_TIMEOUT" \
        --max-time "$RESULT_TIMEOUT" \
        "${auth_args[@]}" \
        -o /tmp/vstorm-boot-post.body -w '%{http_code}' \
        "$RESULT_SERVER_URL" 2>/tmp/vstorm-boot-post.err) || true
    if [[ "$http_code" =~ ^2[0-9][0-9]$ ]]; then
        echo "Boot heartbeat posted to $RESULT_SERVER_URL"
        exit 0
    fi
    echo "Boot heartbeat POST failed attempt $attempt/$RESULT_RETRY: HTTP ${http_code:-000}"
    sleep $((attempt < 4 ? attempt * 2 : 8))
    ((attempt++)) || true
done
echo "Boot heartbeat POST failed after retries (file still written)" >&2
exit 0
