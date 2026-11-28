// Desenvolvimento local: le as fixtures sinteticas em vez do sistema real.
import { fileURLToPath } from "node:url";

process.env.HL_CONTROL_ROOT ??= fileURLToPath(new URL("../fixtures/root", import.meta.url));
process.env.HL_CONTROL_LABEL ??= "homelab-demo";
await import("./main");
