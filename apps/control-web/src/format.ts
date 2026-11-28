// Formatacao e regras de apresentacao (funcoes puras, testadas com Vitest).
import type { Issue, Monitor, SourceMeta, Summary } from "@homelab/contracts";

export type Tone = "ok" | "warn" | "bad" | "info" | "mute";

export function formatBytes(n: number): string {
  const units = ["B", "KiB", "MiB", "GiB", "TiB"];
  let v = n;
  let i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return `${v >= 100 || i === 0 ? Math.round(v) : v.toFixed(1)} ${units[i]}`.replace(".", ",");
}

export function formatDuration(totalSeconds: number): string {
  const s = Math.max(0, Math.floor(totalSeconds));
  const d = Math.floor(s / 86400);
  const h = Math.floor((s % 86400) / 3600);
  const m = Math.floor((s % 3600) / 60);
  if (d > 0) return `${d} d ${h} h`;
  if (h > 0) return `${h} h ${m} min`;
  if (m > 0) return `${m} min`;
  return `${s} s`;
}

export function formatAge(seconds: number | null): string {
  if (seconds === null) return "sem dado";
  if (seconds < 5) return "agora";
  if (seconds < 60) return `há ${Math.floor(seconds)} s`;
  if (seconds < 3600) return `há ${Math.floor(seconds / 60)} min`;
  if (seconds < 86400) return `há ${Math.floor(seconds / 3600)} h`;
  return `há ${Math.floor(seconds / 86400)} d`;
}

export function formatDateTime(iso: string): string {
  return new Intl.DateTimeFormat("pt-BR", { day: "2-digit", month: "2-digit", hour: "2-digit", minute: "2-digit" }).format(new Date(iso));
}

export const pct = (v: number) => `${v.toFixed(1).replace(".", ",")}%`;

/** Tom de uma barra de uso (memoria/disco). */
export const usageTone = (p: number): Tone => (p >= 90 ? "bad" : p >= 75 ? "warn" : "ok");
export const tempTone = (c: number): Tone => (c >= 80 ? "bad" : c >= 65 ? "warn" : "ok");

export type OverallView = { tone: Tone; label: string; detail: string };

const STATUS_WORD: Record<Summary["status"], string> = { ok: "operacional", degraded: "degradado", down: "falha detectada" };

/**
 * Estado geral: so e "Operacional" com um summary valido, recebido na ULTIMA tentativa e com status ok.
 * Se a atualizacao falhou, o ultimo resultado vira apenas referencia ("ultima leitura"), nunca o estado atual.
 */
export function overallView(summary: Summary | null | undefined, lastAttemptFailed: boolean, lastAgeSeconds: number | null = null): OverallView {
  if (!summary) return { tone: "mute", label: "Estado desconhecido", detail: "Não foi possível obter um resumo válido da API." };
  if (lastAttemptFailed)
    return { tone: "mute", label: "Estado não confirmado", detail: `A atualização falhou. Última leitura válida (${formatAge(lastAgeSeconds)}): ${STATUS_WORD[summary.status]}.` };
  const n = summary.issues.length;
  if (summary.status === "ok") return { tone: "ok", label: "Operacional", detail: "Todas as fontes respondem e nenhum problema foi detectado." };
  if (summary.status === "down") return { tone: "bad", label: "Falha detectada", detail: `${n} ${n === 1 ? "problema" : "problemas"}, incluindo falha operacional.` };
  return { tone: "warn", label: "Degradado", detail: `${n} ${n === 1 ? "ponto requer" : "pontos requerem"} atenção.` };
}

export const SOURCE_STATE: Record<SourceMeta["state"], { label: string; tone: Tone }> = {
  ok: { label: "Atualizado", tone: "ok" },
  stale: { label: "Desatualizado", tone: "warn" },
  missing: { label: "Ausente", tone: "mute" },
  invalid: { label: "Inválido", tone: "warn" },
  error: { label: "Falha na fonte", tone: "bad" },
};

/** Monitor: SOMENTE "up" e saudavel. Pendente, manutencao e desconhecido nunca aparecem como ok. */
export const MONITOR_STATUS: Record<Monitor["status"], { label: string; tone: Tone }> = {
  up: { label: "Operacional", tone: "ok" },
  down: { label: "Fora do ar", tone: "bad" },
  pending: { label: "Pendente", tone: "warn" },
  maintenance: { label: "Manutenção", tone: "info" },
  unknown: { label: "Desconhecido", tone: "mute" },
};

export const ISSUE_KIND: Record<Issue["kind"], { label: string; tone: Tone }> = {
  service_failure: { label: "Falha", tone: "bad" },
  service_warning: { label: "Atenção", tone: "warn" },
  stale_data: { label: "Desatualizado", tone: "warn" },
  source_unavailable: { label: "Fonte indisponível", tone: "mute" },
};

const ISSUE_TEXT: Record<string, string> = {
  container_not_running: "Contêiner não está em execução",
  container_unhealthy: "Contêiner reporta saúde ruim",
  container_starting: "Contêiner ainda iniciando",
  no_containers: "Nenhum contêiner informado",
  monitor_down: "Monitor fora do ar",
  monitor_pending: "Monitor pendente",
  monitor_maintenance: "Monitor em manutenção",
  monitor_unknown: "Monitor com estado desconhecido",
  no_monitors: "Nenhum monitor informado",
  incomplete_data: "Dados incompletos da fonte",
  backup_failed: "Último backup falhou",
  restore_test_failed: "Último teste de restauração falhou",
  outdated: "Dado mais antigo que o limite",
  not_found: "Dado ausente",
  not_configured: "Fonte não configurada",
  unreachable: "Serviço inacessível",
  unauthorized: "Credencial recusada",
  timeout: "Tempo limite excedido",
  unparseable: "Conteúdo inválido",
  bad_status: "Resposta inesperada",
};

export const SOURCE_NAME: Record<string, string> = {
  host: "Servidor",
  backup: "Backup",
  "restore-test": "Teste de restauração",
  containers: "Contêineres",
  monitors: "Monitores",
};

export function issueText(i: Issue): string {
  return ISSUE_TEXT[i.code] ?? i.code.replace(/_/g, " ");
}

export const FAILURE_TEXT: Record<string, string> = {
  network: "API inacessível",
  http: "API respondeu com erro",
  contract: "Resposta fora do contrato",
  timeout: "API não respondeu a tempo",
};
