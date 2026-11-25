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
