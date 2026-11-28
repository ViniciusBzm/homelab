// Cliente da API: SOMENTE os seis endpoints GET existentes. Toda resposta e validada pelo
// contrato; resposta invalida nunca vira dado (evita falso estado operacional).
import {
  BackupResponseSchema,
  ContainersResponseSchema,
  HealthResponseSchema,
  HostResponseSchema,
  MonitorsResponseSchema,
  SummaryResponseSchema,
} from "@homelab/contracts";
import type { z } from "zod";

export const ENDPOINTS = {
  health: { path: "/api/health", schema: HealthResponseSchema },
  summary: { path: "/api/v1/summary", schema: SummaryResponseSchema },
  host: { path: "/api/v1/host", schema: HostResponseSchema },
  containers: { path: "/api/v1/containers", schema: ContainersResponseSchema },
  monitors: { path: "/api/v1/monitors", schema: MonitorsResponseSchema },
  backup: { path: "/api/v1/backup", schema: BackupResponseSchema },
} as const;

export type EndpointKey = keyof typeof ENDPOINTS;
export type Payload<K extends EndpointKey> = z.output<(typeof ENDPOINTS)[K]["schema"]>;

/** Falha do lado do cliente (distinta do estado das fontes, que vem em meta.sources). */
export type FetchFailure = "network" | "http" | "contract" | "timeout";

export type Slot<K extends EndpointKey> = {
  /** Ultima resposta VALIDA recebida (mantida se uma atualizacao falhar). */
  last: Payload<K> | null;
  /** Instante (ms) em que `last` foi recebida. */
  receivedAt: number | null;
  /** Falha da ultima tentativa (null = a ultima tentativa deu certo). */
  failure: FetchFailure | null;
  loading: boolean;
};

export async function fetchEndpoint<K extends EndpointKey>(key: K, timeoutMs = 8000): Promise<{ ok: true; data: Payload<K> } | { ok: false; failure: FetchFailure }> {
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), timeoutMs);
  try {
    const res = await fetch(ENDPOINTS[key].path, { signal: ctrl.signal, headers: { accept: "application/json" }, cache: "no-store" });
    if (!res.ok) return { ok: false, failure: "http" };
    let body: unknown;
    try {
      body = await res.json();
    } catch {
      return { ok: false, failure: "contract" };
    }
    const parsed = ENDPOINTS[key].schema.safeParse(body);
    return parsed.success ? { ok: true, data: parsed.data as Payload<K> } : { ok: false, failure: "contract" };
  } catch {
    return { ok: false, failure: ctrl.signal.aborted ? "timeout" : "network" };
  } finally {
    clearTimeout(timer);
  }
}
