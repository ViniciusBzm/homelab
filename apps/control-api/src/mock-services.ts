// Servidores HTTP SIMULADOS (Docker via socket-proxy e /metrics do Kuma) servindo fixtures.
// Usados no modo de desenvolvimento e nos testes; nunca conectam aos servicos reais.
import { createServer, type Server } from "node:http";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import type { AddressInfo } from "node:net";

export const HTTP_FIXTURES = fileURLToPath(new URL("../fixtures/http/", import.meta.url));
export const MOCK_KUMA_KEY = "fixture-kuma-key-0001";

export type Mock = { url: string; server: Server; close: () => Promise<void> };

/**
 * Sobe um servidor em 127.0.0.1. No Windows, faixas de portas reservadas (Hyper-V/WinNAT)
 * podem fazer a porta sorteada falhar com EACCES: tenta de novo algumas vezes.
 */
export async function startMock(handler: Parameters<typeof createServer>[1], port = 0): Promise<Mock> {
  const server = createServer(handler);
  for (let attempt = 0; ; attempt++) {
    try {
      await new Promise<void>((resolve, reject) => {
        server.once("error", reject);
        server.listen(attempt === 0 ? port : 0, "127.0.0.1", () => {
          server.off("error", reject);
          resolve();
        });
      });
      break;
    } catch (err) {
      const code = (err as NodeJS.ErrnoException).code;
      if (attempt >= 8 || (code !== "EACCES" && code !== "EADDRINUSE")) throw err;
    }
  }
  const { port: bound } = server.address() as AddressInfo;
  port = bound;
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

export function mockDocker(file = "docker-containers.json", port = 0): Promise<Mock> {
  const body = readFileSync(HTTP_FIXTURES + file);
  return startMock((req, res) => {
    if (req.method === "GET" && req.url?.startsWith("/containers/json")) {
      res.writeHead(200, { "content-type": "application/json" }).end(body);
    } else res.writeHead(403).end("forbidden");
  }, port);
}

export function mockKuma(file = "kuma-metrics.txt", key = MOCK_KUMA_KEY, port = 0): Promise<Mock> {
  const body = readFileSync(HTTP_FIXTURES + file);
  const expected = "Basic " + Buffer.from(`:${key}`).toString("base64");
  return startMock((req, res) => {
    if (req.url !== "/metrics") return void res.writeHead(404).end();
    if (req.headers.authorization !== expected) return void res.writeHead(401).end("unauthorized");
    res.writeHead(200, { "content-type": "text/plain; version=0.0.4" }).end(body);
  }, port);
}
