import { describe, expect, it } from "vitest";
import { BackupResponseSchema, HostResponseSchema, SourceMetaSchema } from "../src/index";
import { toJsonSchemas } from "../src/export-schemas";

const meta = { apiVersion: "1", generatedAt: "2026-11-27T21:00:00.000Z", sources: [] };

describe("contratos", () => {
  it("envelope aceita data null e rejeita versao errada", () => {
    expect(HostResponseSchema.parse({ data: null, meta }).data).toBeNull();
    expect(() => HostResponseSchema.parse({ data: null, meta: { ...meta, apiVersion: "2" } })).toThrow();
  });

  it("meta da fonte so aceita estados e codigos conhecidos", () => {
    expect(() => SourceMetaSchema.parse({ name: "backup", state: "talvez", ageSeconds: null, error: null })).toThrow();
    expect(() => SourceMetaSchema.parse({ name: "backup", state: "error", ageSeconds: null, error: { code: "x", message: "m" } })).toThrow();
  });

  it("backup rejeita snapshot e data fora do formato", () => {
    const run = { result: "ok", finishedAt: "2026-11-27T18:16:14-03:00", snapshot: "0a1b2c3d", repoSize: "32M" };
    expect(BackupResponseSchema.parse({ data: { backup: run, restoreTest: null }, meta }).data?.backup?.snapshot).toBe("0a1b2c3d");
    expect(() => BackupResponseSchema.parse({ data: { backup: { ...run, snapshot: "/etc" }, restoreTest: null }, meta })).toThrow();
    expect(() => BackupResponseSchema.parse({ data: { backup: { ...run, finishedAt: "ontem" }, restoreTest: null }, meta })).toThrow();
  });

  it("exporta JSON Schema de todas as respostas publicadas", () => {
    const schemas = toJsonSchemas();
    expect(Object.keys(schemas).sort()).toEqual(["backup.response", "error.response", "health.response", "host.response"]);
    for (const s of Object.values(schemas)) expect(s).toMatchObject({ type: "object" });
  });
});
