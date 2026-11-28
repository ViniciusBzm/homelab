// Gera dist/schemas/*.json (JSON Schema) a partir dos contratos Zod.
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { z } from "zod";
import { publishedSchemas } from "./index";

export function toJsonSchemas(): Record<string, unknown> {
  return Object.fromEntries(
    Object.entries(publishedSchemas).map(([name, schema]) => [name, z.toJSONSchema(schema, { io: "output" })]),
  );
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  const out = join(dirname(fileURLToPath(import.meta.url)), "..", "dist", "schemas");
  mkdirSync(out, { recursive: true });
  for (const [name, schema] of Object.entries(toJsonSchemas())) {
    writeFileSync(join(out, `${name}.json`), JSON.stringify(schema, null, 2) + "\n");
  }
  console.log(`schemas exportados em ${out}`);
}
