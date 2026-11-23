#!/usr/bin/env bats
# Unit tests for workload/vstorm-boot-timestamp.sh (guest oneshot).
#
# Exception to the usual `bash "$VSTORM" -n --batch-id=…` dry-run pattern:
# this suite exercises the standalone guest script directly (file I/O, curl POST
# payload, embed parity). Cloud-init YAML only embeds the script; dry-run cannot
# run it. Prefix remains boot-ts.

load 'helpers'

SCRIPT="workload/vstorm-boot-timestamp.sh"
SERVICE="workload/vstorm-boot-timestamp.service"
VSTORM="${VSTORM:-./vstorm}"

setup() {
    _BT_DIR=$(mktemp -d)
    export RESULT_TIMESTAMP_FILE="$_BT_DIR/timestamp.txt"
    unset RESULT_SERVER_URL VSTORM_BATCH_ID RESULT_SERVER_TOKEN VSTORM_VM_NAME
    unset RESULT_RETRY RESULT_TIMEOUT
}

teardown() {
    [[ -n "${_BT_MOCK_BIN:-}" ]] && rm -rf "$_BT_MOCK_BIN"
    [[ -n "${_BT_DIR:-}" ]] && rm -rf "$_BT_DIR"
    if [[ -n "${_BT_PATH_SAVE:-}" ]]; then
        export PATH="$_BT_PATH_SAVE"
        unset _BT_PATH_SAVE
    fi
}

_extract_embedded_boot_script() {
    local yaml=$1
    local marker=${2:-path: /opt/vstorm-boot-timestamp.sh}
    python3 - "$yaml" "$marker" <<'PY'
import sys
from pathlib import Path
text = Path(sys.argv[1]).read_text().splitlines()
marker = sys.argv[2]
i = next(i for i, l in enumerate(text) if marker in l)
j = next(j for j in range(i, i + 5) if text[j].rstrip().endswith("content: |"))
body = []
for k in range(j + 1, len(text)):
    line = text[k]
    if line.startswith("      "):
        body.append(line[6:])
    elif line.strip() == "":
        nxt = next((text[n] for n in range(k + 1, len(text)) if text[n].strip() != ""), "")
        if nxt.startswith("  - ") or (nxt and not nxt.startswith("      ")):
            break
        body.append("")
    else:
        break
while body and body[-1] == "":
    body.pop()
sys.stdout.write("\n".join(body))
if body:
    sys.stdout.write("\n")
PY
}

_install_mock_curl() {
    local mode=$1  # ok | fail
    _BT_MOCK_BIN=$(mktemp -d)
    _BT_PATH_SAVE="$PATH"
    export PATH="$_BT_MOCK_BIN:$PATH"
    cat > "$_BT_MOCK_BIN/curl" <<EOF
#!/bin/bash
# mode=$mode
body=""
out_body="/dev/null"
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    --data-binary)
      shift
      body="\${1#@}"
      ;;
    -o)
      shift
      out_body="\$1"
      ;;
    -w)
      shift
      ;;
    *)
      ;;
  esac
  shift || true
done
if [[ -n "\$body" && -f "\$body" ]]; then
  cp -f "\$body" "$_BT_DIR/last-payload.json"
fi
printf '' > "\$out_body"
if [[ "$mode" == "ok" ]]; then
  printf '200'
  exit 0
fi
printf '503'
exit 0
EOF
    chmod +x "$_BT_MOCK_BIN/curl"
}

# ---------------------------------------------------------------
# boot-ts: syntax / file behavior
# ---------------------------------------------------------------
@test "boot-ts: script has valid bash syntax" {
    bash -n "$SCRIPT"
}

@test "boot-ts: creates timestamp file with numeric unix" {
    run bash "$SCRIPT"
    [[ "$status" -eq 0 ]]
    [[ -f "$RESULT_TIMESTAMP_FILE" ]]
    grep -qE '^[0-9]+,' "$RESULT_TIMESTAMP_FILE"
}

@test "boot-ts: appends on second run and keeps first boot unix" {
    run bash "$SCRIPT"
    [[ "$status" -eq 0 ]]
    first=$(grep -E '^[0-9]+,' "$RESULT_TIMESTAMP_FILE" | head -1 | cut -d, -f1 | tr -d ' ')
    sleep 1
    run bash "$SCRIPT"
    [[ "$status" -eq 0 ]]
    lines=$(grep -cE '^[0-9]+,' "$RESULT_TIMESTAMP_FILE" || true)
    [[ "$lines" -ge 2 ]]
    again=$(grep -E '^[0-9]+,' "$RESULT_TIMESTAMP_FILE" | head -1 | cut -d, -f1 | tr -d ' ')
    [[ "$first" == "$again" ]]
}

@test "boot-ts: skips non-numeric header when resolving boot" {
    printf '%s\n' 'unix-timestamp, YYYY-MM-DDTHH:MM:SSZ' > "$RESULT_TIMESTAMP_FILE"
    run bash "$SCRIPT"
    [[ "$status" -eq 0 ]]
    boot_unix=$(grep -E '^[0-9]+,' "$RESULT_TIMESTAMP_FILE" | head -1 | cut -d, -f1 | tr -d ' ')
    [[ -n "$boot_unix" ]]
    [[ "$output" == *"boot_unix=$boot_unix"* ]]
}

# ---------------------------------------------------------------
# boot-ts: collector POST (mocked curl)
# ---------------------------------------------------------------
@test "boot-ts: POST payload includes heartbeat fields on 2xx" {
    _install_mock_curl ok
    export RESULT_SERVER_URL="http://collector.test/v1/results"
    export VSTORM_BATCH_ID="btpost01"
    export VSTORM_VM_NAME="vm-btpost01-1"
    export RESULT_RETRY=1
    export RESULT_TIMEOUT=1
    run bash "$SCRIPT"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Boot heartbeat posted"* ]]
    [[ -f "$_BT_DIR/last-payload.json" ]]
    python3 - "$_BT_DIR/last-payload.json" <<'PY'
import json, sys
p = json.load(open(sys.argv[1], encoding="utf-8"))
assert p.get("record_type") == "heartbeat"
assert p.get("workload_kind") == "boot"
assert p.get("batch_id") == "btpost01"
assert p.get("vm_name") == "vm-btpost01-1"
assert p.get("boot_timestamp")
assert p.get("agent_state") == "booted"
PY
}

@test "boot-ts: non-2xx POST keeps timestamp file and exits 0" {
    _install_mock_curl fail
    export RESULT_SERVER_URL="http://collector.test/v1/results"
    export VSTORM_BATCH_ID="btfail01"
    export RESULT_RETRY=1
    export RESULT_TIMEOUT=1
    run bash "$SCRIPT"
    [[ "$status" -eq 0 ]]
    [[ -f "$RESULT_TIMESTAMP_FILE" ]]
    grep -qE '^[0-9]+,' "$RESULT_TIMESTAMP_FILE"
    before=$(wc -c < "$RESULT_TIMESTAMP_FILE")
    [[ "$before" -gt 0 ]]
    [[ "$output" == *"Boot heartbeat POST failed"* ]]
    [[ "$output" != *"Boot heartbeat posted"* ]]
}

@test "boot-ts: unreachable RESULT_SERVER_URL still writes file and exits 0" {
    export RESULT_SERVER_URL="http://127.0.0.1:1/v1/results"
    export VSTORM_BATCH_ID="btunreachable"
    export RESULT_RETRY=1
    export RESULT_TIMEOUT=1
    run bash "$SCRIPT"
    [[ "$status" -eq 0 ]]
    [[ -f "$RESULT_TIMESTAMP_FILE" ]]
    grep -qE '^[0-9]+,' "$RESULT_TIMESTAMP_FILE"
    [[ "$output" == *"Boot heartbeat POST failed"* ]]
}

@test "boot-ts: RESULT_SERVER_URL without VSTORM_BATCH_ID skips POST" {
    export RESULT_SERVER_URL="http://127.0.0.1:1/v1/results"
    unset VSTORM_BATCH_ID
    export RESULT_RETRY=1
    export RESULT_TIMEOUT=1
    run bash "$SCRIPT"
    [[ "$status" -eq 0 ]]
    [[ -f "$RESULT_TIMESTAMP_FILE" ]]
    [[ "$output" == *"VSTORM_BATCH_ID unset"* ]]
    [[ "$output" != *"Boot heartbeat posted"* ]]
}

# ---------------------------------------------------------------
# boot-ts: placeholder + runtime splice from standalone source of truth
# ---------------------------------------------------------------
@test "boot-ts: all workload cloud-inits carry the boot script/service placeholders, not embedded copies" {
    local y
    for y in workload/cloudinit-fio-workload.yaml \
             workload/cloudinit-stress-ng-workload.yaml \
             workload/cloudinit-dirty-mem-pages.yaml \
             workload/cloudinit-default.yaml; do
        grep -q 'path: /opt/vstorm-boot-timestamp.sh' "$y"
        grep -q 'path: /etc/systemd/system/vstorm-boot-timestamp.service' "$y"
        # Placeholders present (each alone on its line); bodies no longer embedded.
        grep -qE '^[[:space:]]*\{VSTORM_BOOT_SCRIPT\}[[:space:]]*$' "$y"
        grep -qE '^[[:space:]]*\{VSTORM_BOOT_SERVICE\}[[:space:]]*$' "$y"
        # Distinctive lines now live only in the standalone script/unit files.
        ! grep -q 'Boot heartbeat posted' "$y"
        ! grep -q 'ExecStart=/opt/vstorm-boot-timestamp.sh' "$y"
    done
}

@test "boot-ts: vstorm splices the standalone script into cloud-init userdata byte-for-byte" {
    local out b64 decoded emb src
    src=$(cat "$SCRIPT")
    out=$(bash "$VSTORM" -n --batch-id=bootsp1 --datasource=rhel9 --vms=1 \
        --namespaces=1 --cloudinit=workload/cloudinit-default.yaml 2>/dev/null)
    b64=$(echo "$out" | grep "userdata:" | head -1 | sed 's/.*userdata: *//')
    [ -n "$b64" ]
    decoded=$(echo "$b64" | base64 -d 2>/dev/null)
    # Placeholder line is fully replaced (only the self-describing comment remains).
    [[ "$decoded" != *$'\n      {VSTORM_BOOT_SCRIPT}\n'* ]]
    # Spliced body equals the standalone source of truth.
    printf '%s\n' "$decoded" > "$_BT_DIR/decoded.yaml"
    emb=$(_extract_embedded_boot_script "$_BT_DIR/decoded.yaml")
    [[ "$emb" == "$src" ]]
}

@test "boot-ts: vstorm splices the standalone systemd unit into cloud-init userdata byte-for-byte" {
    local out b64 decoded emb src
    src=$(cat "$SERVICE")
    out=$(bash "$VSTORM" -n --batch-id=bootsv1 --datasource=rhel9 --vms=1 \
        --namespaces=1 --cloudinit=workload/cloudinit-default.yaml 2>/dev/null)
    b64=$(echo "$out" | grep "userdata:" | head -1 | sed 's/.*userdata: *//')
    [ -n "$b64" ]
    decoded=$(echo "$b64" | base64 -d 2>/dev/null)
    [[ "$decoded" != *"{VSTORM_BOOT_SERVICE}"* ]]
    printf '%s\n' "$decoded" > "$_BT_DIR/decoded.yaml"
    emb=$(_extract_embedded_boot_script "$_BT_DIR/decoded.yaml" \
        "path: /etc/systemd/system/vstorm-boot-timestamp.service")
    [[ "$emb" == "$src" ]]
}
