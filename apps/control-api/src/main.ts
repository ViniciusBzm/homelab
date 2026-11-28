import { buildApp } from "./app";
import { loadConfig } from "./config";

const cfg = loadConfig();
const app = buildApp(cfg);

for (const sig of ["SIGINT", "SIGTERM"] as const) {
  process.once(sig, () => {
    app.close().then(() => process.exit(0), () => process.exit(1));
  });
}

app.listen({ host: cfg.host, port: cfg.port }).catch((err) => {
  app.log.error(err);
  process.exit(1);
});
