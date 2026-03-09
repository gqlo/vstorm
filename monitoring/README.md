# Grafana dashboard provisioning (dittybopper)

Provision Grafana dashboards from JSON files so they persist across pod restarts when using dittybopper.

## Running the script with JSON files

From the repo root (or with paths adjusted), run the script and pass one or more dashboard JSON files.

**Single dashboard (default namespace `dittybopper`):**

```bash
./scripts/provision-grafana-dashboards.sh your-dashboard.json
```

**Multiple dashboards:**

```bash
./scripts/provision-grafana-dashboards.sh your-dashboard.json other-dashboard.json
```

**Custom namespace:**

```bash
./scripts/provision-grafana-dashboards.sh my-grafana-ns your-dashboard.json
```

**Usage:** `[namespace] [dashboard1.json [dashboard2.json ...]]` — namespace is optional (default `dittybopper`); first argument is only treated as namespace if it does not end in `.json`. Script: [provision-grafana-dashboards.sh](../scripts/provision-grafana-dashboards.sh).

---

## Explanation

Optional reading: what the script does, how it works, and manual/troubleshooting details.

### Prerequisites

- `oc` CLI logged into the cluster
- Dittybopper (Grafana) already deployed in a namespace (this doc uses `dittybopper` as the namespace; adjust if yours differs)
- A dashboard JSON file (exported from Grafana or from a file)

### What it does / Overview

Dittybopper’s deployment does not mount ConfigMaps labeled `grafana_dashboard=1` by default. To make dashboards persistent you must:

1. Create a **dashboard provider** ConfigMap so Grafana knows where to load dashboards from.
2. Create a **dashboard** ConfigMap with your dashboard JSON (or multiple JSON files in one ConfigMap named `grafana-dashboards-default`).
3. **Patch the dittybopper deployment** to mount both ConfigMaps into the Grafana container.

The script performs all of these steps (and rollout) for you when you pass a namespace and optional JSON files. The sections below describe each step in detail for manual setup or reference.

---

### Step 1: Create the dashboard provider ConfigMap

This tells Grafana to load dashboard JSON files from a specific path inside the container.

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

Use your actual namespace in place of `dittybopper` if different.

---

### Step 2: Export and create the dashboard ConfigMap

### 2a. Export the dashboard from Grafana (if needed)

1. Open Grafana in the browser and go to the dashboard you want to keep.
2. Use **Share dashboard** (or the ⋮ menu) → **Export**.
3. Choose **Export for sharing externally** (or “Save to file”).
4. Save the file locally (e.g. `my-dashboard.json`).

### 2b. Create a ConfigMap from the JSON file(s)

The script uses a single ConfigMap named `grafana-dashboards-default` and can include multiple JSON files (each becomes a key in the ConfigMap). To do the same manually, from the directory where the JSON file(s) are:

```bash
# Single file; replace my-dashboard.json with your file. Use grafana-dashboards-default to match the script.
oc create configmap grafana-dashboards-default \
  --from-file=my-dashboard.json \
  -n dittybopper
```

Multiple dashboards (script behavior):

```bash
oc create configmap grafana-dashboards-default \
  --from-file=dashboard1.json --from-file=dashboard2.json \
  -n dittybopper
```

To force a key to be `dashboard.json` (some setups expect this name):

```bash
oc create configmap grafana-dashboards-default \
  --from-file=dashboard.json=my-dashboard.json \
  -n dittybopper
```

Optional: add the label `grafana_dashboard=1` for consistency with other setups (dittybopper does not use it for mounting; the mount is done in Step 3):

```bash
oc label configmap grafana-dashboards-default grafana_dashboard=1 -n dittybopper
```

---

### Step 3: Mount the ConfigMaps in the dittybopper deployment

Add two volumes to the Grafana container so it sees the provider config and the dashboard JSON.

**Provider config** (so Grafana reads `dashboards.yaml`):

```bash
oc set volume deployment/dittybopper -n dittybopper \
  --add \
  --name=grafana-dashboards-provider \
  --type=configmap \
  --configmap-name=grafana-dashboards-provider \
  --mount-path=/etc/grafana/provisioning/dashboards \
  -c dittybopper
```

**Dashboard ConfigMap** (so Grafana sees your JSON under the path configured in the provider). The script uses the name `grafana-dashboards-default`:

```bash
oc set volume deployment/dittybopper -n dittybopper \
  --add \
  --name=grafana-dashboards-default \
  --type=configmap \
  --configmap-name=grafana-dashboards-default \
  --mount-path=/etc/grafana/provisioning/dashboards/default \
  -c dittybopper
```

If you created a ConfigMap with a different name in Step 2, use that name for `--name` and `--configmap-name`. When the script updates the dashboards ConfigMap, it restarts the deployment so the pod picks up the new JSON.

Wait for the rollout to finish:

```bash
oc rollout status deployment/dittybopper -n dittybopper --timeout=120s
```

---

### Step 4: Verify

1. Open Grafana and go to **Dashboards** (or **Explore**).
2. The provisioned dashboard should appear (title comes from the dashboard JSON).
3. Restart the pod and confirm the dashboard is still there:

   ```bash
   oc rollout restart deployment/dittybopper -n dittybopper
   oc rollout status deployment/dittybopper -n dittybopper --timeout=120s
   ```

Optional: confirm files inside the container:

```bash
oc exec -n dittybopper deployment/dittybopper -c dittybopper -- \
  ls -la /etc/grafana/provisioning/dashboards/
oc exec -n dittybopper deployment/dittybopper -c dittybopper -- \
  ls -la /etc/grafana/provisioning/dashboards/default/
```

You should see `dashboards.yaml` and, under `default/`, your JSON file(s).

---

### Adding more dashboards

- **Using the script:** Re-run the script with the same namespace and **all** dashboard JSON files you want (e.g. `./provision-grafana-dashboards.sh dittybopper dash1.json dash2.json new-dash.json`). The script replaces the `grafana-dashboards-default` ConfigMap with one containing every file you pass and restarts the deployment.
- **Manual (same ConfigMap):** Add another key to the `grafana-dashboards-default` ConfigMap and re-apply, then restart the deployment so the new file is mounted.
- **Manual (separate ConfigMap):** Create a new ConfigMap and add a second volume mounting it into a new folder under provisioning, and extend `dashboards.yaml` with another provider for that path.

---

### Troubleshooting

- **Dashboard does not appear after Step 3**  
  - Check that the JSON is valid and is the format Grafana expects (e.g. export from Grafana and use that file).  
  - Check Grafana logs: `oc logs -n dittybopper deployment/dittybopper -c dittybopper --tail=100` for provisioning or parsing errors.

- **Dashboard disappears after a few minutes**  
  - Without the mounts in Step 3, dashboards live only in the pod. Ensure both volumes are present:  
    `oc get deployment dittybopper -n dittybopper -o jsonpath='{.spec.template.spec.volumes[*].name}'`

- **Wrong namespace**  
  - Replace `dittybopper` in all commands with your Grafana/dittybopper namespace.
