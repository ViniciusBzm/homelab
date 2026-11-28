import { describe, expect, it } from "vitest";
import { cached, fromFsError, runSource, SourceError } from "../src/sources/source";

describe("classificacao de falhas", () => {
  it("ENOENT = missing; EACCES = error/permission_denied; outros = error/io_error", () => {
    const e = (code: string) => Object.assign(new Error(`${code}: /caminho/secreto`), { code });
    expect(fromFsError(e("ENOENT"))).toMatchObject({ state: "missing", code: "not_found" });
    expect(fromFsError(e("EACCES"))).toMatchObject({ state: "error", code: "permission_denied" });
    expect(fromFsError(e("EIO"))).toMatchObject({ state: "error", code: "io_error" });
  });

  it("runSource: mensagens fixas, sem detalhes internos", async () => {
    const r = await runSource("x", async () => Promise.reject(new Error("EIO em /var/backups/segredo")), 1000);
    expect(r).toEqual({ data: null, meta: { name: "x", state: "error", ageSeconds: null, error: { code: "internal", message: "erro interno da fonte" } } });
  });

  it("runSource: timeout vira error/timeout", async () => {
    const r = await runSource("lenta", () => new Promise<never>(() => {}), 50);
    expect(r.meta).toMatchObject({ state: "error", error: { code: "timeout" } });
  });

  it("runSource: SourceError preserva o estado", async () => {
    const r = await runSource("x", async () => Promise.reject(new SourceError("invalid", "unparseable")), 1000);
    expect(r.meta.state).toBe("invalid");
  });
});

describe("cached", () => {
  it("respeita o TTL e deduplica chamadas simultaneas", async () => {
    let calls = 0;
    let t = 0;
    const fn = cached(async () => ++calls, 1000, () => t);
    await Promise.all([fn(), fn(), fn()]);
    expect(calls).toBe(1);
    t = 999;
    await fn();
    expect(calls).toBe(1);
    t = 1000;
    await fn();
    expect(calls).toBe(2);
  });
});
