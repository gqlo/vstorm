# Prompts

Reusable prompts for Cursor agent tasks.

---

## Live Cluster Test Suite

Run the vstorm live cluster test suite (7 tests) against the connected
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
4. `./vstorm --cloudinit=workload/cloudinit-stress-ng-workload.yaml --vms=5 --namespaces=2`
5. `./vstorm --datasource=centos-stream9 --vms=5 --namespaces=1`
6. `./vstorm --storage-class=ocs-storagecluster-ceph-rbd --vms=5 --namespaces=2`
7. `./vstorm --no-snapshot --vms=1 --namespaces=1`

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
  expect SSH failure on Test 5 -- centos-stream9 image issue)
- Check snapshots/DVs: `oc get volumesnapshot -A -l batch-id=<ID>`,
  `oc get datavolume -A -l batch-id=<ID>`

**Update the report** in the existing format in
`docs/live-cluster-test-report.md`: update the Environment table with the
captured cluster info, update the Run History with today's date, replace batch
IDs and verification details per test, and update the summary table and cleanup
section. Mark each test PASS, PARTIAL, or FAIL.

**After all tests**, add cleanup commands to the Cleanup section for all new
batch IDs.
