// Servidor do E2E: API de producao (buildApp) servindo o front-end COMPILADO (dist), com
// fixtures sinteticas e Docker/Kuma SIMULADOS. Datas do backup geradas relativas a "agora".
import { cpSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { buildApp } from "../../control-api/src/app";
import { loadConfig } from "../../control-api/src/config";
import { MOCK_KUMA_KEY, mockDocker, mockKuma } from "../../control-api/src/mock-services";

const api = (p: string) => fileURLToPath(new URL(`../../control-api/${p}`, import.meta.url));
const iso = (msAgo: number) => new Date(Date.now() - msAgo - 3 * 3_600_000).toISOString().replace(/\.\d{3}Z$/, "-03:00");

const root = mkdtempSync(join(tmpdir(), "hl-e2e-"));
cpSync(api("fixtures/root"), root, { recursive: true });
writeFileSync(join(root, "var/backups/homelab-backup.status"), `ok ${iso(2 * 3_600_000)} snapshot=0a1b2c3d repo=32M\n`);
writeFileSync(join(root, "var/backups/homelab-restore-test.status"), `ok ${iso(48 * 3_600_000)} itens=5 dbs_ok\n`);
const keyFile = join(root, "kuma-api-key");
writeFileSync(keyFile, MOCK_KUMA_KEY);

const [docker, kuma] = await Promise.all([mockDocker(), mockKuma()]);
const app = buildApp(
  loadConfig({
    HL_CONTROL_PORT: process.env.E2E_PORT ?? "18090",
    HL_CONTROL_ROOT: root,
    HL_CONTROL_LABEL: "homelab-demo",
    HL_CONTROL_STATFS_FIXTURE: api("fixtures/statfs.json"),
    HL_CONTROL_DOCKER_URL: docker.url,
    HL_CONTROL_KUMA_URL: kuma.url,
    HL_CONTROL_KUMA_API_KEY_FILE: keyFile,
    HL_CONTROL_CACHE_TTL_SECONDS: "0",
    HL_CONTROL_WEB_DIR: fileURLToPath(new URL("../dist", import.meta.url)),
  }),
  { logger: false },
);
await app.listen({ host: "127.0.0.1", port: Number(process.env.E2E_PORT ?? 18090) });
console.log("e2e server ready");
