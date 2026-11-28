import type { ReactNode } from "react";
import type { SourceMeta } from "@homelab/contracts";
import type { EndpointKey, Slot } from "./api";
import {
  FAILURE_TEXT,
  formatBytes,
  formatDateTime,
  formatDuration,
  ISSUE_KIND,
  issueText,
  MONITOR_STATUS,
  pct,
  SOURCE_NAME,
  tempTone,
  usageTone,
  type Tone,
} from "./format";
import { IconAlert, IconArchive, IconBox, IconPulse, IconServer } from "./icons";
import { Badge, Bar, Card, Dot, Empty, Skeleton, SourceBadge, Stat, toneText } from "./ui";
import { liveAge } from "./useDashboard";

type Envelope = { data: unknown; meta: { sources: SourceMeta[] } };

/**
 * Decide o corpo de um cartao a partir do slot: carregando, sem resposta valida da API,
 * fonte sem dado (ausente/invalida/falha) ou o conteudo real. Nunca inventa valores.
 */
function SourceBody<K extends EndpointKey>({
  slot,
  source,
  render,
}: {
  slot: Slot<K>;
  source: string;
  render: (data: NonNullable<Extract<Slot<K>["last"], Envelope>["data"]>) => ReactNode;
}) {
  const env = slot.last as Envelope | null;
  if (!env) {
    if (slot.loading && !slot.failure) return <Skeleton />;
    return <Empty tone="bad" title={FAILURE_TEXT[slot.failure ?? "network"] ?? "Sem resposta"} detail="Nenhum dado válido foi recebido; o estado não pode ser confirmado." testId="api-failure" />;
  }
  const meta = env.meta.sources.find((s) => s.name === source);
  if (env.data === null || env.data === undefined) {
    const titles: Record<string, string> = { missing: "Dado ausente", invalid: "Dado inválido", error: "Falha ao consultar a fonte" };
    return <Empty tone={meta?.state === "error" ? "bad" : "warn"} title={titles[meta?.state ?? "error"] ?? "Sem dado"} detail={meta?.error?.message} testId="source-empty" />;
  }
  return (
    <>
      {meta?.state === "stale" && (
        <p data-testid="stale-banner" className="mb-3 rounded-md bg-warn/10 px-3 py-1.5 text-xs text-warn ring-1 ring-inset ring-warn/25">
          Exibindo o último dado conhecido, mais antigo que o limite.
        </p>
      )}
      {render(env.data as never)}
    </>
  );
}

const metaOf = (slot: Slot<EndpointKey>, name: string) => (slot.last as Envelope | null)?.meta.sources.find((s) => s.name === name);

function Header({ slot, name, now }: { slot: Slot<EndpointKey>; name: string; now: number }) {
  const m = metaOf(slot, name);
  return <SourceBadge meta={m} age={liveAge(m?.ageSeconds, slot.receivedAt, now)} failure={slot.failure} />;
}

export function HostPanel({ slot, now }: { slot: Slot<"host">; now: number }) {
  return (
    <Card title="Servidor" icon={<IconServer />} meta={<Header slot={slot} name="host" now={now} />} testId="panel-host">
      <SourceBody
        slot={slot}
        source="host"
        render={(h) => {
          const perCore = h.cpuCount ? (h.load.one / h.cpuCount) * 100 : null;
          return (
            <div className="space-y-5">
              <div className="grid grid-cols-2 gap-4 sm:grid-cols-3">
                <Stat label="Carga (1 min)" value={h.load.one.toFixed(2).replace(".", ",")} sub={`5 min ${h.load.five.toFixed(2).replace(".", ",")} · 15 min ${h.load.fifteen.toFixed(2).replace(".", ",")}`} />
                <Stat label="Carga por núcleo" value={perCore === null ? "—" : pct(perCore)} sub={h.cpuCount ? `${h.cpuCount} núcleos` : "núcleos desconhecidos"} tone={perCore === null ? undefined : usageTone(perCore)} />
                <Stat label="Uptime" value={formatDuration(h.uptimeSeconds)} sub={h.label ?? undefined} />
              </div>
              <Usage label="Memória" used={h.memory.totalBytes - h.memory.availableBytes} total={h.memory.totalBytes} percent={h.memory.usedPercent} />
              {h.disk ? (
                <Usage label="Armazenamento (/)" used={h.disk.totalBytes - h.disk.availableBytes} total={h.disk.totalBytes} percent={h.disk.usedPercent} />
              ) : (
                <p className="text-xs text-ink-400">Armazenamento: não foi possível medir.</p>
              )}
              <div>
                <p className="mb-2 text-[11px] font-medium uppercase tracking-wider text-ink-400">Temperaturas</p>
                {h.temperatures.length === 0 ? (
                  <p className="text-xs text-ink-400" data-testid="no-temps">
                    Nenhum sensor disponível.
                  </p>
                ) : (
                  <ul className="flex flex-wrap gap-2">
                    {h.temperatures.map((t) => (
                      <li key={t.sensor} className="flex items-center gap-2 rounded-md bg-ink-850 px-2.5 py-1 ring-1 ring-ink-700">
                        <Dot tone={tempTone(t.celsius)} />
                        <span className="font-mono text-[11px] text-ink-300">{t.sensor}</span>
                        <span className={`tabular text-sm font-semibold ${toneText(tempTone(t.celsius))}`}>{t.celsius.toFixed(1).replace(".", ",")} °C</span>
                      </li>
                    ))}
                  </ul>
                )}
              </div>
            </div>
          );
        }}
      />
    </Card>
  );
}

function Usage({ label, used, total, percent }: { label: string; used: number; total: number; percent: number }) {
  const tone = usageTone(percent);
  return (
    <div>
      <div className="mb-1.5 flex items-baseline justify-between gap-2">
        <span className="text-[11px] font-medium uppercase tracking-wider text-ink-400">{label}</span>
        <span className="tabular text-xs text-ink-300">
          <span className={`font-semibold ${toneText(tone)}`}>{pct(percent)}</span> · {formatBytes(used)} de {formatBytes(total)}
        </span>
      </div>
      <Bar value={percent} tone={tone} label={label} />
    </div>
  );
}

const CONTAINER_STATE: Record<string, { label: string; tone: Tone }> = {
  running: { label: "Em execução", tone: "ok" },
  exited: { label: "Parado", tone: "bad" },
  dead: { label: "Morto", tone: "bad" },
  restarting: { label: "Reiniciando", tone: "warn" },
  paused: { label: "Pausado", tone: "warn" },
  created: { label: "Criado", tone: "mute" },
  removing: { label: "Removendo", tone: "warn" },
  unknown: { label: "Desconhecido", tone: "mute" },
};
const HEALTH: Record<string, { label: string; tone: Tone }> = {
  healthy: { label: "Saudável", tone: "ok" },
  unhealthy: { label: "Não saudável", tone: "bad" },
  starting: { label: "Iniciando", tone: "warn" },
  none: { label: "Sem healthcheck", tone: "mute" },
};

export function ContainersPanel({ slot, now }: { slot: Slot<"containers">; now: number }) {
  return (
    <Card title="Contêineres" icon={<IconBox />} meta={<Header slot={slot} name="containers" now={now} />} testId="panel-containers">
      <SourceBody
        slot={slot}
        source="containers"
        render={(c) =>
          c.total === 0 ? (
            <Empty tone="warn" title="Nenhum contêiner informado" detail="A fonte respondeu sem itens; o estado não pode ser confirmado." />
          ) : (
            <div className="-mx-4 -my-1">
              <p className="tabular px-4 pb-2 text-xs text-ink-400">
                <span className="font-semibold text-ink-100">{c.running}</span> de {c.total} em execução
                {c.skipped > 0 && <span className="text-warn"> · {c.skipped} item(ns) ilegível(is) descartado(s)</span>}
              </p>
              <table className="w-full text-left text-sm">
                <thead>
                  <tr className="border-y border-ink-800 text-[11px] uppercase tracking-wider text-ink-400">
                    <th className="px-4 py-2 font-medium">Nome</th>
                    <th className="hidden px-2 py-2 font-medium md:table-cell">Imagem</th>
                    <th className="px-2 py-2 font-medium">Estado</th>
                    <th className="px-4 py-2 font-medium">Saúde</th>
                  </tr>
                </thead>
                <tbody>
                  {c.containers.map((x) => {
                    const st = CONTAINER_STATE[x.state] ?? CONTAINER_STATE.unknown!;
                    const hl = HEALTH[x.health] ?? HEALTH.none!;
                    return (
                      <tr key={x.name} className="border-b border-ink-800/70 last:border-0" data-testid="container-row">
                        <td className="px-4 py-2.5 font-medium text-ink-100">{x.name}</td>
                        <td className="hidden max-w-[18rem] truncate px-2 py-2.5 font-mono text-xs text-ink-400 md:table-cell" title={x.image}>
                          {x.image}
                        </td>
                        <td className="px-2 py-2.5">
                          <Badge tone={st.tone}>{st.label}</Badge>
                        </td>
                        <td className="px-4 py-2.5">
                          <Badge tone={hl.tone}>{hl.label}</Badge>
                        </td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            </div>
          )
        }
      />
    </Card>
  );
}

export function MonitorsPanel({ slot, now }: { slot: Slot<"monitors">; now: number }) {
  return (
    <Card title="Monitores" icon={<IconPulse />} meta={<Header slot={slot} name="monitors" now={now} />} testId="panel-monitors">
      <SourceBody
        slot={slot}
        source="monitors"
        render={(m) =>
          m.total === 0 ? (
            <Empty tone="warn" title="Nenhum monitor informado" detail="A fonte respondeu sem monitores; a disponibilidade não pode ser confirmada." />
          ) : (
            <div>
              <div className="mb-3 flex items-baseline justify-between">
                <p className="tabular text-xs text-ink-400">
                  <span className={`text-lg font-semibold ${m.up === m.total ? "text-ok" : m.down > 0 ? "text-bad" : "text-warn"}`} data-testid="monitors-up">
                    {m.up}/{m.total}
                  </span>{" "}
                  operacionais
                </p>
                <p className="tabular text-xs text-ink-400">
                  {m.down > 0 && <span className="text-bad">{m.down} fora · </span>}
                  {m.notUp > 0 && <span className="text-warn">{m.notUp} não confirmado(s)</span>}
                </p>
              </div>
              <ul className="grid gap-1.5 sm:grid-cols-2">
                {m.monitors.map((x) => {
                  const s = MONITOR_STATUS[x.status];
                  return (
                    <li key={x.name} data-testid="monitor-row" data-status={x.status} className="flex items-center justify-between gap-2 rounded-lg bg-ink-850 px-3 py-2 ring-1 ring-ink-800">
                      <span className="flex min-w-0 items-center gap-2">
                        <Dot tone={s.tone} pulse={x.status === "down"} />
                        <span className="truncate text-sm text-ink-100" title={x.name}>
                          {x.name}
                        </span>
                      </span>
                      <span className="flex shrink-0 items-center gap-2">
                        <span className="hidden font-mono text-[10px] uppercase text-ink-400 sm:inline">{x.type}</span>
                        <span className={`text-[11px] font-medium ${toneText(s.tone)}`}>{s.label}</span>
                      </span>
                    </li>
                  );
                })}
              </ul>
            </div>
          )
        }
      />
    </Card>
  );
}

export function BackupPanel({ slot, now }: { slot: Slot<"backup">; now: number }) {
  const env = slot.last;
  const metaB = env?.meta.sources.find((s) => s.name === "backup");
  const metaR = env?.meta.sources.find((s) => s.name === "restore-test");
  const worst = [metaB, metaR].find((m) => m && m.state !== "ok") ?? metaB;
  return (
    <Card
      title="Backup e restauração"
      icon={<IconArchive />}
      meta={<SourceBadge meta={worst} age={liveAge(metaB?.ageSeconds, slot.receivedAt, now)} failure={slot.failure} />}
      testId="panel-backup"
    >
      {!env ? (
        slot.loading && !slot.failure ? (
          <Skeleton />
        ) : (
          <Empty tone="bad" title={FAILURE_TEXT[slot.failure ?? "network"] ?? "Sem resposta"} detail="Nenhum dado válido foi recebido." testId="api-failure" />
        )
      ) : (
        <div className="grid gap-3 sm:grid-cols-2">
          <RunBox
            title="Último backup"
            meta={metaB}
            age={liveAge(metaB?.ageSeconds, slot.receivedAt, now)}
            run={env.data?.backup ?? null}
            details={(b) => [
              ["Snapshot", b.snapshot ?? "—", true],
              ["Repositório", b.repoSize ?? "—", false],
            ]}
            testId="backup-run"
          />
          <RunBox
            title="Teste de restauração"
            meta={metaR}
            age={liveAge(metaR?.ageSeconds, slot.receivedAt, now)}
            run={env.data?.restoreTest ?? null}
            details={(r) => [
              ["Itens comparados", r.items ?? "—", false],
              ["Bancos íntegros", r.databasesOk === true ? "sim" : r.databasesOk === false ? "não" : "—", false],
              ...(r.failures ? ([["Falhas", r.failures, false]] as [string, string | number, boolean][]) : []),
            ]}
            testId="restore-run"
          />
        </div>
      )}
    </Card>
  );
}

function RunBox<R extends { result: "ok" | "fail"; finishedAt: string }>({
  title,
  meta,
  age,
  run,
  details,
  testId,
}: {
  title: string;
  meta: SourceMeta | undefined;
  age: number | null;
  run: R | null;
  details: (r: R) => [string, string | number, boolean][];
  testId: string;
}) {
  const stale = meta?.state === "stale";
  return (
    <div data-testid={testId} className="rounded-lg bg-ink-850 p-3 ring-1 ring-ink-800">
      <div className="mb-2 flex items-center justify-between gap-2">
        <p className="text-[11px] font-medium uppercase tracking-wider text-ink-400">{title}</p>
        {run ? (
          <Badge tone={run.result === "fail" ? "bad" : stale ? "warn" : "ok"} testId="run-result">
            {run.result === "fail" ? "Falhou" : stale ? "OK · antigo" : "OK"}
          </Badge>
        ) : (
          <Badge tone={meta?.state === "error" ? "bad" : "mute"} testId="run-result">
            Sem dado
          </Badge>
        )}
      </div>
      {run ? (
        <>
          <p className="tabular text-sm text-ink-100">
            {formatDateTime(run.finishedAt)} <span className="text-xs text-ink-400">· {age === null ? "" : `há ${formatDuration(age)}`}</span>
          </p>
          <dl className="mt-2 space-y-1 text-xs">
            {details(run).map(([k, v, mono]) => (
              <div key={k} className="flex justify-between gap-2">
                <dt className="text-ink-400">{k}</dt>
                <dd className={`tabular text-ink-300 ${mono ? "font-mono" : ""}`}>{v}</dd>
              </div>
            ))}
          </dl>
        </>
      ) : (
        <p className="text-xs text-ink-400">{meta?.error?.message ?? "Nenhum registro válido."}</p>
      )}
    </div>
  );
}

export function IssuesPanel({ slot }: { slot: Slot<"summary"> }) {
  const s = slot.last?.data;
  return (
    <Card
      title="Problemas detectados"
      icon={<IconAlert />}
      meta={s ? <Badge tone={s.issues.length === 0 ? "ok" : s.status === "down" ? "bad" : "warn"}>{s.issues.length}</Badge> : null}
      testId="panel-issues"
    >
      {!slot.last ? (
        slot.loading && !slot.failure ? (
          <Skeleton rows={2} />
        ) : (
          <Empty tone="bad" title="Resumo indisponível" detail="Sem um resumo válido, nenhum estado é presumido." testId="api-failure" />
        )
      ) : !s ? (
        <Empty tone="warn" title="Resumo sem dados" />
      ) : s.issues.length === 0 ? (
        <p className="flex items-center gap-2 text-sm text-ok" data-testid="no-issues">
          <Dot tone="ok" /> Nenhum problema detectado.
        </p>
      ) : (
        <ul className="divide-y divide-ink-800">
          {s.issues.map((i, n) => {
            const k = ISSUE_KIND[i.kind];
            return (
              <li key={n} className="flex items-start gap-3 py-2 first:pt-0 last:pb-0" data-testid="issue" data-kind={i.kind}>
                <span className="w-32 shrink-0 pt-0.5">
                  <Badge tone={k.tone}>{k.label}</Badge>
                </span>
                <span className="min-w-0 text-sm">
                  <span className="text-ink-100">{issueText(i)}</span>
                  {i.subject && <span className="text-ink-300"> · {i.subject}</span>}
                  <span className="block text-xs text-ink-400">{SOURCE_NAME[i.source] ?? i.source}</span>
                </span>
              </li>
            );
          })}
        </ul>
      )}
    </Card>
  );
}
