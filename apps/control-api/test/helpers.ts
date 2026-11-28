import { cpSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { loadConfig, type Config } from "../src/config";

export const FIXTURES = fileURLToPath(new URL("../fixtures/root", import.meta.url));

/** Copia as fixtures para um diretorio temporario (cada teste altera a sua copia). */
export function tempRoot(): { root: string; cleanup: () => void; write: (rel: string, text: string) => void; rm: (rel: string) => void } {
  const root = mkdtempSync(join(tmpdir(), "hl-control-"));
  cpSync(FIXTURES, root, { recursive: true });
  return {
    root,
    cleanup: () => rmSync(root, { recursive: true, force: true }),
    write: (rel, text) => writeFileSync(join(root, rel), text),
    rm: (rel) => rmSync(join(root, rel), { recursive: true, force: true }),
  };
}

export function testConfig(root: string, extra: Record<string, string> = {}): Config {
  return loadConfig({ HL_CONTROL_ROOT: root, HL_CONTROL_LABEL: "homelab-demo", HL_CONTROL_CACHE_TTL_SECONDS: "0", ...extra });
}

/** Data ISO com fuso -03:00, `hoursAgo` horas antes de agora. */
export function isoHoursAgo(hoursAgo: number, now = Date.now()): string {
  const d = new Date(now - hoursAgo * 3_600_000 - 3 * 3_600_000);
  return d.toISOString().replace(/\.\d{3}Z$/, "-03:00");
}
