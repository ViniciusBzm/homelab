// Fonte "host": /proc e /sys (somente leitura) + statfs de um arquivo montado do / do host.
// Obrigatorios: loadavg, meminfo, uptime. Opcionais (nao derrubam a fonte): CPUs, disco, temperaturas.
import { readdir, statfs as fsStatfs } from "node:fs/promises";
import { join } from "node:path";
import type { HostSnapshot } from "@homelab/contracts";
import { invalid, readSmall, runSource, type SourceResult } from "./source";

const num = (s: string | undefined) => {
  const n = Number(s);
  if (s === undefined || s === "" || !Number.isFinite(n) || n < 0) throw invalid();
  return n;
};
const pct = (total: number, available: number) => Math.round(((total - available) / total) * 1000) / 10;

export function parseLoadavg(text: string): HostSnapshot["load"] {
  const [one, five, fifteen] = text.trim().split(/\s+/);
  return { one: num(one), five: num(five), fifteen: num(fifteen) };
}

export function parseMeminfo(text: string): HostSnapshot["memory"] {
  const kb = (key: string) => {
    const m = new RegExp(`^${key}:\\s+(\\d+) kB$`, "m").exec(text);
    if (!m) throw invalid();
    return Number(m[1]) * 1024;
  };
  const totalBytes = kb("MemTotal");
  const availableBytes = kb("MemAvailable");
  if (totalBytes <= 0 || availableBytes > totalBytes) throw invalid();
  return { totalBytes, availableBytes, usedPercent: pct(totalBytes, availableBytes) };
}

export function parseUptime(text: string): number {
  return Math.floor(num(text.trim().split(/\s+/)[0]));
}

export function countCpus(statText: string): number | null {
  const n = statText.split("\n").filter((l) => /^cpu\d+\s/.test(l)).length;
  return n > 0 ? n : null;
}

export async function readTemperatures(hwmonDir: string): Promise<HostSnapshot["temperatures"]> {
  const out: HostSnapshot["temperatures"] = [];
  let entries: string[];
  try {
    entries = (await readdir(hwmonDir)).filter((d) => /^hwmon\d{1,3}$/.test(d)).sort();
  } catch {
    return out;
  }
  for (const dir of entries) {
    try {
      const sensor = (await readSmall(join(hwmonDir, dir, "name"), 64)).trim();
      if (!/^[a-z0-9_-]{1,32}$/.test(sensor)) continue;
      const raw = (await readSmall(join(hwmonDir, dir, "temp1_input"), 32)).trim();
      if (!/^-?\d{1,7}$/.test(raw)) continue; // vazio ou lixo: ignorado (nao vira 0 °C)
      const celsius = Number(raw) / 1000;
      if (Number.isFinite(celsius) && celsius >= -40 && celsius <= 150) out.push({ sensor, celsius });
    } catch {
      /* sensor sem temperatura: ignorado */
    }
    if (out.length >= 32) break;
  }
  return out;
}

export type StatfsFn = (path: string) => Promise<{ blocks: number | bigint; bavail: number | bigint; bsize: number | bigint }>;

export async function measureDisk(path: string, statfs: StatfsFn = fsStatfs): Promise<HostSnapshot["disk"]> {
  try {
    const s = await statfs(path);
    const totalBytes = Number(s.blocks) * Number(s.bsize);
    const availableBytes = Number(s.bavail) * Number(s.bsize);
    if (!(totalBytes > 0) || availableBytes > totalBytes) return null;
    return { totalBytes, availableBytes, usedPercent: pct(totalBytes, availableBytes) };
  } catch {
    return null;
  }
}

export type HostSourceOptions = {
  label: string | null;
  paths: { loadavg: string; meminfo: string; uptime: string; stat: string; hwmon: string; disk: string };
  timeoutMs: number;
  statfs?: StatfsFn;
};

export async function collectHost(o: HostSourceOptions): Promise<SourceResult<HostSnapshot>> {
  return runSource(
    "host",
    async () => {
      const [load, memory, uptimeSeconds] = await Promise.all([
        readSmall(o.paths.loadavg).then(parseLoadavg),
        readSmall(o.paths.meminfo, 16_384).then(parseMeminfo),
        readSmall(o.paths.uptime).then(parseUptime),
      ]);
      const [cpuCount, disk, temperatures] = await Promise.all([
        readSmall(o.paths.stat, 65_536).then(countCpus, () => null),
        measureDisk(o.paths.disk, o.statfs),
        readTemperatures(o.paths.hwmon),
      ]);
      return { data: { label: o.label, uptimeSeconds, cpuCount, load, memory, disk, temperatures }, ageSeconds: 0 };
    },
    o.timeoutMs,
  );
}
