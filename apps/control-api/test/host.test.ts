import { afterEach, describe, expect, it } from "vitest";
import { join } from "node:path";
import { collectHost, countCpus, measureDisk, parseLoadavg, parseMeminfo, parseUptime } from "../src/sources/host";
import { tempRoot } from "./helpers";

describe("parsers do host", () => {
  it("loadavg, meminfo, uptime e CPUs", () => {
    expect(parseLoadavg("0.42 0.35 0.30 1/312 4242\n")).toEqual({ one: 0.42, five: 0.35, fifteen: 0.3 });
    expect(parseMeminfo("MemTotal: 1000 kB\nMemAvailable: 250 kB\n")).toEqual({ totalBytes: 1024000, availableBytes: 256000, usedPercent: 75 });
    expect(parseUptime("86400.55 300000.10\n")).toBe(86400);
    expect(countCpus("cpu  1 2\ncpu0 1\ncpu1 1\nintr 0\n")).toBe(2);
    expect(countCpus("intr 0\n")).toBeNull();
  });

  it.each([
    ["loadavg vazio", () => parseLoadavg("")],
    ["loadavg negativo", () => parseLoadavg("-1 0 0")],
    ["meminfo sem MemAvailable", () => parseMeminfo("MemTotal: 1000 kB\n")],
    ["meminfo incoerente", () => parseMeminfo("MemTotal: 10 kB\nMemAvailable: 20 kB\n")],
    ["uptime texto", () => parseUptime("abc")],
  ])("rejeita %s", (_n, fn) => {
    expect(fn).toThrow(expect.objectContaining({ state: "invalid" }));
  });

  it("disco: calcula pelo statfs e devolve null em erro ou valores absurdos", async () => {
    expect(await measureDisk("x", async () => ({ blocks: 100, bavail: 25, bsize: 4096 }))).toEqual({ totalBytes: 409600, availableBytes: 102400, usedPercent: 75 });
    expect(await measureDisk("x", async () => ({ blocks: 0, bavail: 0, bsize: 4096 }))).toBeNull();
    expect(await measureDisk("x", async () => Promise.reject(new Error("x")))).toBeNull();
  });
});

describe("collectHost", () => {
  let t: ReturnType<typeof tempRoot>;
  afterEach(() => t?.cleanup());
  const opts = (root: string) => ({
    label: "homelab-demo",
    timeoutMs: 2000,
    statfs: async () => ({ blocks: 1000, bavail: 720, bsize: 4096 }),
    paths: {
      loadavg: join(root, "proc", "loadavg"),
      meminfo: join(root, "proc", "meminfo"),
      uptime: join(root, "proc", "uptime"),
      stat: join(root, "proc", "stat"),
      hwmon: join(root, "sys", "class", "hwmon"),
      disk: join(root, "var", "backups", "homelab-backup.status"),
    },
  });

  it("ok com sensores validos (sensor sem temperatura e ignorado)", async () => {
    t = tempRoot();
    const r = await collectHost(opts(t.root));
    expect(r.meta).toMatchObject({ name: "host", state: "ok", ageSeconds: 0, error: null });
    expect(r.data).toMatchObject({ label: "homelab-demo", cpuCount: 4, uptimeSeconds: 86400, disk: { usedPercent: 28 } });
    expect(r.data?.temperatures).toEqual([
      { sensor: "k10temp", celsius: 51 },
      { sensor: "radeon", celsius: 53.5 },
    ]);
  });

  it("opcionais ausentes nao derrubam a fonte", async () => {
    t = tempRoot();
    t.rm("proc/stat");
    t.rm("sys");
    const r = await collectHost(opts(t.root));
    expect(r.meta.state).toBe("ok");
    expect(r.data).toMatchObject({ cpuCount: null, temperatures: [] });
  });

  it("obrigatorio ausente = missing; corrompido = invalid", async () => {
    t = tempRoot();
    t.rm("proc/meminfo");
    expect((await collectHost(opts(t.root))).meta).toMatchObject({ state: "missing", error: { code: "not_found" } });
    t.write("proc/meminfo", "lixo");
    expect((await collectHost(opts(t.root))).meta).toMatchObject({ state: "invalid", error: { code: "unparseable" } });
  });
});
