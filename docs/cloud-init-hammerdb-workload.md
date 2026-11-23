# Cloud-init and HammerDB workload

> **Status: design plan / proposal.** This is a guide for *adding* a HammerDB
> workload. The `workload/cloudinit-hammerdb-workload.yaml` profile and its
> result-sync wiring do **not** exist yet — the YAML and shell below are a
> skeleton to build from, not a shipped, tested workload. The `vstorm` commands
> throughout assume you have first created that file (see
> [The cloud-init profile](#the-cloud-init-profile)); they will fail until you do.

Run a [HammerDB](https://www.hammerdb.com/docs6.1/ch01s14.html#d0e755) TPROC-C
(OLTP) database benchmark inside VMs at boot. This plan follows the same pattern
as the [fio](cloud-init-fio-workload.md) and
[stress-ng](cloud-init-stress-ng-workload.md) workloads: a script and systemd unit
delivered through cloud-init, tuned through `vstorm --env`.

Unlike fio/stress-ng, HammerDB needs **a database running in the guest** and the
**HammerDB CLI** (`hammerdbcli`). Both are **pre-installed in the image**; the
cloud-init profile then only initializes the DB, builds the schema once, and runs
the benchmark. The run scripts and `HDB_*` parameters are delivered through the
cloud-init Secret, so one image serves every run configuration.

For VM CPU/memory options (`--cores`, `--memory`, etc.), see the main
[README](../README.md#options).

## Quick start: example commands

Once you have created `workload/cloudinit-hammerdb-workload.yaml` from
[the skeleton below](#the-cloud-init-profile), these are the intended invocations:

| Goal | Command |
|------|---------|
| Default (PostgreSQL TPROC-C) | `vstorm --cloudinit=workload/cloudinit-hammerdb-workload.yaml --cores=4 --memory=8Gi --vms=5` |
| Bigger schema + more virtual users | `vstorm --cloudinit=workload/cloudinit-hammerdb-workload.yaml --env HDB_WAREHOUSES=20 --env HDB_VU=8 --cores=8 --memory=16Gi --vms=5` |
| Longer run | `vstorm --cloudinit=workload/cloudinit-hammerdb-workload.yaml --env HDB_RAMPUP=5 --env HDB_DURATION=30 --vms=5` |
| Dry-run to preview | `vstorm -n --cloudinit=workload/cloudinit-hammerdb-workload.yaml --vms=3` |

Defaults target a **small, self-contained** run (a few warehouses) so it
completes on modest VMs. Scale up with `--env` and larger `--cores`/`--memory`.

## Image requirements and recommendation

**Pre-install HammerDB and the database in the image.** Build a **custom QCOW /
DataSource** with the database, the HammerDB CLI unpacked under `/opt/HammerDB`, and
their runtime dependencies already in place. Keep the image **generic**: do *not*
bake the run scripts or benchmark parameters into it. cloud-init plus the Secret
deliver the run logic and the `HDB_*` parameters at boot, so one image serves every
schema size and run configuration. This is faster, deterministic, and works on
**air-gapped** clusters with no outbound network — a first-boot HammerDB download is
the slowest and most failure-prone step, and this avoids it.

The guest still needs the DB **initialized and started** at boot; the orchestration
script does that (`postgresql-setup --initdb` + `systemctl enable --now`). It
targets **RHEL-family** guests (`postgresql-setup`); adapt the init steps for other
distros.

**OCP OS images** (DataSources from `openshift-virtualization-os-images`, e.g.
`rhel9`) are **minimal**: no DB, no HammerDB. They will fail here. Prefer a custom
DataSource or `--dv-url` (HTTPS, pinned digest) you control, built from one of them
with HammerDB + the DB added. See the
[fio doc](cloud-init-fio-workload.md#image-requirements-and-recommendation)
for the full rationale.

Size the root disk for the database: `HDB_WAREHOUSES` × ~100 MB plus the OS. Raise
`--storage-size`, or attach a data disk with `--data-disk-size=N` and point the DB
data directory at it.

## Run at boot

```bash
vstorm --cloudinit=workload/cloudinit-hammerdb-workload.yaml --vms=5 --namespaces=2
```

The image already has the DB + HammerDB. vstorm injects the build/run Tcl scripts
and the workload script into the cloud-init Secret, which cloud-init writes to
`/opt`, then enables `hammerdb-workload.service` (**one-shot**: init DB → build
schema → run benchmark → exit). Pass `HDB_*` once via `vstorm --env`.

**Result sync is not implemented in this skeleton.** The orchestration script
below only writes NOPM/TPM to `/root/hammerdb-result.txt` and leaves a TODO where a
collector POST would go. To push results to the dashboard, you must add a
`report_result`/heartbeat implementation — mirror
[`report_result` in workload/cloudinit-fio-workload.yaml](../workload/cloudinit-fio-workload.yaml)
and see [workload result sync and dashboard](workload-result-sync-and-dashboard.md).
The `RESULT_SERVER_URL` / `VSTORM_*` rows below are the *intended* contract for
that future work, not yet wired up.

## Tuning: env overrides

Override with `--env KEY=VAL` (repeat as needed):

| Parameter | Description |
|-----------|-------------|
| `HDB_DB` | HammerDB database target (default `pg` for PostgreSQL; e.g. `mysql`, `maria`, `mssql`) |
| `HDB_WAREHOUSES` | TPROC-C schema size in warehouses (default `4`) |
| `HDB_VU` | Virtual users (benchmark clients; default `4`) |
| `HDB_RAMPUP` | Ramp-up minutes before measurement (default `2`) |
| `HDB_DURATION` | Measured run minutes (default `5`) |
| `RESULT_SERVER_URL` | *(planned, not implemented)* Collector results URL for a post-run POST |
| `VSTORM_BATCH_ID` / `VSTORM_VM_NAME` | *(planned)* Auto-injected by vstorm for result join |

```bash
# Larger schema and more virtual users
vstorm --cloudinit=workload/cloudinit-hammerdb-workload.yaml \
  --env HDB_WAREHOUSES=50 --env HDB_VU=16 \
  --cores=8 --memory=16Gi --vms=5

# Collect results to the dashboard collector (requires adding the POST — see above)
vstorm --cloudinit=workload/cloudinit-hammerdb-workload.yaml \
  --env HDB_WAREHOUSES=20 --env HDB_VU=8 \
  --env RESULT_SERVER_URL=http://<reachable-host>:8080/v1/results \
  --cores=8 --memory=16Gi --vms=5 --wait
```

## The cloud-init profile

Create `workload/cloudinit-hammerdb-workload.yaml`. The skeleton below mirrors the
fio/stress-ng profiles — see
[workload/cloudinit-fio-workload.yaml](../workload/cloudinit-fio-workload.yaml)
for the full result-sync boilerplate (`/etc/default/vstorm-guest-env`,
`vstorm-boot-timestamp.service`) to copy verbatim.

```yaml
#cloud-config
preserve_hostname: false
ssh_pwauth: true
disable_root: false
chpasswd:
  expire: false
  users:
    - name: root
      password: password
      type: text

write_files:
  # Guest env injected by `vstorm --env` (HDB_*, RESULT_SERVER_URL, ...)
  - path: /etc/default/vstorm-guest-env
    permissions: '0644'
    content: |
      {VSTORM_GUEST_ENV}

  # TPROC-C schema build script — vstorm injects workload/hammerdb/build.tcl
  - path: /opt/hammerdb/build.tcl
    permissions: '0644'
    content: |
      {HAMMERDB_BUILD_TCL}

  # TPROC-C timed run script — vstorm injects workload/hammerdb/run.tcl
  - path: /opt/hammerdb/run.tcl
    permissions: '0644'
    content: |
      {HAMMERDB_RUN_TCL}

  # Orchestration — vstorm injects workload/hammerdb/hammerdb_workload.sh
  - path: /opt/hammerdb_workload.sh
    permissions: '0755'
    content: |
      {HAMMERDB_ORCHESTRATE_SH}

  # systemd unit — vstorm injects workload/hammerdb/hammerdb-workload.service
  - path: /etc/systemd/system/hammerdb-workload.service
    permissions: '0644'
    content: |
      {HAMMERDB_SERVICE_UNIT}

runcmd:
  - sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
  - sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
  - systemctl restart sshd 2>/dev/null || systemctl restart ssh
  - ["systemctl", "daemon-reload"]
  - ["systemctl", "enable", "--now", "hammerdb-workload.service"]
```

### The injected scripts (`workload/hammerdb/`)

The placeholders above are the single source of truth for the run logic and the
unit; they live as files under `workload/hammerdb/` and vstorm substitutes each one
into the cloud-init Secret at run time (see
[How vstorm injects the scripts](#how-vstorm-injects-the-scripts)).
Because HammerDB and the database are **already in the image**, the orchestration
script only initializes the DB, builds the schema once, and runs the benchmark —
there is no package install or HammerDB download.

`workload/hammerdb/build.tcl` — TPROC-C schema build (CLI / autopilot mode):

```tcl
dbset db $env(HDB_DB)
dbset bm TPC-C
diset connection pg_host localhost
diset connection pg_port 5432
diset tpcc pg_superuser postgres
diset tpcc pg_superuserpass postgres
diset tpcc pg_user tpcc
diset tpcc pg_pass tpcc
diset tpcc pg_dbase tpcc
diset tpcc pg_count_ware $env(HDB_WAREHOUSES)
# Build users must not exceed the warehouse count.
diset tpcc pg_num_vu [expr {min($env(HDB_VU), $env(HDB_WAREHOUSES))}]
buildschema
waittocomplete
quit
```

`workload/hammerdb/run.tcl` — TPROC-C timed run:

```tcl
dbset db $env(HDB_DB)
dbset bm TPC-C
diset connection pg_host localhost
diset connection pg_port 5432
diset tpcc pg_user tpcc
diset tpcc pg_pass tpcc
diset tpcc pg_dbase tpcc
diset tpcc pg_driver timed
diset tpcc pg_rampup $env(HDB_RAMPUP)
diset tpcc pg_duration $env(HDB_DURATION)
loadscript
vuset vu $env(HDB_VU)
vuset logtotemp 1
vucreate
vurun
runtimer [expr {($env(HDB_RAMPUP) + $env(HDB_DURATION)) * 60 + 30}]
vudestroy
quit
```

`workload/hammerdb/hammerdb_workload.sh` — defaults, DB init, build + run:

```bash
#!/bin/bash
set -euo pipefail

export HDB_DB="${HDB_DB:-pg}"
export HDB_WAREHOUSES="${HDB_WAREHOUSES:-4}"
export HDB_VU="${HDB_VU:-4}"
export HDB_RAMPUP="${HDB_RAMPUP:-2}"
export HDB_DURATION="${HDB_DURATION:-5}"

echo "Starting HammerDB TPROC-C: db=$HDB_DB warehouses=$HDB_WAREHOUSES vu=$HDB_VU"

# 1) Initialize and start PostgreSQL, then set up credentials.
# HammerDB connects over TCP (pg_host=localhost) as the superuser WITH a
# password, so the postgres role needs a password and pg_hba must allow
# password auth on loopback (default RHEL pg_hba uses ident/peer).
PGDATA=/var/lib/pgsql/data
if [[ ! -d "$PGDATA/base" ]]; then
    postgresql-setup --initdb
fi
if ! grep -qE '^host .* 127\.0\.0\.1/32 .*(md5|scram)' "$PGDATA/pg_hba.conf"; then
    printf 'host all all 127.0.0.1/32 md5\nhost all all ::1/128 md5\n' \
        >> "$PGDATA/pg_hba.conf"
fi
systemctl enable --now postgresql
# pg_superuserpass in build.tcl must match this password.
sudo -u postgres psql -c "ALTER ROLE postgres WITH PASSWORD 'postgres';"
sudo -u postgres psql -tc "SELECT 1 FROM pg_roles WHERE rolname='tpcc'" \
    | grep -q 1 || sudo -u postgres psql -c \
    "CREATE ROLE tpcc WITH LOGIN SUPERUSER PASSWORD 'tpcc';"

# 2) HammerDB is pre-installed in the image at /opt/HammerDB.
cd /opt/HammerDB

# 3) Build the schema once per configuration, then run the timed benchmark.
#    hammerdbcli can exit 0 even when the build logged an error, so capture
#    the build output and require a completion line (and no error lines)
#    before trusting it. The sentinel records the schema configuration so a
#    reboot skips the build only when it still matches; a changed
#    HDB_WAREHOUSES (or HDB_DB) rebuilds instead of running a stale schema.
#    The completion/error patterns are HammerDB-version-specific — validate
#    them against your release.
BUILD_MARKER=/var/lib/vstorm-hammerdb-build.done
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
    sudo -u postgres psql -c "DROP DATABASE IF EXISTS tpcc;"
    build_log=/root/hammerdb-build.log
    ./hammerdbcli auto /opt/hammerdb/build.tcl 2>&1 | tee "$build_log"
    if grep -qiE 'error|fatal|could not|failed' "$build_log" \
        || ! grep -qi 'schema complete' "$build_log"; then
        echo "HammerDB build did not complete cleanly; not running benchmark" >&2
        exit 1
    fi
    printf '%s\n' "$build_sig" > "$BUILD_MARKER"
fi

./hammerdbcli auto /opt/hammerdb/run.tcl | tee /root/hammerdb-result.txt

echo "HammerDB run finished."
# Optional: parse NOPM/TPM from /root/hammerdb-result.txt and POST to
# RESULT_SERVER_URL (see docs/workload-result-sync-and-dashboard.md).
```

`workload/hammerdb/hammerdb-workload.service` — one-shot systemd unit:

```ini
[Unit]
Description=HammerDB TPROC-C workload (one-shot)
After=network-online.target postgresql.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
# Schema build + rampup + duration far exceed systemd's default 90s
# start timeout for a Type=oneshot unit; disable it so the benchmark
# is not SIGTERM'd mid-run.
TimeoutStartSec=0
EnvironmentFile=-/etc/default/vstorm-guest-env
ExecStart=/opt/hammerdb_workload.sh
Restart=no

[Install]
WantedBy=multi-user.target
```

Notes:

- `hammerdbcli auto <script>` runs a Tcl script non-interactively (autopilot /
  CLI mode) — the same build/run flow the
  [HammerDB CLI docs](https://www.hammerdb.com/docs6.1/ch01s14.html#d0e755)
  automate in a pipeline.
- `$env(HDB_*)` reads the values vstorm injected into
  `/etc/default/vstorm-guest-env` (exported by `hammerdb_workload.sh`).
- `diset` keys are **DB-specific** (`pg_*` for PostgreSQL, `mysql_*` for MySQL,
  `maria_*` for MariaDB). To target MySQL/MariaDB, swap the package, the init
  steps, and the `diset` keys accordingly.
- **Build robustness.** `set -euo pipefail` only catches a non-zero `hammerdbcli`
  exit, but HammerDB can log a failed build/run while the process exits 0. The
  orchestration script therefore captures the build log, aborts before the timed
  run unless the log shows completion with no error lines, and writes a
  `/var/lib/vstorm-hammerdb-build.done` sentinel so a reboot skips an
  already-built schema instead of rebuilding it or running against a half-built
  one. The completion/error grep patterns are **HammerDB-version-specific** —
  validate them against your release before relying on them.
- **Credentials.** Like the sibling fio/stress-ng profiles, this skeleton sets a
  default root password and enables root password SSH for lab convenience, and
  uses fixed `postgres`/`tpcc` DB passwords. Replace these with your own
  credentials (or SSH keys) for any non-lab environment.

## Building the image

The image is the only custom artifact. Build a QCOW / DataSource with the database
and HammerDB installed and **nothing workload-specific** — use whatever image-build
tool you prefer (virt-manager, `guestfish`, Packer, a Containerfile, or a manual
install in a running VM you then snapshot). What to bake in:

| Path in image | Source |
|---------------|--------|
| `/opt/HammerDB` (→ `HammerDB-<ver>`) | HammerDB release, unpacked |
| database package (e.g. `postgresql-server`) | distro package — the orchestration script runs `--initdb` on first boot |

Do **not** bake the run scripts, the systemd unit, or the `HDB_*` parameters into
the image: vstorm injects those into the cloud-init Secret at run time (next
section), so one image serves every run configuration. Point vstorm at the image
with `--dv-url` / `--datasource`.

## How vstorm injects the scripts

The run scripts stay the single source of truth under `workload/hammerdb/`, and
vstorm substitutes each one into the cloud-init **Secret** at run time — no custom
image step for them, and no new object type. This is a design option; **it is not
implemented yet** (vstorm currently substitutes only `{VSTORM_GUEST_ENV}`).

**How it works.** vstorm already base64-encodes the userdata into the cloud-init
Secret and substitutes `{VSTORM_GUEST_ENV}` before encoding. Add more placeholders
handled the same way — each alone on an indented line — and have vstorm fill them
from files at run time, reusing the existing indent/substitution machinery:

| Placeholder | Filled from |
|-------------|-------------|
| `{HAMMERDB_BUILD_TCL}` | `workload/hammerdb/build.tcl` |
| `{HAMMERDB_RUN_TCL}` | `workload/hammerdb/run.tcl` |
| `{HAMMERDB_ORCHESTRATE_SH}` | `workload/hammerdb/hammerdb_workload.sh` |
| `{HAMMERDB_SERVICE_UNIT}` | `workload/hammerdb/hammerdb-workload.service` |

```yaml
write_files:
  - path: /opt/hammerdb/build.tcl
    permissions: '0644'
    content: |
      {HAMMERDB_BUILD_TCL}
```

This keeps the inline script blobs out of the profile with the **smallest** change:
one delivery channel (the Secret), no extra disk, no guest mount, works on any image
and air-gapped. Capacity is not a concern — a Secret holds up to **1 MiB**, and the
largest current profile (`cloudinit-fio-workload.yaml`, with its workload script
spliced in) uses only ~3.7% of that; the HammerDB scripts are smaller.

**Why not a ConfigMap.** A ConfigMap would make a script a standalone cluster
object, but it is a poor fit here: KubeVirt surfaces a ConfigMap as a read-only
**iso9660 disk**, not a guest file, so each VM gains **an extra disk** and the guest
must `mount` it at a `by-id`/serial device path that is KubeVirt-version-dependent.
It also needs **new per-namespace plumbing** and carries the **same 1 MiB limit** as
the Secret, so it buys no capacity. Choose it only if the scripts must exist as
inspectable cluster objects in their own right.

## Monitoring

From the host, use **helpers/log-vm** (uses `virtctl ssh`; set
`STRESS_WORKLOAD_PASSWORD` to the VM root password from your cloud-init):

```bash
helpers/log-vm -u hammerdb-workload.service <vm-name> <namespace> [lines]
```

Inside a VM (via `virtctl console` or SSH):

```bash
systemctl status hammerdb-workload.service
journalctl -u hammerdb-workload.service -f
cat /root/hammerdb-result.txt     # NOPM / TPM once the run completes
```

---

## Design and internals

### End-to-end flow

1. User runs vstorm with `--cloudinit=workload/cloudinit-hammerdb-workload.yaml`
   against an image that already has the DB + HammerDB installed.
2. vstorm replaces `{VSTORM_GUEST_ENV}` with `--env` lines and the script
   placeholders (`{HAMMERDB_*}`) with the files from `workload/hammerdb/`,
   base64-encodes the userdata, and injects it into the cloud-init Secret template
   (one Secret per namespace; each VM references it via `cloudInitNoCloud.secretRef`).
3. On first boot the guest runs cloud-init (`write_files`, `runcmd`), which enables
   `hammerdb-workload.service`.
4. The service initializes PostgreSQL, builds the TPROC-C schema (`build.tcl`), then
   runs the timed benchmark (`run.tcl`) and exits.

### Cloud-init modules used

| Module | Purpose |
|--------|---------|
| **write_files** | Tcl build/run scripts, orchestration script, systemd unit, `/etc/default/vstorm-guest-env` (scripts injected from `workload/hammerdb/`). |
| **runcmd** | SSH config, `daemon-reload`, enable + start `hammerdb-workload.service`. |

### File layout

| Location | Role |
|----------|------|
| **workload/cloudinit-hammerdb-workload.yaml** | The cloud-init profile (slim: env + placeholders only). |
| **workload/hammerdb/{build.tcl,run.tcl,hammerdb_workload.sh,hammerdb-workload.service}** | The run scripts + unit vstorm injects into the Secret. |
| **templates/cloudinit-secret.yaml** | Secret template with `userdata: {CLOUDINIT_B64}`. |
| **vstorm** | Reads the profile, replaces `{VSTORM_GUEST_ENV}` + `{HAMMERDB_*}`, base64-encodes, substitutes into the template. |

### References

- [HammerDB CLI / pipeline automation](https://www.hammerdb.com/docs6.1/ch01s14.html#d0e755) — autopilot build/run commands
- [cloud-init and fio workload](cloud-init-fio-workload.md) — sibling storage workload (full result-sync boilerplate)
- [cloud-init and stress-ng workload](cloud-init-stress-ng-workload.md) — sibling CPU/memory workload
- [workload result sync and dashboard](workload-result-sync-and-dashboard.md) — result push + collector/dashboard
- [README.md](../README.md) — Custom cloud-init section
