// Servidores HTTP SIMULADOS (Docker via socket-proxy e /metrics do Kuma) servindo fixtures.
// Usados no modo de desenvolvimento e nos testes; nunca conectam aos servicos reais.
import { createServer, type Server } from "node:http";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import type { AddressInfo } from "node:net";

export const HTTP_FIXTURES = fileURLToPath(new URL("../fixtures/http/", import.meta.url));
export const MOCK_KUMA_KEY = "fixture-kuma-key-0001";

export type Mock = { url: string; server: Server; close: () => Promise<void> };

export async function startMock(handler: Parameters<typeof createServer>[1]): Promise<Mock> {
  const server = createServer(handler);
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
  const { port } = server.address() as AddressInfo;
  return {
    url: `http://127.0.0.1:${port}`,
    server,
    close: () =>
      new Promise((r) => {
        server.closeAllConnections();
        server.close(() => r());
      }),
  };
}

export function mockDocker(file = "docker-containers.json"): Promise<Mock> {
  const body = readFileSync(HTTP_FIXTURES + file);
  return startMock((req, res) => {
    if (req.method === "GET" && req.url?.startsWith("/containers/json")) {
      res.writeHead(200, { "content-type": "application/json" }).end(body);
    } else res.writeHead(403).end("forbidden");
  });
}

export function mockKuma(file = "kuma-metrics.txt", key = MOCK_KUMA_KEY): Promise<Mock> {
  const body = readFileSync(HTTP_FIXTURES + file);
  const expected = "Basic " + Buffer.from(`:${key}`).toString("base64");
  return startMock((req, res) => {
    if (req.url !== "/metrics") return void res.writeHead(404).end();
    if (req.headers.authorization !== expected) return void res.writeHead(401).end("unauthorized");
    res.writeHead(200, { "content-type": "text/plain; version=0.0.4" }).end(body);
  });
}
