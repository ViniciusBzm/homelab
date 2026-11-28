import { join } from "node:path";
import { z } from "zod";

const EnvSchema = z.object({
  HL_CONTROL_HOST: z.string().min(1).default("127.0.0.1"),
  HL_CONTROL_PORT: z.coerce.number().int().min(1).max(65535).default(8088),
  /** Prefixo dos caminhos lidos (permite fixtures). Em producao: "/". */
  HL_CONTROL_ROOT: z.string().min(1).default("/"),
  HL_CONTROL_LABEL: z.string().regex(/^[A-Za-z0-9 ._-]{1,64}$/).optional(),
  /** Caminho medido com statfs (um arquivo montado do / do host). Padrao: status do backup. */
  HL_CONTROL_DISK_PATH: z.string().min(1).optional(),
  HL_CONTROL_BACKUP_MAX_AGE_HOURS: z.coerce.number().positive().default(26),
  HL_CONTROL_RESTORE_MAX_AGE_DAYS: z.coerce.number().positive().default(35),
  HL_CONTROL_CACHE_TTL_SECONDS: z.coerce.number().min(0).max(300).default(10),
  HL_CONTROL_SOURCE_TIMEOUT_MS: z.coerce.number().int().min(100).max(30_000).default(3000),
});

export type Config = {
  host: string;
  port: number;
  label: string | null;
  backupMaxAgeMs: number;
  restoreMaxAgeMs: number;
  cacheTtlMs: number;
  sourceTimeoutMs: number;
  paths: {
    loadavg: string;
    meminfo: string;
    uptime: string;
    stat: string;
    hwmon: string;
    backupStatus: string;
    restoreStatus: string;
    disk: string;
  };
};

export function loadConfig(env: NodeJS.ProcessEnv = process.env): Config {
  const e = EnvSchema.parse(env);
  const r = (...p: string[]) => join(e.HL_CONTROL_ROOT, ...p);
  const backupStatus = r("var", "backups", "homelab-backup.status");
  return {
    host: e.HL_CONTROL_HOST,
    port: e.HL_CONTROL_PORT,
    label: e.HL_CONTROL_LABEL ?? null,
    backupMaxAgeMs: e.HL_CONTROL_BACKUP_MAX_AGE_HOURS * 3_600_000,
    restoreMaxAgeMs: e.HL_CONTROL_RESTORE_MAX_AGE_DAYS * 86_400_000,
    cacheTtlMs: e.HL_CONTROL_CACHE_TTL_SECONDS * 1000,
    sourceTimeoutMs: e.HL_CONTROL_SOURCE_TIMEOUT_MS,
    paths: {
      loadavg: r("proc", "loadavg"),
      meminfo: r("proc", "meminfo"),
      uptime: r("proc", "uptime"),
      stat: r("proc", "stat"),
      hwmon: r("sys", "class", "hwmon"),
      backupStatus,
      restoreStatus: r("var", "backups", "homelab-restore-test.status"),
      disk: e.HL_CONTROL_DISK_PATH ?? backupStatus,
    },
  };
}
