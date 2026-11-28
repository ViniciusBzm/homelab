// Garante que as fixtures sao sinteticas: nada de IP privado, MAC, hostname ou usuario reais.
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { fileURLToPath } from "node:url";

const ALL = fileURLToPath(new URL("../fixtures", import.meta.url));

function files(dir: string): string[] {
  return readdirSync(dir).flatMap((n) => {
    const p = join(dir, n);
    return statSync(p).isDirectory() ? files(p) : [p];
  });
}

describe("fixtures", () => {
  it("nao contem dados sensiveis", () => {
    const all = files(ALL);
    expect(all.length).toBeGreaterThan(5);
    for (const f of all) {
      const text = readFileSync(f, "utf8");
      expect(text, f).not.toMatch(/\b(10|172\.(1[6-9]|2\d|3[01])|192\.168)\.\d{1,3}\.\d{1,3}\b/);
      // unica excecao: MAC sintetico "02:00:00:00:00:07" plantado para provar a filtragem
      expect(text.replace(/02:00:00:00:00:07/g, ""), f).not.toMatch(/([0-9a-f]{2}:){5}[0-9a-f]{2}/i);
      expect(text, f).not.toMatch(/homelab-01|vinicius/i);
    }
  });
});
