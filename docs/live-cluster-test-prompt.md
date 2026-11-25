# Live Cluster Test Prompt

Reusable prompt for Cursor agent tasks.

---

## Live Cluster Test Suite

Run the vstorm live cluster test suite (17 tests) against the connected
OpenShift cluster and update `docs/live-cluster-test-report.md` with the
results.

**Before starting**, verify cluster access by running `oc whoami` and
`oc get nodes --no-headers | head -1`. If either fails, stop and report the
error. Also capture the environment info for the report: `oc version`
(OpenShift/Kubernetes versions), default storage class (`oc get sc -o name`),
and snapshot classes (`oc get volumesnapshotclass -o name`).

**Tests to run in order:**

1. `./vstorm --cores=4 --memory=8Gi --vms=3 --namespaces=2`
2. `./vstorm --datasource=fedora --vms=5 --namespaces=1`
3. `./vstorm --dv-url=http://d21-h25-000-r650.rdu2.scalelab.redhat.com:8000/rhel9-cloud-init.qcow --vms=2 --namespaces=2`
4. `./vstorm --cloudinit=workload/stress-ng/cloudinit-stress-ng-workload.yaml --vms=5 --namespaces=2`
5. `./vstorm --datasource=centos-stream9 --vms=5 --namespaces=1`
6. `./vstorm --storage-class=ocs-storagecluster-ceph-rbd --vms=5 --namespaces=2`
7. `./vstorm --no-snapshot --vms=1 --namespaces=1`
8. `./vstorm --containerdisk --vms=3 --namespaces=1`
9. `./vstorm --storage-class=lvms-vg-nvme --snapshot-class=lvms-vg-nvme --vms=3 --namespaces=2`
10. `./vstorm --vms-per-namespace=5 --namespaces=3 --wait`
11. `./vstorm --containerdisk --cloudinit=workload/stress-ng/cloudinit-stress-ng-workload.yaml --vms=3 --namespaces=2`
12. `./vstorm --run-strategy=Halted --vms=3 --namespaces=1`
13. `./vstorm --cores=2 --memory=4Gi --request-cpu=500m --request-memory=2Gi --vms=3 --namespaces=1`
14. `./vstorm --basename=perf-vm --storage-size=50Gi --vms=3 --namespaces=1`
15. `./vstorm --profile --vms=10 --namespaces=2`
16. `./vstorm --memory=8Gi --cores=2 --dv-url=http://d21-h25-000-r650.rdu2.scalelab.redhat.com:8088/rhel9-cloud-init.qcow --cloudinit=workload/stress-ng/cloudinit-stress-ng-workload.yaml --env STRESS_TOGETHER=0 --env CPU_ACTIVE_PROBABILITY=30 --env MEM_ACTIVE_PROBABILITY=80`
17. `./vstorm --cores=4 --memory=8Gi --dv-url=http://storage.scalelab.redhat.com/lee/vm-images/rhel9-cloud-init.qcow --cloudinit=workload/dirty-mem/cloudinit-dirty-mem-pages.yaml --env DIRTY_RATE_FRACTION=0.4 --vms=1`

**After each test:**

- Note the batch ID from the output
- Wait for VMs: `oc get vm -A -l batch-id=<ID> --no-headers` until all show
  "Running"
- Verify options via `oc get vm -A -l batch-id=<ID> -o jsonpath=...` (cores,
  memory, storage class, access mode, run strategy, cloud-init secret,
  snapshot/no-snapshot resources)
- SSH into 1-3 VMs using
  `virtctl ssh --local-ssh-opts="-o PasswordAuthentication=yes" -n <ns> root@vmi/<vm>`
  and run `nproc`, `free -h`, `hostname` (skip SSH for Test 3 -- no cloud-init;
  expect SSH failure on Test 5 -- centos-stream9 image issue; skip SSH for
  Test 12 -- VMs are Halted)
- Check snapshots/DVs: `oc get volumesnapshot -A -l batch-id=<ID>`,
  `oc get datavolume -A -l batch-id=<ID>`

**Update the report** in the existing format in
`docs/live-cluster-test-report.md`: update the Environment table with the
captured cluster info, update the Run History with today's date, replace batch
IDs and verification details per test, and update the summary table and cleanup
section. Mark each test PASS, PARTIAL, or FAIL.

**After all tests**, add cleanup commands to the Cleanup section for all new
batch IDs.
