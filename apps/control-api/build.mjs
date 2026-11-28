// Empacota a API para producao: dist/server.mjs, executado com `node` puro (sem tsx).
// O codigo do monorepo (incluindo @homelab/contracts) e embutido; dependencias de runtime
// (fastify, @fastify/static, zod) ficam externas e vem de `npm ci --omit=dev`.
import { build } from "esbuild";
import { readFileSync } from "node:fs";

const pkg = JSON.parse(readFileSync(new URL("./package.json", import.meta.url), "utf8"));
const external = Object.keys(pkg.dependencies).filter((d) => !d.startsWith("@homelab/"));

await build({
  entryPoints: [new URL("./src/main.ts", import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, "$1")],
  outfile: new URL("./dist/server.mjs", import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, "$1"),
  bundle: true,
  platform: "node",
  target: "node22",
  format: "esm",
  external,
  minify: false,
  sourcemap: false,
  legalComments: "none",
  logLevel: "info",
});
