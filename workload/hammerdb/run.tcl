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
