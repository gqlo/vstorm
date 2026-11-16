# AGENTS.md

Project instructions for AI coding agents (Cursor, Claude Code, Codex, Gemini CLI,
Zed, etc.). This is the **single source of truth**. Tool-specific entry points
point back here:

- `CLAUDE.md` is a symlink to this file (Claude Code).
- Cursor also reads this file, and keeps finer-grained, glob-scoped rules in
  `.cursor/rules/*.mdc` (same guidance, auto-attached per file path).
- Codex / Gemini CLI / Zed read this file directly.

Keep edits here; do not duplicate content into tool-specific files.

---

## Project Context

vstorm is a **Bash CLI tool** for batch VM creation on OpenShift Virtualization.
There is no build step -- the main script (`vstorm`) is executed directly.

### Architecture

- `vstorm` -- main script (~991 lines of Bash)
- `templates/` -- YAML templates with `{PLACEHOLDER}` syntax, processed by `sed`
- `helpers/` -- utility scripts and cloud-init YAML configs
- `tests/*.bats` -- Bats unit tests (dry-run and mock-based)
- `monitoring/` -- Python data collector + JS dashboard
- `docs/` -- project documentation (Markdown)
- `logs/` -- created at runtime for batch manifests and logs

### Clone Modes

1. **Snapshot**: DataSource -> base DV -> VolumeSnapshot -> VM clones (default for OCS)
2. **Direct DataSource**: DataSource -> each VM clones directly (no-snapshot or WFFC storage)
3. **URL import**: URL -> base DV -> VM clones from base PVC

All resources are tagged with a 6-character hex **batch ID** and carry `batch-id`
and `vm-basename` labels.

### Dependencies

- **Runtime**: `bash`, `oc` (OpenShift CLI), `xxd`, `sed`
- **Testing**: `bats`, Python `unittest`, Node built-in test runner
- **CI**: GitHub Actions running `bats`, `yamllint`, `markdownlint-cli2`,
  `unittest`, `node --test`

---

## Behavioral Guidelines

Behavioral guidelines to reduce common LLM coding mistakes. Merge with the
project-specific rules below.

**Tradeoff:** These bias toward caution over speed. For trivial tasks, use judgment.

### 1. Think Before Coding

**Don't assume. Don't hide confusion. Surface tradeoffs.**

- State your assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them -- don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.

### 2. Simplicity First

**Minimum code that solves the problem. Nothing speculative.**

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.

Ask: "Would a senior engineer say this is overcomplicated?" If yes, simplify.

### 3. Surgical Changes

**Touch only what you must. Clean up only your own mess.**

- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it -- don't delete it.
- Remove imports/variables/functions that *your* changes made unused; don't
  remove pre-existing dead code unless asked.

The test: every changed line should trace directly to the user's request.

### 4. Goal-Driven Execution

**Define success criteria. Loop until verified.**

- "Add validation" -> "Write tests for invalid inputs, then make them pass"
- "Fix the bug" -> "Write a test that reproduces it, then make it pass"
- "Refactor X" -> "Ensure tests pass before and after"

For multi-step tasks, state a brief plan with a verify step for each.

---

## Bash Coding Standards

Applies to: `vstorm`, `helpers/*`.

### Script Header

Every script must start with `#!/bin/bash` and `set -eu`.

### Error Handling

Use `fatal()` for error exits -- never bare `echo` + `exit 1`:

```bash
# BAD
echo "Error: something failed"
exit 1

# GOOD
fatal "Error: something failed"
```

### Variable Naming

- **Globals/config**: `UPPER_SNAKE_CASE` (e.g. `STORAGE_CLASS`, `NUM_VMS`)
- **Locals**: `lower_snake_case`; declare with `local` or `local -i` for integers

### Syntax Conventions

- Use `(( ))` for arithmetic, `[[ ]]` for string/file tests -- never `[ ]`
- Use **tab indentation** (not spaces) for shell code
- Use `$(command)` for command substitution, never backticks

### Output

- Use `log_message` for user-facing status output, not raw `echo`
- `echo` is acceptable only inside `fatal()` and `help()`

### Functions

- Use `function_name() {` style (no `function` keyword)
- The one exception is `function process_template()` (historical)

### Option Parsing

- Short options use `getopts`
- Long options are parsed via the `process_option()` helper inside the `getopts` loop
- New options must be added to both the parser and the `help()` text

---

## Shell Script Safety

Applies to: `vstorm`, `helpers/*`.

### Variable Quoting

Always quote variables -- unquoted expansions break on spaces and trigger globbing:

```bash
# BAD
if [[ -n $STORAGE_CLASS ]] ; then
# GOOD
if [[ -n "$STORAGE_CLASS" ]] ; then
```

### Unset Variables

Use `${VAR:-default}`. Never reference a bare `$VAR` that could be empty under `set -eu`:

```bash
# BAD -- exits under set -u if VM_ID is unset
echo "$VM_ID"
# GOOD
echo "${VM_ID:-}"
```

### Pipe Safety

`set -e` does not catch mid-pipe failures. Handle explicitly:

```bash
# BAD -- if oc fails, awk still runs and set -e won't catch it
oc get ns --no-headers | awk '{print $1}'
# GOOD
oc get ns --no-headers 2>/dev/null | awk '{print $1}' || true
```

### Other Rules

- Use `$(command)`, never backticks.
- Never use `eval`. Use arrays for dynamic commands.
- For `oc` commands where failure is a valid outcome (e.g. checking if a
  resource exists), append `|| true` or handle the error path.
- Only redirect stderr to `/dev/null` when the error is expected and handled.
  Never silently discard unexpected errors.
- Check for commands with `[[ -z "$(type -t cmd)" ]]` (matching existing pattern).

---

## YAML Template Conventions

Applies to: `templates/*.yaml`.

### Placeholder Syntax

Templates use `{VARIABLE_NAME}` placeholders processed by `sed` in `process_template()`.

**Available placeholders:** `{vm-ns}`, `{vm-id}`, `{VM_BASENAME}`, `{BATCH_ID}`,
`{DV_URL}`, `{DATASOURCE}`, `{DATASOURCE_NS}`, `{BASE_PVC_NAME}`, `{STORAGE_SIZE}`,
`{STORAGE_CLASS}`, `{ACCESS_MODE}`, `{SNAPSHOT_CLASS}`, `{VM_CPU_CORES}`,
`{VM_MEMORY}`, `{RUN_STRATEGY}`.

**Indented token placeholders** (`{CLOUDINIT_DISK}`, `{CLOUDINIT_VOLUME}`,
`{RESOURCES}`, `{DOMAIN_FIRMWARE}`) are processed by `indent_token()` and must
appear **alone on a line** with leading spaces defining the indentation level:

- **`{DOMAIN_FIRMWARE}`** expands from `--firmware=efi` (default: `features.smm`
  plus `firmware.bootloader.efi` with **`secureBoot: false`**) or
  `--firmware=bios` (`firmware.bootloader.bios: {}` only).

### Required Labels

All resources must include both labels:

```yaml
labels:
  batch-id: "{BATCH_ID}"
  vm-basename: "{VM_BASENAME}"
```

### Style

- 2-space YAML indentation (enforced by yamllint)
- No `---` document-start marker (disabled in `.yamllint`)
- Use `volumeMode: Block` for storage specs
- Quote label values that could be interpreted as non-strings

---

## Testing: Require Corresponding Tests

When adding or significantly changing a **function** (method, exported helper,
CLI subcommand handler), add or update a **corresponding test in the same change**.

| Language / area | Put production code in | Put tests in | Run |
|---|---|---|---|
| Python (`monitoring/`) | `monitoring/data-collector/`, `monitoring/scripts/` | `monitoring/tests/test_*.py` | `python3 -m unittest discover -s monitoring/tests -v` |
| Dashboard JS helpers | `monitoring/data-collector/static/dashboard-lib.js` | `monitoring/tests/test_dashboard_lib.js` | `node --test monitoring/tests/test_dashboard_lib.js` |
| Dashboard UI wiring | `app.js` | Extract pure logic into `dashboard-lib.js`, test there | same as above |
| Bash | `vstorm`, `helpers/`, `workload/`, `tests/helpers.bash` | `tests/*.bats` | `bats tests/` |

### Rules

1. New function -> new test covering happy path and at least one edge/error case when non-trivial.
2. Changed behavior -> update the matching test so expectations stay truthful.
3. Prefer testable helpers over untested DOM/CLI glue.
4. Ship the test with the implementation, not as a follow-up.
5. Run the suite for the language you touched before finishing.

**Exceptions** (document in the PR/commit body if used): trivial one-line
wrappers forwarding to already-tested code; generated code or pure config;
prototype spikes explicitly marked temporary (must add tests before merge).

---

## Testing: Bats Patterns

Applies to: `tests/*.bats`.

### Test Naming

Use `@test "PREFIX: descriptive title"` where PREFIX is a category code:
`QS` (Quick Start), `NS` (No-snapshot), `DC` (Direct DataSource clone),
`AD` (Auto-detection), `AM` (Access mode), `SP` (StorageProfile auto-detection),
`WFFC` (WaitForFirstConsumer), `COMBO` (Option combinations), `OPT` (Option
coverage), `UDN` (User Defined Network).

### Structure & Key Patterns

```bash
@test "PREFIX: descriptive title" {
  run bash "$VSTORM" -n --batch-id=XXXX [options]
  [ "$status" -eq 0 ]
  [[ "$output" == *"expected substring"* ]]
  [[ "$output" != *"unexpected substring"* ]]
}
```

- Always use **dry-run** (`-n`) with a fixed `--batch-id` for deterministic output.
- Use `[[ "$output" == *"..."* ]]` for substring matching; `grep -c` to count.
- Mock `oc` by creating a script in a temp dir and prepending it to `PATH`.
- `$VSTORM` is defined at the top of the file as `./vstorm`.

### File Organization

The suite is split across numbered files so `bats tests/ --jobs N` parallelises
across files (`01-quickstart.bats`, `02-core-validation.bats`,
`03-yaml-no-snapshot.bats`, `04-clone-modes.bats`, `05-storage-wffc.bats`,
`06-combos-storage.bats`, `07-combos-scale-naming.bats`, `08-combos-wffc-misc.bats`,
`09-delete-profile.bats`, `10-containerdisk.bats`, `11-completion.bats`,
`14-udn.bats`). Shared helpers (e.g. `_create_mock_oc`) live in `tests/helpers.bash`,
loaded with `load 'helpers'`.

---

## Testing: Fix Discipline

When a test fails:

1. **Check the code logic first** -- is the failure a real bug or wrong behavior?
2. **Analyze the test** -- only then decide if the test is wrong (outdated
   expectation, bad assertion) or correctly catching a bug.
3. **Do not change tests solely to make them pass.** If the test was correct, fix
   the code; if the test was wrong, fix it with a clear justification.

Order: code logic -> test analysis -> fix the right thing.

---

## Pre-Commit Checks

Before creating any `git commit`, run the relevant checks and fix any failures.

| When these change | Run |
|---|---|
| `vstorm` / `templates` / `helpers` / `workload` / bats tests | `bats tests/` |
| `monitoring/data-collector/`, `monitoring/tests/`, `monitoring/scripts/` | `python3 -m unittest discover -s monitoring/tests -v` |
| `monitoring/data-collector/static/` | `node --test monitoring/tests/test_dashboard_lib.js` |
| Changed plain YAML (`helpers/`, `workload/`, `monitoring/yaml/`, `monitoring/tests/fixtures/`, `.github/workflows/`; **not** `templates/`) | `yamllint <files>` |
| Changed `.md` files | `markdownlint-cli2 "**/*.md"` |

### Rules

- If any check fails, fix the issue before committing.
- Never use `--no-verify` to bypass pre-commit hooks.
- After committing, run `git status` to verify the commit succeeded.
- If a pre-commit hook rejects the commit, fix the reported issue and create a
  new commit (do not amend).

---

## CI/CD Workflow

Independent jobs in `.github/workflows/test.yaml`:

| Job | Tool | What it checks |
|---|---|---|
| `test` | `bats` | `bats tests/` (all unit tests) |
| `test-python` | `unittest` | `monitoring/tests/` after installing `monitoring/tests/requirements.txt` |
| `test-js` | `node --test` | `monitoring/tests/test_dashboard_lib.js` |
| `lint-yaml` | `yamllint` | Plain YAML under `helpers/`, `workload/`, `monitoring/yaml/`, `monitoring/tests/fixtures/`, `.github/workflows/` |
| `lint-markdown` | `markdownlint-cli2` | `**/*.md` |

### Conventions

- Triggers: all `push` and `pull_request` events; runner `ubuntu-latest`.
- Jobs must be **independent** and run in parallel -- never add dependencies
  between lint jobs. Keep each job focused on one tool for clear failure reporting.
- Adding a new linter (e.g. shellcheck): add it as a **new job**, not inline.
- Adding YAML outside the lint-yaml globs: update yamllint in
  `.github/workflows/test.yaml`, `hooks/pre-commit`, and `helpers/run-all-tests.sh`.
- Adding Python test deps: put them in `monitoring/tests/requirements.txt`.

---

## Agent Debug Logs

All debug/instrumentation logs for this project **must** go in the `logs/` folder
(e.g. `logs/debug-*.log`), **never** under `.cursor/`, the project root, `tmp/`,
or other ad-hoc locations. If a tool provisions a log path under `.cursor/`, treat
this rule as overriding it and use `logs/` instead. The `logs/` directory is
already used at runtime for batch manifests and run logs.
