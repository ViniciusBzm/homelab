import { afterEach, describe, expect, it } from "vitest";
import { join } from "node:path";
import { collectBackup, parseStatusLine, toBackupRun, toRestoreRun } from "../src/sources/backup";
import { SourceError } from "../src/sources/source";
import { isoHoursAgo, tempRoot } from "./helpers";

const NOW = Date.parse("2026-11-27T22:00:00-03:00");
const H = 3_600_000;

describe("parseStatusLine", () => {
  it("le backup ok com snapshot e tamanho", () => {
    const run = toBackupRun(parseStatusLine("ok 2026-11-27T18:16:14-03:00 snapshot=0a1b2c3d repo=32M\n", NOW));
    expect(run).toEqual({ result: "ok", finishedAt: "2026-11-27T18:16:14-03:00", snapshot: "0a1b2c3d", repoSize: "32M" });
  });

  it("le restauracao ok e falha com contagem", () => {
    expect(toRestoreRun(parseStatusLine("ok 2026-11-27T13:56:43-03:00 itens=5 dbs_ok", NOW))).toMatchObject({ items: 5, databasesOk: true, failures: null });
    expect(toRestoreRun(parseStatusLine("fail 2026-11-27T13:56:43-03:00 falhas=2", NOW))).toMatchObject({ result: "fail", failures: 2, databasesOk: null });
  });

  it("descarta texto livre: caminhos internos nunca chegam a resposta", () => {
    const line = "fail 2026-11-27T03:36:00-03:00 snapshot=? com 1 falha(s); ver /var/log/homelab/homelab-backup.log";
    const run = toBackupRun(parseStatusLine(line, NOW));
    expect(run).toEqual({ result: "fail", finishedAt: "2026-11-27T03:36:00-03:00", snapshot: null, repoSize: null });
    expect(JSON.stringify(run)).not.toMatch(/\/var|log|falha/);
  });

  it.each([
    ["vazio", ""],
    ["resultado desconhecido", "talvez 2026-11-27T18:16:14-03:00"],
    ["sem data", "ok"],
    ["data invalida", "ok 2026-13-45T99:00:00-03:00"],
    ["data sem fuso", "ok 2026-11-27T18:16:14"],
    ["30 de fevereiro", "ok 2026-02-30T10:00:00-03:00"],
    ["31 de abril", "ok 2026-04-31T10:00:00Z"],
    ["24:00", "ok 2026-11-27T24:00:00Z"],
    ["fuso impossivel", "ok 2026-11-27T10:00:00+15:00"],
  ])("rejeita conteudo invalido (%s)", (_n, text) => {
    expect(() => parseStatusLine(text, NOW)).toThrow(SourceError);
    try {
      parseStatusLine(text, NOW);
    } catch (e) {
      expect((e as SourceError).state).toBe("invalid");
    }
  });

  it("rejeita data no futuro (alem da tolerancia de relogio)", () => {
    expect(() => parseStatusLine("ok 2026-11-28T03:00:00-03:00", NOW)).toThrow(expect.objectContaining({ code: "future_date" }));
  });

  it("ignora valores fora do formato esperado", () => {
    const run = toBackupRun(parseStatusLine("ok 2026-11-27T18:16:14-03:00 snapshot=XYZ repo=muito", NOW));
    expect(run.snapshot).toBeNull();
    expect(run.repoSize).toBeNull();
  });
});

describe("collectBackup: ausente, invalido, desatualizado e falha real", () => {
  let t: ReturnType<typeof tempRoot>;
  afterEach(() => t?.cleanup());
  const opts = (root: string) => ({
    backupStatus: join(root, "var", "backups", "homelab-backup.status"),
    restoreStatus: join(root, "var", "backups", "homelab-restore-test.status"),
    backupMaxAgeMs: 26 * H,
    restoreMaxAgeMs: 35 * 24 * H,
    timeoutMs: 2000,
    now: () => NOW,
  });

  it("ok: dados validos e recentes", async () => {
    t = tempRoot();
    const [b, r] = await collectBackup(opts(t.root));
    expect(b.meta).toMatchObject({ name: "backup", state: "ok", error: null, ageSeconds: Math.floor((NOW - Date.parse("2026-11-27T18:16:14-03:00")) / 1000) });
    expect(r.meta.state).toBe("ok");
    expect(b.data?.snapshot).toBe("0a1b2c3d");
  });

  it("missing: arquivo inexistente", async () => {
    t = tempRoot();
    t.rm("var/backups/homelab-backup.status");
    const [b, r] = await collectBackup(opts(t.root));
    expect(b).toEqual({ data: null, meta: { name: "backup", state: "missing", ageSeconds: null, error: { code: "not_found", message: "dado ausente" } } });
    expect(r.meta.state).toBe("ok");
  });

  it("invalid: conteudo corrompido e arquivo grande demais", async () => {
    t = tempRoot();
    t.write("var/backups/homelab-backup.status", "\u0000\u0001lixo");
    t.write("var/backups/homelab-restore-test.status", "ok ".repeat(3000));
    const [b, r] = await collectBackup(opts(t.root));
    expect(b.meta).toMatchObject({ state: "invalid", error: { code: "unparseable" } });
    expect(r.meta).toMatchObject({ state: "invalid", error: { code: "too_large" } });
  });

  it("stale: dado valido, mas antigo (o dado continua na resposta)", async () => {
    t = tempRoot();
    t.write("var/backups/homelab-backup.status", `ok ${isoHoursAgo(30, NOW)} snapshot=0a1b2c3d repo=32M\n`);
    const [b] = await collectBackup(opts(t.root));
    expect(b.meta).toMatchObject({ state: "stale", error: { code: "outdated" } });
    expect(b.meta.ageSeconds).toBe(30 * 3600);
    expect(b.data?.snapshot).toBe("0a1b2c3d");
  });

  it("error: falha real de leitura (diretorio no lugar do arquivo)", async () => {
    t = tempRoot();
    t.rm("var/backups/homelab-backup.status");
    t.write("var/backups/.keep", "");
    const o = opts(t.root);
    const [b] = await collectBackup({ ...o, backupStatus: join(t.root, "var", "backups") });
    expect(b.meta).toMatchObject({ state: "error", error: { code: "io_error" } });
    expect(JSON.stringify(b)).not.toContain(t.root);
  });
});
