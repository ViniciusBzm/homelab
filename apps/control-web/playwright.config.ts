import { defineConfig } from "@playwright/test";

const PORT = Number(process.env.E2E_PORT ?? 18090);

// Usa o Microsoft Edge instalado no Windows (canal "msedge"): nenhum navegador e baixado.
export default defineConfig({
  testDir: "./e2e",
  timeout: 30_000,
  fullyParallel: false,
  workers: 1,
  reporter: [["list"]],
  use: {
    baseURL: `http://127.0.0.1:${PORT}`,
    channel: process.env.E2E_CHANNEL ?? "msedge",
    viewport: { width: 1440, height: 1000 },
    trace: "off",
  },
  webServer: {
    command: "npx tsx e2e/serve.ts",
    url: `http://127.0.0.1:${PORT}/api/health`,
    reuseExistingServer: false,
    timeout: 60_000,
    env: { E2E_PORT: String(PORT) },
  },
});
