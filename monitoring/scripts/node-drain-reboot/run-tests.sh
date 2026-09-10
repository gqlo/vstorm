#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

if ! command -v bats >/dev/null 2>&1; then
  echo "run-tests: bats is required (e.g. sudo dnf install bats)" >&2
  exit 1
fi

bats mcp-reboot-watch.bats
