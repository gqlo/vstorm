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
injected via `write_files`, tuned through `vstorm --env`.

Unlike fio/stress-ng, HammerDB needs **a database running in the guest** and the
**HammerDB CLI** (`hammerdbcli`). The cloud-init profile installs both, builds the
schema once, then runs the benchmark.

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

**Strongly recommended: bake everything into the image.** Pre-install the
database, HammerDB CLI, and all dependencies (`curl`, build/runtime libs, the
HammerDB release unpacked under `/opt/HammerDB`) into a **custom QCOW / DataSource**
so cloud-init only has to *run* the benchmark. This is faster, deterministic, and
works on **air-gapped** clusters with no outbound network — the first-boot
download is the slowest and most failure-prone step. See
[Variant: pre-installed image](#variant-pre-installed-image) below.

If instead you let the workload **install the DB + HammerDB at first boot** (the
skeleton's default), the image needs **working DNF/Yum repositories** and
**outbound network access** to fetch the HammerDB release. The skeleton targets
**RHEL-family** guests (`postgresql-server` + `postgresql-setup`); adapt the
package and init steps for other distros.

**OCP OS images** (DataSources from `openshift-virtualization-os-images`, e.g.
`rhel9`) are **minimal**: no enabled repos, no DB, no HammerDB. The at-boot path
will fail on them. Prefer a custom DataSource or `--dv-url` (HTTPS, pinned digest)
you control. See the [fio doc](cloud-init-fio-workload.md#image-requirements-and-recommendation)
for the full rationale.

Size the root disk for the database: `HDB_WAREHOUSES` × ~100 MB plus the OS. Raise
`--storage-size`, or attach a data disk with `--data-disk-size=N` and point the DB
data directory at it.

## Run at boot

```bash
vstorm --cloudinit=workload/cloudinit-hammerdb-workload.yaml --vms=5 --namespaces=2
```

Cloud-init installs the DB + HammerDB, writes the build/run Tcl scripts and the
workload script to `/opt`, and enables `hammerdb-workload.service` (**one-shot**:
build schema → run benchmark → exit). Pass `HDB_*` once via `vstorm --env`.

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
| `HDB_VERSION` | HammerDB release to download (default pinned in the script) |
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

packages:
  - postgresql-server
  - curl

write_files:
  # Guest env injected by `vstorm --env` (HDB_*, RESULT_SERVER_URL, ...)
  - path: /etc/default/vstorm-guest-env
    permissions: '0644'
    content: |
      {VSTORM_GUEST_ENV}

  # TPROC-C schema build script (CLI / autopilot mode)
  - path: /opt/hammerdb/build.tcl
    permissions: '0644'
    content: |
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

  # TPROC-C timed run script
  - path: /opt/hammerdb/run.tcl
    permissions: '0644'
    content: |
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

  # Orchestration: defaults, DB init, HammerDB download, build + run
  - path: /opt/hammerdb_workload.sh
    permissions: '0755'
    content: |
      #!/bin/bash
      set -euo pipefail

      export HDB_DB="${HDB_DB:-pg}"
      export HDB_WAREHOUSES="${HDB_WAREHOUSES:-4}"
      export HDB_VU="${HDB_VU:-4}"
      export HDB_RAMPUP="${HDB_RAMPUP:-2}"
      export HDB_DURATION="${HDB_DURATION:-5}"
      HDB_VERSION="${HDB_VERSION:-4.12}"

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

      # 2) Install HammerDB CLI if missing
      if [[ ! -x /opt/HammerDB/hammerdbcli ]]; then
          tgz="HammerDB-${HDB_VERSION}-Linux.tar.gz"
          curl -fsSL -o "/tmp/${tgz}" \
              "https://github.com/TPC-Council/HammerDB/releases/download/v${HDB_VERSION}/${tgz}"
          mkdir -p /opt && tar -xzf "/tmp/${tgz}" -C /opt
          ln -sfn "/opt/HammerDB-${HDB_VERSION}" /opt/HammerDB
      fi
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

  - path: /etc/systemd/system/hammerdb-workload.service
    permissions: '0644'
    content: |
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

runcmd:
  - sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
  - sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
  - systemctl restart sshd 2>/dev/null || systemctl restart ssh
  - ["systemctl", "daemon-reload"]
  - ["systemctl", "enable", "--now", "hammerdb-workload.service"]
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

## Variant: pre-installed image

When the DB, HammerDB, and all dependencies are **already baked into the image**
(recommended — see [Image requirements](#image-requirements-and-recommendation)),
drop `packages:` and the install/download logic. Cloud-init then only writes env +
scripts and starts the service, so no repos or outbound network are required (works
air-gapped).

Build the image once with whatever image-build tool you use (virt-manager,
`guestfish`, Packer, a Containerfile, or a manual install in a running VM you then
snapshot). Whatever the tool, the image needs the DB + HammerDB in place, plus the
**shared boot-timestamp agent** so the cloud-init profile no longer has to embed
the ~100-line script under `write_files`. The files to bake in:

| Path in image | Permissions | Source |
|---------------|-------------|--------|
| `/opt/HammerDB` (→ `HammerDB-<ver>`) | — | HammerDB release, unpacked |
| DB packages initialized (e.g. `postgresql-setup --initdb`) | — | distro package + init |
| `/opt/vstorm-boot-timestamp.sh` | `0755` | copy of `workload/vstorm-boot-timestamp.sh` |
| `/etc/systemd/system/vstorm-boot-timestamp.service` | `0644` | copy of that unit |

**Boot-timestamp agent: baked in, not embedded.** `workload/vstorm-boot-timestamp.sh`
stays the single source of truth; with a pre-installed image it is delivered by
the image build instead of copy-pasted into every profile's `write_files`
(which `tests/15-boot-timestamp.bats` otherwise has to keep byte-for-byte
identical). This shrinks the cloud-init profile and strengthens the
self-contained / air-gapped property, at the cost of **tying the profile to a
custom image**: a stock image without the script would otherwise fail at
`systemctl enable`. Keep the **full** `runcmd` (SSH setup, `daemon-reload`, and the
`hammerdb-workload.service` enable) and only guard the boot-timestamp entry so it
degrades gracefully — heartbeat on a baked image, workload still runs (no
heartbeat) on a stock one:

```yaml
runcmd:
  - sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
  - sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
  - systemctl restart sshd 2>/dev/null || systemctl restart ssh
  - ["systemctl", "daemon-reload"]
  - |
    if [ -x /opt/vstorm-boot-timestamp.sh ]; then
      systemctl enable --now vstorm-boot-timestamp.service
    else
      echo "vstorm-boot-timestamp.sh not in image; skipping boot heartbeat" >&2
    fi
  - ["systemctl", "enable", "--now", "hammerdb-workload.service"]
```

Two caveats to carry into the build: the image's copy of the script can drift
from what the collector/dashboard expect (there is no runtime parity check once
it is baked in — version the image), and this baked-in approach suits workloads
that already mandate a custom image (HammerDB does); keep the `write_files` embed
for the portable `default`/`fio`/`stress-ng` profiles that must run on generic
images.

Then point vstorm at it (`--dv-url` / `--datasource`) and trim the orchestration
script so it assumes everything is present:

```bash
#!/bin/bash
set -euo pipefail
export HDB_DB="${HDB_DB:-pg}" HDB_WAREHOUSES="${HDB_WAREHOUSES:-4}" \
       HDB_VU="${HDB_VU:-4}" HDB_RAMPUP="${HDB_RAMPUP:-2}" HDB_DURATION="${HDB_DURATION:-5}"

systemctl enable --now postgresql
# Bake the pg_hba loopback md5 rule into the image; set the superuser password here.
sudo -u postgres psql -c "ALTER ROLE postgres WITH PASSWORD 'postgres';"
sudo -u postgres psql -tc "SELECT 1 FROM pg_roles WHERE rolname='tpcc'" | grep -q 1 \
  || sudo -u postgres psql -c "CREATE ROLE tpcc WITH LOGIN SUPERUSER PASSWORD 'tpcc';"

cd /opt/HammerDB
# Same guarded build as the full script: build once per configuration behind a
# sentinel, rebuild when HDB_WAREHOUSES/HDB_DB change, and only run the benchmark
# if the build log reports completion with no errors.
BUILD_MARKER=/var/lib/vstorm-hammerdb-build.done
build_sig="db=$HDB_DB warehouses=$HDB_WAREHOUSES"
if [[ -f "$BUILD_MARKER" && "$(cat "$BUILD_MARKER")" == "$build_sig" ]]; then
    echo "Schema already built for [$build_sig]; skipping build"
else
    # Drop any existing tpcc before (re)building so a changed config or a retry
    # after a failed/partial first build starts clean; IF EXISTS is a no-op on a
    # genuine first build and touches only tpcc.
    sudo -u postgres psql -c "DROP DATABASE IF EXISTS tpcc;"
    ./hammerdbcli auto /opt/hammerdb/build.tcl 2>&1 | tee /root/hammerdb-build.log
    if grep -qiE 'error|fatal|could not|failed' /root/hammerdb-build.log \
        || ! grep -qi 'schema complete' /root/hammerdb-build.log; then
        echo "HammerDB build did not complete cleanly; not running benchmark" >&2
        exit 1
    fi
    printf '%s\n' "$build_sig" > "$BUILD_MARKER"
fi
./hammerdbcli auto /opt/hammerdb/run.tcl | tee /root/hammerdb-result.txt
```

With a pre-installed image you can also drop `curl` from `packages:` entirely and
leave only the `write_files` + `runcmd` sections in the cloud-init profile.

### Alternatives to baking: ConfigMap or runtime injection

Baking the boot-timestamp agent into the image removes the `write_files` embed but
**ties the profile to a custom image**. Two alternatives keep
`workload/vstorm-boot-timestamp.sh` as the single source of truth *without*
requiring a custom image, so the portable `default`/`fio`/`stress-ng` profiles can
drop the embed too. Both are design options — neither is implemented yet.

**Option 1 — ConfigMap disk.** vstorm creates a ConfigMap (one per namespace, the
same way it already creates the cloud-init Secret) whose data is the script read
from `workload/vstorm-boot-timestamp.sh`, and the VM mounts it. KubeVirt surfaces a
ConfigMap as an **iso9660 disk**, not a guest file, so the guest still has to mount
it — the ~100-line embed shrinks to a mount+install step:

```yaml
# VM spec: expose the ConfigMap as a disk (serial lets the guest find it)
volumes:
  - name: vstorm-agent
    configMap:
      name: vstorm-agent
# ...matching domain.devices.disks entry with serial: vstorm-agent
```

```yaml
# cloud-init runcmd: mount the disk, install the script, start the service
runcmd:
  - mkdir -p /mnt/vstorm-agent
  - mount -o ro /dev/disk/by-id/*vstorm-agent* /mnt/vstorm-agent
  - install -m 0755 /mnt/vstorm-agent/vstorm-boot-timestamp.sh /opt/
  - systemctl enable --now vstorm-boot-timestamp.service
```

Trade-offs: no custom image and no outbound network (works air-gapped), and the
script lives as an inspectable cluster object; but it needs **new vstorm plumbing**
(create/manage the ConfigMap per namespace), adds **a disk to every VM**, and the
guest must mount it (the `by-id`/serial device path is KubeVirt-version-dependent —
confirm it against your release).

**Option 2 — runtime injection into the existing Secret (simplest).** vstorm
already base64-encodes the userdata into the cloud-init Secret and substitutes
`{VSTORM_GUEST_ENV}` before encoding. Add one more placeholder handled the same
way — e.g. `{VSTORM_BOOT_TIMESTAMP_SH}` alone on an indented line — and have vstorm
fill it from `workload/vstorm-boot-timestamp.sh` at run time (reusing the existing
indent/substitution machinery). This removes the embed and the parity test with the
**smallest** change: no ConfigMap, no extra disk, no guest mount, same single
delivery channel, works on any image and air-gapped.

Recommendation: use the **ConfigMap** when you want the agent to exist as a
standalone cluster object; use **runtime injection** when the goal is simply to
kill the duplication with the fewest moving parts.

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

1. User runs vstorm with `--cloudinit=workload/cloudinit-hammerdb-workload.yaml`.
2. vstorm replaces `{VSTORM_GUEST_ENV}` with `--env` lines, base64-encodes the
   userdata, and injects it into the cloud-init Secret template (one Secret per
   namespace; each VM references it via `cloudInitNoCloud.secretRef`).
3. On first boot the guest runs cloud-init (`packages`, `write_files`, `runcmd`),
   which enables `hammerdb-workload.service`.
4. The service initializes PostgreSQL, downloads HammerDB, builds the TPROC-C
   schema (`build.tcl`), then runs the timed benchmark (`run.tcl`) and exits.

### Cloud-init modules used

| Module | Purpose |
|--------|---------|
| **packages** | Installs the database + `curl`. Requires working repos. |
| **write_files** | Tcl build/run scripts, orchestration script, systemd unit, `/etc/default/vstorm-guest-env`. |
| **runcmd** | SSH config, `daemon-reload`, enable + start `hammerdb-workload.service`. |

### File layout

| Location | Role |
|----------|------|
| **workload/cloudinit-hammerdb-workload.yaml** | The cloud-init profile. |
| **templates/cloudinit-secret.yaml** | Secret template with `userdata: {CLOUDINIT_B64}`. |
| **vstorm** | Reads file, replaces `{VSTORM_GUEST_ENV}`, base64-encodes, substitutes into the template. |

### References

- [HammerDB CLI / pipeline automation](https://www.hammerdb.com/docs6.1/ch01s14.html#d0e755) — autopilot build/run commands
- [cloud-init and fio workload](cloud-init-fio-workload.md) — sibling storage workload (full result-sync boilerplate)
- [cloud-init and stress-ng workload](cloud-init-stress-ng-workload.md) — sibling CPU/memory workload
- [workload result sync and dashboard](workload-result-sync-and-dashboard.md) — result push + collector/dashboard
- [README.md](../README.md) — Custom cloud-init section
