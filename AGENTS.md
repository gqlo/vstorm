# AGENTS.md

Guidance for AI coding agents (Cursor, Claude Code, Codex, and others) working
in this repository. This is the single source of truth for project conventions;
`CLAUDE.md` is a symlink to this file.

---

## Project overview

vstorm is a **Bash CLI tool** for batch VM creation on OpenShift Virtualization.
There is no build step — the main script (`vstorm`) is executed directly and is
distributed as a single self-contained file.

### Architecture

- `vstorm` — main script (~3,600 lines of Bash). It is **sourceable**: a source
  guard (`if [[ "${BASH_SOURCE[0]}" == "${0}" ]]`) means sourcing the file
  defines every function without parsing argv or touching a cluster.
- `templates/` — YAML templates with `{PLACEHOLDER}` syntax, processed by `sed`
  in `process_template()`.
- `helpers/` — utility scripts and cloud-init YAML configs.
- `workload/` — in-guest workload scripts and cloud-init configs.
- `tests/*.bats` — Bats tests (numbered files, dry-run and mock-based) plus
  `tests/90-unit-pure-functions.bats` (fast unit tests that source `vstorm`).
- `monitoring/` — result collector / dashboard (Python + JS) with its own tests.
- `docs/` — project documentation (Markdown).
- `logs/` — created at runtime for batch manifests and run logs.

### Clone modes

1. **Snapshot**: DataSource → base DV → VolumeSnapshot → VM clones (default for OCS).
2. **Direct DataSource**: DataSource → each VM clones directly (no-snapshot or WFFC storage).
3. **URL import**: URL → base DV → VM clones from base PVC.

All resources are tagged with a 6-character hex **batch ID** and carry
`batch-id` and `vm-basename` labels.

### Dependencies

- **Runtime**: `bash`, `oc` (OpenShift CLI), `xxd`, `sed`.
- **Testing**: `bats`; `python3` (`unittest`) and `node --test` for `monitoring/`.
- **CI**: GitHub Actions running `bats`, `yamllint`, `markdownlint-cli2`.

---

## Bash coding standards

Applies to `vstorm` and `helpers/*`.

- **Header**: every script starts with `#!/bin/bash` and `set -eu`.
- **Errors**: use `fatal()` for error exits — never bare `echo` + `exit 1`.
  `echo` is acceptable only inside `fatal()` and `help()`.
- **Output**: use `log_message` for user-facing status, not raw `echo`.
- **Naming**: globals/config `UPPER_SNAKE_CASE` (`STORAGE_CLASS`, `NUM_VMS`);
  locals `lower_snake_case`, declared with `local` (or `local -i` for integers).
- **Syntax**: `(( ))` for arithmetic, `[[ ]]` for string/file tests — never `[ ]`.
  Command substitution `$(...)`, never backticks. Tab indentation for shell code.
- **Functions**: `function_name() {` style (no `function` keyword). The lone
  historical exception is `process_template()`.
- **Option parsing**: short options via `getopts`; long options via
  `process_option()`. Simple value options live in the `_VSTORM_SIMPLE_OPTS`
  registry (one line each); options with extra side effects stay as explicit
  cases. A new option must be added to the parser **and** the `help()` text
  **and** `tab-completion/vstorm.bash`.

## Shell safety

- **Quote variables**: always `"$VAR"` — unquoted expansions break on spaces and glob.
- **Unset vars**: use `${VAR:-default}`; never reference a bare `$VAR` that could
  be unset under `set -u`.
- **Pipe safety**: `set -e` does not catch mid-pipe failures. For `oc | awk`
  chains where `oc` may fail, add `2>/dev/null ... || true`.
- **`oc` that may fail**: for reads where failure is a valid outcome (checking if
  a resource exists), append `|| true` or handle the error path.
- **Stderr**: only redirect to `/dev/null` when the error is expected and handled.
- **Command existence**: check with `[[ -z "$(type -t cmd)" ]]` (project pattern).
- **`eval`**: avoid for dynamic commands — use arrays. (The manifest code uses
  `eval` only to consume trusted, shell-quoted `var=value` lines from
  `_json_fields_to_shell`; do not introduce new `eval` of untrusted input.)

---

## YAML template conventions

Applies to `templates/*.yaml`.

- **Placeholders**: `{VARIABLE_NAME}`, substituted by `sed` in `process_template()`
  (e.g. `{vm-ns}`, `{vm-id}`, `{VM_BASENAME}`, `{BATCH_ID}`, `{DV_URL}`,
  `{DATASOURCE}`, `{DATASOURCE_NS}`, `{BASE_PVC_NAME}`, `{STORAGE_SIZE}`,
  `{STORAGE_CLASS}`, `{ACCESS_MODE}`, `{SNAPSHOT_CLASS}`, `{VM_CPU_CORES}`,
  `{VM_MEMORY}`, `{RUN_STRATEGY}`).
- **Indented tokens**: `{CLOUDINIT_DISK}`, `{CLOUDINIT_VOLUME}`, `{RESOURCES}`,
  `{DOMAIN_FIRMWARE}` are expanded by `indent_token()` and must appear **alone on
  a line** with leading spaces defining the indentation level. `{DOMAIN_FIRMWARE}`
  expands from `--firmware=efi` (default: `features.smm` + `firmware.bootloader.efi`
  with `secureBoot: false`) or `--firmware=bios` (`firmware.bootloader.bios: {}`).
- **Required labels**: every resource includes both `batch-id: "{BATCH_ID}"` and
  `vm-basename: "{VM_BASENAME}"` (quote values that could parse as non-strings).
- **Style**: 2-space indentation (enforced by yamllint); no `---` document-start
  marker (disabled in `.yamllint`); `volumeMode: Block` for storage specs.

---

## Testing

### Bats patterns

- **Naming**: `@test "PREFIX: descriptive title"` where PREFIX is a category code
  (`QS` Quick Start, `NS` no-snapshot, `DC` direct clone, `AD` auto-detection,
  `AM` access mode, `SP` StorageProfile, `WFFC`, `COMBO`, `OPT`, `UDN`, …).
- **Determinism**: end-to-end tests run in dry-run mode (`-n`) with a fixed
  `--batch-id`; assert with `[[ "$output" == *"..."* ]]`; count with `grep -c`.
- **Mock `oc`**: create a script in a temp dir and prepend it to `PATH`
  (`_create_mock_oc` in `tests/helpers.bash`, loaded via `load 'helpers'`).
- **File organization**: the suite is split across **numbered** `tests/NN-*.bats`
  files so `bats tests/ --jobs N` parallelises across files. Within a file,
  groups are separated by `# ===...===` banners and each test has a header
  comment with its ID and the command under test.
- **Unit tests**: `tests/90-unit-pure-functions.bats` `source`s `vstorm` and
  calls functions directly (no subprocess, no mock `oc`) — the fast layer for
  pure/validation/detection helpers (`join_name`, `validate_subnet`,
  `parse_bool_flag`, `_apply_simple_option`, `detect_access_mode`, …). Use `run`
  for functions that may call `fatal`; call directly to inspect mutated globals.

### Corresponding tests required

**Target: 100% coverage of the change delta.** Every new or behavior-changing
function (method / exported helper / CLI handler / significant bash function)
ships with a matching test **in the same change** — do not leave new or changed
functions untested, and do not defer tests to a follow-up.

| Code | Tests | Run |
|---|---|---|
| `vstorm`, `helpers/`, `workload/`, `tests/helpers.bash` | `tests/*.bats` | `bats tests/` |
| `monitoring/data-collector/**/*.py`, `monitoring/scripts/*.py` | `monitoring/tests/test_*.py` | `python3 -m unittest discover -s monitoring/tests -v` |
| `monitoring/data-collector/static/dashboard-lib.js` | `monitoring/tests/test_dashboard_lib.js` | `node --test monitoring/tests/test_dashboard_lib.js` |
| Pure logic currently in `app.js` | extract into `dashboard-lib.js`, then test there | same as above |

Rules:

1. New function → new test covering the happy path and, when non-trivial, one
   edge/error case.
2. Changed behavior → update the matching test so expectations stay truthful.
3. Prefer extracting pure logic into testable helpers over leaving it only in DOM
   handlers or large untested bash blocks.
4. Ship the test with the implementation, in the same commit/PR.

Exceptions (note in the commit/PR body if used): trivial one-line wrappers that
forward to an already-tested function; generated code or pure config with no
behavior; explicitly-temporary prototype spikes (add tests before merge).

### Test-fix discipline

When a test fails, fix the right thing in this order:

1. **Check the code logic first** — decide whether the failure is a real bug.
2. **Then analyze the test** — is the expectation outdated/wrong, or is it
   correctly catching a bug?
3. **Do not change tests solely to make them pass.** Don't relax assertions or
   rewrite expectations just to go green. If the test was right, fix the code; if
   the test was wrong, fix the test with a clear justification.

---

## Pre-commit checks

Before any `git commit`, run the relevant checks and fix failures. A pre-commit
hook also runs them; **never** bypass it with `--no-verify`. If a hook rejects a
commit, fix the issue and make a new commit (do not amend). After committing,
run `git status` to confirm.

Run the check(s) matching what changed:

```bash
# Bats — when vstorm / templates / helpers / workload / bats tests change
bats tests/

# Python — when monitoring/data-collector, monitoring/tests, or monitoring/scripts change
python3 -m unittest discover -s monitoring/tests -v

# Dashboard JS — when monitoring/data-collector/static or its test changes
node --test monitoring/tests/test_dashboard_lib.js

# YAML lint — changed plain YAML (helpers/, workload/, monitoring/yaml/,
# monitoring/tests/fixtures/, .github/workflows/; NOT templates/)
yamllint helpers/*.yaml workload/*.yaml monitoring/yaml/*.yaml \
  monitoring/tests/fixtures/*.yaml .github/workflows/*.yaml

# Markdown lint — changed .md files
markdownlint-cli2 "**/*.md"
```

---

## CI workflow

Independent, parallel jobs in `.github/workflows/test.yaml` (all on
`ubuntu-latest`, triggered on every `push` and `pull_request`):

| Job | Tool | Checks |
|---|---|---|
| `test` | `bats` | `bats tests/` |
| `test-python` | `unittest` | `monitoring/tests/` (after `pip install -r monitoring/tests/requirements.txt`) |
| `test-js` | `node --test` | `monitoring/tests/test_dashboard_lib.js` |
| `lint-yaml` | `yamllint` | plain YAML under `helpers/`, `workload/`, `monitoring/yaml/`, `monitoring/tests/fixtures/`, `.github/workflows/` |
| `lint-markdown` | `markdownlint-cli2` | `**/*.md` |

Conventions:

- Keep jobs **independent** and one tool per job for clear failure reporting;
  never add dependencies between lint jobs.
- Add a new linter (e.g. shellcheck) as a **new job**, not inline in an existing one.
- Adding YAML outside the lint-yaml globs → update yamllint in
  `.github/workflows/test.yaml`, `hooks/pre-commit`, and `helpers/run-all-tests.sh`.
- Adding Python test deps → `monitoring/tests/requirements.txt`.
- Adding dashboard JS helpers → `monitoring/data-collector/static/dashboard-lib.js`,
  covered by `monitoring/tests/test_dashboard_lib.js`.

---

## Debug logs

All agent/debug logs for this project **must** go under **`logs/`**, never under
`.cursor/`, the project root, `tmp/`, or ad-hoc locations (e.g.
`logs/debug-<session-id>.log`). The `logs/` directory is already used at runtime
for batch manifests and run logs — keep debug output there too for a single place
to inspect. If a tool provisions a log path elsewhere (e.g. under `.cursor/`),
treat this rule as overriding it.

---

## Behavioral guidelines

Guidelines to reduce common LLM coding mistakes. They bias toward caution over
speed; for trivial tasks, use judgment.

1. **Think before coding.** State assumptions explicitly; if uncertain, ask. If
   multiple interpretations exist, present them — don't pick silently. If a
   simpler approach exists, say so.
2. **Simplicity first.** Write the minimum code that solves the problem. No
   speculative features, abstractions for single-use code, unrequested
   "flexibility", or error handling for impossible scenarios. If 200 lines could
   be 50, rewrite.
3. **Surgical changes.** Touch only what you must. Don't "improve" adjacent code,
   refactor what isn't broken, or reformat to taste. Match existing style. Remove
   orphans **your** change created; mention (don't delete) pre-existing dead code.
   Every changed line should trace to the request.
4. **Goal-driven execution.** Turn tasks into verifiable goals ("add validation"
   → "write tests for invalid inputs, then make them pass") and loop until
   verified.

Working if: fewer unnecessary diff lines, fewer rewrites from overcomplication,
and clarifying questions come before implementation rather than after mistakes.
