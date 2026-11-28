// Primitivas visuais: cartao, selos, barra (SVG, sem style inline: compativel com a CSP), estados.
import type { ReactNode } from "react";
import type { SourceMeta } from "@homelab/contracts";
import { FAILURE_TEXT, formatAge, SOURCE_STATE, type Tone } from "./format";
import type { FetchFailure } from "./api";

const TONE_TEXT: Record<Tone, string> = { ok: "text-ok", warn: "text-warn", bad: "text-bad", info: "text-info", mute: "text-mute" };
const TONE_BG: Record<Tone, string> = { ok: "bg-ok/12 ring-ok/30", warn: "bg-warn/12 ring-warn/30", bad: "bg-bad/12 ring-bad/35", info: "bg-info/12 ring-info/30", mute: "bg-ink-700/60 ring-ink-600" };
const TONE_DOT: Record<Tone, string> = { ok: "bg-ok", warn: "bg-warn", bad: "bg-bad", info: "bg-info", mute: "bg-mute" };
const TONE_FILL: Record<Tone, string> = { ok: "fill-ok", warn: "fill-warn", bad: "fill-bad", info: "fill-info", mute: "fill-mute" };

export const toneText = (t: Tone) => TONE_TEXT[t];

export function Dot({ tone, pulse = false }: { tone: Tone; pulse?: boolean }) {
  return (
    <span className="relative inline-flex size-2 shrink-0">
      {pulse && <span className={`absolute inline-flex size-full animate-ping rounded-full opacity-50 ${TONE_DOT[tone]}`} />}
      <span className={`relative inline-flex size-2 rounded-full ${TONE_DOT[tone]}`} />
    </span>
  );
}

export function Badge({ tone, children, testId }: { tone: Tone; children: ReactNode; testId?: string }) {
  return (
    <span data-testid={testId} data-tone={tone} className={`inline-flex items-center gap-1.5 whitespace-nowrap rounded-md px-2 py-0.5 text-[11px] font-medium ring-1 ring-inset ${TONE_BG[tone]} ${TONE_TEXT[tone]}`}>
      {children}
    </span>
  );
}

/** Barra de uso em SVG (largura por atributo, nao por style). */
export function Bar({ value, tone, label }: { value: number; tone: Tone; label: string }) {
  const w = Math.max(0, Math.min(100, value));
  return (
    <svg className="h-1.5 w-full overflow-hidden rounded-full" viewBox="0 0 100 6" preserveAspectRatio="none" role="meter" aria-label={label} aria-valuenow={Math.round(w)} aria-valuemin={0} aria-valuemax={100}>
      <rect x="0" y="0" width="100" height="6" className="fill-ink-700" />
      <rect x="0" y="0" width={w} height="6" className={TONE_FILL[tone]} />
    </svg>
  );
}

export function Card({ title, icon, meta, children, className = "", testId }: { title: string; icon?: ReactNode; meta?: ReactNode; children: ReactNode; className?: string; testId?: string }) {
  return (
    <section data-testid={testId} className={`flex h-full min-w-0 flex-col rounded-xl border border-ink-700/80 bg-ink-900/80 shadow-[0_1px_0_0_rgba(255,255,255,0.03)_inset] ${className}`}>
      <header className="flex flex-wrap items-center justify-between gap-x-3 gap-y-2 border-b border-ink-800 px-4 py-3">
        <h2 className="flex items-center gap-2 whitespace-nowrap text-[13px] font-semibold tracking-wide text-ink-100">
          {icon && <span className="text-ink-400">{icon}</span>}
          {title}
        </h2>
        <div className="ml-auto flex items-center gap-2">{meta}</div>
      </header>
      <div className="flex-1 p-4">{children}</div>
    </section>
  );
}

/** Selo de estado de UMA fonte (meta.sources) + idade do dado. */
export function SourceBadge({ meta, age, failure }: { meta: SourceMeta | undefined; age: number | null; failure: FetchFailure | null }) {
  if (!meta) return failure ? <Badge tone="bad">{FAILURE_TEXT[failure]}</Badge> : <Badge tone="mute">Carregando</Badge>;
  const s = SOURCE_STATE[meta.state];
  return (
    <span className="flex items-center gap-2">
      {failure && (
        <Badge tone="warn" testId="refresh-failed">
          Falha ao atualizar
        </Badge>
      )}
      <span className="tabular whitespace-nowrap text-[11px] text-ink-400" data-testid="age" title="Idade do dado">
        {formatAge(age)}
      </span>
      <Badge tone={s.tone} testId="source-state">
        {s.label}
      </Badge>
    </span>
  );
}

/** Corpo de cartao quando nao ha dado utilizavel. Nunca mostra valores ficticios. */
export function Empty({ title, detail, tone = "mute", testId = "empty" }: { title: string; detail?: string; tone?: Tone; testId?: string }) {
  return (
    <div data-testid={testId} className="flex h-full min-h-24 flex-col items-center justify-center gap-1 rounded-lg border border-dashed border-ink-700 px-4 py-6 text-center">
      <p className={`text-sm font-medium ${TONE_TEXT[tone]}`}>{title}</p>
      {detail && <p className="max-w-xs text-xs text-ink-400">{detail}</p>}
    </div>
  );
}

export function Skeleton({ rows = 3 }: { rows?: number }) {
  return (
    <div className="space-y-3" data-testid="loading" aria-busy="true">
      {Array.from({ length: rows }, (_, i) => (
        <div key={i} className="h-4 animate-pulse rounded bg-ink-800" />
      ))}
    </div>
  );
}

export function Stat({ label, value, sub, tone }: { label: string; value: ReactNode; sub?: ReactNode; tone?: Tone }) {
  return (
    <div className="min-w-0">
      <p className="text-[11px] font-medium uppercase tracking-wider text-ink-400">{label}</p>
      <p className={`tabular mt-1 truncate text-xl font-semibold ${tone ? TONE_TEXT[tone] : "text-ink-100"}`}>{value}</p>
      {sub && <p className="tabular mt-0.5 truncate text-xs text-ink-400">{sub}</p>}
    </div>
  );
}
