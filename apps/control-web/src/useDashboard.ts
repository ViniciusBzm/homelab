import { useCallback, useEffect, useRef, useState } from "react";
import { ENDPOINTS, fetchEndpoint, type EndpointKey, type Slot } from "./api";

export const REFRESH_MS = 15_000;
const KEYS = Object.keys(ENDPOINTS) as EndpointKey[];

export type Dashboard = { [K in EndpointKey]: Slot<K> };

const empty = (): Dashboard =>
  Object.fromEntries(KEYS.map((k) => [k, { last: null, receivedAt: null, failure: null, loading: true }])) as unknown as Dashboard;

/** Busca os seis endpoints em paralelo a cada 15 s; mantem o ultimo dado valido e registra a falha. */
export function useDashboard() {
  const [state, setState] = useState<Dashboard>(empty);
  const [now, setNow] = useState(() => Date.now());
  const [nextAt, setNextAt] = useState(() => Date.now() + REFRESH_MS);
  const busy = useRef(false);

  const refresh = useCallback(async () => {
    if (busy.current) return;
    busy.current = true;
    setState((s) => Object.fromEntries(KEYS.map((k) => [k, { ...s[k], loading: true }])) as unknown as Dashboard);
    const results = await Promise.all(KEYS.map((k) => fetchEndpoint(k)));
    const at = Date.now();
    setState((s) => {
      const next = { ...s } as Record<EndpointKey, Slot<EndpointKey>>;
      KEYS.forEach((k, i) => {
        const r = results[i]!;
        next[k] = r.ok ? { last: r.data, receivedAt: at, failure: null, loading: false } : { ...s[k], failure: r.failure, loading: false };
      });
      return next as unknown as Dashboard;
    });
    setNextAt(Date.now() + REFRESH_MS);
    busy.current = false;
  }, []);

  useEffect(() => {
    void refresh();
    const poll = setInterval(() => void refresh(), REFRESH_MS);
    const tick = setInterval(() => setNow(Date.now()), 1000);
    return () => {
      clearInterval(poll);
      clearInterval(tick);
    };
  }, [refresh]);

  return { state, now, nextAt, refresh };
}

/** Idade do dado da fonte somada ao tempo desde que a resposta chegou ao navegador. */
export function liveAge(ageSeconds: number | null | undefined, receivedAt: number | null, now: number): number | null {
  if (ageSeconds === null || ageSeconds === undefined || receivedAt === null) return null;
  return ageSeconds + Math.max(0, Math.floor((now - receivedAt) / 1000));
}
