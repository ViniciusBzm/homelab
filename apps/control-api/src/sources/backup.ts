// Fonte "backup": arquivos de status gravados pelos scripts do servidor, por exemplo
//   ok 2026-11-27T18:16:14-03:00 snapshot=b6d9e6f2 repo=32M
//   fail 2026-11-27T03:36:00-03:00 snapshot=? com 1 falha(s); ver /var/log/...
//   ok 2026-11-27T13:56:43-03:00 itens=5 dbs_ok
// So campos conhecidos e validados saem na API; o texto livre (que pode ter caminhos) e descartado.
import { parseStrictIso, type BackupRun, type RestoreRun } from "@homelab/contracts";
import { invalid, readSmall, runSource, type SourceResult } from "./source";

const CLOCK_SKEW_MS = 5 * 60_000;

export type ParsedStatus = {
  result: "ok" | "fail";
  finishedAt: string;
  finishedAtMs: number;
  fields: Map<string, string>;
  flags: Set<string>;
};

export function parseStatusLine(text: string, nowMs: number): ParsedStatus {
  const line = (text.split(/\r?\n/, 1)[0] ?? "").trim();
  const [result, finishedAt, ...rest] = line.split(/\s+/);
  if (result !== "ok" && result !== "fail") throw invalid();
  const finishedAtMs = finishedAt ? parseStrictIso(finishedAt) : null;
  if (!finishedAt || finishedAtMs === null) throw invalid();
  if (finishedAtMs > nowMs + CLOCK_SKEW_MS) throw invalid("future_date");
  const fields = new Map<string, string>();
  const flags = new Set<string>();
  for (const tok of rest) {
    const kv = /^([a-z_]{1,16})=([A-Za-z0-9._?-]{1,64})$/.exec(tok);
    if (kv) fields.set(kv[1]!, kv[2]!);
    else if (/^[a-z_]{1,16}$/.test(tok)) flags.add(tok);
  }
  return { result, finishedAt, finishedAtMs, fields, flags };
}

const match = (v: string | undefined, re: RegExp) => (v !== undefined && re.test(v) ? v : null);
const int = (v: string | undefined) => (v !== undefined && /^\d{1,9}$/.test(v) ? Number(v) : null);

export function toBackupRun(p: ParsedStatus): BackupRun {
  return {
    result: p.result,
    finishedAt: p.finishedAt,
    snapshot: match(p.fields.get("snapshot"), /^[0-9a-f]{8,64}$/),
    repoSize: match(p.fields.get("repo"), /^\d+(\.\d+)?[KMGT]?$/),
  };
}

export function toRestoreRun(p: ParsedStatus): RestoreRun {
  return {
    result: p.result,
    finishedAt: p.finishedAt,
    items: int(p.fields.get("itens")),
    databasesOk: p.flags.has("dbs_ok") ? true : null,
    failures: int(p.fields.get("falhas")),
  };
}

async function readStatus<T>(path: string, maxAgeMs: number, now: () => number, map: (p: ParsedStatus) => T) {
  const text = await readSmall(path);
  const t = now();
  const parsed = parseStatusLine(text, t);
  const ageMs = Math.max(0, t - parsed.finishedAtMs);
  return { data: map(parsed), ageSeconds: Math.floor(ageMs / 1000), stale: ageMs > maxAgeMs };
}

export type BackupSourceOptions = {
  backupStatus: string;
  restoreStatus: string;
  backupMaxAgeMs: number;
  restoreMaxAgeMs: number;
  timeoutMs: number;
  now?: () => number;
};

export async function collectBackup(o: BackupSourceOptions): Promise<[SourceResult<BackupRun>, SourceResult<RestoreRun>]> {
  const now = o.now ?? Date.now;
  return Promise.all([
    runSource("backup", () => readStatus(o.backupStatus, o.backupMaxAgeMs, now, toBackupRun), o.timeoutMs),
    runSource("restore-test", () => readStatus(o.restoreStatus, o.restoreMaxAgeMs, now, toRestoreRun), o.timeoutMs),
  ]);
}
