/* Pure helpers for the data-collector dashboard (browser + Node tests). */

(function (root) {
  "use strict";

  function escapeHtml(s) {
    return String(s)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
  }

  function fmtTs(ts) {
    // Always render as UTC ISO-8601 with Z (API stores unix UTC epoch seconds).
    if (ts == null) return "—";
    if (typeof ts === "string" && ts.trim()) {
      const s = ts.trim();
      const n = Number(s);
      if (Number.isFinite(n) && String(n) === s) {
        const d = new Date(n * 1000);
        if (!Number.isNaN(d.getTime())) return d.toISOString().replace(/\.\d{3}Z$/, "Z");
      }
      if (/[zZ]|[+-]\d{2}:?\d{2}$/.test(s)) {
        return s.endsWith("Z") || s.endsWith("z") ? s.replace(/z$/i, "Z") : s;
      }
      const d = new Date(s.includes("T") ? s + "Z" : s + "T00:00:00Z");
      if (!Number.isNaN(d.getTime())) return d.toISOString().replace(/\.\d{3}Z$/, "Z");
      return s;
    }
    const d = new Date(Number(ts) * 1000);
    if (Number.isNaN(d.getTime())) return String(ts);
    return d.toISOString().replace(/\.\d{3}Z$/, "Z");
  }

  function displayTs(...vals) {
    for (const v of vals) {
      if (v == null || v === "") continue;
      if (typeof v === "string" && v.trim()) return v.trim();
      if (typeof v === "number" && Number.isFinite(v)) return fmtTs(v);
    }
    return "—";
  }

  function fmtNum(n, digits = 1) {
    if (n == null || Number.isNaN(Number(n))) return "—";
    const x = Number(n);
    if (Math.abs(x) >= 1e9) return (x / 1e9).toFixed(digits) + "G";
    if (Math.abs(x) >= 1e6) return (x / 1e6).toFixed(digits) + "M";
    if (Math.abs(x) >= 1e3) return (x / 1e3).toFixed(digits) + "k";
    return x.toFixed(digits);
  }

  function fmtBw(bps) {
    if (bps == null) return "—";
    return fmtNum(bps, 1) + " B/s";
  }

  function fmtWorkloadStatus(uiStatus) {
    return uiStatus === "running" ? "running" : "idle";
  }

  /** Batches-list Workload status column: running / idle only. */
  function fmtWorkloadColumn(s) {
    if (!s) return "—";
    const running = Number(s.running || 0);
    const total = Number(s.configured ?? 0);
    const idle = total > 0 ? Math.max(0, total - running) : Number(s.idle || 0);
    return `${running} running · ${idle} idle`;
  }

  /** Parse location hash (or a hash string) into a route object. */
  function parseRoute(hash) {
    const raw =
      hash != null
        ? String(hash)
        : typeof location !== "undefined"
          ? location.hash || "#/runs"
          : "#/runs";
    const h = raw.replace(/^#/, "");
    const parts = h.split("/").filter(Boolean);
    if (parts[0] === "timestamps") return { name: "timestamps" };
    if (parts[0] !== "runs") return { name: "runs" };
    if (parts.length === 1) return { name: "runs" };
    const batchId = decodeURIComponent(parts[1]);
    if (parts.length === 2) return { name: "run", batchId };
    if (parts[2] === "timestamps") return { name: "batch-timestamps", batchId };
    if (parts[2] === "payload" && parts[3]) {
      return { name: "payload", batchId, resultId: decodeURIComponent(parts[3]) };
    }
    if (parts[2] === "vms" && parts[3]) {
      const vm = decodeURIComponent(parts[3]);
      if (parts[4] === "cycles" && parts[5] != null) {
        return { name: "cycle", batchId, vm, cycle: decodeURIComponent(parts[5]) };
      }
      return { name: "vm", batchId, vm };
    }
    return { name: "run", batchId };
  }

  function statusBadge(status, fioRc) {
    const st = status || (fioRc != null && Number(fioRc) !== 0 ? "fio_error" : "ok");
    if (!st || st === "ok") return '<span class="badge ok">ok</span>';
    if (st === "post_error") return `<span class="badge warn">${escapeHtml(st)}</span>`;
    return `<span class="badge err">${escapeHtml(st)}</span>`;
  }

  function createAnchorUnix(vm, batchDvCreatedAt, batchStartedAt) {
    if (vm && vm.dv_created_at_unix != null && Number.isFinite(Number(vm.dv_created_at_unix))) {
      return Number(vm.dv_created_at_unix);
    }
    if (batchDvCreatedAt != null && Number.isFinite(Number(batchDvCreatedAt))) {
      return Number(batchDvCreatedAt);
    }
    if (batchStartedAt != null && Number.isFinite(Number(batchStartedAt))) {
      return Number(batchStartedAt);
    }
    return null;
  }

  function bootDurationsSeconds(vms, batchStartedAt, batchDvCreatedAt) {
    const list = vms || [];
    const hasPerVmDv = list.some(
      (v) => v.dv_created_at_unix != null && Number.isFinite(Number(v.dv_created_at_unix))
    );
    const out = [];
    for (const v of list) {
      const boot = v.boot_timestamp_unix;
      if (boot == null) continue;
      let anchor = null;
      if (v.dv_created_at_unix != null && Number.isFinite(Number(v.dv_created_at_unix))) {
        anchor = Number(v.dv_created_at_unix);
      } else if (!hasPerVmDv) {
        anchor = createAnchorUnix(v, batchDvCreatedAt, batchStartedAt);
      }
      if (anchor == null) continue;
      const s = Number(boot) - Number(anchor);
      if (!Number.isFinite(s) || s < 0) continue;
      out.push({ vm_name: v.vm_name, seconds: s });
    }
    return out;
  }

  function fmtBootTimeSummary(vms, batchStartedAt, batchDvCreatedAt) {
    const samples = bootDurationsSeconds(vms, batchStartedAt, batchDvCreatedAt);
    if (!samples.length) return "Boot time —";
    const seconds = samples.map((s) => s.seconds);
    const min = Math.min(...seconds);
    const max = Math.max(...seconds);
    const avg = seconds.reduce((a, b) => a + b, 0) / seconds.length;
    const label =
      batchDvCreatedAt != null || (vms || []).some((v) => v.dv_created_at_unix != null)
        ? "DV→boot"
        : "Boot time";
    return `${label} avg ${Math.round(avg)}s · min ${Math.round(min)}s · max ${Math.round(max)}s`;
  }

  function csvEscape(val) {
    const s = val == null ? "" : String(val);
    if (/[",\n\r]/.test(s)) return `"${s.replace(/"/g, '""')}"`;
    return s;
  }

  /** End − start in whole seconds; empty string if either side is missing. */
  function durationSeconds(endUnix, startUnix) {
    if (endUnix == null || startUnix == null) return "";
    const end = Number(endUnix);
    const start = Number(startUnix);
    if (!Number.isFinite(end) || !Number.isFinite(start)) return "";
    return String(Math.round(end - start));
  }

  const CSV_DURATION_HEADERS = [
    "base_dv_creation_s",
    "snapshot_creation_s",
    "dv_creation_s",
    "data_dv_creation_s",
    "vm_ready_s",
    "vm_provision_s",
  ];

  function timingDurationCells({
    baseDvCreated,
    baseDvBound,
    snapshotCreated,
    snapshotReady,
    dvCreated,
    pvcBound,
    dataDvCreated,
    dataPvcBound,
    boot,
  }) {
    return [
      durationSeconds(baseDvBound, baseDvCreated),
      durationSeconds(snapshotReady, snapshotCreated),
      durationSeconds(pvcBound, dvCreated),
      durationSeconds(dataPvcBound, dataDvCreated),
      durationSeconds(boot, dvCreated),
      durationSeconds(boot, pvcBound),
    ];
  }

  function buildBootTimesCsv(batchId, vms, batchStartedAt, batchDvCreatedAt) {
    const header = [
      "batch_id",
      "vm_name",
      "namespace",
      ...CSV_DURATION_HEADERS,
      "batch_started_at_utc",
      "base_dv_created_at_utc",
      "base_dv_ready_at_utc",
      "base_dv_bound_at_utc",
      "snapshot_created_at_utc",
      "snapshot_ready_at_utc",
      "dv_created_at_utc",
      "dv_ready_at_utc",
      "pvc_created_at_utc",
      "pvc_bound_at_utc",
      "data_dv_created_at_utc",
      "data_dv_ready_at_utc",
      "data_pvc_created_at_utc",
      "data_pvc_bound_at_utc",
      "ssh_ready_at_utc",
      "boot_timestamp_utc",
    ];
    const startedIso = fmtTs(batchStartedAt);
    const rows = [header.join(",")];
    for (const v of vms || []) {
      const boot = v.boot_timestamp_unix;
      const baseDv = v.base_dv_created_at_unix;
      const baseDvReady = v.base_dv_ready_at_unix;
      const baseDvBound = v.base_dv_bound_at_unix;
      const snap = v.snapshot_created_at_unix;
      const snapReady = v.snapshot_ready_at_unix;
      const dv = v.dv_created_at_unix;
      const dvReady = v.dv_ready_at_unix;
      const pvc = v.pvc_created_at_unix;
      const pvcBound = v.pvc_bound_at_unix;
      const dataDv = v.data_dv_created_at_unix;
      const dataDvReady = v.data_dv_ready_at_unix;
      const dataPvc = v.data_pvc_created_at_unix;
      const dataPvcBound = v.data_pvc_bound_at_unix;
      const sshReady = v.ssh_ready_at_unix;
      rows.push(
        [
          csvEscape(batchId),
          csvEscape(v.vm_name),
          csvEscape(v.namespace || ""),
          ...timingDurationCells({
            baseDvCreated: baseDv,
            baseDvBound,
            snapshotCreated: snap,
            snapshotReady: snapReady,
            dvCreated: dv,
            pvcBound,
            dataDvCreated: dataDv,
            dataPvcBound,
            boot,
          }),
          csvEscape(startedIso === "—" ? "" : startedIso),
          csvEscape(baseDv != null ? fmtTs(baseDv) : ""),
          csvEscape(baseDvReady != null ? fmtTs(baseDvReady) : ""),
          csvEscape(baseDvBound != null ? fmtTs(baseDvBound) : ""),
          csvEscape(snap != null ? fmtTs(snap) : ""),
          csvEscape(snapReady != null ? fmtTs(snapReady) : ""),
          csvEscape(dv != null ? fmtTs(dv) : ""),
          csvEscape(dvReady != null ? fmtTs(dvReady) : ""),
          csvEscape(pvc != null ? fmtTs(pvc) : ""),
          csvEscape(pvcBound != null ? fmtTs(pvcBound) : ""),
          csvEscape(dataDv != null ? fmtTs(dataDv) : ""),
          csvEscape(dataDvReady != null ? fmtTs(dataDvReady) : ""),
          csvEscape(dataPvc != null ? fmtTs(dataPvc) : ""),
          csvEscape(dataPvcBound != null ? fmtTs(dataPvcBound) : ""),
          csvEscape(sshReady != null ? fmtTs(sshReady) : ""),
          csvEscape(boot != null ? fmtTs(boot) : ""),
        ].join(",")
      );
    }
    return rows.join("\n") + "\n";
  }

  function histogramBins(values, { maxBins = 12, minWidth = 5 } = {}) {
    if (!values.length) return { labels: [], counts: [], edges: [] };
    const sorted = [...values].sort((a, b) => a - b);
    const lo = sorted[0];
    const hi = sorted[sorted.length - 1];
    if (hi === lo) {
      const label = `${Math.round(lo)}s`;
      return { labels: [label], counts: [values.length], edges: [lo, lo + minWidth] };
    }
    const n = Math.min(maxBins, Math.max(3, Math.ceil(Math.sqrt(values.length))));
    let width = (hi - lo) / n;
    if (width < minWidth) width = minWidth;
    const binCount = Math.max(1, Math.ceil((hi - lo) / width));
    const edges = [];
    for (let i = 0; i <= binCount; i++) edges.push(lo + i * width);
    edges[edges.length - 1] = Math.max(edges[edges.length - 1], hi);
    const counts = new Array(binCount).fill(0);
    for (const v of values) {
      let idx = Math.floor((v - lo) / width);
      if (idx >= binCount) idx = binCount - 1;
      if (idx < 0) idx = 0;
      counts[idx] += 1;
    }
    const labels = [];
    for (let i = 0; i < binCount; i++) {
      const a = Math.round(edges[i]);
      const b = Math.round(edges[i + 1]);
      labels.push(`${a}–${b}s`);
    }
    return { labels, counts, edges };
  }

  function buildCrossBatchTimestampsCsv(items) {
    const header = [
      "batch_id",
      "basename",
      "cloudinit",
      "vm_name",
      "namespace",
      ...CSV_DURATION_HEADERS,
      "batch_started_at_utc",
      "base_dv_created_at_utc",
      "base_dv_ready_at_utc",
      "base_dv_bound_at_utc",
      "snapshot_created_at_utc",
      "snapshot_ready_at_utc",
      "dv_created_at_utc",
      "dv_ready_at_utc",
      "pvc_created_at_utc",
      "pvc_bound_at_utc",
      "data_dv_created_at_utc",
      "data_dv_ready_at_utc",
      "data_pvc_created_at_utc",
      "data_pvc_bound_at_utc",
      "ssh_ready_at_utc",
      "boot_timestamp_utc",
    ];
    const rows = [header.join(",")];
    for (const it of items || []) {
      rows.push(
        [
          csvEscape(it.batch_id),
          csvEscape(it.basename || ""),
          csvEscape(it.cloudinit || ""),
          csvEscape(it.vm_name || ""),
          csvEscape(it.namespace || ""),
          ...timingDurationCells({
            baseDvCreated: it.base_dv_created_at,
            baseDvBound: it.base_dv_bound_at,
            snapshotCreated: it.snapshot_created_at,
            snapshotReady: it.snapshot_ready_at,
            dvCreated: it.dv_created_at,
            pvcBound: it.pvc_bound_at,
            dataDvCreated: it.data_dv_created_at,
            dataPvcBound: it.data_pvc_bound_at,
            boot: it.boot_timestamp,
          }),
          csvEscape(it.batch_started_at != null ? fmtTs(it.batch_started_at) : ""),
          csvEscape(it.base_dv_created_at != null ? fmtTs(it.base_dv_created_at) : ""),
          csvEscape(it.base_dv_ready_at != null ? fmtTs(it.base_dv_ready_at) : ""),
          csvEscape(it.base_dv_bound_at != null ? fmtTs(it.base_dv_bound_at) : ""),
          csvEscape(it.snapshot_created_at != null ? fmtTs(it.snapshot_created_at) : ""),
          csvEscape(it.snapshot_ready_at != null ? fmtTs(it.snapshot_ready_at) : ""),
          csvEscape(it.dv_created_at != null ? fmtTs(it.dv_created_at) : ""),
          csvEscape(it.dv_ready_at != null ? fmtTs(it.dv_ready_at) : ""),
          csvEscape(it.pvc_created_at != null ? fmtTs(it.pvc_created_at) : ""),
          csvEscape(it.pvc_bound_at != null ? fmtTs(it.pvc_bound_at) : ""),
          csvEscape(it.data_dv_created_at != null ? fmtTs(it.data_dv_created_at) : ""),
          csvEscape(it.data_dv_ready_at != null ? fmtTs(it.data_dv_ready_at) : ""),
          csvEscape(it.data_pvc_created_at != null ? fmtTs(it.data_pvc_created_at) : ""),
          csvEscape(it.data_pvc_bound_at != null ? fmtTs(it.data_pvc_bound_at) : ""),
          csvEscape(it.ssh_ready_at != null ? fmtTs(it.ssh_ready_at) : ""),
          csvEscape(it.boot_timestamp != null ? fmtTs(it.boot_timestamp) : ""),
        ].join(",")
      );
    }
    return rows.join("\n") + "\n";
  }

  /** Default rows per page for dashboard tables. */
  const DEFAULT_PAGE_SIZE = 100;

  function pagerMeta(total, page, pageSize) {
    const size = Math.max(1, Math.floor(Number(pageSize) || DEFAULT_PAGE_SIZE));
    const n = Math.max(0, Math.floor(Number(total) || 0));
    const totalPages = Math.max(1, Math.ceil(n / size) || 1);
    let p = Math.floor(Number(page) || 1);
    if (!Number.isFinite(p) || p < 1) p = 1;
    if (p > totalPages) p = totalPages;
    const start = n === 0 ? 0 : (p - 1) * size;
    const end = Math.min(start + size, n);
    return { page: p, pageSize: size, total: n, totalPages, start, end };
  }

  function slicePage(items, page, pageSize) {
    const list = items || [];
    const meta = pagerMeta(list.length, page, pageSize);
    return { meta, items: list.slice(meta.start, meta.end) };
  }

  function normalizeApiBase(raw) {
    let s = String(raw == null ? "" : raw).trim();
    if (!s) return "";
    s = s.replace(/\/+$/, "");
    if (!/^https?:\/\//i.test(s)) {
      s = "http://" + s;
    }
    return s;
  }

  /** Build an absolute or same-origin API URL from optional base + path. */
  function apiUrl(path, base) {
    const b = normalizeApiBase(base);
    const p = path.startsWith("/") ? path : "/" + path;
    return b ? b + p : p;
  }

  /** Default TTL for in-memory GET response cache (Option A). */
  const DEFAULT_API_CACHE_TTL_MS = 30_000;

  function apiCacheKey(apiBase, method, path) {
    const m = String(method || "GET").toUpperCase();
    const p = path.startsWith("/") ? path : "/" + path;
    return `${normalizeApiBase(apiBase)}|${m}|${p}`;
  }

  function cloneJson(value) {
    if (value == null) return value;
    return JSON.parse(JSON.stringify(value));
  }

  /** In-memory GET cache with TTL (fresh hit returns data; stale/miss returns null). */
  function createApiCache(options) {
    const ttlMs =
      options && options.ttlMs != null ? Number(options.ttlMs) : DEFAULT_API_CACHE_TTL_MS;
    const store = new Map();

    function get(apiBase, method, path, now) {
      const ts = now != null ? Number(now) : Date.now();
      const key = apiCacheKey(apiBase, method, path);
      const hit = store.get(key);
      if (!hit) return null;
      if (ts - hit.fetchedAt >= ttlMs) {
        store.delete(key);
        return null;
      }
      return cloneJson(hit.data);
    }

    function set(apiBase, method, path, data, now) {
      const key = apiCacheKey(apiBase, method, path);
      store.set(key, {
        data: cloneJson(data),
        fetchedAt: now != null ? Number(now) : Date.now(),
      });
    }

    function clear() {
      store.clear();
    }

    function invalidatePathPrefix(pathPrefix) {
      const needle = pathPrefix.startsWith("/") ? pathPrefix : "/" + pathPrefix;
      for (const key of store.keys()) {
        if (key.includes(needle)) store.delete(key);
      }
    }

    return {
      ttlMs,
      get,
      set,
      clear,
      invalidatePathPrefix,
      apiCacheKey,
    };
  }

  const api = {
    escapeHtml,
    fmtTs,
    displayTs,
    fmtNum,
    fmtBw,
    fmtWorkloadStatus,
    fmtWorkloadColumn,
    parseRoute,
    statusBadge,
    createAnchorUnix,
    bootDurationsSeconds,
    fmtBootTimeSummary,
    csvEscape,
    durationSeconds,
    buildBootTimesCsv,
    buildCrossBatchTimestampsCsv,
    histogramBins,
    DEFAULT_PAGE_SIZE,
    pagerMeta,
    slicePage,
    normalizeApiBase,
    apiUrl,
    DEFAULT_API_CACHE_TTL_MS,
    apiCacheKey,
    createApiCache,
  };

  root.WorkloadDashboardLib = api;
  if (typeof module !== "undefined" && module.exports) {
    module.exports = api;
  }
})(typeof globalThis !== "undefined" ? globalThis : this);
