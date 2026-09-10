#!/usr/bin/env node
"use strict";

const { describe, it } = require("node:test");
const assert = require("node:assert/strict");
const path = require("node:path");

const lib = require(path.join(
  __dirname,
  "..",
  "data-collector",
  "static",
  "dashboard-lib.js"
));

describe("fmtTs", () => {
  it("formats unix seconds as UTC Z", () => {
    assert.equal(lib.fmtTs(1784699425), "2026-07-22T05:50:25Z");
  });

  it("passes through ISO with Z", () => {
    assert.equal(lib.fmtTs("2026-07-22T05:50:25Z"), "2026-07-22T05:50:25Z");
  });

  it("treats naive ISO as UTC", () => {
    assert.equal(lib.fmtTs("2026-07-22T05:50:25"), "2026-07-22T05:50:25Z");
  });

  it("returns em dash for null", () => {
    assert.equal(lib.fmtTs(null), "—");
  });
});

describe("fmtWorkloadStatus / fmtWorkloadColumn", () => {
  it("maps only running to running", () => {
    assert.equal(lib.fmtWorkloadStatus("running"), "running");
    assert.equal(lib.fmtWorkloadStatus("idle"), "idle");
    assert.equal(lib.fmtWorkloadStatus("waiting"), "idle");
    assert.equal(lib.fmtWorkloadStatus("queued"), "idle");
  });

  it("formats running/idle column from summary", () => {
    assert.equal(
      lib.fmtWorkloadColumn({ configured: 8, running: 2, idle: 6 }),
      "2 running · 6 idle"
    );
    assert.equal(lib.fmtWorkloadColumn(null), "—");
  });
});

describe("parseRoute", () => {
  it("defaults to runs list", () => {
    assert.deepEqual(lib.parseRoute("#/runs"), { name: "runs" });
    assert.deepEqual(lib.parseRoute(""), { name: "runs" });
  });

  it("parses batch detail", () => {
    assert.deepEqual(lib.parseRoute("#/runs/a1b2c3"), {
      name: "run",
      batchId: "a1b2c3",
    });
  });

  it("parses vm and cycle routes", () => {
    assert.deepEqual(lib.parseRoute("#/runs/a1b2c3/vms/vm-1"), {
      name: "vm",
      batchId: "a1b2c3",
      vm: "vm-1",
    });
    assert.deepEqual(lib.parseRoute("#/runs/a1b2c3/vms/vm-1/cycles/2"), {
      name: "cycle",
      batchId: "a1b2c3",
      vm: "vm-1",
      cycle: "2",
    });
  });

  it("parses timestamps routes", () => {
    assert.deepEqual(lib.parseRoute("#/timestamps"), { name: "timestamps" });
    assert.deepEqual(lib.parseRoute("#/runs/a1b2c3/timestamps"), {
      name: "batch-timestamps",
      batchId: "a1b2c3",
    });
  });

  it("parses payload route", () => {
    assert.deepEqual(lib.parseRoute("#/runs/a1b2c3/payload/deadbeef"), {
      name: "payload",
      batchId: "a1b2c3",
      resultId: "deadbeef",
    });
  });
});

describe("boot durations and CSV", () => {
  const started = 1000;
  const dvCreated = 1020;
  const vms = [
    { vm_name: "vm-a", namespace: "ns1", boot_timestamp_unix: 1045, dv_created_at_unix: 1020 },
    { vm_name: "vm-b", namespace: "ns1", boot_timestamp_unix: 1100, dv_created_at_unix: 1030 },
    { vm_name: "vm-c", namespace: "ns1", boot_timestamp_unix: null },
  ];

  it("computes DV→boot durations preferring per-VM dv_created", () => {
    assert.deepEqual(lib.bootDurationsSeconds(vms, started, dvCreated), [
      { vm_name: "vm-a", seconds: 25 },
      { vm_name: "vm-b", seconds: 70 },
    ]);
  });

  it("skips VMs missing per-VM dv when any VM has dv_created", () => {
    const mixed = [
      { vm_name: "vm-a", boot_timestamp_unix: 1060, dv_created_at_unix: 1000 },
      { vm_name: "vm-b", boot_timestamp_unix: 5000, dv_created_at_unix: null },
    ];
    assert.deepEqual(lib.bootDurationsSeconds(mixed, 900, 1000), [
      { vm_name: "vm-a", seconds: 60 },
    ]);
  });

  it("falls back to batch started_at when no DV times", () => {
    const plain = [
      { vm_name: "vm-a", boot_timestamp_unix: 1045 },
      { vm_name: "vm-b", boot_timestamp_unix: 1100 },
    ];
    assert.deepEqual(lib.bootDurationsSeconds(plain, started), [
      { vm_name: "vm-a", seconds: 45 },
      { vm_name: "vm-b", seconds: 100 },
    ]);
  });

  it("summarizes avg/min/max", () => {
    assert.equal(
      lib.fmtBootTimeSummary(vms, started, dvCreated),
      "DV→boot avg 48s · min 25s · max 70s"
    );
    assert.equal(lib.fmtBootTimeSummary([], started), "Boot time —");
  });

  it("builds boot times CSV with DV columns", () => {
    const csv = lib.buildBootTimesCsv("a1b2c3", vms, started, dvCreated);
    const lines = csv.trim().split("\n");
    assert.equal(
      lines[0],
      "batch_id,vm_name,namespace,base_dv_creation_s,snapshot_creation_s,dv_creation_s,data_dv_creation_s,vm_ready_s,vm_provision_s,batch_started_at_utc,base_dv_created_at_utc,base_dv_ready_at_utc,base_dv_bound_at_utc,snapshot_created_at_utc,snapshot_ready_at_utc,dv_created_at_utc,dv_ready_at_utc,pvc_created_at_utc,pvc_bound_at_utc,data_dv_created_at_utc,data_dv_ready_at_utc,data_pvc_created_at_utc,data_pvc_bound_at_utc,ssh_ready_at_utc,boot_timestamp_utc"
    );
    const a = lines[1].split(",");
    const b = lines[2].split(",");
    const c = lines[3].split(",");
    assert.equal(a[0], "a1b2c3");
    assert.equal(a[1], "vm-a");
    assert.equal(a[2], "ns1");
    assert.equal(a[7], "25"); // vm_ready_s: 1045-1020
    assert.equal(a[8], ""); // no pvc_bound → empty vm_provision_s
    assert.equal(a[9], lib.fmtTs(started));
    assert.equal(a[15], lib.fmtTs(1020));
    assert.equal(a[24], lib.fmtTs(1045));
    assert.equal(b[1], "vm-b");
    assert.equal(b[7], "70"); // 1100-1030
    assert.equal(b[8], "");
    assert.equal(b[15], lib.fmtTs(1030));
    assert.equal(b[24], lib.fmtTs(1100));
    assert.equal(c[1], "vm-c");
    assert.equal(c[7], ""); // no boot → empty vm_ready_s
    assert.equal(c[8], "");
    assert.equal(c[24], ""); // null boot → empty cell
  });

  it("fills base DV and snapshot columns in boot times CSV", () => {
    const rich = [
      {
        vm_name: "vm-a",
        namespace: "ns1",
        boot_timestamp_unix: 1100,
        base_dv_created_at_unix: 1005,
        base_dv_ready_at_unix: 1010,
        base_dv_bound_at_unix: 1011,
        snapshot_created_at_unix: 1015,
        snapshot_ready_at_unix: 1018,
        dv_created_at_unix: 1020,
        dv_ready_at_unix: 1022,
        pvc_created_at_unix: 1025,
        pvc_bound_at_unix: 1026,
        data_dv_created_at_unix: 1028,
        data_dv_ready_at_unix: 1029,
        data_pvc_created_at_unix: 1030,
        data_pvc_bound_at_unix: 1031,
        ssh_ready_at_unix: 1050,
      },
    ];
    const csv = lib.buildBootTimesCsv("a1b2c3", rich, started, dvCreated);
    const cols = csv.trim().split("\n")[1].split(",");
    assert.equal(cols[0], "a1b2c3");
    assert.equal(cols[1], "vm-a");
    assert.equal(cols[2], "ns1");
    // durations: bound-created / ready-created / pvc_bound-dv_created / data / boot-dv
    assert.equal(cols[3], "6"); // 1011-1005
    assert.equal(cols[4], "3"); // 1018-1015
    assert.equal(cols[5], "6"); // 1026-1020
    assert.equal(cols[6], "3"); // 1031-1028
    assert.equal(cols[7], "80"); // 1100-1020
    assert.equal(cols[8], "74"); // 1100-1026 vm_provision_s
    assert.equal(cols[9], lib.fmtTs(started));
    assert.equal(cols[10], lib.fmtTs(1005));
    assert.equal(cols[11], lib.fmtTs(1010));
    assert.equal(cols[12], lib.fmtTs(1011));
    assert.equal(cols[13], lib.fmtTs(1015));
    assert.equal(cols[14], lib.fmtTs(1018));
    assert.equal(cols[15], lib.fmtTs(1020));
    assert.equal(cols[23], lib.fmtTs(1050));
    assert.equal(cols[24], lib.fmtTs(1100));
  });

  it("builds cross-batch timestamps CSV", () => {
    const csv = lib.buildCrossBatchTimestampsCsv([
      {
        batch_id: "b1",
        basename: "rhel9",
        cloudinit: "workload/x.yaml",
        vm_name: "vm-a",
        namespace: "ns1",
        batch_started_at: 1000,
        base_dv_created_at: 1005,
        base_dv_ready_at: 1010,
        base_dv_bound_at: 1011,
        snapshot_created_at: 1015,
        snapshot_ready_at: 1018,
        dv_created_at: 1020,
        dv_ready_at: 1022,
        pvc_created_at: 1025,
        pvc_bound_at: 1026,
        data_dv_created_at: 1028,
        data_dv_ready_at: 1029,
        data_pvc_created_at: 1030,
        data_pvc_bound_at: 1031,
        ssh_ready_at: 1050,
        boot_timestamp: 1100,
      },
    ]);
    const lines = csv.trim().split("\n");
    assert.equal(
      lines[0],
      "batch_id,basename,cloudinit,vm_name,namespace,base_dv_creation_s,snapshot_creation_s,dv_creation_s,data_dv_creation_s,vm_ready_s,vm_provision_s,batch_started_at_utc,base_dv_created_at_utc,base_dv_ready_at_utc,base_dv_bound_at_utc,snapshot_created_at_utc,snapshot_ready_at_utc,dv_created_at_utc,dv_ready_at_utc,pvc_created_at_utc,pvc_bound_at_utc,data_dv_created_at_utc,data_dv_ready_at_utc,data_pvc_created_at_utc,data_pvc_bound_at_utc,ssh_ready_at_utc,boot_timestamp_utc"
    );
    assert.ok(lines[1].startsWith("b1,rhel9,workload/x.yaml,vm-a,ns1,"));
    assert.ok(lines[1].endsWith(lib.fmtTs(1100)));
    const cols = lines[1].split(",");
    assert.equal(cols[5], "6");
    assert.equal(cols[6], "3");
    assert.equal(cols[7], "6");
    assert.equal(cols[8], "3");
    assert.equal(cols[9], "80");
    assert.equal(cols[10], "74"); // boot - pvc_bound
    assert.equal(cols[12], lib.fmtTs(1005));
    assert.equal(cols[13], lib.fmtTs(1010));
    assert.equal(cols[14], lib.fmtTs(1011));
    assert.equal(cols[15], lib.fmtTs(1015));
    assert.equal(cols[16], lib.fmtTs(1018));
    assert.equal(cols[25], lib.fmtTs(1050));
  });

  it("leaves base/snapshot CSV cells empty when absent", () => {
    const csv = lib.buildBootTimesCsv(
      "a1b2c3",
      [{ vm_name: "vm-a", namespace: "ns1", boot_timestamp_unix: 1045, dv_created_at_unix: 1020 }],
      started,
      dvCreated
    );
    const cols = csv.trim().split("\n")[1].split(",");
    // duration cols empty except vm_ready (boot - dv)
    assert.equal(cols[3], "");
    assert.equal(cols[4], "");
    assert.equal(cols[5], "");
    assert.equal(cols[6], "");
    assert.equal(cols[7], "25");
    assert.equal(cols[8], "");
    // absolute base/snapshot empty; dv present
    assert.equal(cols[10], "");
    assert.equal(cols[11], "");
    assert.equal(cols[12], "");
    assert.equal(cols[13], "");
    assert.equal(cols[15], lib.fmtTs(1020));
  });

  it("durationSeconds returns empty when either side is missing", () => {
    assert.equal(lib.durationSeconds(null, 10), "");
    assert.equal(lib.durationSeconds(20, null), "");
    assert.equal(lib.durationSeconds(25, 10), "15");
  });

  it("escapes CSV fields", () => {
    assert.equal(lib.csvEscape('a,b'), '"a,b"');
    assert.equal(lib.csvEscape('say "hi"'), '"say ""hi"""');
  });
});

describe("histogramBins", () => {
  it("returns empty for no values", () => {
    assert.deepEqual(lib.histogramBins([]), {
      labels: [],
      counts: [],
      edges: [],
    });
  });

  it("bins identical values into one bar", () => {
    const { labels, counts } = lib.histogramBins([10, 10, 10]);
    assert.equal(labels.length, 1);
    assert.deepEqual(counts, [3]);
  });

  it("places values into multiple bins", () => {
    const { counts, edges } = lib.histogramBins([10, 20, 30, 40], {
      maxBins: 4,
      minWidth: 5,
    });
    assert.ok(counts.reduce((a, b) => a + b, 0) === 4);
    assert.ok(edges.length === counts.length + 1);
  });
});

describe("pagination", () => {
  it("defaults to 100 rows per page", () => {
    assert.equal(lib.DEFAULT_PAGE_SIZE, 100);
  });

  it("pagerMeta clamps page and computes slice bounds", () => {
    const m = lib.pagerMeta(250, 2, 100);
    assert.deepEqual(m, {
      page: 2,
      pageSize: 100,
      total: 250,
      totalPages: 3,
      start: 100,
      end: 200,
    });
    assert.equal(lib.pagerMeta(250, 0, 100).page, 1);
    assert.equal(lib.pagerMeta(250, 99, 100).page, 3);
    assert.equal(lib.pagerMeta(0, 1, 100).totalPages, 1);
  });

  it("slicePage returns the requested window", () => {
    const items = Array.from({ length: 105 }, (_, i) => i + 1);
    const first = lib.slicePage(items, 1, 100);
    assert.equal(first.meta.page, 1);
    assert.deepEqual(first.items, items.slice(0, 100));
    const last = lib.slicePage(items, 2, 100);
    assert.equal(last.meta.page, 2);
    assert.deepEqual(last.items, items.slice(100));
  });
});

describe("escapeHtml / statusBadge", () => {
  it("escapes HTML", () => {
    assert.equal(lib.escapeHtml('<a "x">'), "&lt;a &quot;x&quot;&gt;");
  });

  it("renders status badges", () => {
    assert.equal(lib.statusBadge("ok"), '<span class="badge ok">ok</span>');
    assert.ok(lib.statusBadge("post_error").includes("warn"));
    assert.ok(lib.statusBadge(null, 1).includes("fio_error"));
  });
});

describe("normalizeApiBase / apiUrl", () => {
  it("normalizes empty and strips trailing slashes", () => {
    assert.equal(lib.normalizeApiBase(""), "");
    assert.equal(lib.normalizeApiBase("  "), "");
    assert.equal(lib.normalizeApiBase("http://lab:8080/"), "http://lab:8080");
    assert.equal(lib.normalizeApiBase("http://lab:8080///"), "http://lab:8080");
  });

  it("adds http:// when scheme missing", () => {
    assert.equal(lib.normalizeApiBase("127.0.0.1:8080"), "http://127.0.0.1:8080");
    assert.equal(lib.normalizeApiBase("lab.example:8080"), "http://lab.example:8080");
  });

  it("builds same-origin or absolute API URLs", () => {
    assert.equal(lib.apiUrl("/v1/batches", ""), "/v1/batches");
    assert.equal(lib.apiUrl("v1/batches", ""), "/v1/batches");
    assert.equal(
      lib.apiUrl("/v1/batches", "http://lab:8080"),
      "http://lab:8080/v1/batches"
    );
    assert.equal(
      lib.apiUrl("/healthz", "http://lab:8080/"),
      "http://lab:8080/healthz"
    );
  });
});

describe("createApiCache", () => {
  it("returns null on miss and cloned data on fresh hit", () => {
    const cache = lib.createApiCache({ ttlMs: 30_000 });
    assert.equal(cache.get("http://lab:8080", "GET", "/v1/batches?archived=0"), null);
    cache.set("http://lab:8080", "GET", "/v1/batches?archived=0", { items: [{ batch_id: "a1" }] }, 1000);
    const hit = cache.get("http://lab:8080", "GET", "/v1/batches?archived=0", 1010);
    assert.deepEqual(hit, { items: [{ batch_id: "a1" }] });
    hit.items[0].batch_id = "mutated";
    const hit2 = cache.get("http://lab:8080", "GET", "/v1/batches?archived=0", 1020);
    assert.equal(hit2.items[0].batch_id, "a1");
  });

  it("expires entries after TTL", () => {
    const cache = lib.createApiCache({ ttlMs: 1000 });
    cache.set("http://lab:8080", "GET", "/v1/batches", { items: [] }, 1000);
    assert.notEqual(cache.get("http://lab:8080", "GET", "/v1/batches", 1500), null);
    assert.equal(cache.get("http://lab:8080", "GET", "/v1/batches", 2001), null);
  });

  it("keys include api base, method, and path", () => {
    const cache = lib.createApiCache();
    assert.equal(
      cache.apiCacheKey("http://lab:8080/", "get", "v1/batches"),
      "http://lab:8080|GET|/v1/batches"
    );
    assert.equal(
      cache.apiCacheKey("", "GET", "/healthz"),
      "|GET|/healthz"
    );
  });

  it("invalidatePathPrefix removes matching entries", () => {
    const cache = lib.createApiCache({ ttlMs: 60_000 });
    cache.set("", "GET", "/v1/batches", { items: [] }, 1);
    cache.set("", "GET", "/v1/batches/a1", { batch_id: "a1" }, 1);
    cache.set("", "GET", "/v1/timestamps", { items: [] }, 1);
    cache.invalidatePathPrefix("/v1/batches");
    assert.equal(cache.get("", "GET", "/v1/batches", 2), null);
    assert.equal(cache.get("", "GET", "/v1/batches/a1", 2), null);
    assert.notEqual(cache.get("", "GET", "/v1/timestamps", 2), null);
  });
});
