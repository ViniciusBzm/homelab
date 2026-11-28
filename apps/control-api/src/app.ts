import Fastify, { type FastifyInstance, type FastifyReply } from "fastify";
import type { z } from "zod";
import {
  API_VERSION,
  BackupResponseSchema,
  HealthResponseSchema,
  HostResponseSchema,
  type BackupRun,
  type HostSnapshot,
  type RestoreRun,
  type SourceMeta,
} from "@homelab/contracts";
import type { Config } from "./config";
import { collectBackup } from "./sources/backup";
import { collectHost } from "./sources/host";
import { cached, type SourceResult } from "./sources/source";

export const VERSION = "0.1.0";

export type Sources = {
  host: () => Promise<SourceResult<HostSnapshot>>;
  backup: () => Promise<[SourceResult<BackupRun>, SourceResult<RestoreRun>]>;
};

export function defaultSources(cfg: Config): Sources {
  return {
    host: cached(() => collectHost({ label: cfg.label, paths: cfg.paths, timeoutMs: cfg.sourceTimeoutMs }), cfg.cacheTtlMs),
    backup: cached(
      () =>
        collectBackup({
          backupStatus: cfg.paths.backupStatus,
          restoreStatus: cfg.paths.restoreStatus,
          backupMaxAgeMs: cfg.backupMaxAgeMs,
          restoreMaxAgeMs: cfg.restoreMaxAgeMs,
          timeoutMs: cfg.sourceTimeoutMs,
        }),
      cfg.cacheTtlMs * 3,
    ),
  };
}

const apiError = (code: string, message: string) => ({ error: { code, message } });

export function buildApp(cfg: Config, opts: { sources?: Partial<Sources>; logger?: boolean } = {}): FastifyInstance {
  const sources: Sources = { ...defaultSources(cfg), ...opts.sources };
  const app = Fastify({
    logger: opts.logger === false ? false : { level: "info", redact: ["req.headers.authorization", "req.headers.cookie"] },
    exposeHeadRoutes: true,
  });

  // Contrato garantido na saida: resposta fora do schema e bug -> 500 generico (detalhe so no log).
  function send<S extends z.ZodType>(reply: FastifyReply, schema: S, payload: z.input<S>) {
    const parsed = schema.safeParse(payload);
    if (!parsed.success) {
      reply.log.error({ issues: parsed.error.issues }, "resposta viola o contrato");
      return reply.code(500).send(apiError("internal", "erro interno"));
    }
    return reply.send(parsed.data);
  }
  const envelope = <T>(data: T, sourcesMeta: SourceMeta[]) => ({
    data,
    meta: { apiVersion: API_VERSION, generatedAt: new Date().toISOString(), sources: sourcesMeta },
  });

  app.addHook("onSend", async (_req, reply) => {
    reply.header("cache-control", "no-store");
    reply.header("x-content-type-options", "nosniff");
    reply.header("referrer-policy", "no-referrer");
    reply.header("content-security-policy", "default-src 'none'; frame-ancestors 'none'");
  });

  app.setNotFoundHandler((_req, reply) => reply.code(404).send(apiError("not_found", "rota inexistente")));
  app.setErrorHandler((err: { statusCode?: number }, req, reply) => {
    const status = err.statusCode && err.statusCode >= 400 && err.statusCode < 500 ? err.statusCode : 500;
    if (status === 500) req.log.error(err);
    return reply.code(status).send(status === 500 ? apiError("internal", "erro interno") : apiError("bad_request", "requisicao invalida"));
  });

  app.get("/api/health", async (_req, reply) =>
    send(reply, HealthResponseSchema, envelope({ status: "ok" as const, version: VERSION, uptimeSeconds: Math.floor(process.uptime()) }, [])),
  );

  app.get("/api/v1/host", async (_req, reply) => {
    const r = await sources.host();
    return send(reply, HostResponseSchema, envelope(r.data, [r.meta]));
  });

  app.get("/api/v1/backup", async (_req, reply) => {
    const [b, rt] = await sources.backup();
    return send(reply, BackupResponseSchema, envelope({ backup: b.data, restoreTest: rt.data }, [b.meta, rt.meta]));
  });

  return app;
}
