import { afterEach, beforeEach, describe, expect, it } from "vitest";
import type { FastifyInstance } from "fastify";
import { ApiErrorSchema, BackupResponseSchema, HealthResponseSchema, HostResponseSchema } from "@homelab/contracts";
import { buildApp } from "../src/app";
import { runSource } from "../src/sources/source";
import { isoHoursAgo, testConfig, tempRoot } from "./helpers";

let t: ReturnType<typeof tempRoot>;
let app: FastifyInstance;

beforeEach(async () => {
  t = tempRoot();
  t.write("var/backups/homelab-backup.status", `ok ${isoHoursAgo(2)} snapshot=0a1b2c3d repo=32M\n`);
  t.write("var/backups/homelab-restore-test.status", `ok ${isoHoursAgo(48)} itens=5 dbs_ok\n`);
  app = buildApp(testConfig(t.root), { logger: false });
  await app.ready();
});
afterEach(async () => {
  await app.close();
  t.cleanup();
});

const get = (url: string) => app.inject({ method: "GET", url });

describe("rotas", () => {
  it("GET /api/health", async () => {
    const res = await get("/api/health");
    expect(res.statusCode).toBe(200);
    const body = HealthResponseSchema.parse(res.json());
    expect(body.data).toMatchObject({ status: "ok", version: "0.1.0" });
    expect(body.meta.sources).toEqual([]);
  });

  it("GET /api/v1/host segue o contrato", async () => {
    const res = await get("/api/v1/host");
    expect(res.statusCode).toBe(200);
    const body = HostResponseSchema.parse(res.json());
    expect(body.meta.sources[0]).toMatchObject({ name: "host", state: "ok" });
    expect(body.data?.load.one).toBe(0.42);
  });

  it("GET /api/v1/backup segue o contrato", async () => {
    const res = await get("/api/v1/backup");
    const body = BackupResponseSchema.parse(res.json());
    expect(body.meta.sources.map((s) => [s.name, s.state])).toEqual([
      ["backup", "ok"],
      ["restore-test", "ok"],
    ]);
    expect(body.data?.backup?.snapshot).toBe("0a1b2c3d");
  });

  it("fonte com problema: 200, data parcial nula e estado por fonte (sem derrubar a API)", async () => {
    t.rm("var/backups/homelab-backup.status");
    t.write("var/backups/homelab-restore-test.status", "corrompido");
    const res = await get("/api/v1/backup");
    expect(res.statusCode).toBe(200);
    const body = BackupResponseSchema.parse(res.json());
    expect(body.data).toEqual({ backup: null, restoreTest: null });
    expect(body.meta.sources.map((s) => s.state)).toEqual(["missing", "invalid"]);
    expect(res.body).not.toContain(t.root.replace(/\\/g, "\\\\"));
    expect(res.body).not.toMatch(/var[\\/]+backups/);
  });

  it("host indisponivel: data null e meta com o motivo", async () => {
    t.rm("proc");
    const body = HostResponseSchema.parse((await get("/api/v1/host")).json());
    expect(body.data).toBeNull();
    expect(body.meta.sources[0]).toMatchObject({ state: "missing", error: { code: "not_found" } });
  });
});

describe("seguranca", () => {
  it("existem somente rotas GET/HEAD", async () => {
    const printed = app.printRoutes({ commonPrefix: false, includeMeta: false });
    expect(printed).toContain("/api/v1/backup (GET, HEAD)");
    expect(printed).not.toMatch(/POST|PUT|PATCH|DELETE|OPTIONS/);
    for (const m of ["POST", "PUT", "PATCH", "DELETE"] as const) {
      for (const url of ["/api/health", "/api/v1/host", "/api/v1/backup"]) {
        expect((await app.inject({ method: m, url })).statusCode, `${m} ${url}`).toBe(404);
      }
    }
  });

  it("404 e erros no formato padrao, com cabecalhos de seguranca", async () => {
    const res = await get("/api/v1/nada");
    expect(res.statusCode).toBe(404);
    expect(ApiErrorSchema.parse(res.json()).error.code).toBe("not_found");
    expect(res.headers["x-content-type-options"]).toBe("nosniff");
    expect(res.headers["cache-control"]).toBe("no-store");
    expect(String(res.headers["content-security-policy"])).toContain("default-src 'none'");
  });

  it("violacao de contrato vira 500 generico", async () => {
    const bad = buildApp(testConfig(t.root), {
      logger: false,
      sources: { host: async () => ({ data: { label: "x" } as never, meta: { name: "host", state: "ok", ageSeconds: 0, error: null } }) },
    });
    const res = await bad.inject({ method: "GET", url: "/api/v1/host" });
    expect(res.statusCode).toBe(500);
    expect(res.json()).toEqual({ error: { code: "internal", message: "erro interno" } });
    await bad.close();
  });

  it("fonte lenta respeita o timeout", async () => {
    const slow = buildApp(testConfig(t.root), {
      logger: false,
      sources: { host: () => runSource("host", () => new Promise<never>(() => {}), 100) },
    });
    const res = await slow.inject({ method: "GET", url: "/api/v1/host" });
    expect(res.statusCode).toBe(200);
    expect(HostResponseSchema.parse(res.json()).meta.sources[0]).toMatchObject({ state: "error", error: { code: "timeout" } });
    await slow.close();
  });
});
