# Cloud-init and HammerDB workload

Run a [HammerDB](https://www.hammerdb.com/docs6.1/ch01s14.html#d0e755) TPROC-C
(OLTP) database benchmark inside VMs at boot. This guide shows how to **add** the
workload as a cloud-init profile — the same pattern used by the
[fio](cloud-init-fio-workload.md) and [stress-ng](cloud-init-stress-ng-workload.md)
workloads: a script and systemd unit injected via `write_files`, tuned through
`vstorm --env`.

Unlike fio/stress-ng, HammerDB needs **a database running in the guest** and the
**HammerDB CLI** (`hammerdbcli`). The cloud-init profile installs both, builds the
schema once, then runs the benchmark.

For VM CPU/memory options (`--cores`, `--memory`, etc.), see the main
[README](../README.md#options).

## Quick start: example commands

| Goal | Command |
|------|---------|
| Default (PostgreSQL TPROC-C) | `vstorm --cloudinit=workload/cloudinit-hammerdb-workload.yaml --cores=4 --memory=8Gi --vms=5` |
| Bigger schema + more virtual users | `vstorm --cloudinit=workload/cloudinit-hammerdb-workload.yaml --env HDB_WAREHOUSES=20 --env HDB_VU=8 --cores=8 --memory=16Gi --vms=5` |
| Longer run | `vstorm --cloudinit=workload/cloudinit-hammerdb-workload.yaml --env HDB_RAMPUP=5 --env HDB_DURATION=30 --vms=5` |
| Dry-run to preview | `vstorm -n --cloudinit=workload/cloudinit-hammerdb-workload.yaml --vms=3` |

Defaults target a **small, self-contained** run (a few warehouses) so it
completes on modest VMs. Scale up with `--env` and larger `--cores`/`--memory`.

## Image requirements and recommendation

The workload **installs the database and HammerDB at first boot** via the guest
package manager and a download. Use a **customized QCOW** (or DataSource) with
**working DNF/Yum (or APT) repositories** and outbound network access to fetch the
HammerDB release — or an image with both preinstalled.

**OCP OS images** (DataSources from `openshift-virtualization-os-images`, e.g.
`rhel9`) are **minimal**: no enabled repos, no DB, no HammerDB. The workload will
fail on them. Prefer a custom DataSource or `--dv-url` (HTTPS, pinned digest) you
control. See the [fio doc](cloud-init-fio-workload.md#image-requirements-and-recommendation)
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

If `RESULT_SERVER_URL` is set, the guest can POST a result JSON when the run
finishes — see [workload result sync and dashboard](workload-result-sync-and-dashboard.md).

## Tuning: env overrides

Override with `--env KEY=VAL` (repeat as needed):

| Parameter | Description |
|-----------|-------------|
| `HDB_DB` | HammerDB database target (default `pg` for PostgreSQL; e.g. `mysql`, `maria`) |
| `HDB_WAREHOUSES` | TPROC-C schema size in warehouses (default `4`) |
| `HDB_VU` | Virtual users (benchmark clients; default `4`) |
| `HDB_RAMPUP` | Ramp-up minutes before measurement (default `2`) |
| `HDB_DURATION` | Measured run minutes (default `5`) |
| `HDB_VERSION` | HammerDB release to download (default pinned in the script) |
| `RESULT_SERVER_URL` | Collector results URL; enables one POST after the run |
| `VSTORM_BATCH_ID` / `VSTORM_VM_NAME` | Auto-injected by vstorm for result join |

```bash
# Larger schema and more virtual users
vstorm --cloudinit=workload/cloudinit-hammerdb-workload.yaml \
  --env HDB_WAREHOUSES=50 --env HDB_VU=16 \
  --cores=8 --memory=16Gi --vms=5

# Collect results to the dashboard collector
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
      diset tpcc pg_num_vu $env(HDB_VU)
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

      # 1) Initialize and start PostgreSQL, create the tpcc role
      if [[ ! -d /var/lib/pgsql/data/base ]]; then
          postgresql-setup --initdb
      fi
      systemctl enable --now postgresql
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

      # 3) Build the schema once, then run the timed benchmark
      ./hammerdbcli auto /opt/hammerdb/build.tcl
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
