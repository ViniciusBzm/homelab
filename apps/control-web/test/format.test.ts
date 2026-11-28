import { describe, expect, it } from "vitest";
import type { Summary } from "@homelab/contracts";
import { formatAge, formatBytes, formatDuration, MONITOR_STATUS, overallView, tempTone, usageTone } from "../src/format";
import { liveAge } from "../src/useDashboard";

const summary = (status: Summary["status"], issues: Summary["issues"] = []): Summary => ({ status, issues, counts: { containers: null, monitors: null } });

describe("estado geral nunca e falsamente operacional", () => {
  it("sem resumo valido = desconhecido", () => {
    expect(overallView(null, false)).toMatchObject({ tone: "mute", label: "Estado desconhecido" });
    expect(overallView(undefined, true)).toMatchObject({ tone: "mute" });
  });

  it("ultima atualizacao falhou = nao confirmado, mesmo que a leitura anterior fosse ok", () => {
    const v = overallView(summary("ok"), true, 125);
    expect(v.tone).toBe("mute");
    expect(v.label).toBe("Estado não confirmado");
    expect(v.detail).toContain("há 2 min");
  });

  it("ok, degradado e falha", () => {
    expect(overallView(summary("ok"), false).label).toBe("Operacional");
    expect(overallView(summary("degraded", [{ kind: "service_warning", source: "monitors", code: "monitor_pending", subject: "M" }]), false)).toMatchObject({ tone: "warn" });
    expect(overallView(summary("down", [{ kind: "service_failure", source: "monitors", code: "monitor_down", subject: "M" }]), false)).toMatchObject({ tone: "bad" });
  });

  it("so 'up' e saudavel nos monitores", () => {
    for (const st of ["pending", "maintenance", "unknown", "down"] as const) expect(MONITOR_STATUS[st].tone).not.toBe("ok");
    expect(MONITOR_STATUS.up.tone).toBe("ok");
  });
});

describe("formatacao", () => {
  it("bytes, duracao e idade", () => {
    expect(formatBytes(512)).toBe("512 B");
    expect(formatBytes(5_628_755_968)).toBe("5,2 GiB");
    expect(formatDuration(86_400)).toBe("1 d 0 h");
    expect(formatDuration(3_660)).toBe("1 h 1 min");
    expect(formatAge(null)).toBe("sem dado");
    expect(formatAge(2)).toBe("agora");
    expect(formatAge(7_200)).toBe("há 2 h");
  });

  it("limiares de uso e temperatura", () => {
    expect([usageTone(50), usageTone(80), usageTone(95)]).toEqual(["ok", "warn", "bad"]);
    expect([tempTone(50), tempTone(70), tempTone(85)]).toEqual(["ok", "warn", "bad"]);
  });

  it("idade ao vivo soma o tempo desde a resposta", () => {
    expect(liveAge(10, 1_000, 6_500)).toBe(15);
    expect(liveAge(null, 1_000, 6_500)).toBeNull();
    expect(liveAge(10, null, 6_500)).toBeNull();
  });
});
