// Resumo: separa INDISPONIBILIDADE da fonte (a API nao obteve o dado) de FALHA OPERACIONAL
// relatada pela fonte (monitor DOWN, conteiner parado/unhealthy, backup com falha).
import type { BackupRun, Containers, HostSnapshot, Issue, Monitors, RestoreRun, Summary } from "@homelab/contracts";
import type { SourceResult } from "./source";

export type AllSources = {
  host: SourceResult<HostSnapshot>;
  backup: SourceResult<BackupRun>;
  restoreTest: SourceResult<RestoreRun>;
  containers: SourceResult<Containers>;
  monitors: SourceResult<Monitors>;
};

export function summarize(s: AllSources): Summary {
  const issues: Issue[] = [];
  for (const r of Object.values(s) as SourceResult<unknown>[]) {
    const { name, state, error } = r.meta;
    if (state === "stale") issues.push({ kind: "stale_data", source: name, code: "outdated", subject: null });
    else if (state !== "ok") issues.push({ kind: "source_unavailable", source: name, code: error?.code ?? "internal", subject: null });
  }
  const fail = (source: string, code: string, subject: string | null) => issues.push({ kind: "service_failure", source, code, subject });
  const warn = (source: string, code: string, subject: string | null) => issues.push({ kind: "service_warning", source, code, subject });
  const cs = s.containers.data;
  if (cs) {
    for (const c of cs.containers) {
      if (c.state !== "running") fail("containers", "container_not_running", c.name);
      else if (c.health === "unhealthy") fail("containers", "container_unhealthy", c.name);
      else if (c.health === "starting") warn("containers", "container_starting", c.name);
    }
    if (cs.total === 0) warn("containers", "no_containers", null);
    if (cs.skipped > 0) warn("containers", "incomplete_data", null);
  }
  const ms = s.monitors.data;
  if (ms) {
    // Somente "up" e saudavel: pendente, manutencao e desconhecido nunca contam como ok.
    for (const m of ms.monitors) {
      if (m.status === "down") fail("monitors", "monitor_down", m.name);
      else if (m.status !== "up") warn("monitors", `monitor_${m.status}`, m.name);
    }
    if (ms.total === 0) warn("monitors", "no_monitors", null);
    if (ms.skipped > 0) warn("monitors", "incomplete_data", null);
  }
  if (s.backup.data?.result === "fail") fail("backup", "backup_failed", null);
  if (s.restoreTest.data?.result === "fail") fail("restore-test", "restore_test_failed", null);

  const status = issues.some((i) => i.kind === "service_failure") ? "down" : issues.length > 0 ? "degraded" : "ok";
  const c = s.containers.data;
  const m = s.monitors.data;
  return {
    status,
    issues,
    counts: {
      containers: c ? { total: c.total, running: c.running } : null,
      monitors: m ? { total: m.total, up: m.up, down: m.down } : null,
    },
  };
}
