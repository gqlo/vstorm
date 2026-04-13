#!/bin/bash
VM=fedora-dev

while true; do
  sudo virsh qemu-monitor-command $VM \
    '{"execute":"calc-dirty-rate","arguments":{"calc-time":1,"mode":"dirty-bitmap"}}' \
    > /dev/null 2>&1
  sleep 1.5
  rate=$(sudo virsh qemu-monitor-command $VM \
    '{"execute":"query-dirty-rate"}' 2>/dev/null \
    | jq '.return["dirty-rate"]')
  echo "$(date '+%H:%M:%S') | ${rate} MB/s"
done
