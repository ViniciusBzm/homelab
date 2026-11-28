import { readFile } from "node:fs/promises";
import fastifyStatic from "@fastify/static";
import Fastify, { type FastifyInstance, type FastifyReply } from "fastify";
import type { z } from "zod";
import {
  API_VERSION,
  BackupResponseSchema,
  ContainersResponseSchema,
  HealthResponseSchema,
  HostResponseSchema,
  MonitorsResponseSchema,
  SummaryResponseSchema,
  type BackupRun,
  type Containers,
  type HostSnapshot,
  type Monitors,
  type RestoreRun,
  type SourceMeta,
} from "@homelab/contracts";
import type { Config } from "./config";
import { collectBackup } from "./sources/backup";
import { collectContainers } from "./sources/containers";
import { collectHost, type StatfsFn } from "./sources/host";
import { collectMonitors } from "./sources/monitors";
import { cached, withCacheAge, type SourceResult } from "./sources/source";
import { summarize } from "./sources/summary";

export const VERSION = "0.3.0";

/** CSP da API (JSON): nada pode ser carregado. */
export const CSP_API = "default-src 'none'; frame-ancestors 'none'";
/** CSP do front-end: so recursos da propria origem; sem inline, sem eval, sem terceiros. */
export const CSP_WEB =
  "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; font-src 'self'; connect-src 'self'; manifest-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'";

type Timed<T> = () => Promise<{ value: T; at: number }>;
export type Sources = {
  host: Timed<SourceResult<HostSnapshot>>;
  backup: Timed<[SourceResult<BackupRun>, SourceResult<RestoreRun>]>;
  containers: Timed<SourceResult<Containers>>;
  monitors: Timed<SourceResult<Monitors>>;
};

/** Para testes: fonte sem cache (coletada agora). */
export const fresh = <T>(fn: () => Promise<T>): Timed<T> => async () => ({ value: await fn(), at: Date.now() });

function fixtureStatfs(file: string): StatfsFn {
  return async () => JSON.parse(await readFile(file, "utf8")) as Awaited<ReturnType<StatfsFn>>;
}

export function defaultSources(cfg: Config): Sources {
  const t = cfg.sourceTimeoutMs;
  return {
    host: cached(
      () => collectHost({ label: cfg.label, paths: cfg.paths, timeoutMs: t, statfs: cfg.statfsFixture ? fixtureStatfs(cfg.statfsFixture) : undefined }),
      cfg.cacheTtlMs,
    ),
    backup: cached(
      () =>
        collectBackup({
          backupStatus: cfg.paths.backupStatus,
          restoreStatus: cfg.paths.restoreStatus,
          backupMaxAgeMs: cfg.backupMaxAgeMs,
          restoreMaxAgeMs: cfg.restoreMaxAgeMs,
          timeoutMs: t,
        }),
      cfg.cacheTtlMs * 3,
    ),
    containers: cached(() => collectContainers({ dockerUrl: cfg.dockerUrl, timeoutMs: t }), cfg.cacheTtlMs),
    monitors: cached(() => collectMonitors({ kumaUrl: cfg.kumaUrl, apiKeyFile: cfg.kumaApiKeyFile, timeoutMs: t }), cfg.cacheTtlMs * 3),
  };
}

const apiError = (code: string, message: string) => ({ error: { code, message } });

export function buildApp(cfg: Config, opts: { sources?: Partial<Sources>; logger?: boolean } = {}): FastifyInstance {
  const src: Sources = { ...defaultSources(cfg), ...opts.sources };
  const app = Fastify({
    logger: opts.logger === false ? false : { level: "info", redact: ["req.headers.authorization", "req.headers.cookie"] },
    exposeHeadRoutes: true,
  });

  // Leitura das fontes ja com a idade do cache somada.
  const read = {
    host: async () => {
      const { value, at } = await src.host();
      return withCacheAge(value, at);
    },
    backup: async () => {
      const { value, at } = await src.backup();
      return [withCacheAge(value[0], at), withCacheAge(value[1], at)] as const;
    },
    containers: async () => {
      const { value, at } = await src.containers();
      return withCacheAge(value, at);
    },
    monitors: async () => {
      const { value, at } = await src.monitors();
      return withCacheAge(value, at);
    },
  };

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

  app.addHook("onSend", async (req, reply) => {
    const isApi = req.url.startsWith("/api/") || !cfg.webDir;
    reply.header("x-content-type-options", "nosniff");
    reply.header("referrer-policy", "no-referrer");
    reply.header("content-security-policy", isApi ? CSP_API : CSP_WEB);
    if (isApi || !/\/assets\//.test(req.url)) reply.header("cache-control", "no-store");
  });

  if (cfg.webDir) {
    // Front-end compilado (Vite): index.html + /assets/* com hash. Somente GET/HEAD.
    app.register(fastifyStatic, { root: cfg.webDir, prefix: "/", index: ["index.html"], wildcard: true, decorateReply: false });
  }

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
    const r = await read.host();
    return send(reply, HostResponseSchema, envelope(r.data, [r.meta]));
  });

  app.get("/api/v1/backup", async (_req, reply) => {
    const [b, rt] = await read.backup();
    return send(reply, BackupResponseSchema, envelope({ backup: b.data, restoreTest: rt.data }, [b.meta, rt.meta]));
  });

  app.get("/api/v1/containers", async (_req, reply) => {
    const r = await read.containers();
    return send(reply, ContainersResponseSchema, envelope(r.data, [r.meta]));
  });

  app.get("/api/v1/monitors", async (_req, reply) => {
    const r = await read.monitors();
    return send(reply, MonitorsResponseSchema, envelope(r.data, [r.meta]));
  });

  // Fontes em paralelo e independentes: a falha de uma nao afeta as outras.
  app.get("/api/v1/summary", async (_req, reply) => {
    const [host, [backup, restoreTest], containers, monitors] = await Promise.all([read.host(), read.backup(), read.containers(), read.monitors()]);
    const all = { host, backup, restoreTest, containers, monitors };
    return send(reply, SummaryResponseSchema, envelope(summarize(all), Object.values(all).map((r) => r.meta)));
  });

  return app;
}
