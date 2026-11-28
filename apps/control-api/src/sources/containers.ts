// Fonte "containers": GET /containers/json?all=1 no socket-proxy (somente leitura).
// Lista PERMITIDA de campos: Names, Image, State, Status (so para derivar a saude) e Created.
// Labels, Mounts, NetworkSettings, Ports, Command, Id etc. sao descartados; nunca usa inspect.
import type { Container, Containers } from "@homelab/contracts";
import { httpGet, invalid, runSource, type SourceResult } from "./source";

const STATES = new Set(["created", "running", "paused", "restarting", "removing", "exited", "dead"]);
const NAME = /^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$/;
const IMAGE = /^[a-z0-9][a-z0-9._/:@-]{0,199}$/;

export function parseContainers(body: string): Containers {
  let raw: unknown;
  try {
    raw = JSON.parse(body);
  } catch {
    throw invalid();
  }
  if (!Array.isArray(raw)) throw invalid();
  const containers: Container[] = [];
  let skipped = Math.max(0, raw.length - 256);
  for (const item of raw.slice(0, 256)) {
    if (!item || typeof item !== "object") {
      skipped++;
      continue;
    }
    const o = item as Record<string, unknown>;
    const first = Array.isArray(o.Names) ? o.Names[0] : undefined;
    const name = typeof first === "string" ? first.replace(/^\//, "") : "";
    if (!NAME.test(name)) {
      skipped++;
      continue;
    }
    const image = typeof o.Image === "string" && IMAGE.test(o.Image) ? o.Image : "unknown";
    const st = typeof o.State === "string" ? o.State.toLowerCase() : "";
    const status = typeof o.Status === "string" ? o.Status : "";
    const health = /\(unhealthy\)/.test(status)
      ? "unhealthy"
      : /\(healthy\)/.test(status)
        ? "healthy"
        : /\(health: starting\)/.test(status)
          ? "starting"
          : "none";
    const created = typeof o.Created === "number" && Number.isInteger(o.Created) && o.Created > 0 ? new Date(o.Created * 1000).toISOString() : null;
    containers.push({ name, image, state: (STATES.has(st) ? st : "unknown") as Container["state"], health, createdAt: created });
  }
  containers.sort((a, b) => a.name.localeCompare(b.name));
  return { total: containers.length, running: containers.filter((c) => c.state === "running").length, skipped, containers };
}

export function collectContainers(o: { dockerUrl: string; timeoutMs: number }): Promise<SourceResult<Containers>> {
  return runSource(
    "containers",
    async (signal) => ({
      data: parseContainers(await httpGet(new URL("/containers/json?all=1", o.dockerUrl).href, { signal, maxBytes: 2 * 1024 * 1024 })),
      ageSeconds: 0,
    }),
    o.timeoutMs,
  );
}
