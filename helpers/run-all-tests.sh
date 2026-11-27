#!/usr/bin/env bash
# Run the full local test suite without going through git pre-commit:
#   - yamllint: plain YAML under helpers/, workload/, monitoring/yaml/,
#     monitoring/tests/fixtures/, .github/workflows/ (not templates/ — Go
#     templates are not valid YAML; same globs as .github/workflows/test.yaml)
#   - markdownlint-cli2: git-tracked *.md (CI uses **/*.md on checkout; we use
#     git ls-files so local-only trees like rh-internal-doc/ are skipped)
#   - Bats: tests/
#   - Python unittest: monitoring/tests/
#   - Node: monitoring/tests/test_dashboard_lib.js
# Usage: ./helpers/run-all-tests.sh   (from repo root or any cwd)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if ! command -v yamllint >/dev/null 2>&1; then
    echo "run-all-tests: yamllint is required (e.g. pip install yamllint)" >&2
    exit 1
fi
if ! command -v markdownlint-cli2 >/dev/null 2>&1; then
    echo "run-all-tests: markdownlint-cli2 is required (e.g. npm install -g markdownlint-cli2)" >&2
    exit 1
fi
if ! command -v bats >/dev/null 2>&1; then
    echo "run-all-tests: bats is required (e.g. sudo apt install bats)" >&2
    exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
    echo "run-all-tests: python3 is required for monitoring/tests" >&2
    exit 1
fi
if ! command -v node >/dev/null 2>&1; then
    echo "run-all-tests: node is required for dashboard JS tests" >&2
    exit 1
fi

echo "==> yamllint (plain YAML: helpers, workload, monitoring, workflows)"
shopt -s nullglob
_yaml_files=(
  helpers/*.yaml
  workload/*/*.yaml
  monitoring/yaml/*.yaml
  monitoring/tests/fixtures/*.yaml
  .github/workflows/*.yaml
)
if ((${#_yaml_files[@]} == 0)); then
  echo "run-all-tests: no YAML files matched yamllint globs" >&2
  exit 1
fi
yamllint "${_yaml_files[@]}"

echo "==> markdownlint-cli2 (git-tracked *.md)"
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    _md_files=()
    while IFS= read -r f || [[ -n "$f" ]]; do
        [[ -n "$f" ]] && _md_files+=("$f")
    done < <(git ls-files -- '*.md' '*.MD' 2>/dev/null || true)
    if ((${#_md_files[@]} == 0)); then
        echo "run-all-tests: no tracked .md files" >&2
        exit 1
    fi
    markdownlint-cli2 "${_md_files[@]}"
else
    echo "run-all-tests: not a git repository; cannot enumerate .md files (use a git checkout)" >&2
    exit 1
fi

echo "==> Bats (tests/)"
bats tests/

echo "==> Python unittest (monitoring/tests/)"
python3 -m unittest discover -s monitoring/tests -v

echo "==> Node dashboard lib tests"
node --test monitoring/tests/test_dashboard_lib.js

echo "run-all-tests: OK"
