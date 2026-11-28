// Fonte "monitors": GET /metrics do Uptime Kuma (Prometheus) com chave de API (Basic, senha = chave).
// Usa SO a metrica monitor_status e SO os rotulos monitor_name e monitor_type.
// monitor_url, monitor_hostname, monitor_port (que podem conter tokens de push e enderecos) sao descartados.
import { readFile } from "node:fs/promises";
import type { Monitor, Monitors } from "@homelab/contracts";
import { fromFsError, httpGet, invalid, runSource, SourceError, type SourceResult } from "./source";

const STATUS: Record<string, Monitor["status"]> = { "0": "down", "1": "up", "2": "pending", "3": "maintenance" };
const LINE = /^monitor_status\{(.*)\}\s+(-?\d+(?:\.\d+)?)\s*$/;
const LABEL = /([a-zA-Z_][a-zA-Z0-9_]*)="((?:[^"\\]|\\.)*)"\s*,?/g;

function unescape(v: string): string {
  return v.replace(/\\(["\\n])/g, (_m, c: string) => (c === "n" ? " " : c));
}

export function parseMetrics(body: string): Monitors {
  const monitors: Monitor[] = [];
  let sawMetric = false;
  for (const line of body.split("\n")) {
    const m = LINE.exec(line.trim());
    if (!m) continue;
    sawMetric = true;
    const labels = new Map<string, string>();
    for (const l of m[1]!.matchAll(LABEL)) labels.set(l[1]!, unescape(l[2]!));
    const name = (labels.get("monitor_name") ?? "").replace(/[\u0000-\u001f\u007f]/g, "").trim().slice(0, 64);
    const typeRaw = labels.get("monitor_type") ?? "";
    if (!name) continue;
    monitors.push({ name, type: /^[a-z0-9-]{1,32}$/.test(typeRaw) ? typeRaw : "unknown", status: STATUS[m[2]!] ?? "unknown" });
    if (monitors.length >= 200) break;
  }
  if (!sawMetric && !/^# (HELP|TYPE) /m.test(body)) throw invalid();
  monitors.sort((a, b) => a.name.localeCompare(b.name));
  return {
    total: monitors.length,
    up: monitors.filter((x) => x.status === "up").length,
    down: monitors.filter((x) => x.status === "down").length,
    monitors,
  };
}

/** Le a chave de API de um arquivo (fora do Git). Nunca registrada nem devolvida. */
export async function readApiKey(file: string | null): Promise<string> {
  if (!file) throw new SourceError("missing", "not_configured");
  let key: string;
  try {
    key = (await readFile(file, "utf8")).trim();
  } catch (err) {
    throw fromFsError(err);
  }
  if (!/^[A-Za-z0-9_+=\/.-]{8,256}$/.test(key)) throw invalid();
  return key;
}

export function collectMonitors(o: { kumaUrl: string; apiKeyFile: string | null; timeoutMs: number }): Promise<SourceResult<Monitors>> {
  return runSource(
    "monitors",
    async (signal) => {
      const key = await readApiKey(o.apiKeyFile);
      const auth = "Basic " + Buffer.from(`:${key}`).toString("base64");
      const body = await httpGet(new URL("/metrics", o.kumaUrl).href, { signal, headers: { authorization: auth }, maxBytes: 2 * 1024 * 1024 });
      return { data: parseMetrics(body), ageSeconds: 0 };
    },
    o.timeoutMs,
  );
}
