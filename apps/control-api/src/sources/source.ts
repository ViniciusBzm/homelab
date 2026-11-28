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

/** Executa uma fonte com timeout; qualquer erro vira meta classificada e data=null. */
export async function runSource<T>(name: string, fn: () => Promise<Collected<T>>, timeoutMs: number): Promise<SourceResult<T>> {
  let timer: NodeJS.Timeout | undefined;
  const timeout = new Promise<never>((_, reject) => {
    timer = setTimeout(() => reject(new SourceError("error", "timeout")), timeoutMs);
  });
  try {
    const r = await Promise.race([fn(), timeout]);
    return { data: r.data, meta: meta(name, r.stale ? "stale" : "ok", r.ageSeconds, r.stale ? "outdated" : undefined) };
  } catch (err) {
    const e = err instanceof SourceError ? err : new SourceError("error", "internal");
    return { data: null, meta: meta(name, e.state, null, e.code) };
  } finally {
    clearTimeout(timer);
  }
}

/** Cache com TTL e deduplicacao de chamadas simultaneas (protege o CPU fraco do servidor). */
export function cached<T>(fn: () => Promise<T>, ttlMs: number, now: () => number = Date.now): () => Promise<T> {
  let value: { v: T; at: number } | undefined;
  let inflight: Promise<T> | undefined;
  return () => {
    if (value && now() - value.at < ttlMs) return Promise.resolve(value.v);
    inflight ??= fn()
      .then((v) => {
        value = { v, at: now() };
        return v;
      })
      .finally(() => {
        inflight = undefined;
      });
    return inflight;
  };
}
