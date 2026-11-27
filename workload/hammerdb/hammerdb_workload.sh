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
# pg_hba is first-match, and default RHEL ships loopback rules (ident/peer)
# that would win over an appended md5 rule. Drop any existing loopback host
# rules (IPv4 and IPv6) so our password rules take precedence, then append
# them. Idempotent: a re-run removes the rules we added and re-appends them.
sed -i -E '/^[[:space:]]*host[[:space:]].*[[:space:]](127\.0\.0\.1\/32|::1\/128)[[:space:]]/d' \
    "$PGDATA/pg_hba.conf"
printf 'host all all 127.0.0.1/32 md5\nhost all all ::1/128 md5\n' \
    >> "$PGDATA/pg_hba.conf"
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
    # Clear the marker before dropping: if the rebuild fails after the DROP, no
    # stale marker survives to skip the (now-missing) schema on the next run.
    rm -f "$BUILD_MARKER"
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
