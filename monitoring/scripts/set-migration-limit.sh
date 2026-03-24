oc patch hyperconverged kubevirt-hyperconverged -n openshift-cnv --type=merge -p '{
  "spec": {
    "liveMigrationConfig": {
      "parallelMigrationsPerCluster": 50,
      "parallelOutboundMigrationsPerNode": 10
    }
  }
}'

