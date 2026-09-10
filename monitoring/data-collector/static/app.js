/* Workload-result dashboard (hash router). */

const state = {
  chart: null,
  timer: null,
  downloadUrl: null,
  selectedBatches: new Set(),
  bypassCacheOnce: false,
  filters: {
    q: "",
    archived: "0",
    datePreset: "all", // all | today | day
    date: "",
    batch_id: "",
    namespace: "",
    api_server: "",
  },
};

const TOKEN_KEY = "workload-result-token";
const API_BASE_KEY = "workload-result-api-base";
/** Used when localStorage has never set an API base (standalone dashboard). */
const DEFAULT_API_BASE =
  "http://n42-h01-b02-mx750c.rdu3.labs.perfscale.redhat.com:8080";

const {
  escapeHtml,
  fmtTs,
  displayTs,
  fmtNum,
  fmtBw,
  fmtWorkloadStatus,
  fmtWorkloadColumn,
  parseRoute,
  statusBadge,
  bootDurationsSeconds,
  durationSeconds,
  csvEscape,
  buildCrossBatchTimestampsCsv,
  histogramBins,
  DEFAULT_PAGE_SIZE,
  pagerMeta,
  slicePage,
  normalizeApiBase,
  apiUrl,
  createApiCache,
} = globalThis.WorkloadDashboardLib;

const apiCache = createApiCache();

function invalidateApiCacheAfterMutation(path) {
  if (String(path || "").startsWith("/v1/")) {
    apiCache.invalidatePathPrefix("/v1/batches");
    apiCache.invalidatePathPrefix("/v1/timestamps");
  }
}

function getStoredToken() {
  try {
    return localStorage.getItem(TOKEN_KEY) || "";
  } catch {
    return "";
  }
}

function setStoredToken(token) {
  try {
    if (token) localStorage.setItem(TOKEN_KEY, token);
    else localStorage.removeItem(TOKEN_KEY);
  } catch {
    /* ignore quota / private mode */
  }
}

function getStoredApiBase() {
  try {
    const raw = localStorage.getItem(API_BASE_KEY);
    // null = never configured → lab default; "" = explicit same-origin.
    if (raw === null) return normalizeApiBase(DEFAULT_API_BASE);
    return normalizeApiBase(raw);
  } catch {
    return normalizeApiBase(DEFAULT_API_BASE);
  }
}

function setStoredApiBase(base) {
  try {
    // Always persist (including "") so clearing the field opts into same-origin
    // instead of falling back to DEFAULT_API_BASE on the next load.
    localStorage.setItem(API_BASE_KEY, normalizeApiBase(base));
  } catch {
    /* ignore */
  }
}

/** Apply ?api= once on load (persists to localStorage). */
function consumeApiQueryParam() {
  try {
    const u = new URL(window.location.href);
    if (!u.searchParams.has("api")) return;
    setStoredApiBase(u.searchParams.get("api") || "");
    u.searchParams.delete("api");
    const qs = u.searchParams.toString();
    history.replaceState(
      null,
      "",
      u.pathname + (qs ? "?" + qs : "") + u.hash
    );
  } catch {
    /* ignore */
  }
}

function currentApiBase() {
  return getStoredApiBase();
}

async function api(path, opts = {}) {
  const method = (opts.method || "GET").toUpperCase();
  const bypassCache = Boolean(opts.bypassCache || state.bypassCacheOnce);
  if (state.bypassCacheOnce) state.bypassCacheOnce = false;
  const apiBase = currentApiBase();

  if (method === "GET" && !bypassCache) {
    const cached = apiCache.get(apiBase, method, path);
    if (cached !== null) return cached;
  }

  const headers = {
    Accept: "application/json",
    ...(opts.body ? { "Content-Type": "application/json" } : {}),
    ...(opts.headers || {}),
  };
  const token = getStoredToken();
  if (token && !headers.Authorization) {
    headers.Authorization = `Bearer ${token}`;
  }

  const url = apiUrl(path, currentApiBase());

  const doFetch = async (hdrs) => {
    let res;
    try {
      res = await fetch(url, { ...opts, headers: hdrs });
    } catch (err) {
      const msg = err && err.message ? err.message : String(err);
      throw new Error(`network error (${url}): ${msg}`);
    }
    const text = await res.text();
    let data = null;
    try {
      data = text ? JSON.parse(text) : null;
    } catch {
      data = { error: text };
    }
    return { res, data };
  };

  let { res, data } = await doFetch(headers);
  if (res.status === 401) {
    const entered = window.prompt("Collector requires a bearer token. Enter token:");
    if (entered != null && entered.trim()) {
      setStoredToken(entered.trim());
      headers.Authorization = `Bearer ${entered.trim()}`;
      ({ res, data } = await doFetch(headers));
    }
  }
  if (!res.ok) {
    throw new Error((data && data.error) || res.statusText || "request failed");
  }
  if (method === "GET") {
    apiCache.set(apiBase, method, path, data);
  } else {
    invalidateApiCacheAfterMutation(path);
  }
  return data;
}

function $(sel) {
  return document.querySelector(sel);
}

/** Launch-time guest env for display (FIO_* and related knobs first). */
function formatGuestEnv(env) {
  if (!env || typeof env !== "object") return "—";
  const prefer = [
    "WORKLOAD_TYPE",
    "FIO_SIZE",
    "FIO_BS",
    "FIO_IODEPTH",
    "FIO_NUMJOBS",
    "FIO_DIRECT",
    "FIO_TIME_BASED",
    "FIO_RUNTIME",
    "FIO_DIRECTORY",
    "FIO_RW",
    "FIO_CUSTOM_OPTS",
    "WORKLOAD_RUN_MODE",
    "WORKLOAD_RUN_COUNT",
    "WORKLOAD_MAX_JOBS",
    "RESULT_SERVER_URL",
  ];
  const lines = [];
  const seen = new Set();
  for (const k of prefer) {
    if (env[k] == null || String(env[k]).trim() === "") continue;
    lines.push(`${k}=${env[k]}`);
    seen.add(k);
  }
  for (const k of Object.keys(env).sort()) {
    if (seen.has(k)) continue;
    if (env[k] == null || String(env[k]).trim() === "") continue;
    lines.push(`${k}=${env[k]}`);
  }
  return lines.length ? lines.join("\n") : "—";
}

function setCrumbs(items) {
  const el = $("#crumbs");
  el.innerHTML = items
    .map((it, i) => {
      const sep = i ? '<span class="sep">/</span>' : "";
      if (it.href) return `${sep}<a href="${escapeHtml(it.href)}">${escapeHtml(it.label)}</a>`;
      return `${sep}<span>${escapeHtml(it.label)}</span>`;
    })
    .join("");
}

function destroyChart() {
  if (state.chart) {
    state.chart.destroy();
    state.chart = null;
  }
  if (state.downloadUrl) {
    URL.revokeObjectURL(state.downloadUrl);
    state.downloadUrl = null;
  }
}

async function render() {
  const app = $("#app");
  const route = parseRoute();
  destroyChart();
  try {
    if (route.name === "runs") await renderRuns(app);
    else if (route.name === "timestamps") await renderTimestamps(app);
    else if (route.name === "batch-timestamps") await renderBatchTimestamps(app, route.batchId);
    else if (route.name === "run") await renderRun(app, route.batchId);
    else if (route.name === "vm") await renderVm(app, route.batchId, route.vm);
    else if (route.name === "cycle") await renderCycle(app, route.batchId, route.vm, route.cycle);
    else if (route.name === "payload") await renderPayload(app, route.batchId, route.resultId);
    else await renderRuns(app);
  } catch (err) {
    setCrumbs([{ label: "Batches", href: "#/runs" }, { label: "Error" }]);
    app.innerHTML = `<div class="error">${escapeHtml(err.message)}</div>`;
  }
}

function filterQueryParams() {
  const f = state.filters;
  const params = new URLSearchParams();
  if (f.q) params.set("q", f.q);
  if (f.archived !== "all") params.set("archived", f.archived);
  if (f.datePreset === "today") params.set("today", "1");
  else if (f.datePreset === "day" && f.date) params.set("date", f.date);
  if (f.batch_id) params.set("batch_id", f.batch_id);
  if (f.namespace) params.set("namespace", f.namespace);
  if (f.api_server) params.set("api_server", f.api_server);
  return params;
}

function cellDash(val) {
  if (val == null || val === "") return "—";
  return escapeHtml(String(val));
}

function fmtTsCell(ts) {
  const s = fmtTs(ts);
  return s === "—" ? "—" : escapeHtml(s);
}

/** Render First/Prev/Next/Last controls into `el` (hidden when ≤1 page). */
function renderPagerControls(el, meta, onPage) {
  if (!el) return;
  if (!meta || meta.total <= meta.pageSize) {
    el.innerHTML = "";
    el.hidden = true;
    return;
  }
  el.hidden = false;
  const from = meta.start + 1;
  const to = meta.end;
  const atFirst = meta.page <= 1;
  const atLast = meta.page >= meta.totalPages;
  el.innerHTML = `
    <div class="pager-info muted">
      ${escapeHtml(String(from))}–${escapeHtml(String(to))} of ${escapeHtml(String(meta.total))}
      · page ${escapeHtml(String(meta.page))} / ${escapeHtml(String(meta.totalPages))}
      · ${escapeHtml(String(meta.pageSize))} / page
    </div>
    <div class="pager-actions">
      <button type="button" class="btn" data-pager="first" ${atFirst ? "disabled" : ""}>First</button>
      <button type="button" class="btn" data-pager="prev" ${atFirst ? "disabled" : ""}>Prev</button>
      <button type="button" class="btn" data-pager="next" ${atLast ? "disabled" : ""}>Next</button>
      <button type="button" class="btn" data-pager="last" ${atLast ? "disabled" : ""}>Last</button>
    </div>`;
  el.querySelectorAll("[data-pager]").forEach((btn) => {
    btn.onclick = () => {
      const action = btn.getAttribute("data-pager");
      let next = meta.page;
      if (action === "first") next = 1;
      else if (action === "prev") next = meta.page - 1;
      else if (action === "next") next = meta.page + 1;
      else if (action === "last") next = meta.totalPages;
      onPage(next);
    };
  });
}

/**
 * Client-side table pagination.
 * @param {{
 *   tbody: HTMLElement,
 *   pagers?: HTMLElement[],
 *   rowHtmls: string[],
 *   pageSize?: number,
 *   page?: number,
 *   onRendered?: (meta: object) => void,
 * }} opts
 */
function bindPaginatedTable({ tbody, pagers = [], rowHtmls, pageSize = DEFAULT_PAGE_SIZE, page = 1, onRendered }) {
  let current = page;
  const paint = (nextPage, { scroll } = {}) => {
    const prev = current;
    const { meta, items } = slicePage(rowHtmls, nextPage, pageSize);
    current = meta.page;
    tbody.innerHTML = items.join("");
    for (const pager of pagers) {
      renderPagerControls(pager, meta, (p) => paint(p, { scroll: true }));
    }
    if (scroll && meta.page !== prev && pagers[0]) {
      pagers[0].scrollIntoView({ block: "nearest", behavior: "smooth" });
    }
    if (onRendered) onRendered(meta);
  };
  paint(current);
  return { go: paint, getPage: () => current };
}

function bindClickableRows(root) {
  (root || document).querySelectorAll("tr.clickable").forEach((tr) => {
    tr.onclick = (e) => {
      if (e.target.closest("a")) return;
      if (e.target.closest("input")) return;
      if (e.target.closest("button")) return;
      if (tr.dataset.href) location.hash = tr.dataset.href;
    };
  });
}

function renderTimestampsTableShell(headers, { emptyMessage } = {}) {
  return `<div class="pager" data-pager-slot="top" hidden></div>
    <div class="table-wrap timestamps-wrap"><table class="timestamps-table">
    <thead><tr>${headers.map((h) => `<th>${escapeHtml(h)}</th>`).join("")}</tr></thead>
    <tbody data-pager-body></tbody>
  </table></div>
  <div class="pager" data-pager-slot="bottom" hidden></div>
  <div class="empty" data-pager-empty style="display:none">${escapeHtml(
    emptyMessage || "No VM timestamps for the current filters."
  )}</div>`;
}

function mountTimestampsTable(panel, headers, rows) {
  const rowHtmls = (rows || []).map(
    (cells) => `<tr>${cells.map((c) => `<td class="mono">${c}</td>`).join("")}</tr>`
  );
  panel.innerHTML = renderTimestampsTableShell(headers);
  const empty = panel.querySelector("[data-pager-empty]");
  const tbody = panel.querySelector("[data-pager-body]");
  const pagers = [...panel.querySelectorAll("[data-pager-slot]")];
  const tableWrap = panel.querySelector(".table-wrap");
  if (!rowHtmls.length) {
    if (empty) empty.style.display = "";
    if (tableWrap) tableWrap.style.display = "none";
    pagers.forEach((p) => {
      p.hidden = true;
    });
    return;
  }
  if (empty) empty.style.display = "none";
  bindPaginatedTable({ tbody, pagers, rowHtmls });
}

function crossBatchTimestampRow(it) {
  const durations = [
    durationSeconds(it.base_dv_bound_at, it.base_dv_created_at),
    durationSeconds(it.snapshot_ready_at, it.snapshot_created_at),
    durationSeconds(it.pvc_bound_at, it.dv_created_at),
    durationSeconds(it.data_pvc_bound_at, it.data_dv_created_at),
    durationSeconds(it.boot_timestamp, it.dv_created_at),
    durationSeconds(it.boot_timestamp, it.pvc_bound_at),
  ].map((d) => (d === "" ? "—" : escapeHtml(d)));
  return [
    cellDash(it.batch_id),
    cellDash(it.basename || ""),
    cellDash(it.cloudinit || ""),
    cellDash(it.vm_name || ""),
    cellDash(it.namespace || ""),
    ...durations,
    fmtTsCell(it.batch_started_at),
    fmtTsCell(it.base_dv_created_at),
    fmtTsCell(it.base_dv_ready_at),
    fmtTsCell(it.base_dv_bound_at),
    fmtTsCell(it.snapshot_created_at),
    fmtTsCell(it.snapshot_ready_at),
    fmtTsCell(it.dv_created_at),
    fmtTsCell(it.dv_ready_at),
    fmtTsCell(it.pvc_created_at),
    fmtTsCell(it.pvc_bound_at),
    fmtTsCell(it.data_dv_created_at),
    fmtTsCell(it.data_dv_ready_at),
    fmtTsCell(it.data_pvc_created_at),
    fmtTsCell(it.data_pvc_bound_at),
    fmtTsCell(it.ssh_ready_at),
    fmtTsCell(it.boot_timestamp),
  ];
}

const CROSS_BATCH_TS_HEADERS = [
  "batch_id",
  "basename",
  "cloudinit",
  "vm_name",
  "namespace",
  "base_dv_creation_s",
  "snapshot_creation_s",
  "dv_creation_s",
  "data_dv_creation_s",
  "vm_ready_s",
  "vm_provision_s",
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

const BATCH_TS_HEADERS = [
  "id",
  "vm_name",
  "namespace",
  "snapshot_creation_s",
  "dv_creation_s",
  "vm_provision_s",
  "vm_ready_s",
  "boot_timestamp_utc",
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
  "data_dv_creation_s",
  "data_dv_ready_at_utc",
  "data_pvc_created_at_utc",
  "data_pvc_bound_at_utc",
  "ssh_ready_at_utc",
  "base_dv_creation_s",
];

function batchTimingContext(summary) {
  return {
    started_at: summary.started_at,
    dv_created_at: summary.dv_created_at,
    base_dv_created_at: summary.base_dv_created_at,
    base_dv_ready_at: summary.base_dv_ready_at,
    base_dv_bound_at: summary.base_dv_bound_at,
    snapshot_created_at: summary.snapshot_created_at,
    snapshot_ready_at: summary.snapshot_ready_at,
  };
}

function enrichVmTimestamps(v, batchCtx) {
  return {
    ...v,
    base_dv_created_at_unix: v.base_dv_created_at_unix ?? batchCtx.base_dv_created_at,
    base_dv_ready_at_unix: v.base_dv_ready_at_unix ?? batchCtx.base_dv_ready_at,
    base_dv_bound_at_unix: v.base_dv_bound_at_unix ?? batchCtx.base_dv_bound_at,
    snapshot_created_at_unix: v.snapshot_created_at_unix ?? batchCtx.snapshot_created_at,
    snapshot_ready_at_unix: v.snapshot_ready_at_unix ?? batchCtx.snapshot_ready_at,
  };
}

/** Plain-text cells for batch timestamps table / CSV (matches BATCH_TS_HEADERS). */
function batchTimestampCells(v, batchCtx, rowId) {
  const row = enrichVmTimestamps(v, batchCtx);
  const boot = row.boot_timestamp_unix;
  const baseDv = row.base_dv_created_at_unix;
  const baseDvBound = row.base_dv_bound_at_unix;
  const snap = row.snapshot_created_at_unix;
  const snapReady = row.snapshot_ready_at_unix;
  const dv =
    row.dv_created_at_unix != null ? row.dv_created_at_unix : batchCtx.dv_created_at;
  const pvcBound = row.pvc_bound_at_unix;
  const dataDv = row.data_dv_created_at_unix;
  const dataPvcBound = row.data_pvc_bound_at_unix;
  const ts = (unix) => (unix == null ? "" : fmtTs(unix));
  return [
    rowId != null ? String(rowId) : "",
    row.vm_name || "",
    row.namespace || "",
    durationSeconds(snapReady, snap),
    durationSeconds(pvcBound, dv),
    durationSeconds(boot, pvcBound),
    durationSeconds(boot, row.dv_created_at_unix),
    ts(boot),
    ts(batchCtx.started_at),
    ts(baseDv),
    ts(row.base_dv_ready_at_unix),
    ts(baseDvBound),
    ts(snap),
    ts(snapReady),
    ts(dv),
    ts(row.dv_ready_at_unix),
    ts(row.pvc_created_at_unix),
    ts(pvcBound),
    ts(dataDv),
    durationSeconds(dataPvcBound, dataDv),
    ts(row.data_dv_ready_at_unix),
    ts(row.data_pvc_created_at_unix),
    ts(dataPvcBound),
    ts(row.ssh_ready_at_unix),
    durationSeconds(baseDvBound, baseDv),
  ];
}

function batchTimestampRow(v, batchCtx, rowId) {
  return batchTimestampCells(v, batchCtx, rowId).map((c) =>
    c === "" ? "—" : escapeHtml(c)
  );
}

function buildBatchTimestampsCsv(batchCtx, vms) {
  const lines = [BATCH_TS_HEADERS.join(",")];
  (vms || []).forEach((v, i) => {
    lines.push(batchTimestampCells(v, batchCtx, i + 1).map(csvEscape).join(","));
  });
  return `${lines.join("\n")}\n`;
}

/** Max VMs per /vms request (server caps here; larger pages can crash the collector). */
const EXPORT_PAGE_SIZE = 500;

async function fetchAllBatchVms(batchId, onProgress) {
  const probe = await api(
    `/v1/batches/${encodeURIComponent(batchId)}/vms?limit=1&offset=0`
  );
  const total = Number(probe.total || 0);
  if (!total) return [];

  const MAX_EXPORT = 100000;
  if (total > MAX_EXPORT) {
    throw new Error(`batch has ${total} VMs; export supports up to ${MAX_EXPORT}`);
  }

  const all = [];
  let offset = 0;
  while (offset < total) {
    const limit = Math.min(EXPORT_PAGE_SIZE, total - offset);
    const page = await api(
      `/v1/batches/${encodeURIComponent(batchId)}/vms?limit=${limit}&offset=${offset}`
    );
    const chunk = page.items || [];
    if (!chunk.length) break;
    all.push(...chunk);
    offset += chunk.length;
    if (onProgress) onProgress(all.length, total);
  }
  return all;
}

/** Server-paged batch timestamps table (GET /v1/batches/:id/vms). */
async function bindBatchTimestampsPager(batchId, batchCtx, panel) {
  const tbody = panel.querySelector("[data-pager-body]");
  const pagers = [...panel.querySelectorAll("[data-pager-slot]")];
  const empty = panel.querySelector("[data-pager-empty]");
  const tableWrap = panel.querySelector(".table-wrap");
  if (!tbody) return;

  let inflight = 0;

  const paint = async (page, { scroll } = {}) => {
    const req = ++inflight;
    const limit = DEFAULT_PAGE_SIZE;
    const offset = (Math.max(1, page || 1) - 1) * limit;
    tbody.innerHTML = `<tr><td colspan="${BATCH_TS_HEADERS.length}" class="muted">Loading…</td></tr>`;
    try {
      const data = await api(
        `/v1/batches/${encodeURIComponent(batchId)}/vms?limit=${limit}&offset=${offset}`
      );
      if (req !== inflight) return;
      const items = data.items || [];
      const total = Number(data.total || 0);
      if (!total && !items.length) {
        if (tableWrap) tableWrap.style.display = "none";
        pagers.forEach((p) => {
          p.hidden = true;
        });
        if (empty) empty.style.display = "";
        return;
      }
      if (empty) empty.style.display = "none";
      if (tableWrap) tableWrap.style.display = "";
      const meta = pagerMeta(total, Math.floor(offset / limit) + 1, limit);
      tbody.innerHTML = items
        .map(
          (v, i) =>
            `<tr>${batchTimestampRow(v, batchCtx, offset + i + 1)
              .map((c) => `<td class="mono">${c}</td>`)
              .join("")}</tr>`
        )
        .join("");
      for (const pager of pagers) {
        renderPagerControls(pager, meta, (p) => paint(p, { scroll: true }));
      }
      if (scroll && pagers[0]) {
        pagers[0].scrollIntoView({ block: "nearest", behavior: "smooth" });
      }
    } catch (err) {
      if (req !== inflight) return;
      tbody.innerHTML = `<tr><td colspan="${BATCH_TS_HEADERS.length}" class="muted">Failed to load VMs: ${escapeHtml(
        err && err.message ? err.message : String(err)
      )}</td></tr>`;
    }
  };

  await paint(1);
}

async function renderTimestamps(app) {
  setCrumbs([
    { label: "Batches", href: "#/runs" },
    { label: "Timestamps" },
  ]);
  const params = filterQueryParams();
  const data = await api("/v1/timestamps?" + params.toString());
  const items = data.items || [];
  const rows = items.map(crossBatchTimestampRow);
  app.innerHTML = `
    <div class="panel">
      <div class="row" style="justify-content:space-between;align-items:center">
        <div>
          <h2 style="margin:0">Timestamps</h2>
          <div class="muted" style="margin-top:0.35rem">
            ${escapeHtml(String(items.length))} VM row${items.length === 1 ? "" : "s"}
            using the current Batches filters.
            Duration columns are seconds; absolute times are UTC.
          </div>
        </div>
        <div class="actions">
          <a class="btn" href="#/runs">Back to batches</a>
          <button type="button" class="btn primary" id="btn-download-timestamps-csv" ${
            items.length ? "" : "disabled"
          }>Download CSV</button>
        </div>
      </div>
    </div>
    <div class="panel" id="timestamps-table-panel"></div>`;

  mountTimestampsTable($("#timestamps-table-panel"), CROSS_BATCH_TS_HEADERS, rows);

  const btn = $("#btn-download-timestamps-csv");
  if (btn && items.length) {
    btn.onclick = () => {
      const csv = buildCrossBatchTimestampsCsv(items);
      const stamp = new Date().toISOString().replace(/[:.]/g, "-").slice(0, 19);
      downloadTextFile(`all-timestamps-${stamp}Z.csv`, csv, "text/csv;charset=utf-8");
    };
  }
}

async function renderBatchTimestamps(app, batchId) {
  setCrumbs([
    { label: "Batches", href: "#/runs" },
    { label: batchId, href: `#/runs/${encodeURIComponent(batchId)}` },
    { label: "Timestamps" },
  ]);
  const b = await api(
    "/v1/batches/" + encodeURIComponent(batchId) + "?view=summary"
  );
  const batchCtx = batchTimingContext(b);
  const totalVms =
    Number(b.vm_summary?.configured ?? b.total_vms ?? 0) || 0;
  app.innerHTML = `
    <div class="panel">
      <div class="row" style="justify-content:space-between;align-items:center">
        <div>
          <h2 style="margin:0">Timestamps · ${escapeHtml(batchId)}</h2>
          <div class="muted" style="margin-top:0.35rem">
            ${escapeHtml(String(totalVms))} VM row${totalVms === 1 ? "" : "s"}.
            Duration columns are seconds; absolute times are UTC.
          </div>
        </div>
        <div class="actions">
          <a class="btn" href="#/runs/${encodeURIComponent(batchId)}">Back to batch</a>
          <button type="button" class="btn primary" id="btn-download-batch-timestamps-csv" ${
            totalVms ? "" : "disabled"
          }>Download CSV</button>
        </div>
      </div>
    </div>
    <div class="panel" id="batch-timestamps-table-panel">${renderTimestampsTableShell(
      BATCH_TS_HEADERS
    )}</div>`;

  const panel = $("#batch-timestamps-table-panel");
  if (panel) await bindBatchTimestampsPager(batchId, batchCtx, panel);

  const btn = $("#btn-download-batch-timestamps-csv");
  if (btn && totalVms) {
    btn.onclick = async () => {
      const label = btn.textContent;
      btn.disabled = true;
      btn.textContent = "Preparing…";
      try {
        const vms = await fetchAllBatchVms(batchId, (done, total) => {
          btn.textContent = `Preparing… (${done}/${total})`;
        });
        const csv = buildBatchTimestampsCsv(batchCtx, vms);
        downloadTextFile(`${batchId}-creation-timestamps.csv`, csv, "text/csv;charset=utf-8");
      } catch (err) {
        alert(
          "CSV export failed: " + (err && err.message ? err.message : String(err))
        );
      } finally {
        btn.disabled = false;
        btn.textContent = label;
      }
    };
  }
}

async function renderRuns(app) {
  setCrumbs([{ label: "Batches" }]);
  const params = filterQueryParams();
  const data = await api("/v1/batches?" + params.toString());
  const items = data.items || [];
  const facets = data.facets || {};
  const f = state.filters;
  const totals = items.reduce(
    (acc, b) => {
      const s = b.vm_summary || {};
      acc.batches += 1;
      acc.configured += Number(s.configured || b.total_vms || 0);
      acc.checked_in += Number(s.checked_in || 0);
      if (s.vmi_running != null) {
        acc.vmi_running += Number(s.vmi_running || 0);
        acc.vmi_known = true;
      }
      acc.running += Number(s.running || 0);
      acc.idle += Number(s.idle || 0);
      acc.waiting += Number(s.waiting || 0);
      acc.error += Number(s.error || 0);
      return acc;
    },
    {
      batches: 0,
      configured: 0,
      checked_in: 0,
      vmi_running: 0,
      vmi_known: false,
      running: 0,
      idle: 0,
      waiting: 0,
      error: 0,
    }
  );

  const opt = (value, label, selected) =>
    `<option value="${escapeHtml(value)}" ${selected ? "selected" : ""}>${escapeHtml(label)}</option>`;
  const facetOpts = (values, current, emptyLabel) =>
    [opt("", emptyLabel, !current)]
      .concat((values || []).map((v) => opt(v, v, v === current)))
      .join("");

  app.innerHTML = `
    <div class="panel">
      <div class="row" style="justify-content:space-between;align-items:center">
        <div class="muted mono">
          ${escapeHtml(String(totals.batches))} batches ·
          ${escapeHtml(String(totals.configured))} VMs created ·
          ${escapeHtml(String(totals.checked_in))} contacted collector ·
          ${escapeHtml(totals.vmi_known ? String(totals.vmi_running) : "—")} VMI running ·
          ${escapeHtml(String(totals.running))} workload running ·
          ${escapeHtml(String(totals.idle))} idle ·
          ${escapeHtml(String(totals.waiting))} not contacted
          ${totals.error ? ` · ${escapeHtml(String(totals.error))} error` : ""}
        </div>
        <a class="btn" href="#/timestamps">Timestamps</a>
      </div>
      <form id="filter-form" class="filters" autocomplete="off">
        <label class="filter-field">
          <span>Search</span>
          <input type="search" id="filter-q" placeholder="batch / basename / label…" value="${escapeHtml(f.q)}" />
        </label>
        <label class="filter-field">
          <span>Date</span>
          <select id="filter-date-preset">
            ${opt("all", "All dates", f.datePreset === "all")}
            ${opt("today", "Today (UTC)", f.datePreset === "today")}
            ${opt("day", "Specific day…", f.datePreset === "day")}
          </select>
        </label>
        <label class="filter-field" id="filter-date-wrap" style="${f.datePreset === "day" ? "" : "display:none"}">
          <span>Day (UTC)</span>
          <input type="date" id="filter-date" value="${escapeHtml(f.date)}" />
        </label>
        <label class="filter-field">
          <span>Batch</span>
          <input type="search" id="filter-batch" list="facet-batches" placeholder="batch id…" value="${escapeHtml(f.batch_id)}" />
          <datalist id="facet-batches">${(facets.batch_ids || []).map((v) => `<option value="${escapeHtml(v)}">`).join("")}</datalist>
        </label>
        <label class="filter-field">
          <span>Namespace</span>
          <select id="filter-namespace">
            ${facetOpts(facets.namespaces, f.namespace, "All namespaces")}
          </select>
        </label>
        <label class="filter-field">
          <span>API server</span>
          <select id="filter-api-server">
            ${facetOpts(facets.api_servers, f.api_server, "All API servers")}
          </select>
        </label>
        <label class="filter-field">
          <span>Status</span>
          <select id="filter-archived">
            ${opt("0", "Active", f.archived === "0")}
            ${opt("1", "Archived", f.archived === "1")}
            ${opt("all", "All", f.archived === "all")}
          </select>
        </label>
        <div class="filter-actions">
          <button type="submit" class="btn primary" id="filter-apply">Apply</button>
          <button type="button" class="btn" id="filter-clear">Clear</button>
        </div>
      </form>
      ${
        items.length
          ? `<div class="batch-toolbar">
        <label class="check-all-label"><input type="checkbox" id="batch-check-all" ${
          items.length && items.every((b) => state.selectedBatches.has(b.batch_id)) ? "checked" : ""
        } /> Select all</label>
        <button type="button" class="btn danger" id="btn-delete-selected" ${
          state.selectedBatches.size ? "" : "disabled"
        }>Delete selected (${escapeHtml(String(state.selectedBatches.size))})</button>
      </div>
      <div class="table-wrap"><table>
        <thead>
          <tr>
            <th class="col-check"></th>
            <th>Batch</th>
            <th>Basename</th>
            <th>API server</th>
            <th>Namespaces</th>
            <th>Started</th>
            <th>Stopped</th>
            <th>Workload status</th>
            <th>Cycles</th>
            <th>Errors</th>
            <th>IOPS avg</th>
            <th>BW avg</th>
            <th>Workload</th>
            <th></th>
          </tr>
        </thead>
        <tbody>
          ${items
            .map(
              (b) => `<tr class="clickable" data-href="#/runs/${encodeURIComponent(b.batch_id)}">
              <td class="col-check" onclick="event.stopPropagation()">
                <input type="checkbox" class="batch-check" data-batch="${escapeHtml(b.batch_id)}" ${
                  state.selectedBatches.has(b.batch_id) ? "checked" : ""
                } />
              </td>
              <td class="mono">${escapeHtml(b.batch_id)}${b.archived ? ' <span class="badge archived">archived</span>' : ""}</td>
              <td>${escapeHtml(b.basename || "—")}</td>
              <td class="mono" title="${escapeHtml(b.api_server || "")}">${escapeHtml(
                b.api_server
                  ? b.api_server.replace(/^https?:\/\//, "").replace(/:6443$/, "")
                  : "—"
              )}</td>
              <td class="mono">${escapeHtml((b.namespaces || []).join(", ") || "—")}</td>
              <td class="mono">${escapeHtml(fmtTs(b.started_at))}</td>
              <td class="mono">${escapeHtml(fmtTs(b.stopped_at))}</td>
              <td class="muted">${escapeHtml(fmtWorkloadColumn(b.vm_summary))}</td>
              <td>${escapeHtml(String(b.cycle_count ?? 0))}</td>
              <td>${
                b.error_count
                  ? `<span class="badge err">${escapeHtml(String(b.error_count))}</span>`
                  : "0"
              }</td>
              <td>${escapeHtml(fmtNum(b.iops_avg, 0))}</td>
              <td>${escapeHtml(fmtBw(b.bw_avg))}</td>
              <td class="mono">${escapeHtml(b.fingerprint || b.cloudinit || "—")}</td>
              <td class="row-actions" onclick="event.stopPropagation()">
                <a class="btn" href="#/runs/${encodeURIComponent(b.batch_id)}">Open</a>
                <button type="button" class="btn danger btn-delete-batch" data-batch="${escapeHtml(b.batch_id)}">Delete</button>
              </td>
            </tr>`
            )
            .join("")}
        </tbody>
      </table></div>`
          : `<div class="empty">No batches match these filters. POST batch/cycle payloads to <span class="mono">/v1/results</span>.</div>`
      }
    </div>`;

  const syncFiltersFromForm = () => {
    state.filters.q = ($("#filter-q") && $("#filter-q").value.trim()) || "";
    state.filters.archived = ($("#filter-archived") && $("#filter-archived").value) || "0";
    state.filters.datePreset = ($("#filter-date-preset") && $("#filter-date-preset").value) || "all";
    state.filters.date = ($("#filter-date") && $("#filter-date").value) || "";
    state.filters.batch_id = ($("#filter-batch") && $("#filter-batch").value.trim()) || "";
    state.filters.namespace = ($("#filter-namespace") && $("#filter-namespace").value) || "";
    state.filters.api_server = ($("#filter-api-server") && $("#filter-api-server").value) || "";
  };

  const applyFilters = () => {
    syncFiltersFromForm();
    render();
  };

  const updateBulkDeleteBtn = () => {
    const btn = $("#btn-delete-selected");
    const all = $("#batch-check-all");
    if (btn) {
      btn.disabled = state.selectedBatches.size === 0;
      btn.textContent = `Delete selected (${state.selectedBatches.size})`;
    }
    if (all && items.length) {
      all.checked = items.every((b) => state.selectedBatches.has(b.batch_id));
      all.indeterminate =
        !all.checked && items.some((b) => state.selectedBatches.has(b.batch_id));
    }
  };

  $("#filter-date-preset").onchange = () => {
    const wrap = $("#filter-date-wrap");
    const preset = $("#filter-date-preset").value;
    wrap.style.display = preset === "day" ? "" : "none";
    if (preset === "day" && !$("#filter-date").value) {
      $("#filter-date").value = new Date().toISOString().slice(0, 10);
    }
    // For "day", wait until the date input is set; still apply (uses today's date default).
    applyFilters();
  };
  ["filter-namespace", "filter-api-server", "filter-archived", "filter-date"].forEach((id) => {
    const el = $("#" + id);
    if (el) el.onchange = applyFilters;
  });
  $("#filter-form").onsubmit = (e) => {
    e.preventDefault();
    applyFilters();
  };
  $("#filter-clear").onclick = () => {
    clearFilters();
    render();
  };

  // Drop selections that are no longer in the current list.
  const visibleIds = new Set(items.map((b) => b.batch_id));
  for (const id of [...state.selectedBatches]) {
    if (!visibleIds.has(id)) state.selectedBatches.delete(id);
  }
  updateBulkDeleteBtn();

  const checkAll = $("#batch-check-all");
  if (checkAll) {
    checkAll.onchange = () => {
      if (checkAll.checked) items.forEach((b) => state.selectedBatches.add(b.batch_id));
      else items.forEach((b) => state.selectedBatches.delete(b.batch_id));
      app.querySelectorAll(".batch-check").forEach((cb) => {
        cb.checked = checkAll.checked;
      });
      updateBulkDeleteBtn();
    };
  }
  app.querySelectorAll(".batch-check").forEach((cb) => {
    cb.onchange = () => {
      const id = cb.getAttribute("data-batch");
      if (!id) return;
      if (cb.checked) state.selectedBatches.add(id);
      else state.selectedBatches.delete(id);
      updateBulkDeleteBtn();
    };
  });
  const deleteSelected = $("#btn-delete-selected");
  if (deleteSelected) {
    deleteSelected.onclick = async () => {
      const ids = [...state.selectedBatches];
      if (!ids.length) return;
      if (
        !confirm(
          `Delete ${ids.length} batch${ids.length === 1 ? "" : "es"} (${ids.join(", ")}) and all stored payloads?`
        )
      ) {
        return;
      }
      try {
        for (const id of ids) {
          await api("/v1/batches/" + encodeURIComponent(id), { method: "DELETE" });
          state.selectedBatches.delete(id);
        }
        render();
      } catch (err) {
        alert("Delete failed: " + (err && err.message ? err.message : err));
        render();
      }
    };
  }

  app.querySelectorAll("tr.clickable").forEach((tr) => {
    tr.onclick = (e) => {
      if (e.target.closest("a, button, .row-actions, .col-check, input")) return;
      location.hash = tr.dataset.href;
    };
  });
  app.querySelectorAll(".btn-delete-batch").forEach((btn) => {
    btn.onclick = async (e) => {
      e.preventDefault();
      e.stopPropagation();
      const id = btn.getAttribute("data-batch");
      if (!id) return;
      if (!confirm(`Delete batch ${id} and all stored payloads?`)) return;
      try {
        await api("/v1/batches/" + encodeURIComponent(id), { method: "DELETE" });
        state.selectedBatches.delete(id);
        render();
      } catch (err) {
        alert("Delete failed: " + (err && err.message ? err.message : err));
      }
    };
  });
}

async function renderRun(app, batchId) {
  const summaryTitle = `${batchId}-Summary`;
  setCrumbs([
    { label: "Batches", href: "#/runs" },
    { label: summaryTitle },
  ]);
  // Summary view avoids loading the full manifest / all VMs; table pages fetch separately.
  const b = await api(
    "/v1/batches/" + encodeURIComponent(batchId) + "?view=summary"
  );
  const bp = b.batch_payload || {};
  const batchResultId = b.batch_result_id;
  const vs = b.vm_summary || {};
  const bootStats = b.boot_stats || {};
  const bootSummary =
    bootStats.count > 0
      ? `${bootStats.label || "Boot time"} avg ${Math.round(bootStats.avg_s)}s · min ${Math.round(
          bootStats.min_s
        )}s · max ${Math.round(bootStats.max_s)}s`
      : "Boot time …";
  const guestEnvLines = formatGuestEnv(bp.guest_env);
  const totalVms = Number(b.total_vms != null ? b.total_vms : vs.configured) || 0;

  app.innerHTML = `
    <div class="panel">
      <div class="row" style="justify-content:space-between">
        <div>
          <h2 style="margin:0">${escapeHtml(summaryTitle)} ${b.archived ? '<span class="badge archived">archived</span>' : ""}</h2>
          <div class="muted">${escapeHtml(b.basename || "")} · ${escapeHtml(b.fingerprint || b.cloudinit || "")}</div>
          <div class="muted" style="margin-top:0.35rem">${escapeHtml(fmtWorkloadColumn(vs))}</div>
          <div class="muted mono" style="margin-top:0.35rem">
            <span id="boot-summary">${escapeHtml(bootSummary)}</span>
            · <a href="#/runs/${encodeURIComponent(batchId)}/timestamps">View object creation timestamps</a>
          </div>
        </div>
        <div class="actions">
          ${batchResultId ? `<a class="btn" href="#/runs/${encodeURIComponent(batchId)}/payload/${encodeURIComponent(batchResultId)}">View manifest</a>` : ""}
          <button type="button" class="btn" id="btn-archive">${b.archived ? "Unarchive" : "Archive"}</button>
          <button type="button" class="btn danger" id="btn-delete">Delete</button>
        </div>
      </div>
      <div class="grid-2" style="margin-top:1rem">
        <dl class="kv">
          <dt>Batch started</dt><dd class="mono">${escapeHtml(fmtTs(b.started_at))}</dd>
          <dt>VMs</dt><dd>${escapeHtml(String(b.total_vms ?? "—"))}</dd>
          <dt>Namespaces</dt><dd>${escapeHtml(String(b.total_namespaces ?? "—"))}</dd>
          <dt>DVs</dt><dd>${escapeHtml(String(b.dv_count ?? "—"))}</dd>
          <dt>PVCs</dt><dd>${escapeHtml(String(b.pvc_count ?? "—"))}</dd>
        </dl>
        <div>
          <h3 style="margin-top:0">vstorm metadata</h3>
          <dl class="kv">
            <dt>API server</dt><dd class="mono">${escapeHtml((bp.cluster && bp.cluster.api_server) || "—")}</dd>
            <dt>Nodes</dt><dd>${escapeHtml(
              bp.cluster && (bp.cluster.worker_nodes != null || bp.cluster.master_nodes != null)
                ? `${bp.cluster.worker_nodes ?? "—"} worker / ${bp.cluster.master_nodes ?? "—"} master`
                : "—"
            )}</dd>
            <dt>oc version</dt><dd class="mono" style="white-space:pre-wrap">${escapeHtml((bp.cluster && bp.cluster.oc_version) || "—")}</dd>
            <dt>Namespaces</dt><dd class="mono">${escapeHtml((bp.namespaces || []).join(", ") || "—")}</dd>
            <dt>Storage</dt><dd>${escapeHtml(bp.storage_class || "—")} / ${escapeHtml(bp.volume_mode || "—")}</dd>
            <dt>Cmdline</dt><dd class="mono">${escapeHtml((bp.cmdline || []).join(" ") || "—")}</dd>
            <dt>FIO / guest env</dt><dd class="mono" style="white-space:pre-wrap">${escapeHtml(guestEnvLines)}</dd>
            <dt>Notes</dt><dd><input type="text" id="notes" style="width:100%" value="${escapeHtml(b.notes || "")}" placeholder="Notes…" /></dd>
            <dt>Label</dt><dd><input type="text" id="label" style="width:100%" value="${escapeHtml(b.label || "")}" placeholder="Label…" /></dd>
          </dl>
          <button type="button" class="btn primary" id="btn-save-meta">Save notes/label</button>
        </div>
      </div>
      <p class="muted" style="margin-top:1rem;margin-bottom:0">
        FIO knobs are set once at VM create (<span class="mono">vstorm --env FIO_*=…</span>).
        Each guest runs one fio job and POSTs one result when finished.
      </p>
    </div>

    <div class="panel">
      <h3 style="margin-top:0">VMs${
        totalVms ? ` <span class="muted" style="font-weight:normal">(${escapeHtml(String(totalVms))})</span>` : ""
      }</h3>
      <div class="pager" id="vms-pager-top" hidden></div>
      <div class="table-wrap"><table>
        <thead><tr><th>VM</th><th class="sortable" data-sort="dv_creation_s" title="PVC bound − DV created (seconds). Click to sort."><span class="sort-label">dv_creation_s</span><span class="sort-indicator" aria-hidden="true">↕</span></th><th class="sortable" data-sort="vm_provision_s" title="Boot − PVC bound (seconds). Click to sort."><span class="sort-label">vm_provision_s</span><span class="sort-indicator" aria-hidden="true">↕</span></th><th class="sortable" data-sort="vm_ready_s" title="Boot − DV created (seconds). Click to sort."><span class="sort-label">vm_ready_s</span><span class="sort-indicator" aria-hidden="true">↕</span></th><th class="sortable" data-sort="boot_timestamp" title="UTC when network-online.target is reached (vstorm-boot-timestamp.service). Click to sort."><span class="sort-label">Boot @ net-online</span><span class="sort-indicator" aria-hidden="true">↕</span></th><th>Mode</th><th>data_dv_creation_s</th><th>Workload status</th></tr></thead>
        <tbody id="vms-tbody"><tr><td colspan="8" class="muted">Loading…</td></tr></tbody>
      </table></div>
      <div class="pager" id="vms-pager-bottom" hidden></div>
      <div class="empty" id="vms-empty" style="display:none">No VMs listed yet.</div>
    </div>

    <div class="panel">
      <h3 style="margin-top:0">DV create → guest boot</h3>
      <p class="muted" style="margin-top:0">
        Seconds from DataVolume <span class="mono">creationTimestamp</span> (per-VM when known, else earliest in batch; falls back to vstorm start) to the guest boot timestamp (UTC).
      </p>
      <div class="chart-wrap"><canvas id="boot-chart"></canvas></div>
      <div id="boot-chart-empty" class="empty" style="display:none">No boot timestamps yet.</div>
      <div id="boot-chart-stats" class="muted mono" style="margin-top:0.5rem"></div>
    </div>`;

  drawBootHistogram([]); // placeholder until async chart loads
  loadBootChart(batchId);

  $("#btn-archive").onclick = async () => {
    try {
      await api("/v1/batches/" + encodeURIComponent(batchId), {
        method: "PATCH",
        body: JSON.stringify({ archived: !b.archived }),
      });
      render();
    } catch (err) {
      alert("Archive failed: " + (err && err.message ? err.message : err));
    }
  };
  $("#btn-delete").onclick = async () => {
    if (!confirm(`Delete batch ${batchId} and all stored payloads?`)) return;
    try {
      await api("/v1/batches/" + encodeURIComponent(batchId), { method: "DELETE" });
      location.hash = "#/runs";
    } catch (err) {
      alert("Delete failed: " + (err && err.message ? err.message : err));
    }
  };
  $("#btn-save-meta").onclick = async () => {
    await api("/v1/batches/" + encodeURIComponent(batchId), {
      method: "PATCH",
      body: JSON.stringify({
        notes: $("#notes").value,
        label: $("#label").value,
      }),
    });
    render();
  };

  await bindServerVmPager(batchId);
}

function vmRowHtml(batchId, v) {
  const dvCreation = durationSeconds(v.pvc_bound_at_unix, v.dv_created_at_unix);
  const dataDvCreation = durationSeconds(v.data_pvc_bound_at_unix, v.data_dv_created_at_unix);
  const vmReady = durationSeconds(v.boot_timestamp_unix, v.dv_created_at_unix);
  const vmProvision = durationSeconds(v.boot_timestamp_unix, v.pvc_bound_at_unix);
  return `<tr class="clickable" data-href="#/runs/${encodeURIComponent(batchId)}/vms/${encodeURIComponent(v.vm_name)}">
              <td class="mono"><a href="#/runs/${encodeURIComponent(batchId)}/vms/${encodeURIComponent(v.vm_name)}">${escapeHtml(v.vm_name)}</a></td>
              <td class="mono">${dvCreation === "" ? "—" : escapeHtml(dvCreation)}</td>
              <td class="mono">${vmProvision === "" ? "—" : escapeHtml(vmProvision)}</td>
              <td class="mono">${vmReady === "" ? "—" : escapeHtml(vmReady)}</td>
              <td class="mono">${escapeHtml(fmtTs(v.boot_timestamp_unix))}</td>
              <td class="mono">${escapeHtml(v.policy_mode || "—")}${
                v.policy_remaining != null ? ` · ${escapeHtml(String(v.policy_remaining))}` : ""
              }</td>
              <td class="mono">${dataDvCreation === "" ? "—" : escapeHtml(dataDvCreation)}</td>
              <td>${escapeHtml(fmtWorkloadStatus(v.ui_status))}</td>
            </tr>`;
}

/** Server-side VM table pages (GET /v1/batches/:id/vms?limit&offset&sort&order). */
async function bindServerVmPager(batchId) {
  const tbody = $("#vms-tbody");
  const empty = $("#vms-empty");
  const tableWrap = tbody && tbody.closest(".table-wrap");
  const table = tbody && tbody.closest("table");
  const pagers = [$("#vms-pager-top"), $("#vms-pager-bottom")].filter(Boolean);
  if (!tbody) return;

  let current = 1;
  let inflight = 0;
  let sortCol = "vm_name";
  let sortDir = "asc";

  const updateSortHeaders = () => {
    if (!table) return;
    for (const th of table.querySelectorAll("th.sortable")) {
      const col = th.dataset.sort;
      const indicator = th.querySelector(".sort-indicator");
      th.classList.remove("sort-asc", "sort-desc");
      if (col === sortCol) {
        th.classList.add(sortDir === "asc" ? "sort-asc" : "sort-desc");
        th.setAttribute("aria-sort", sortDir === "asc" ? "ascending" : "descending");
        if (indicator) indicator.textContent = sortDir === "asc" ? "↑" : "↓";
      } else {
        th.setAttribute("aria-sort", "none");
        if (indicator) indicator.textContent = "↕";
      }
    }
  };

  if (table && !table.dataset.sortBound) {
    table.dataset.sortBound = "1";
    for (const th of table.querySelectorAll("th.sortable")) {
      th.addEventListener("click", () => {
        const col = th.dataset.sort;
        if (!col) return;
        if (sortCol === col) sortDir = sortDir === "asc" ? "desc" : "asc";
        else {
          sortCol = col;
          sortDir = "asc";
        }
        updateSortHeaders();
        paint(1);
      });
    }
  }
  updateSortHeaders();

  const paint = async (nextPage, { scroll } = {}) => {
    const page = Math.max(1, nextPage || 1);
    const req = ++inflight;
    const limit = DEFAULT_PAGE_SIZE;
    const offset = (page - 1) * limit;
    tbody.innerHTML = `<tr><td colspan="8" class="muted">Loading…</td></tr>`;
    try {
      const sortQs =
        sortCol === "vm_name"
          ? ""
          : `&sort=${encodeURIComponent(sortCol)}&order=${encodeURIComponent(sortDir)}`;
      const data = await api(
        `/v1/batches/${encodeURIComponent(batchId)}/vms?limit=${limit}&offset=${offset}${sortQs}`
      );
      if (req !== inflight) return;
      const items = data.items || [];
      const total = Number(data.total || 0);
      current = page;
      if (!total && !items.length) {
        if (tableWrap) tableWrap.style.display = "none";
        pagers.forEach((p) => {
          p.hidden = true;
        });
        if (empty) empty.style.display = "";
        return;
      }
      if (empty) empty.style.display = "none";
      if (tableWrap) tableWrap.style.display = "";
      const meta = pagerMeta(total, page, limit);
      current = meta.page;
      tbody.innerHTML = items.map((v) => vmRowHtml(batchId, v)).join("");
      for (const pager of pagers) {
        renderPagerControls(pager, meta, (p) => paint(p, { scroll: true }));
      }
      bindClickableRows(tbody);
      updateSortHeaders();
      if (scroll && pagers[0]) {
        pagers[0].scrollIntoView({ block: "nearest", behavior: "smooth" });
      }
    } catch (err) {
      if (req !== inflight) return;
      tbody.innerHTML = `<tr><td colspan="8" class="muted">Failed to load VMs: ${escapeHtml(
        err && err.message ? err.message : String(err)
      )}</td></tr>`;
    }
  };

  await paint(1);
}

function downloadTextFile(filename, text, mime) {
  if (state.downloadUrl) {
    URL.revokeObjectURL(state.downloadUrl);
    state.downloadUrl = null;
  }
  const blob = new Blob([text], { type: mime || "text/plain;charset=utf-8" });
  const url = URL.createObjectURL(blob);
  state.downloadUrl = url;
  const a = document.createElement("a");
  a.href = url;
  a.download = filename;
  document.body.appendChild(a);
  a.click();
  a.remove();
}

/** Fetch boot-duration samples after the page shell is up (avoids O(n) summary payload). */
async function loadBootChart(batchId) {
  const statsEl = $("#boot-chart-stats");
  const summaryEl = $("#boot-summary");
  try {
    const data = await api(
      `/v1/batches/${encodeURIComponent(batchId)}/boot-chart`
    );
    if (summaryEl) {
      if (data.count > 0) {
        const label = data.label || "Boot time";
        summaryEl.textContent =
          `${label} avg ${Math.round(data.avg_s)}s · min ${Math.round(data.min_s)}s · max ${Math.round(
            data.max_s
          )}s · n=${data.count}`;
      } else {
        summaryEl.textContent = "Boot time —";
      }
    }
    drawBootHistogramFromSamples(data.samples || [], data);
  } catch (err) {
    if (summaryEl) summaryEl.textContent = "Boot time —";
    if (statsEl) {
      statsEl.textContent =
        "Boot chart unavailable: " + (err && err.message ? err.message : err);
    }
  }
}

function drawBootHistogram(vms, startedAt, dvCreatedAt) {
  drawBootHistogramFromSamples(bootDurationsSeconds(vms, startedAt, dvCreatedAt));
}

function drawBootHistogramFromSamples(samples, stats) {
  const canvas = $("#boot-chart");
  const emptyEl = $("#boot-chart-empty");
  const statsEl = $("#boot-chart-stats");
  if (!canvas || typeof Chart === "undefined") return;

  if (!samples.length) {
    canvas.style.display = "none";
    if (emptyEl) emptyEl.style.display = "";
    if (statsEl) statsEl.textContent = "";
    return;
  }
  canvas.style.display = "";
  if (emptyEl) emptyEl.style.display = "none";

  const seconds = samples.map((s) => s.seconds);
  const { labels, counts, edges } = histogramBins(seconds);
  const sorted = [...seconds].sort((a, b) => a - b);
  const avg =
    stats && stats.avg_s != null
      ? Number(stats.avg_s)
      : seconds.reduce((a, b) => a + b, 0) / seconds.length;
  const minS = stats && stats.min_s != null ? Number(stats.min_s) : sorted[0];
  const maxS =
    stats && stats.max_s != null ? Number(stats.max_s) : sorted[sorted.length - 1];
  if (statsEl) {
    statsEl.textContent =
      `${samples.length} VMs · min ${Math.round(minS)}s · ` +
      `avg ${Math.round(avg)}s · max ${Math.round(maxS)}s`;
  }

  if (state.chart) {
    try {
      state.chart.destroy();
    } catch {
      /* ignore */
    }
    state.chart = null;
  }

  state.chart = new Chart(canvas, {
    type: "bar",
    data: {
      labels,
      datasets: [
        {
          label: "VMs",
          data: counts,
          backgroundColor: "rgba(9, 105, 218, 0.65)",
          borderColor: "#0969da",
          borderWidth: 1,
        },
      ],
    },
    options: {
      responsive: true,
      maintainAspectRatio: false,
      plugins: {
        legend: { display: false },
        tooltip: {
          callbacks: {
            afterBody(items) {
              if (!items.length) return "";
              const idx = items[0].dataIndex;
              const a = edges[idx];
              const b = edges[idx + 1];
              const last = idx === counts.length - 1;
              const names = samples
                .filter((s) => s.seconds >= a && (last ? s.seconds <= b : s.seconds < b))
                .map((s) => s.vm_name);
              return names.length ? names.slice(0, 8).join("\n") + (names.length > 8 ? "\n…" : "") : "";
            },
          },
        },
      },
      scales: {
        x: { title: { display: true, text: "Create → guest boot (seconds)" } },
        y: {
          beginAtZero: true,
          ticks: { stepSize: 1, precision: 0 },
          title: { display: true, text: "VM count" },
        },
      },
    },
  });
}

async function renderVm(app, batchId, vm) {
  setCrumbs([
    { label: "Batches", href: "#/runs" },
    { label: batchId, href: `#/runs/${encodeURIComponent(batchId)}` },
    { label: vm },
  ]);
  const data = await api(
    `/v1/batches/${encodeURIComponent(batchId)}/vms/${encodeURIComponent(vm)}`
  );
  const id = data.identity || {};
  const cycles = data.cycles || [];
  const policy = data.policy || {};

  app.innerHTML = `
    <div class="panel">
      <div class="row" style="justify-content:space-between;align-items:flex-start">
        <div>
          <h2 style="margin-top:0">${escapeHtml(vm)}</h2>
          <dl class="kv">
            <dt>Hostname</dt><dd class="mono">${escapeHtml(id.hostname || "—")}</dd>
            <dt>CPU / RAM</dt><dd>${escapeHtml(String(id.cpu_count ?? "—"))} / ${escapeHtml(
              id.mem_total_kb != null ? fmtNum(id.mem_total_kb, 0) + " KiB" : "—"
            )}</dd>
            <dt title="UTC when network-online.target is reached (vstorm-boot-timestamp.service)">Boot @ net-online</dt><dd class="mono">${escapeHtml(fmtTs(id.boot_timestamp_unix))}</dd>
            <dt>First report lag</dt><dd>${escapeHtml(
              id.first_report_lag_s != null ? id.first_report_lag_s + "s" : "—"
            )}</dd>
            <dt>Mode</dt><dd class="mono">${escapeHtml(policy.mode || "—")} · remaining=${escapeHtml(
              String(policy.remaining ?? "—")
            )} · rev=${escapeHtml(String(policy.revision ?? "—"))}</dd>
          </dl>
        </div>
      </div>
    </div>
    <div class="panel">
      <h3 style="margin-top:0">Cycles${
        cycles.length ? ` <span class="muted" style="font-weight:normal">(${escapeHtml(String(cycles.length))})</span>` : ""
      }</h3>
      ${
        cycles.length
          ? `<div class="pager" id="cycles-pager-top" hidden></div>
        <div class="table-wrap"><table>
        <thead><tr><th>Cycle</th><th>Type</th><th>Status</th><th>fio start</th><th>fio stop</th><th>Duration</th><th>fio_rc</th><th>IOPS avg</th><th>BW avg</th><th>Error</th><th></th></tr></thead>
        <tbody id="cycles-tbody"></tbody>
      </table></div>
      <div class="pager" id="cycles-pager-bottom" hidden></div>`
          : `<div class="empty">Waiting for guest results.</div>`
      }
    </div>`;

  const cyclesTbody = $("#cycles-tbody");
  if (cyclesTbody && cycles.length) {
    const rowHtmls = cycles.map((c) => {
      const bad =
        (c.status && c.status !== "ok") ||
        (c.fio_rc != null && Number(c.fio_rc) !== 0);
      return `<tr class="clickable${bad ? " row-error" : ""}" data-href="#/runs/${encodeURIComponent(batchId)}/payload/${encodeURIComponent(c.result_id)}">
              <td>${escapeHtml(String(c.cycle ?? "—"))}</td>
              <td class="mono">${escapeHtml(c.record_type || "result")}</td>
              <td>${statusBadge(c.status, c.fio_rc)}</td>
              <td class="mono">${escapeHtml(fmtTs(c.started_at))}</td>
              <td class="mono">${escapeHtml(fmtTs(c.stopped_at))}</td>
              <td>${escapeHtml(c.duration_s != null ? c.duration_s + "s" : "—")}</td>
              <td>${escapeHtml(String(c.fio_rc ?? "—"))}</td>
              <td>${escapeHtml(fmtNum(c.iops, 0))}</td>
              <td>${escapeHtml(fmtBw(c.bw_bytes))}</td>
              <td class="muted">${escapeHtml(c.error_message || "—")}</td>
              <td><a href="#/runs/${encodeURIComponent(batchId)}/payload/${encodeURIComponent(c.result_id)}">Payload</a></td>
            </tr>`;
    });
    bindPaginatedTable({
      tbody: cyclesTbody,
      pagers: [$("#cycles-pager-top"), $("#cycles-pager-bottom")].filter(Boolean),
      rowHtmls,
      onRendered: () => bindClickableRows(cyclesTbody),
    });
  }
}

async function renderCycle(app, batchId, vm, cycle) {
  const list = await api(
    `/v1/batches/${encodeURIComponent(batchId)}/results?vm=${encodeURIComponent(vm)}&record_type=result&limit=500`
  );
  const match = (list.items || []).find((r) => String(r.cycle) === String(cycle));
  if (!match) throw new Error(`cycle ${cycle} not found for ${vm}`);
  location.replace(`#/runs/${encodeURIComponent(batchId)}/payload/${encodeURIComponent(match.result_id)}`);
}

async function renderPayload(app, batchId, resultId) {
  const data = await api(
    `/v1/batches/${encodeURIComponent(batchId)}/results/${encodeURIComponent(resultId)}`
  );
  const meta = data.meta || {};
  const payload = data.payload || {};
  const fio = payload.fio_group_reporting;

  setCrumbs([
    { label: "Batches", href: "#/runs" },
    { label: batchId, href: `#/runs/${encodeURIComponent(batchId)}` },
    ...(meta.vm_name
      ? [{ label: meta.vm_name, href: `#/runs/${encodeURIComponent(batchId)}/vms/${encodeURIComponent(meta.vm_name)}` }]
      : []),
    { label: "Payload" },
  ]);

  app.innerHTML = `
    <div class="panel">
      <div class="row" style="justify-content:space-between">
        <div>
          <h2 style="margin:0">Payload</h2>
          <div class="muted mono">${escapeHtml([meta.record_type, meta.source, meta.workload_kind].filter(Boolean).join(" · "))} · ${escapeHtml(resultId)}</div>
        </div>
        <div class="actions">
          <button type="button" class="btn" id="btn-copy">Copy JSON</button>
          <a class="btn" id="btn-download" href="#">Download</a>
        </div>
      </div>
      <dl class="kv" style="margin-top:1rem">
        <dt>fio start</dt><dd class="mono">${escapeHtml(displayTs(payload.fio_start, payload.fio_start_unix, payload.started_at))}</dd>
        <dt>fio stop</dt><dd class="mono">${escapeHtml(displayTs(payload.fio_stop, payload.fio_stop_unix, payload.stopped_at))}</dd>
        <dt>Reported</dt><dd class="mono">${escapeHtml(displayTs(payload.reported_at, payload.reported_at_unix))}</dd>
        <dt>Command</dt><dd class="mono">${escapeHtml(
          Array.isArray(payload.fio_command) ? payload.fio_command.join(" ") : (payload.cmdline || []).join?.(" ") || "—"
        )}</dd>
        <dt>Exit / status</dt><dd>${escapeHtml(String(payload.fio_rc ?? "—"))} ${statusBadge(payload.status, payload.fio_rc)}</dd>
        <dt>Error</dt><dd>${escapeHtml(payload.error_message || "—")}</dd>
      </dl>
    </div>
    ${
      fio
        ? `<div class="panel">
      <h3 style="margin-top:0">fio_group_reporting</h3>
      <pre class="payload">${escapeHtml(JSON.stringify(fio, null, 2))}</pre>
    </div>`
        : ""
    }
    <div class="panel">
      <h3 style="margin-top:0">Raw payload</h3>
      <pre class="payload" id="raw-json">${escapeHtml(JSON.stringify(payload, null, 2))}</pre>
    </div>`;

  const raw = JSON.stringify(payload, null, 2);
  $("#btn-copy").onclick = async () => {
    await navigator.clipboard.writeText(raw);
    $("#btn-copy").textContent = "Copied";
    setTimeout(() => ($("#btn-copy").textContent = "Copy JSON"), 1200);
  };
  if (state.downloadUrl) {
    URL.revokeObjectURL(state.downloadUrl);
    state.downloadUrl = null;
  }
  const blob = new Blob([raw], { type: "application/json" });
  const url = URL.createObjectURL(blob);
  state.downloadUrl = url;
  const dl = $("#btn-download");
  dl.href = url;
  dl.download = `${batchId}-${resultId.slice(0, 8)}.json`;
}

function clearFilters() {
  state.filters = {
    q: "",
    archived: "0",
    datePreset: "all",
    date: "",
    batch_id: "",
    namespace: "",
    api_server: "",
  };
  state.selectedBatches.clear();
}

function setupApiBase() {
  const input = $("#api-base");
  const btn = $("#btn-api-apply");
  if (!input || !btn) return;
  input.value = currentApiBase();
  const apply = () => {
    setStoredApiBase(input.value);
    input.value = currentApiBase();
    apiCache.clear();
    render();
  };
  btn.onclick = apply;
  input.addEventListener("keydown", (e) => {
    if (e.key === "Enter") {
      e.preventDefault();
      apply();
    }
  });
}

function setupRefresh() {
  $("#btn-refresh").onclick = () => {
    state.bypassCacheOnce = true;
    render();
  };
  const box = $("#auto-refresh");
  const arm = () => {
    if (state.timer) clearInterval(state.timer);
    if (box.checked) {
      state.timer = setInterval(() => {
        const ae = document.activeElement;
        if (ae && (ae.tagName === "INPUT" || ae.tagName === "SELECT" || ae.tagName === "TEXTAREA")) {
          return;
        }
        render();
      }, 5000);
    }
  };
  box.onchange = arm;
  arm();
}

function setupBrandHome() {
  const brand = document.querySelector(".brand-title");
  if (!brand) return;
  brand.addEventListener("click", (e) => {
    e.preventDefault();
    clearFilters();
    if (location.hash === "#/runs" || location.hash === "#/" || !location.hash) {
      render();
    } else {
      location.hash = "#/runs";
    }
  });
}

window.addEventListener("hashchange", () => render());
window.addEventListener("DOMContentLoaded", () => {
  consumeApiQueryParam();
  if (!location.hash) location.hash = "#/runs";
  setupApiBase();
  setupRefresh();
  setupBrandHome();
  render();
});
