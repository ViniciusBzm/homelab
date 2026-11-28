// Fontes HTTP contra servidores SIMULADOS: cancelamento, filtragem, classificacao de falhas.
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { collectContainers, parseContainers } from "../src/sources/containers";
import { collectMonitors, parseMetrics } from "../src/sources/monitors";
import { httpGet, runSource } from "../src/sources/source";
import { HTTP_FIXTURES, MOCK_KUMA_KEY, mockDocker, mockKuma, startMock, type Mock } from "../src/mock-services";
import { readFileSync } from "node:fs";
import { CLOSED } from "./helpers";

const SECRETS = /FIXTURE-SECRET|FIXTUREPUSHTOKEN|secret-path|198\.51\.100|02:00:00|example\.invalid|host\.docker\.internal|api\/push|Mounts|Labels|Command|NetworkSettings|monitor_url|monitor_hostname|fixture-kuma-key/;

let mocks: Mock[] = [];
afterEach(async () => {
  await Promise.all(mocks.map((m) => m.close()));
  mocks = [];
});
const track = async (m: Promise<Mock>) => {
  const x = await m;
  mocks.push(x);
  return x;
};
function keyFile(content = MOCK_KUMA_KEY) {
  const f = join(mkdtempSync(join(tmpdir(), "hl-key-")), "key");
  writeFileSync(f, content);
  return f;
}

describe("httpGet", () => {
  it("cancela de fato a requisicao no timeout (o servidor ve a conexao fechar)", async () => {
    let closedAt = 0;
    const started = Date.now();
    const m = await track(
      startMock((req) => {
        req.socket.on("close", () => (closedAt = Date.now()));
      }),
    );
    const r = await runSource("lenta", async (signal) => ({ data: await httpGet(m.url, { signal, maxBytes: 100 }), ageSeconds: 0 }), 150);
    expect(r.meta).toMatchObject({ state: "error", error: { code: "timeout" } });
    await new Promise((res) => setTimeout(res, 100));
    expect(closedAt).toBeGreaterThan(0);
    expect(closedAt - started).toBeLessThan(1000);
  });

  it("classifica: inacessivel, 401/403, outro status, corpo grande demais e redirecionamento", async () => {
    const signal = new AbortController().signal;
    await expect(httpGet(CLOSED, { signal, maxBytes: 10 })).rejects.toMatchObject({ code: "unreachable" });
    const m = await track(
      startMock((req, res) => {
        if (req.url === "/401") return void res.writeHead(401).end();
        if (req.url === "/403") return void res.writeHead(403).end();
        if (req.url === "/500") return void res.writeHead(500).end();
        if (req.url === "/302") return void res.writeHead(302, { location: "http://example.invalid/" }).end();
        res.writeHead(200).end("x".repeat(5000));
      }),
    );
    await expect(httpGet(m.url + "/401", { signal, maxBytes: 10 })).rejects.toMatchObject({ code: "unauthorized" });
    await expect(httpGet(m.url + "/403", { signal, maxBytes: 10 })).rejects.toMatchObject({ code: "unauthorized" });
    await expect(httpGet(m.url + "/500", { signal, maxBytes: 10 })).rejects.toMatchObject({ code: "bad_status" });
    await expect(httpGet(m.url + "/302", { signal, maxBytes: 10 })).rejects.toMatchObject({ code: "bad_status" });
    await expect(httpGet(m.url + "/big", { signal, maxBytes: 1000 })).rejects.toMatchObject({ state: "invalid", code: "too_large" });
  });
});

describe("containers", () => {
  it("filtra estritamente os campos e deriva estado e saude", async () => {
    const m = await track(mockDocker());
    const r = await collectContainers({ dockerUrl: m.url, timeoutMs: 2000 });
    expect(r.meta.state).toBe("ok");
    expect(r.data).toMatchObject({ total: 4, running: 4 });
    expect(r.data?.containers[3]).toEqual({
      name: "uptime-kuma",
      image: "louislam/uptime-kuma:2.5.12-slim",
      state: "running",
      health: "healthy",
      createdAt: new Date(1795800000 * 1000).toISOString(),
    });
    expect(r.data?.containers.find((c) => c.name === "socket-proxy")?.health).toBe("none");
    for (const c of r.data!.containers) expect(Object.keys(c).sort()).toEqual(["createdAt", "health", "image", "name", "state"]);
    expect(JSON.stringify(r)).not.toMatch(SECRETS);
  });

  it("estados e saude variados; nomes e imagens invalidos sao tratados", () => {
    const d = parseContainers(
      JSON.stringify([
        { Names: ["/a"], Image: "x:1", State: "exited", Status: "Exited (1) 2 hours ago", Created: 1 },
        { Names: ["/b"], Image: "x:1", State: "running", Status: "Up 1 minute (unhealthy)" },
        { Names: ["/c"], Image: "X Y", State: "weird", Status: "Up (health: starting)" },
        { Names: ["/../etc"], Image: "x" },
        "lixo",
      ]),
    );
    expect(d.containers.map((c) => [c.name, c.state, c.health, c.image])).toEqual([
      ["a", "exited", "none", "x:1"],
      ["b", "running", "unhealthy", "x:1"],
      ["c", "unknown", "starting", "unknown"],
    ]);
    expect(d.running).toBe(1);
    expect(d.skipped).toBe(2);
  });

  it("JSON invalido = invalid; servico fora = unreachable", async () => {
    expect(() => parseContainers("{nao json")).toThrow(expect.objectContaining({ state: "invalid" }));
    expect(() => parseContainers('{"a":1}')).toThrow(expect.objectContaining({ state: "invalid" }));
    const r = await collectContainers({ dockerUrl: CLOSED, timeoutMs: 2000 });
    expect(r.meta).toMatchObject({ state: "error", error: { code: "unreachable" } });
  });
});

describe("monitors", () => {
  it("usa so monitor_status, so nome/tipo; descarta URL, host, porta e token de push", async () => {
    const m = await track(mockKuma());
    const r = await collectMonitors({ kumaUrl: m.url, apiKeyFile: keyFile(), timeoutMs: 2000 });
    expect(r.meta.state).toBe("ok");
    expect(r.data).toMatchObject({ total: 6, up: 6, down: 0 });
    expect(r.data?.monitors.find((x) => x.type === "push")).toEqual({ name: "Backup diario (restic)", type: "push", status: "up" });
    for (const x of r.data!.monitors) expect(Object.keys(x).sort()).toEqual(["name", "status", "type"]);
    expect(JSON.stringify(r)).not.toMatch(SECRETS);
  });

  it("mapeia DOWN, PENDING, MAINTENANCE e desconhecido; trata escapes e controles", () => {
    const d = parseMetrics(
      [
        'monitor_status{monitor_name="A",monitor_type="http"} 0',
        'monitor_status{monitor_name="B \\"x\\"",monitor_type="http"} 2',
        'monitor_status{monitor_name="C",monitor_type="TIPO RUIM"} 3',
        'monitor_status{monitor_name="D",monitor_type="http"} 9',
        'monitor_status{monitor_type="http"} 1',
      ].join("\n"),
    );
    expect(d.monitors.map((x) => [x.name, x.type, x.status])).toEqual([
      ["A", "http", "down"],
      ['B "x"', "http", "pending"],
      ["C", "unknown", "maintenance"],
      ["D", "http", "unknown"],
    ]);
    expect(d).toMatchObject({ total: 4, up: 0, down: 1, notUp: 3, skipped: 1 });
  });

  it("corpo que nao e Prometheus = invalid", () => {
    expect(() => parseMetrics("<html>login</html>")).toThrow(expect.objectContaining({ state: "invalid" }));
  });

  it("sem chave = missing/not_configured; chave errada = unauthorized; chave mal formada = invalid", async () => {
    const m = await track(mockKuma());
    expect((await collectMonitors({ kumaUrl: m.url, apiKeyFile: null, timeoutMs: 2000 })).meta).toMatchObject({ state: "missing", error: { code: "not_configured" } });
    expect((await collectMonitors({ kumaUrl: m.url, apiKeyFile: keyFile("chave-errada-123"), timeoutMs: 2000 })).meta).toMatchObject({ state: "error", error: { code: "unauthorized" } });
    expect((await collectMonitors({ kumaUrl: m.url, apiKeyFile: keyFile("x"), timeoutMs: 2000 })).meta).toMatchObject({ state: "invalid" });
    expect((await collectMonitors({ kumaUrl: m.url, apiKeyFile: join(tmpdir(), "nao-existe-hl"), timeoutMs: 2000 })).meta).toMatchObject({ state: "missing", error: { code: "not_found" } });
  });

  it("a fixture do Kuma realmente contem os dados sensiveis que devem ser filtrados", () => {
    expect(readFileSync(HTTP_FIXTURES + "kuma-metrics.txt", "utf8")).toMatch(/FIXTUREPUSHTOKEN/);
    expect(readFileSync(HTTP_FIXTURES + "docker-containers.json", "utf8")).toMatch(/FIXTURE-SECRET-LABEL/);
  });
});
