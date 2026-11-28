// Desenvolvimento local: fixtures sinteticas + Docker/Kuma SIMULADOS (nada de servicos reais).
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { MOCK_KUMA_KEY, mockDocker, mockKuma } from "./mock-services";

const fixtures = (p: string) => fileURLToPath(new URL(`../fixtures/${p}`, import.meta.url));
const [docker, kuma] = await Promise.all([mockDocker(undefined, 18375), mockKuma(undefined, undefined, 18301)]);
const keyFile = join(mkdtempSync(join(tmpdir(), "hl-control-dev-")), "kuma-api-key");
writeFileSync(keyFile, MOCK_KUMA_KEY, { mode: 0o600 });

process.env.HL_CONTROL_ROOT ??= fixtures("root");
process.env.HL_CONTROL_LABEL ??= "homelab-demo";
process.env.HL_CONTROL_STATFS_FIXTURE ??= fixtures("statfs.json");
process.env.HL_CONTROL_DOCKER_URL ??= docker.url;
process.env.HL_CONTROL_KUMA_URL ??= kuma.url;
process.env.HL_CONTROL_KUMA_API_KEY_FILE ??= keyFile;
await import("./main");
