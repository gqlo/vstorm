# Monitoring (Grafana, Prometheus, CNV / descheduler)

This directory holds **Grafana dashboards**, **Prometheus-related YAML**, and **helper scripts** for OpenShift / CNV and descheduler analysis.

## Contents

- [Scripts](#scripts)

### Persist your JSON dashboard in Dittybopper

- [Persist your JSON dashboard in Dittybopper](#persist-your-json-dashboard-in-dittybopper)
- [`dashboard/desched-cnv.json`](#dashboarddesched-cnvjson)
- [Provisioning to dittybopper (persistent Grafana)](#provisioning-to-dittybopper-persistent-grafana)
- [What provisioning does (overview)](#what-provisioning-does-overview)
- [Prerequisites](#prerequisites)
- [Step 1: Dashboard provider ConfigMap](#step-1-dashboard-provider-configmap)
- [Step 2: Dashboard ConfigMap](#step-2-dashboard-configmap)
- [Step 3: Mount volumes on dittybopper](#step-3-mount-volumes-on-dittybopper)
- [Step 4: Verify](#step-4-verify)
- [Adding more dashboards](#adding-more-dashboards)
- [Troubleshooting](#troubleshooting)

## Scripts

| Script | Description |
|--------|-------------|
| [`scripts/provision-grafana-dashboards.sh`](scripts/provision-grafana-dashboards.sh) | Apply Grafana dashboard JSON to Dittybopper ([persist JSON dashboard](#persist-your-json-dashboard-in-dittybopper)). |
| [`scripts/prom-query`](scripts/prom-query) | Run **PromQL** against in-cluster Prometheus; batch from YAML or inline. |
| [`scripts/migration-stats.py`](scripts/migration-stats.py) | **VMIM** stats summary (evacuation / workload / migration counts, durations, running VMs). |
| [`scripts/compute_euclidean_distance.py`](scripts/compute_euclidean_distance.py) | Post-process **CSV** from `prom-query` into ideal-point Euclidean distance. |

### `prom-query`

Runs queries through the Prometheus pod in `openshift-monitoring` (configurable).

```bash
# All queries in a YAML file → CSV under csv-data/ next to the YAML
./monitoring/scripts/prom-query monitoring/yaml/prom-queries.yaml

# One named query
./monitoring/scripts/prom-query monitoring/yaml/prom-queries.yaml memory-per-worker

# List query names
./monitoring/scripts/prom-query monitoring/yaml/prom-queries.yaml -l

# Inline PromQL to stdout
./monitoring/scripts/prom-query -s 1h -e now -S 5m 'up{job="kubelet"}'
```

Requires: `oc`, `python3`, **PyYAML** (`pip install pyyaml`).

### `migration-stats.py`

```bash
# Default: summary only (all namespaces)
python3 monitoring/scripts/migration-stats.py

# CSV listing (type, workload, vmim name, seconds)
python3 monitoring/scripts/migration-stats.py --csv
python3 monitoring/scripts/migration-stats.py --namespace my-ns --output out.csv
```

Requires: `oc` logged into the cluster.

### `compute_euclidean_distance.py`

After generating the expected per-worker and avg CSVs with `prom-query`, run from repo root:

```bash
python3 monitoring/scripts/compute_euclidean_distance.py
```

Requires: **pandas**.

---

## YAML

| File | Description |
|------|-------------|
| [`yaml/prom-queries.yaml`](yaml/prom-queries.yaml) | Named **PromQL** queries (memory/CPU per worker, averages, descheduler-style signals). Use with `prom-query`. |
| [`yaml/prom-queries-descheduler-counts.yaml`](yaml/prom-queries-descheduler-counts.yaml) | Queries that **count** nodes above thresholds using **descheduler recording rule** series (`descheduler:*`). Requires those rules in the cluster. |
| [`yaml/desched-rules.yaml`](yaml/desched-rules.yaml) | Reference export of **PrometheusRule** `descheduler-rules` (OpenShift kube-descheduler-operator): recording rules for utilization, pressure, deviations, ideal-point distance, etc. Pair with `prom-queries-descheduler-counts.yaml` and dashboards. |

YAML format for `prom-query` (abbreviated):

```yaml
defaults:
  start: "2026-02-24 19:10:37"
  end: "2026-02-24 19:20:25"
  step: 5s

my-query-name:
  description: "Human-readable label"
  query: |
    promql_here
```

CSVs are written under `csv-data/` beside the YAML file (one file per query name).

---

## Persist your JSON dashboard in Dittybopper

Use the **provisioning script** below to keep dashboard JSON across pod restarts, or skip to [Prerequisites](#prerequisites) for **manual** setup and troubleshooting.

### `dashboard/desched-cnv.json`

Grafana dashboard for **descheduler / CNV** metrics (`description`: descheduler dashboard). Import in Grafana or provision with the script below.

### Provisioning to dittybopper (persistent Grafana)

Script: [`scripts/provision-grafana-dashboards.sh`](scripts/provision-grafana-dashboards.sh)

From the **repo root** (adjust paths if needed):

**Single dashboard (default namespace `dittybopper`):**

```bash
./monitoring/scripts/provision-grafana-dashboards.sh monitoring/dashboard/desched-cnv.json
```

**Multiple dashboards:**

```bash
./monitoring/scripts/provision-grafana-dashboards.sh monitoring/dashboard/desched-cnv.json other-dashboard.json
```

**Custom namespace:**

```bash
./monitoring/scripts/provision-grafana-dashboards.sh my-grafana-ns monitoring/dashboard/desched-cnv.json
```

**Usage:** `[namespace] [dashboard1.json [dashboard2.json ...]]` — namespace is optional (default `dittybopper`); the first argument is only treated as a namespace if it does **not** end in `.json`.

#### What provisioning does (overview)

Dittybopper often does not mount ConfigMaps labeled `grafana_dashboard=1` by default. The script:

1. Creates a **dashboard provider** ConfigMap (`grafana-dashboards-provider`).
2. Creates **`grafana-dashboards-default`** with your JSON file(s).
3. **Patches** the dittybopper deployment to mount both into the Grafana container and rolls out.

### Prerequisites

- `oc` logged into the cluster
- Dittybopper (Grafana) deployed (this doc uses namespace `dittybopper`; adjust if yours differs)
- Dashboard JSON (e.g. from `dashboard/` or exported from Grafana)

### Step 1: Dashboard provider ConfigMap

```bash
oc apply -f - << 'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboards-provider
  namespace: dittybopper
data:
  dashboards.yaml: |
    apiVersion: 1
    providers:
      - name: 'default'
        orgId: 1
        folder: ''
        type: file
        options:
          path: /etc/grafana/provisioning/dashboards/default
EOF
```

### Step 2: Dashboard ConfigMap

Export from Grafana (**Share** → **Export**) if needed, then:

```bash
oc create configmap grafana-dashboards-default \
  --from-file=desched-cnv.json=monitoring/dashboard/desched-cnv.json \
  -n dittybopper
```

Multiple files: add more `--from-file=...` arguments. Optional label:

```bash
oc label configmap grafana-dashboards-default grafana_dashboard=1 -n dittybopper
```

### Step 3: Mount volumes on dittybopper

**Provider:**

```bash
oc set volume deployment/dittybopper -n dittybopper \
  --add \
  --name=grafana-dashboards-provider \
  --type=configmap \
  --configmap-name=grafana-dashboards-provider \
  --mount-path=/etc/grafana/provisioning/dashboards \
  -c dittybopper
```

**Dashboards:**

```bash
oc set volume deployment/dittybopper -n dittybopper \
  --add \
  --name=grafana-dashboards-default \
  --type=configmap \
  --configmap-name=grafana-dashboards-default \
  --mount-path=/etc/grafana/provisioning/dashboards/default \
  -c dittybopper
```

```bash
oc rollout status deployment/dittybopper -n dittybopper --timeout=120s
```

### Step 4: Verify

Open Grafana → **Dashboards**. After pod restart, dashboards should still appear if mounts are correct:

```bash
oc rollout restart deployment/dittybopper -n dittybopper
oc rollout status deployment/dittybopper -n dittybopper --timeout=120s
```

```bash
oc exec -n dittybopper deployment/dittybopper -c dittybopper -- \
  ls -la /etc/grafana/provisioning/dashboards/default/
```

### Adding more dashboards

- **Script:** Re-run with **all** JSON files you want in one ConfigMap (script replaces `grafana-dashboards-default`).
- **Manual:** Add keys to the ConfigMap and restart the deployment.

### Troubleshooting

- **Dashboard missing:** Validate JSON; check Grafana logs:  
  `oc logs -n dittybopper deployment/dittybopper -c dittybopper --tail=100`
- **Dashboard disappears:** Ensure both provider and dashboard volumes are on the deployment:  
  `oc get deployment dittybopper -n dittybopper -o jsonpath='{.spec.template.spec.volumes[*].name}'`
- **Wrong namespace:** Replace `dittybopper` everywhere with your Grafana namespace.
