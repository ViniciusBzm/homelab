import { describe, expect, it } from "vitest";
import { BackupResponseSchema, HostResponseSchema, parseStrictIso, SourceMetaSchema, SummarySchema } from "../src/index";
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

  it("datas: aceita validas e recusa impossiveis", () => {
    expect(parseStrictIso("2028-02-29T10:00:00-03:00")).not.toBeNull();
    for (const d of ["2026-02-29T10:00:00Z", "2026-02-30T10:00:00-03:00", "2026-04-31T10:00:00Z", "2026-11-27T24:00:00Z", "2026-11-27T10:60:00Z", "2026-13-01T10:00:00Z", "2026-11-27T10:00:00+15:00"])
      expect(parseStrictIso(d), d).toBeNull();
  });

  it("resumo so aceita tipos de problema conhecidos", () => {
    const issue = { kind: "service_failure", source: "monitors", code: "monitor_down", subject: "M" };
    expect(SummarySchema.parse({ status: "down", issues: [issue], counts: { containers: null, monitors: null } }).status).toBe("down");
    expect(() => SummarySchema.parse({ status: "down", issues: [{ ...issue, kind: "outro" }], counts: { containers: null, monitors: null } })).toThrow();
  });

  it("exporta JSON Schema de todas as respostas publicadas", () => {
    const schemas = toJsonSchemas();
    expect(Object.keys(schemas).sort()).toEqual(["backup.response", "containers.response", "error.response", "health.response", "host.response", "monitors.response", "summary.response"]);
    for (const s of Object.values(schemas)) expect(s).toMatchObject({ type: "object" });
  });
});
