// Infraestrutura comum das fontes: erros classificados, leitura limitada, timeout e cache.
import { open } from "node:fs/promises";
import type { SourceErrorCode, SourceMeta, SourceState } from "@homelab/contracts";

export type SourceResult<T> = { data: T | null; meta: SourceMeta };

/** Mensagens FIXAS por codigo: nada de caminhos, conteudo de arquivo ou mensagens do sistema. */
const MESSAGES: Record<SourceErrorCode, string> = {
  not_found: "dado ausente",
  unparseable: "conteudo invalido",
  too_large: "conteudo maior que o limite",
  future_date: "data no futuro",
  outdated: "dado mais antigo que o limite",
  permission_denied: "sem permissao de leitura",
  timeout: "tempo limite excedido",
  io_error: "falha de leitura",
  not_configured: "fonte nao configurada",
  unreachable: "servico inacessivel",
  unauthorized: "credencial recusada pelo servico",
  bad_status: "resposta inesperada do servico",
  internal: "erro interno da fonte",
};

export class SourceError extends Error {
  constructor(
    readonly state: Exclude<SourceState, "ok" | "stale">,
    readonly code: SourceErrorCode,
  ) {
    super(code);
  }
}

export const invalid = (code: SourceErrorCode = "unparseable") => new SourceError("invalid", code);

/** Converte erros do sistema de arquivos em ausente (ENOENT) ou falha real. */
export function fromFsError(err: unknown): SourceError {
  if (err instanceof SourceError) return err;
  const code = (err as NodeJS.ErrnoException | undefined)?.code;
  if (code === "ENOENT" || code === "ENOTDIR") return new SourceError("missing", "not_found");
  if (code === "EACCES" || code === "EPERM") return new SourceError("error", "permission_denied");
  return new SourceError("error", "io_error");
}

/** Le no maximo `max` bytes; acima disso o dado e invalido (protege contra arquivos inesperados). */
export async function readSmall(path: string, max = 4096): Promise<string> {
  let fh;
  try {
    fh = await open(path, "r");
    const buf = Buffer.alloc(max + 1);
    const { bytesRead } = await fh.read(buf, 0, max + 1, 0);
    if (bytesRead > max) throw invalid("too_large");
    return buf.subarray(0, bytesRead).toString("utf8");
  } catch (err) {
    throw fromFsError(err);
  } finally {
    await fh?.close();
  }
}

export function meta(name: string, state: SourceState, ageSeconds: number | null, code?: SourceErrorCode): SourceMeta {
  return { name, state, ageSeconds, error: code ? { code, message: MESSAGES[code] } : null };
}

export type Collected<T> = { data: T; ageSeconds: number | null; stale?: boolean };

/**
 * Executa uma fonte com timeout. No timeout o AbortSignal e acionado, cancelando de fato
 * requisicoes HTTP em andamento. Qualquer erro vira meta classificada e data=null.
 */
export async function runSource<T>(name: string, fn: (signal: AbortSignal) => Promise<Collected<T>>, timeoutMs: number): Promise<SourceResult<T>> {
  const ctrl = new AbortController();
  let timer: NodeJS.Timeout | undefined;
  const timeout = new Promise<never>((_, reject) => {
    timer = setTimeout(() => {
      ctrl.abort();
      reject(new SourceError("error", "timeout"));
    }, timeoutMs);
  });
  try {
    const r = await Promise.race([fn(ctrl.signal), timeout]);
    return { data: r.data, meta: meta(name, r.stale ? "stale" : "ok", r.ageSeconds, r.stale ? "outdated" : undefined) };
  } catch (err) {
    const e = err instanceof SourceError ? err : new SourceError("error", "internal");
    return { data: null, meta: meta(name, e.state, null, e.code) };
  } finally {
    clearTimeout(timer);
  }
}

/** Cache com TTL e deduplicacao; devolve tambem o instante da coleta (para somar a idade do cache). */
export function cached<T>(fn: () => Promise<T>, ttlMs: number, now: () => number = Date.now): () => Promise<{ value: T; at: number }> {
  let value: { value: T; at: number } | undefined;
  let inflight: Promise<{ value: T; at: number }> | undefined;
  return () => {
    if (value && now() - value.at < ttlMs) return Promise.resolve(value);
    inflight ??= fn()
      .then((v) => (value = { value: v, at: now() }))
      .finally(() => {
        inflight = undefined;
      });
    return inflight;
  };
}

/** Soma o tempo em cache a idade informada pela fonte. */
export function withCacheAge<T>(r: SourceResult<T>, at: number, now: number = Date.now()): SourceResult<T> {
  const extra = Math.max(0, Math.floor((now - at) / 1000));
  return r.meta.ageSeconds === null || extra === 0 ? r : { ...r, meta: { ...r.meta, ageSeconds: r.meta.ageSeconds + extra } };
}

/**
 * GET HTTP com limite de bytes, sem redirecionamentos e cancelavel. Classifica falhas:
 * conexao -> unreachable · 401/403 -> unauthorized · outro nao-2xx -> bad_status · excesso -> too_large.
 */
export async function httpGet(url: string, opts: { signal: AbortSignal; headers?: Record<string, string>; maxBytes: number }): Promise<string> {
  let res: Response;
  try {
    res = await fetch(url, { signal: opts.signal, headers: opts.headers, redirect: "manual" });
  } catch (err) {
    if (opts.signal.aborted) throw new SourceError("error", "timeout");
    throw new SourceError("error", "unreachable");
  }
  if (res.status === 401 || res.status === 403) {
    await res.body?.cancel();
    throw new SourceError("error", "unauthorized");
  }
  if (res.status < 200 || res.status > 299) {
    await res.body?.cancel();
    throw new SourceError("error", "bad_status");
  }
  const reader = res.body?.getReader();
  if (!reader) return "";
  const chunks: Uint8Array[] = [];
  let total = 0;
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      total += value.byteLength;
      if (total > opts.maxBytes) {
        await reader.cancel();
        throw invalid("too_large");
      }
      chunks.push(value);
    }
  } catch (err) {
    if (err instanceof SourceError) throw err;
    throw new SourceError("error", opts.signal.aborted ? "timeout" : "unreachable");
  }
  return Buffer.concat(chunks).toString("utf8");
}
