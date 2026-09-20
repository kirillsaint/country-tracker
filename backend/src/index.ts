import { serve } from "@hono/node-server";
import { Hono } from "hono";
import { logger } from "hono/logger";
import { HTTPException } from "hono/http-exception";
import { config } from "./config.js";
import { closeDb, connectDb } from "./db.js";
import { api } from "./routes.js";
import { auth } from "./authRoutes.js";
import { resumeChecks } from "./regimes.js";
import { ensureCities } from "./cities.js";

const app = new Hono();

app.use(logger());
app.get("/health", (c) => c.json({ ok: true }));
app.route("/auth", auth);
app.route("/api", api);

app.onError((err, c) => {
  if (err instanceof HTTPException) {
    return c.json({ error: err.message }, err.status);
  }
  console.error(err);
  return c.json({ error: "internal_error" }, 500);
});

await connectDb();
void resumeChecks();
// справочник городов подтягивается в фоне, если его ещё нет
void ensureCities();

const server = serve({ fetch: app.fetch, port: config.port, hostname: "0.0.0.0" }, (info) => {
  console.log(`API listening on http://0.0.0.0:${info.port}`);
});

for (const sig of ["SIGINT", "SIGTERM"] as const) {
  process.on(sig, () => {
    server.close();
    closeDb().finally(() => process.exit(0));
  });
}
