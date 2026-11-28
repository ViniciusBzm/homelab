import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { FastifyInstance } from "fastify";
import { ContainersResponseSchema, MonitorsResponseSchema, SummaryResponseSchema } from "@homelab/contracts";
import { buildApp } from "../src/app";
import { MOCK_KUMA_KEY, mockDocker, mockKuma, startMock, type Mock } from "../src/mock-services";
import { summarize } from "../src/sources/summary";
import { meta } from "../src/sources/source";
import type { AllSources } from "../src/sources/summary";
import { isoHoursAgo, testConfig, tempRoot } from "./helpers";

const ok = <T>(name: string, data: T) => ({ data, meta: meta(name, "ok", 0) });
const base = (): AllSources & { backup: { data: NonNullable<AllSources["backup"]["data"]> }; containers: { data: NonNullable<AllSources["containers"]["data"]> }; monitors: { data: NonNullable<AllSources["monitors"]["data"]> } } => ({
  host: ok("host", null as never),
  backup: ok("backup", { result: "ok" as const, finishedAt: "2026-11-27T18:16:14-03:00", snapshot: null, repoSize: null }),
  restoreTest: ok("restore-test", { result: "ok" as const, finishedAt: "2026-11-27T13:56:43-03:00", items: 5, databasesOk: true, failures: null }),
  containers: ok("containers", { total: 1, running: 1, containers: [{ name: "a", image: "x:1", state: "running" as const, health: "healthy" as const, createdAt: null }] }),
  monitors: ok("monitors", { total: 1, up: 1, down: 0, monitors: [{ name: "M", type: "http", status: "up" as const }] }),
});

describe("summarize: indisponibilidade x falha operacional", () => {
  it("tudo ok", () => {
    expect(summarize(base())).toMatchObject({ status: "ok", issues: [] });
  });

  it("fonte indisponivel = degraded (source_unavailable), sem inventar falha", () => {
    const s = base();
    const u: AllSources = { ...s, monitors: { data: null, meta: meta("monitors", "error", null, "unreachable") } };
    expect(summarize(u)).toEqual({
      status: "degraded",
      issues: [{ kind: "source_unavailable", source: "monitors", code: "unreachable", subject: null }],
      counts: { containers: { total: 1, running: 1 }, monitors: null },
    });
  });

  it("dado desatualizado = degraded (stale_data)", () => {
    const s = base();
    s.backup = { ...s.backup, meta: meta("backup", "stale", 999_999, "outdated") };
    expect(summarize(s)).toMatchObject({ status: "degraded", issues: [{ kind: "stale_data", source: "backup" }] });
  });

  it("falhas operacionais = down, com o sujeito", () => {
    const s = base();
    s.monitors.data.monitors[0]!.status = "down";
    s.containers.data.containers.push({ name: "b", image: "x:1", state: "exited", health: "none", createdAt: null });
    s.backup.data.result = "fail";
    const r = summarize(s);
    expect(r.status).toBe("down");
    expect(r.issues.map((i) => [i.kind, i.code, i.subject])).toEqual([
      ["service_failure", "container_not_running", "b"],
      ["service_failure", "monitor_down", "M"],
      ["service_failure", "backup_failed", null],
    ]);
  });
});

describe("rotas novas (servicos simulados)", () => {
  let t: ReturnType<typeof tempRoot>;
  let mocks: Mock[];
  let app: FastifyInstance;
  let keyFile: string;

  beforeEach(async () => {
    t = tempRoot();
    t.write("var/backups/homelab-backup.status", `ok ${isoHoursAgo(2)} snapshot=0a1b2c3d repo=32M\n`);
    t.write("var/backups/homelab-restore-test.status", `ok ${isoHoursAgo(48)} itens=5 dbs_ok\n`);
    keyFile = join(mkdtempSync(join(tmpdir(), "hl-key-")), "key");
    writeFileSync(keyFile, MOCK_KUMA_KEY);
    mocks = await Promise.all([mockDocker(), mockKuma()]);
  });
  afterEach(async () => {
    await app?.close();
    await Promise.all(mocks.map((m) => m.close()));
    t.cleanup();
  });
  const build = (extra: Record<string, string> = {}) =>
    (app = buildApp(testConfig(t.root, { HL_CONTROL_DOCKER_URL: mocks[0]!.url, HL_CONTROL_KUMA_URL: mocks[1]!.url, HL_CONTROL_KUMA_API_KEY_FILE: keyFile, ...extra }), { logger: false }));

  it("containers, monitors e summary seguem o contrato; summary ok", async () => {
    build();
    const c = ContainersResponseSchema.parse((await app.inject("/api/v1/containers")).json());
    const m = MonitorsResponseSchema.parse((await app.inject("/api/v1/monitors")).json());
    const res = await app.inject("/api/v1/summary");
    const s = SummaryResponseSchema.parse(res.json());
    expect(c.data?.total).toBe(4);
    expect(m.data?.total).toBe(6);
    expect(s.data).toMatchObject({ status: "ok", issues: [], counts: { containers: { total: 4, running: 4 }, monitors: { total: 6, up: 6, down: 0 } } });
    expect(s.meta.sources.map((x) => x.name)).toEqual(["host", "backup", "restore-test", "containers", "monitors"]);
    expect(res.body).not.toMatch(/FIXTURE|api\/push|fixture-kuma-key/);
  });

  it("degradacao independente: Docker fora nao afeta monitores, host e backup", async () => {
    await mocks[0]!.close();
    build();
    const s = SummaryResponseSchema.parse((await app.inject("/api/v1/summary")).json());
    expect(s.data?.status).toBe("degraded");
    expect(s.meta.sources.map((x) => [x.name, x.state])).toEqual([
      ["host", "ok"],
      ["backup", "ok"],
      ["restore-test", "ok"],
      ["containers", "error"],
      ["monitors", "ok"],
    ]);
    expect(s.data?.counts).toEqual({ containers: null, monitors: { total: 6, up: 6, down: 0 } });
  });

  it("Kuma lento nao atrasa a resposta alem do timeout da fonte", async () => {
    const slow = await startMock(() => {});
    mocks.push(slow);
    build({ HL_CONTROL_KUMA_URL: slow.url, HL_CONTROL_SOURCE_TIMEOUT_MS: "200" });
    const t0 = Date.now();
    const s = SummaryResponseSchema.parse((await app.inject("/api/v1/summary")).json());
    expect(Date.now() - t0).toBeLessThan(1500);
    expect(s.meta.sources.find((x) => x.name === "monitors")).toMatchObject({ state: "error", error: { code: "timeout" } });
    expect(s.meta.sources.find((x) => x.name === "containers")?.state).toBe("ok");
  });

  it("idade do dado em cache cresce enquanto o cache e servido", async () => {
    build({ HL_CONTROL_CACHE_TTL_SECONDS: "60" });
    const a = (await app.inject("/api/v1/backup")).json();
    await new Promise((r) => setTimeout(r, 1100));
    const b = (await app.inject("/api/v1/backup")).json();
    expect(b.meta.sources[0].ageSeconds).toBeGreaterThan(a.meta.sources[0].ageSeconds);
    expect(b.data).toEqual(a.data);
  });
});
