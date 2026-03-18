# Monitoring (Grafana, Prometheus, CNV / descheduler)

This directory holds **Grafana dashboards**, **Prometheus-related YAML**, and **helper scripts** for OpenShift / CNV and descheduler analysis.

## Contents

- [Persist your JSON dashboard in Dittybopper (provisioning to dittybopper)](#persist-your-json-dashboard-in-dittybopper-provisioning-to-dittybopper)
- [Run Prometheus queries](#prom-query)
- [Summarize migration stats](#migration-statspy)
- [Compute Euclidean distance](#compute_euclidean_distancepy)
- [Troubleshooting](#troubleshooting)
- [Appendix](#appendix)

## Persist your JSON dashboard in Dittybopper (provisioning to dittybopper)

Use the **provisioning script** below to persist dashboard JSON across pod restarts, or skip to [Prerequisites](#prerequisites) in the appendix for **manual** setup and troubleshooting.

**Single dashboard (default namespace `dittybopper`):**

```bash
./scripts/provision-grafana-dashboards.sh path/to/your.json
```

**Usage:** `[namespace] [dashboard1.json [dashboard2.json ...]]` — namespace is optional (default `dittybopper`); the first argument is only treated as a namespace if it does **not** end in `.json`.

### `prom-query`

Runs queries through the Prometheus pod in `openshift-monitoring` (configurable).

```bash
# All queries in a YAML file → CSV under csv-data/ next to the YAML
./scripts/prom-query yaml/prom-queries.yaml

# One named query
./scripts/prom-query yaml/prom-queries.yaml memory-per-worker

# List query names
./scripts/prom-query yaml/prom-queries.yaml -l

# Inline PromQL to stdout
./scripts/prom-query -s 1h -e now -S 5m 'up{job="kubelet"}'
```

### `migration-stats.py`

```bash
# Default: summary only (all namespaces)
python3 scripts/migration-stats.py

# CSV listing (type, workload, vmim name, seconds)
python3 scripts/migration-stats.py --csv
python3 scripts/migration-stats.py --namespace my-ns --output out.csv
```

### `compute_euclidean_distance.py`

After generating the expected per-worker and avg CSVs with `prom-query`, run from repo root:

```bash
python3 scripts/compute_euclidean_distance.py
```

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

## Appendix

### Grafana provisioning

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
