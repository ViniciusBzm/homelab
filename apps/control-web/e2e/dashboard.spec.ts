// E2E do painel: caminho real (API de producao + front compilado + servicos simulados) e
// cenarios de borda injetados com page.route (respostas da API substituidas no navegador).
import { expect, test, type Page, type Route } from "@playwright/test";

const meta = (sources: object[]) => ({ apiVersion: "1", generatedAt: new Date().toISOString(), sources });
const src = (name: string, state = "ok", ageSeconds: number | null = 0, error: object | null = null) => ({ name, state, ageSeconds, error });
const json = (body: unknown, status = 200) => (route: Route) => route.fulfill({ status, contentType: "application/json", body: JSON.stringify(body) });

/** Coleta erros do console e violacoes de CSP durante o teste. */
function watchConsole(page: Page) {
  const errors: string[] = [];
  page.on("console", (m) => m.type() === "error" && errors.push(m.text()));
  page.on("pageerror", (e) => errors.push(e.message));
  return errors;
}

test("caminho real: painel completo, CSP restritiva e sem erros", async ({ page }) => {
  const errors = watchConsole(page);
  const res = await page.goto("/");
  const csp = res?.headers()["content-security-policy"] ?? "";
  expect(csp).toContain("default-src 'none'");
  expect(csp).toContain("script-src 'self'");
  expect(csp).not.toMatch(/unsafe-inline|unsafe-eval/);

  await expect(page.getByTestId("overall-label")).toHaveText("Operacional");
  await expect(page.getByTestId("container-row")).toHaveCount(4);
  await expect(page.getByTestId("monitor-row")).toHaveCount(6);
  await expect(page.getByTestId("monitors-up")).toHaveText("6/6");
  await expect(page.getByTestId("no-issues")).toBeVisible();
  await expect(page.getByTestId("backup-run").getByTestId("run-result")).toHaveText("OK");
  await expect(page.getByTestId("panel-host")).toContainText("51,0 °C");
  await expect(page.getByTestId("panel-host")).toContainText("28,0%");
  await expect(page.locator("body")).not.toContainText(/FIXTURE|api\/push|fixture-kuma-key/);

  const api = await page.request.get("/api/v1/host");
  expect(api.headers()["content-security-policy"]).toBe("default-src 'none'; frame-ancestors 'none'");
  expect(errors).toEqual([]);
});

test("monitores pendentes/desconhecidos nunca aparecem como saudaveis", async ({ page }) => {
  await page.route("**/api/v1/monitors", json({
    data: {
      total: 4, up: 1, down: 0, notUp: 3, skipped: 0,
      monitors: [
        { name: "A ok", type: "http", status: "up" },
        { name: "B pendente", type: "http", status: "pending" },
        { name: "C desconhecido", type: "http", status: "unknown" },
        { name: "D manutencao", type: "http", status: "maintenance" },
      ],
    },
    meta: meta([src("monitors")]),
  }));
  await page.goto("/");
  await expect(page.getByTestId("monitors-up")).toHaveText("1/4");
  const row = (n: string) => page.getByTestId("monitor-row").filter({ hasText: n });
  await expect(row("B pendente")).toContainText("Pendente");
  await expect(row("C desconhecido")).toContainText("Desconhecido");
  await expect(row("D manutencao")).toContainText("Manutenção");
  for (const n of ["B pendente", "C desconhecido", "D manutencao"]) await expect(row(n)).not.toContainText("Operacional");
});

test("resposta fora do contrato no resumo = estado desconhecido (nunca operacional)", async ({ page }) => {
  await page.route("**/api/v1/summary", json({ data: { status: "ok" }, meta: meta([]) }));
  await page.goto("/");
  await expect(page.getByTestId("overall-label")).toHaveText("Estado desconhecido");
  await expect(page.getByTestId("panel-issues").getByTestId("api-failure")).toBeVisible();
});

test("falha da API num endpoint nao inventa dados e nao afeta os outros", async ({ page }) => {
  await page.route("**/api/v1/containers", json({ error: { code: "internal", message: "erro interno" } }, 500));
  await page.goto("/");
  const panel = page.getByTestId("panel-containers");
  await expect(panel.getByTestId("api-failure")).toContainText("API respondeu com erro");
  await expect(page.getByTestId("container-row")).toHaveCount(0);
  await expect(page.getByTestId("monitor-row")).toHaveCount(6);
});

test("fonte ausente, invalida e desatualizada sao distinguidas", async ({ page }) => {
  await page.route("**/api/v1/host", json({ data: null, meta: meta([src("host", "missing", null, { code: "not_found", message: "dado ausente" })]) }));
  await page.route("**/api/v1/containers", json({ data: null, meta: meta([src("containers", "invalid", null, { code: "unparseable", message: "conteudo invalido" })]) }));
  await page.route("**/api/v1/backup", json({
    data: { backup: { result: "ok", finishedAt: "2026-01-01T03:30:00-03:00", snapshot: "0a1b2c3d", repoSize: "32M" }, restoreTest: null },
    meta: meta([src("backup", "stale", 9_000_000, { code: "outdated", message: "dado mais antigo que o limite" }), src("restore-test", "missing", null, { code: "not_found", message: "dado ausente" })]),
  }));
  await page.goto("/");
  await expect(page.getByTestId("panel-host").getByTestId("source-empty")).toContainText("Dado ausente");
  await expect(page.getByTestId("panel-host").getByTestId("source-state")).toHaveText("Ausente");
  await expect(page.getByTestId("panel-containers").getByTestId("source-empty")).toContainText("Dado inválido");
  await expect(page.getByTestId("backup-run").getByTestId("run-result")).toHaveText("OK · antigo");
  await expect(page.getByTestId("restore-run").getByTestId("run-result")).toHaveText("Sem dado");
  await expect(page.getByTestId("panel-backup").getByTestId("source-state")).toHaveText("Desatualizado");
});

test("falha ao atualizar depois de um sucesso: estado nao confirmado e ultimo dado mantido", async ({ page }) => {
  await page.goto("/");
  await expect(page.getByTestId("overall-label")).toHaveText("Operacional");
  await page.route("**/api/**", (r) => r.abort("connectionrefused"));
  await page.getByRole("button", { name: "Atualizar" }).click();
  await expect(page.getByTestId("overall-label")).toHaveText("Estado não confirmado");
  await expect(page.getByTestId("overall")).toContainText("operacional");
  await expect(page.getByTestId("panel-host").getByTestId("refresh-failed")).toBeVisible();
  await expect(page.getByTestId("container-row")).toHaveCount(4);
});

test("carregamento mostra esqueleto, sem valores ficticios", async ({ page }) => {
  await page.route("**/api/v1/host", async (r) => {
    await new Promise((res) => setTimeout(res, 1500));
    await r.continue();
  });
  await page.goto("/");
  await expect(page.getByTestId("panel-host").getByTestId("loading")).toBeVisible();
  await expect(page.getByTestId("panel-host")).not.toContainText("°C");
  await expect(page.getByTestId("panel-host")).toContainText("°C", { timeout: 5000 });
});

test("layout responsivo em tela de celular", async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto("/");
  await expect(page.getByTestId("overall-label")).toHaveText("Operacional");
  const overflow = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
  expect(overflow).toBeLessThanOrEqual(0);
});
