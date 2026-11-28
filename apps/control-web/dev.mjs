// Desenvolvimento local com hot reload: API (fixtures + Docker/Kuma SIMULADOS) + Vite.
// Painel em http://127.0.0.1:5173 (o Vite encaminha /api para a API em 127.0.0.1:8088).
import { spawn, spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("../..", import.meta.url));
const opts = { cwd: root, stdio: "inherit", shell: process.platform === "win32" };
const procs = [
  spawn("npm", ["run", "dev", "-w", "@homelab/control-api"], opts),
  spawn("npm", ["run", "dev", "-w", "@homelab/control-web"], opts),
];
// Encerra a arvore inteira de cada processo (no Windows, kill() so atinge o shell intermediario).
const killTree = (p) => {
  if (p.exitCode !== null || !p.pid) return;
  if (process.platform === "win32") spawnSync("taskkill", ["/pid", String(p.pid), "/T", "/F"], { stdio: "ignore" });
  else p.kill("SIGTERM");
};
const stop = (code = 0) => {
  for (const p of procs) killTree(p);
  process.exit(code);
};
process.on("SIGINT", () => stop());
process.on("SIGTERM", () => stop());
for (const p of procs) p.on("exit", () => stop(1));
