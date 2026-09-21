import { createHash, randomBytes } from "node:crypto";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { Hono, type MiddlewareHandler } from "hono";
import { zValidator } from "@hono/zod-validator";
import { HTTPException } from "hono/http-exception";
import { deleteCookie, getCookie, setCookie } from "hono/cookie";
import { serveStatic } from "@hono/node-server/serve-static";
import { createRemoteJWKSet, jwtVerify } from "jose";
import { ObjectId } from "mongodb";
import { z } from "zod";
import { config } from "./config.js";
import {
  adminSessions, dayOverrides, discoverAiCache, discoverLog, documents, entries, jobs, placeCache, placeDismissals, placeRatings, placeSaves,
  points, rawDb, regimeChecks, regimes, rules, sessions, tastePreferences, tasteProfiles, users,
} from "./db.js";
import { isAiEnabled } from "./ai.js";
import { isPlacesEnabled } from "./places.js";

// Админка в браузере: вход только через Google (web-клиент), внутрь пускаем email из ADMIN_EMAILS.
// Сессия — httpOnly cookie, в базе лежит только хеш. Read-only просмотр всего плюс несколько
// опасных действий (удалить пользователя со всеми данными, отозвать сессии, почистить кэши и задачи).

export const isAdminEnabled = () => config.adminEmails.size > 0 && config.adminGoogleClientId.length > 0;

type AdminEnv = { Variables: { adminEmail: string } };
export const admin = new Hono<AdminEnv>();

const COOKIE = "stamps_admin";
const SESSION_DAYS = 7;
const googleJWKS = createRemoteJWKSet(new URL(config.googleJwksUrl));
const hash = (t: string) => createHash("sha256").update(t).digest("hex");

const requireAdmin: MiddlewareHandler<AdminEnv> = async (c, next) => {
  const token = getCookie(c, COOKIE);
  if (!token) throw new HTTPException(401, { message: "not signed in" });
  const s = await adminSessions.findOne({ tokenHash: hash(token) });
  if (!s || s.expiresAt < new Date() || !config.adminEmails.has(s.email)) throw new HTTPException(401, { message: "session expired" });
  c.set("adminEmail", s.email);
  await next();
};

// MARK: вход

admin.get("/api/config", (c) => c.json({ enabled: isAdminEnabled(), googleClientId: config.adminGoogleClientId }));

admin.post("/api/login", zValidator("json", z.object({ credential: z.string().min(10) })), async (c) => {
  if (!isAdminEnabled()) throw new HTTPException(503, { message: "admin is not configured (ADMIN_EMAILS, ADMIN_GOOGLE_CLIENT_ID)" });
  let email: string;
  let name: string | null;
  try {
    const { payload } = await jwtVerify(c.req.valid("json").credential, googleJWKS, {
      issuer: ["https://accounts.google.com", "accounts.google.com"],
      audience: config.adminGoogleClientId,
    });
    if (typeof payload.email !== "string" || payload.email_verified !== true) throw new Error("no verified email");
    email = payload.email.toLowerCase();
    name = typeof payload.name === "string" ? payload.name : null;
  } catch (e) {
    throw new HTTPException(401, { message: `invalid google token: ${(e as Error).message}` });
  }
  if (!config.adminEmails.has(email)) throw new HTTPException(403, { message: `${email} is not an admin` });
  const token = randomBytes(32).toString("base64url");
  await adminSessions.insertOne({ tokenHash: hash(token), email, name, createdAt: new Date().toISOString(), expiresAt: new Date(Date.now() + SESSION_DAYS * 86_400_000) });
  setCookie(c, COOKIE, token, {
    httpOnly: true,
    sameSite: "Lax",
    path: "/admin",
    maxAge: SESSION_DAYS * 86_400,
    // за Cloudflare запрос приходит по http, но наружу это https
    secure: process.env.NODE_ENV === "production",
  });
  return c.json({ email, name });
});

admin.post("/api/logout", async (c) => {
  const token = getCookie(c, COOKIE);
  if (token) await adminSessions.deleteOne({ tokenHash: hash(token) });
  deleteCookie(c, COOKIE, { path: "/admin" });
  return c.json({ ok: true });
});

admin.get("/api/me", requireAdmin, async (c) => {
  const s = await adminSessions.findOne({ tokenHash: hash(getCookie(c, COOKIE)!) });
  return c.json({ email: c.get("adminEmail"), name: s?.name ?? null });
});

admin.use("/api/*", async (c, next) => {
  // всё ниже /api, кроме входа — только для админа
  if (["/admin/api/config", "/admin/api/login", "/admin/api/logout"].includes(c.req.path)) return next();
  return requireAdmin(c, next);
});

// MARK: обзор

const COLLECTIONS = [
  "users", "sessions", "points", "day_overrides", "rules", "documents", "entries", "regimes", "regime_checks",
  "place_ratings", "place_saves", "place_dismissals", "taste_preferences", "taste_profiles", "discover_log",
  "discover_ai_cache", "place_cache", "jobs", "cities", "cities_meta", "admin_sessions",
] as const;

// коллекции с полем userId — их можно фильтровать по пользователю и они удаляются вместе с ним.
// Функция, а не константа: экспорты db.ts заполняются при подключении, после загрузки модуля
const userCollections = () => ({
  points, day_overrides: dayOverrides, rules, documents, entries, regimes, place_ratings: placeRatings, place_saves: placeSaves,
  place_dismissals: placeDismissals, taste_preferences: tastePreferences, taste_profiles: tasteProfiles, discover_log: discoverLog, sessions, jobs,
});
type UserCollection = keyof ReturnType<typeof userCollections>;
const USER_COLLECTION_NAMES = new Set(["points", "day_overrides", "rules", "documents", "entries", "regimes", "place_ratings", "place_saves", "place_dismissals", "taste_preferences", "taste_profiles", "discover_log", "sessions", "jobs"]);

const oid = (s: string) => {
  if (!ObjectId.isValid(s)) throw new HTTPException(400, { message: "bad id" });
  return new ObjectId(s);
};
const isoDaysAgo = (d: number) => new Date(Date.now() - d * 86_400_000).toISOString();

admin.get("/api/overview", async (c) => {
  const db = rawDb();
  const counts: Record<string, number> = {};
  await Promise.all(COLLECTIONS.map(async (name) => { counts[name] = await db.collection(name).estimatedDocumentCount(); }));
  const [pointsByDay, latestUsers, latestPoints, runningJobs, sources] = await Promise.all([
    points.aggregate<{ _id: string; n: number }>([{ $match: { localDate: { $gte: isoDaysAgo(30).slice(0, 10) } } }, { $group: { _id: "$localDate", n: { $sum: 1 } } }, { $sort: { _id: 1 } }]).toArray(),
    users.find({}, { sort: { createdAt: -1 }, limit: 8 }).toArray(),
    points.find({}, { sort: { recordedAt: -1 }, limit: 12, projection: { _id: 0 } }).toArray(),
    jobs.countDocuments({ status: { $in: ["queued", "running"] } }),
    points.aggregate<{ _id: string; n: number }>([{ $group: { _id: "$source", n: { $sum: 1 } } }]).toArray(),
  ]);
  const emailById = new Map(latestUsers.map((u) => [u._id.toHexString(), u.email]));
  return c.json({
    counts,
    pointsByDay: pointsByDay.map((d) => ({ day: d._id, n: d.n })),
    sources: Object.fromEntries(sources.map((s) => [s._id, s.n])),
    latestUsers: latestUsers.map(publicAdminUser),
    latestPoints: latestPoints.map((p) => ({ ...p, userId: p.userId.toHexString(), userEmail: emailById.get(p.userId.toHexString()) ?? null })),
    runningJobs,
    features: { ai: isAiEnabled(), places: isPlacesEnabled(), selfStore: !!(config.selfStoreUrl && config.selfStoreAppId), models: { main: config.openRouterModel, fast: config.openRouterFastModel } },
  });
});

function publicAdminUser(u: { _id: ObjectId; email: string | null; name: string | null; apple: unknown; google: unknown; createdAt: string }) {
  return { id: u._id.toHexString(), email: u.email, name: u.name, apple: !!u.apple, google: !!u.google, createdAt: u.createdAt };
}

// MARK: пользователи

admin.get("/api/users", async (c) => {
  const list = await users.find({}, { sort: { createdAt: -1 } }).toArray();
  const byUser = <T extends { _id: ObjectId }>(rows: T[]) => new Map(rows.map((r) => [r._id.toHexString(), r]));
  const [pts, docs, sess, ratings] = await Promise.all([
    byUser(await points.aggregate<{ _id: ObjectId; n: number; last: string; countries: string[] }>([{ $group: { _id: "$userId", n: { $sum: 1 }, last: { $max: "$recordedAt" }, countries: { $addToSet: "$countryCode" } } }]).toArray()),
    byUser(await documents.aggregate<{ _id: ObjectId; n: number }>([{ $group: { _id: "$userId", n: { $sum: 1 } } }]).toArray()),
    byUser(await sessions.aggregate<{ _id: ObjectId; n: number; last: string }>([{ $group: { _id: "$userId", n: { $sum: 1 }, last: { $max: "$lastUsedAt" } } }]).toArray()),
    byUser(await placeRatings.aggregate<{ _id: ObjectId; n: number }>([{ $group: { _id: "$userId", n: { $sum: 1 } } }]).toArray()),
  ]);
  return c.json({
    users: list.map((u) => {
      const id = u._id.toHexString();
      return {
        ...publicAdminUser(u),
        points: pts.get(id)?.n ?? 0,
        lastPointAt: pts.get(id)?.last ?? null,
        countries: (pts.get(id)?.countries ?? []).filter(Boolean).length,
        documents: docs.get(id)?.n ?? 0,
        sessions: sess.get(id)?.n ?? 0,
        lastSeenAt: sess.get(id)?.last ?? null,
        ratings: ratings.get(id)?.n ?? 0,
      };
    }),
  });
});

admin.get("/api/users/:id", async (c) => {
  const userId = oid(c.req.param("id"));
  const u = await users.findOne({ _id: userId });
  if (!u) throw new HTTPException(404, { message: "user not found" });
  const counts: Record<string, number> = {};
  await Promise.all(Object.entries(userCollections()).map(async ([name, col]) => { counts[name] = await (col as typeof points).countDocuments({ userId }); }));
  const [countries, sess, prefs, profile] = await Promise.all([
    points.aggregate<{ _id: string | null; n: number; first: string; last: string; cities: string[] }>([
      { $match: { userId } },
      { $group: { _id: "$countryCode", n: { $sum: 1 }, first: { $min: "$recordedAt" }, last: { $max: "$recordedAt" }, cities: { $addToSet: "$city" } } },
      { $sort: { last: -1 } },
    ]).toArray(),
    sessions.find({ userId }, { sort: { lastUsedAt: -1 }, projection: { _id: 0, tokenHash: 0 } }).toArray(),
    tastePreferences.findOne({ userId }, { projection: { _id: 0, userId: 0 } }),
    tasteProfiles.findOne({ userId }, { projection: { _id: 0, userId: 0 } }),
  ]);
  return c.json({
    user: { ...publicAdminUser(u), providers: { apple: u.apple, google: u.google }, rulesSeeded: !!u.rulesSeeded },
    counts,
    countries: countries.map((x) => ({ countryCode: x._id, n: x.n, first: x.first, last: x.last, cities: x.cities.filter(Boolean) })),
    sessions: sess,
    taste: { preferences: prefs, profile },
  });
});

admin.get("/api/users/:id/points", zValidator("query", z.object({ from: z.string().optional(), to: z.string().optional(), limit: z.coerce.number().int().min(1).max(20000).default(5000), skip: z.coerce.number().int().min(0).default(0) })), async (c) => {
  const userId = oid(c.req.param("id"));
  const q = c.req.valid("query");
  const filter: Record<string, unknown> = { userId };
  if (q.from || q.to) filter.recordedAt = { ...(q.from ? { $gte: q.from } : {}), ...(q.to ? { $lte: q.to + "T23:59:59.999Z" } : {}) };
  const [total, rows] = await Promise.all([
    points.countDocuments(filter),
    points.find(filter, { sort: { recordedAt: -1 }, skip: q.skip, limit: q.limit, projection: { _id: 0, userId: 0 } }).toArray(),
  ]);
  return c.json({ total, points: rows });
});

// любая пользовательская коллекция целиком: документы, правила, оценки…
admin.get("/api/users/:id/data/:collection", async (c) => {
  const userId = oid(c.req.param("id"));
  const name = c.req.param("collection") as UserCollection;
  const col = userCollections()[name];
  if (!col) throw new HTTPException(404, { message: "unknown collection" });
  const projection: Record<string, 0> = { _id: 0, userId: 0, ...(name === "sessions" ? { tokenHash: 0 } : {}) };
  const rows = await (col as typeof points).find({ userId }, { projection, limit: 2000 }).toArray();
  return c.json({ rows });
});

admin.delete("/api/users/:id", async (c) => {
  const userId = oid(c.req.param("id"));
  const u = await users.findOne({ _id: userId });
  if (!u) throw new HTTPException(404, { message: "user not found" });
  const deleted: Record<string, number> = {};
  for (const [name, col] of Object.entries(userCollections())) deleted[name] = (await (col as typeof points).deleteMany({ userId })).deletedCount;
  await users.deleteOne({ _id: userId });
  console.log(`admin ${c.get("adminEmail")} deleted user ${u.email ?? userId.toHexString()}:`, deleted);
  return c.json({ deleted });
});

admin.delete("/api/users/:id/sessions", async (c) => {
  const userId = oid(c.req.param("id"));
  const r = await sessions.deleteMany({ userId });
  return c.json({ deleted: r.deletedCount });
});

// MARK: общие списки

admin.get("/api/regime-checks", async (c) => {
  const rows = await regimeChecks.find({}, { sort: { requestedAt: -1 }, limit: 200, projection: { _id: 0 } }).toArray();
  return c.json({ rows });
});

admin.get("/api/jobs", async (c) => {
  const rows = await jobs.find({}, { sort: { createdAt: -1 }, limit: 200, projection: { _id: 0 } }).toArray();
  const emails = new Map((await users.find({ _id: { $in: rows.map((r) => r.userId) } }).toArray()).map((u) => [u._id.toHexString(), u.email]));
  return c.json({ rows: rows.map((r) => ({ ...r, userId: r.userId.toHexString(), userEmail: emails.get(r.userId.toHexString()) ?? null })) });
});

admin.delete("/api/jobs", async (c) => {
  const r = await jobs.deleteMany({ status: { $in: ["done", "failed"] } });
  return c.json({ deleted: r.deletedCount });
});

admin.delete("/api/cache", async (c) => {
  const [a, b] = await Promise.all([placeCache.deleteMany({}), discoverAiCache.deleteMany({})]);
  return c.json({ deleted: { place_cache: a.deletedCount, discover_ai_cache: b.deletedCount } });
});

// MARK: сырые коллекции

admin.get("/api/collections", async (c) => {
  const db = rawDb();
  const rows = await Promise.all(COLLECTIONS.map(async (name) => {
    const [count, stats] = await Promise.all([
      db.collection(name).estimatedDocumentCount(),
      db.command({ collStats: name }).catch(() => null) as Promise<{ size?: number; storageSize?: number; totalIndexSize?: number } | null>,
    ]);
    return { name, count, size: stats?.size ?? null, storageSize: stats?.storageSize ?? null, indexSize: stats?.totalIndexSize ?? null, perUser: USER_COLLECTION_NAMES.has(name) };
  }));
  return c.json({ collections: rows });
});

admin.get("/api/collections/:name", zValidator("query", z.object({ skip: z.coerce.number().int().min(0).default(0), limit: z.coerce.number().int().min(1).max(200).default(50), userId: z.string().optional(), filter: z.string().optional() })), async (c) => {
  const name = c.req.param("name") as (typeof COLLECTIONS)[number];
  if (!COLLECTIONS.includes(name)) throw new HTTPException(404, { message: "unknown collection" });
  const q = c.req.valid("query");
  let filter: Record<string, unknown> = {};
  if (q.filter) {
    try {
      filter = JSON.parse(q.filter);
    } catch {
      throw new HTTPException(400, { message: "filter must be JSON" });
    }
  }
  if (q.userId) filter.userId = oid(q.userId);
  const col = rawDb().collection(name);
  const projection = name === "sessions" || name === "admin_sessions" ? { tokenHash: 0 } : {};
  const [total, rows] = await Promise.all([col.countDocuments(filter), col.find(filter, { skip: q.skip, limit: q.limit, projection, sort: { _id: -1 } }).toArray()]);
  return c.json({ total, rows });
});

// MARK: статика React-приложения

const distDir = path.resolve(config.adminDistDir);
admin.use("/assets/*", serveStatic({ root: path.relative(process.cwd(), distDir) || ".", rewriteRequestPath: (p) => p.replace(/^\/admin/, "") }));
let indexHtml: string | null = null;
admin.get("/*", async (c) => {
  if (c.req.path.startsWith("/admin/api/")) return c.notFound();
  if (!indexHtml || process.env.NODE_ENV !== "production") {
    indexHtml = await readFile(path.join(distDir, "index.html"), "utf8").catch(() => null);
  }
  if (!indexHtml) return c.text("Admin UI is not built: run `pnpm --dir admin build` (or use the Docker image).", 503);
  return c.html(indexHtml);
});
