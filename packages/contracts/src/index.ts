// Contratos da API do HomeLab Control (v1). Mudancas em /api/v1 sao somente ADITIVAS.
import { z } from "zod";

export const API_VERSION = "1" as const;

const isoDateTime = z.string().datetime({ offset: true });
const nonNegInt = z.number().int().nonnegative();
const percent = z.number().min(0).max(100);

/**
 * Estado de uma fonte de dados:
 * - ok:      dado valido e dentro do prazo
 * - missing: dado ausente (ex.: arquivo inexistente)
 * - invalid: dado presente, mas ilegivel ou incoerente
 * - stale:   dado valido, porem mais antigo que o limite (o dado e devolvido)
 * - error:   falha real ao obter o dado (permissao, E/S, timeout)
 */
export const SourceStateSchema = z.enum(["ok", "missing", "invalid", "stale", "error"]);

export const SourceErrorCodeSchema = z.enum([
  "not_found",
  "unparseable",
  "too_large",
  "future_date",
  "outdated",
  "permission_denied",
  "timeout",
  "io_error",
  "internal",
]);

export const SourceMetaSchema = z.object({
  name: z.string().regex(/^[a-z][a-z0-9-]{0,31}$/),
  state: SourceStateSchema,
  /** Idade do dado em segundos (null quando nao ha dado). */
  ageSeconds: nonNegInt.nullable(),
  /** Mensagem fixa e generica: nunca contem caminhos, conteudo de arquivos ou detalhes internos. */
  error: z.object({ code: SourceErrorCodeSchema, message: z.string().max(120) }).nullable(),
});

export const MetaSchema = z.object({
  apiVersion: z.literal(API_VERSION),
  generatedAt: isoDateTime,
  sources: z.array(SourceMetaSchema),
});

export function envelopeSchema<T extends z.ZodType>(data: T) {
  return z.object({ data: data.nullable(), meta: MetaSchema });
}

export const HealthSchema = z.object({
  status: z.literal("ok"),
  version: z.string().regex(/^\d+\.\d+\.\d+$/),
  uptimeSeconds: nonNegInt,
});

const capacity = z.object({ totalBytes: nonNegInt, availableBytes: nonNegInt, usedPercent: percent });

export const HostSnapshotSchema = z.object({
  label: z.string().max(64).nullable(),
  uptimeSeconds: nonNegInt,
  cpuCount: z.number().int().positive().nullable(),
  load: z.object({ one: z.number().nonnegative(), five: z.number().nonnegative(), fifteen: z.number().nonnegative() }),
  memory: capacity,
  /** Disco do sistema de arquivos raiz do host (null quando nao foi possivel medir). */
  disk: capacity.nullable(),
  temperatures: z
    .array(z.object({ sensor: z.string().regex(/^[a-z0-9_-]{1,32}$/), celsius: z.number().min(-40).max(150) }))
    .max(32),
});

export const RunResultSchema = z.enum(["ok", "fail"]);

export const BackupRunSchema = z.object({
  result: RunResultSchema,
  finishedAt: isoDateTime,
  snapshot: z.string().regex(/^[0-9a-f]{8,64}$/).nullable(),
  repoSize: z.string().regex(/^\d+(\.\d+)?[KMGT]?$/).nullable(),
});

export const RestoreRunSchema = z.object({
  result: RunResultSchema,
  finishedAt: isoDateTime,
  items: nonNegInt.nullable(),
  databasesOk: z.boolean().nullable(),
  failures: nonNegInt.nullable(),
});

export const BackupStatusSchema = z.object({
  backup: BackupRunSchema.nullable(),
  restoreTest: RestoreRunSchema.nullable(),
});

export const ApiErrorSchema = z.object({
  error: z.object({ code: z.string().regex(/^[a-z_]{1,32}$/), message: z.string().max(120) }),
});

export const HealthResponseSchema = envelopeSchema(HealthSchema);
export const HostResponseSchema = envelopeSchema(HostSnapshotSchema);
export const BackupResponseSchema = envelopeSchema(BackupStatusSchema);

/** Schemas publicados como JSON Schema para clientes externos (ex.: WristOps). */
export const publishedSchemas = {
  "health.response": HealthResponseSchema,
  "host.response": HostResponseSchema,
  "backup.response": BackupResponseSchema,
  "error.response": ApiErrorSchema,
} as const;

export type SourceState = z.infer<typeof SourceStateSchema>;
export type SourceErrorCode = z.infer<typeof SourceErrorCodeSchema>;
export type SourceMeta = z.infer<typeof SourceMetaSchema>;
export type Meta = z.infer<typeof MetaSchema>;
export type Health = z.infer<typeof HealthSchema>;
export type HostSnapshot = z.infer<typeof HostSnapshotSchema>;
export type BackupRun = z.infer<typeof BackupRunSchema>;
export type RestoreRun = z.infer<typeof RestoreRunSchema>;
export type BackupStatus = z.infer<typeof BackupStatusSchema>;
export type ApiError = z.infer<typeof ApiErrorSchema>;
