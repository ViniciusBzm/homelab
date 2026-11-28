import { overallView, SOURCE_NAME, SOURCE_STATE } from "./format";
import { IconRefresh, IconShield } from "./icons";
import { BackupPanel, ContainersPanel, HostPanel, IssuesPanel, MonitorsPanel } from "./panels";
import { Badge, Dot } from "./ui";
import { useDashboard } from "./useDashboard";

const HERO_RING = { ok: "ring-ok/30 from-ok/10", warn: "ring-warn/30 from-warn/10", bad: "ring-bad/40 from-bad/12", info: "ring-info/30 from-info/10", mute: "ring-ink-600 from-ink-800/40" } as const;

export function App() {
  const { state, now, nextAt, refresh } = useDashboard();
  const summary = state.summary;
  const view = overallView(summary.last?.data, summary.failure !== null, summary.receivedAt === null ? null : Math.floor((now - summary.receivedAt) / 1000));
  const refreshing = Object.values(state).some((s) => s.loading);
  const secs = Math.max(0, Math.ceil((nextAt - now) / 1000));
  const label = state.host.last?.data?.label;
  const version = state.health.last?.data?.version;

  return (
    <div className="min-h-dvh bg-[radial-gradient(1200px_600px_at_10%_-10%,rgba(91,141,239,0.10),transparent)]">
      <div className="mx-auto max-w-7xl px-4 py-5 sm:px-6 lg:py-7">
        <header className="mb-5 flex flex-wrap items-center justify-between gap-3">
          <div className="flex items-center gap-3">
            <div className="grid size-9 place-items-center rounded-lg bg-accent-soft text-accent ring-1 ring-accent/30">
              <IconShield />
            </div>
            <div>
              <h1 className="text-base font-semibold tracking-tight text-ink-100">HomeLab Control</h1>
              <p className="text-xs text-ink-400">
                {label ? <span className="font-mono">{label}</span> : "servidor"} · somente leitura
              </p>
            </div>
          </div>
          <div className="flex items-center gap-3">
            <span className="tabular text-xs text-ink-400" data-testid="countdown">
              {refreshing ? "Atualizando…" : `Atualiza em ${secs} s`}
            </span>
            <button
              type="button"
              onClick={() => void refresh()}
              disabled={refreshing}
              className="inline-flex items-center gap-1.5 rounded-lg bg-ink-800 px-3 py-1.5 text-xs font-medium text-ink-100 ring-1 ring-ink-700 transition hover:bg-ink-700 focus-visible:outline-2 focus-visible:outline-accent disabled:opacity-60"
            >
              <IconRefresh spin={refreshing} /> Atualizar
            </button>
          </div>
        </header>

        <section
          data-testid="overall"
          data-tone={view.tone}
          className={`mb-5 flex flex-wrap items-center justify-between gap-4 rounded-xl bg-gradient-to-r to-ink-900/60 p-4 ring-1 sm:p-5 ${HERO_RING[view.tone]}`}
        >
          <div className="flex items-center gap-3">
            <Dot tone={view.tone} pulse={view.tone === "bad"} />
            <div>
              <p className="text-lg font-semibold tracking-tight text-ink-100" data-testid="overall-label">
                {view.label}
              </p>
              <p className="text-sm text-ink-300">{view.detail}</p>
            </div>
          </div>
          <ul className="flex flex-wrap gap-1.5" aria-label="Estado das fontes">
            {(summary.last?.meta.sources ?? []).map((s) => (
              <li key={s.name}>
                <Badge tone={SOURCE_STATE[s.state].tone}>
                  {SOURCE_NAME[s.name] ?? s.name}: {SOURCE_STATE[s.state].label.toLowerCase()}
                </Badge>
              </li>
            ))}
          </ul>
        </section>

        <main className="grid gap-4 lg:grid-cols-12">
          <div className="lg:col-span-7">
            <HostPanel slot={state.host} now={now} />
          </div>
          <div className="lg:col-span-5">
            <IssuesPanel slot={summary} />
          </div>
          <div className="lg:col-span-7">
            <ContainersPanel slot={state.containers} now={now} />
          </div>
          <div className="lg:col-span-5">
            <BackupPanel slot={state.backup} now={now} />
          </div>
          <div className="lg:col-span-12">
            <MonitorsPanel slot={state.monitors} now={now} />
          </div>
        </main>

        <footer className="mt-6 flex flex-wrap items-center justify-between gap-2 text-[11px] text-ink-400">
          <span>Dados atualizados automaticamente a cada 15 s · nenhuma ação administrativa disponível.</span>
          <span className="font-mono">{version ? `API v${version}` : "API —"}</span>
        </footer>
      </div>
    </div>
  );
}
