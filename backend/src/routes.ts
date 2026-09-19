import { randomUUID } from "node:crypto";
import { Hono } from "hono";
import { zValidator } from "@hono/zod-validator";
import { HTTPException } from "hono/http-exception";
import { z } from "zod";
import { type AuthEnv, requireSession } from "./auth.js";
import { dayOverrides, points, rules, users } from "./db.js";
import { countryAt, countryName, localDateOf } from "./geo.js";
import { SCHENGEN } from "./presets.js";
import {
  addDays,
  buildDailyPresence,
  cityStats,
  countryStats,
  currentStatus,
  daysBetween,
  evaluateRule,
  primaryOf,
  timeline,
} from "./stats.js";
import { type Point, type Rule, publicProjection } from "./types.js";

export const api = new Hono<AuthEnv>();
api.use("*", requireSession);

const isoDate = z.string().regex(/^\d{4}-\d{2}-\d{2}$/, "expected YYYY-MM-DD");
const countryCode = z.string().length(2).transform((s) => s.toUpperCase());

// MARK: точки

const pointSchema = z.object({
  clientId: z.string().min(8).max(64),
  lat: z.number().min(-90).max(90),
  lon: z.number().min(-180).max(180),
  accuracy: z.number().nullable().optional(),
  recordedAt: z.string().datetime({ offset: true }),
  tzOffsetMin: z.number().int().min(-14 * 60).max(14 * 60).default(0),
  source: z.enum(["visit", "significant", "hourly", "foreground", "manual"]),
  arrivalAt: z.string().datetime({ offset: true }).nullable().optional(),
  departureAt: z.string().datetime({ offset: true }).nullable().optional(),
  city: z.string().max(200).nullable().optional(),
  region: z.string().max(200).nullable().optional(),
  deviceId: z.string().max(100).nullable().optional(),
});

// Устройство копит точки оффлайн и шлёт пачкой; дубли по clientId молча пропускаем.
api.post("/points", zValidator("json", z.object({ points: z.array(pointSchema).min(1).max(500) })), async (c) => {
  const userId = c.get("userId");
  const now = new Date().toISOString();
  const docs: Point[] = c.req.valid("json").points.map((p) => {
    const country = countryAt(p.lat, p.lon);
    const recordedAt = new Date(p.recordedAt).toISOString();
    return {
      userId,
      clientId: p.clientId,
      lat: p.lat,
      lon: p.lon,
      accuracy: p.accuracy ?? null,
      recordedAt,
      tzOffsetMin: p.tzOffsetMin,
      localDate: localDateOf(recordedAt, p.tzOffsetMin),
      source: p.source,
      arrivalAt: p.arrivalAt ?? null,
      departureAt: p.departureAt ?? null,
      countryCode: country?.code ?? null,
      countryName: country?.name ?? null,
      city: p.city ?? null,
      region: p.region ?? null,
      deviceId: p.deviceId ?? null,
      createdAt: now,
    };
  });

  let inserted = 0;
  try {
    const res = await points.insertMany(docs, { ordered: false });
    inserted = res.insertedCount;
  } catch (e: any) {
    // 11000 = duplicate key; всё, что не дубль, — настоящая ошибка
    if (e?.code !== 11000 && !e?.writeErrors?.every((w: any) => w.code === 11000)) throw e;
    inserted = e.result?.insertedCount ?? e.insertedCount ?? 0;
  }

  return c.json({ inserted, skipped: docs.length - inserted, points: docs.map(({ userId: _, ...p }) => p) }, 201);
});

api.get(
  "/points",
  zValidator(
    "query",
    z.object({
      from: isoDate.optional(),
      to: isoDate.optional(),
      limit: z.coerce.number().int().min(1).max(5000).default(500),
    }),
  ),
  async (c) => {
    const { from, to, limit } = c.req.valid("query");
    const filter: Record<string, unknown> = { userId: c.get("userId") };
    if (from || to) filter.localDate = { ...(from && { $gte: from }), ...(to && { $lte: to }) };
    const list = await points.find(filter, { projection: publicProjection }).sort({ recordedAt: -1 }).limit(limit).toArray();
    return c.json({ points: list });
  },
);

// MARK: присутствие по дням

// Смещение таймзоны пользователя в минутах — приложение шлёт его в каждом запросе статистики.
const tzQuery = { tz: z.coerce.number().int().min(-14 * 60).max(14 * 60).optional() };

/**
 * "Сегодня" — по часам пользователя, а не сервера: в Тбилиси уже 20-е, когда в UTC ещё 19-е,
 * и точка с localDate=20-е иначе выпадает из диапазона "до сегодня".
 * Берём tz из запроса, иначе — из последней точки, иначе UTC.
 */
async function loadPresence(userId: Point["userId"], tz?: number) {
  const [all, overrides] = await Promise.all([
    points.find({ userId }).toArray(),
    dayOverrides.find({ userId }).toArray(),
  ]);
  const latest = all.reduce<Point | null>((acc, p) => (!acc || p.recordedAt > acc.recordedAt ? p : acc), null);
  const offset = tz ?? latest?.tzOffsetMin ?? 0;
  const today = localDateOf(new Date().toISOString(), offset);
  return { days: buildDailyPresence(all, overrides, today), today };
}

const rangeQuery = z.object({ from: isoDate.optional(), to: isoDate.optional(), ...tzQuery });

function resolveRange(q: { from?: string; to?: string }, today: string) {
  return { from: q.from ?? `${today.slice(0, 4)}-01-01`, to: q.to ?? today };
}

api.get("/stats/countries", zValidator("query", rangeQuery), async (c) => {
  const q = c.req.valid("query");
  const { days, today } = await loadPresence(c.get("userId"), q.tz);
  const { from, to } = resolveRange(q, today);
  return c.json({ from, to, today, countries: countryStats(days, from, to) });
});

api.get("/stats/cities", zValidator("query", rangeQuery), async (c) => {
  const userId = c.get("userId");
  const q = c.req.valid("query");
  const { days, today } = await loadPresence(userId, q.tz);
  const { from, to } = resolveRange(q, today);
  const stats = cityStats(days, from, to);

  // Координаты города для карты — среднее по точкам с этим городом. У ручных записей точек нет.
  const coords = await points
    .aggregate<{ _id: { countryCode: string | null; city: string | null }; lat: number; lon: number }>([
      { $match: { userId, city: { $ne: null } } },
      { $group: { _id: { countryCode: "$countryCode", city: "$city" }, lat: { $avg: "$lat" }, lon: { $avg: "$lon" } } },
    ])
    .toArray();
  const byKey = new Map(coords.map((x) => [`${x._id.countryCode}|${x._id.city}`, x]));
  const cities = stats.map((s) => {
    const p = byKey.get(`${s.countryCode}|${s.city}`);
    return { ...s, lat: p ? Number(p.lat.toFixed(4)) : null, lon: p ? Number(p.lon.toFixed(4)) : null };
  });
  return c.json({ from, to, today, cities });
});

api.get("/stats/current", zValidator("query", z.object(tzQuery)), async (c) => {
  const { days, today } = await loadPresence(c.get("userId"), c.req.valid("query").tz);
  return c.json({ today, current: currentStatus(days, today) });
});

api.get("/timeline", zValidator("query", rangeQuery), async (c) => {
  const q = c.req.valid("query");
  const { days, today } = await loadPresence(c.get("userId"), q.tz);
  const { from, to } = resolveRange(q, today);
  return c.json({ from, to, today, segments: timeline(days, from, to) });
});

// Календарь по дням: основная страна + все страны дня. Для ручной проверки и правок.
api.get("/days", zValidator("query", rangeQuery), async (c) => {
  const q = c.req.valid("query");
  const { days: p, today } = await loadPresence(c.get("userId"), q.tz);
  const { from, to } = resolveRange(q, today);
  const days = [...p.keys()]
    .filter((d) => d >= from && d <= to)
    .sort()
    .reverse()
    .map((date) => ({ date, primary: primaryOf(p.get(date)), all: p.get(date) }));
  return c.json({ from, to, days });
});

api.put(
  "/days/:date",
  zValidator("param", z.object({ date: isoDate })),
  zValidator(
    "json",
    z.object({
      countryCode,
      city: z.string().max(200).nullable().optional(),
      note: z.string().max(500).nullable().optional(),
    }),
  ),
  async (c) => {
    const userId = c.get("userId");
    const { date } = c.req.valid("param");
    const body = c.req.valid("json");
    const doc = {
      userId,
      localDate: date,
      countryCode: body.countryCode,
      countryName: countryName(body.countryCode),
      city: body.city ?? null,
      note: body.note ?? null,
      createdAt: new Date().toISOString(),
    };
    await dayOverrides.replaceOne({ userId, localDate: date }, doc, { upsert: true });
    const { userId: _, ...override } = doc;
    return c.json({ override });
  },
);

api.delete("/days/:date", zValidator("param", z.object({ date: isoDate })), async (c) => {
  const { date } = c.req.valid("param");
  const res = await dayOverrides.deleteOne({ userId: c.get("userId"), localDate: date });
  return c.json({ deleted: res.deletedCount === 1 });
});

// MARK: ручные записи (диапазоны дней)

const rangeBody = z
  .object({
    from: isoDate,
    to: isoDate,
    countryCode,
    city: z.string().trim().max(200).nullable().optional(),
    note: z.string().trim().max(500).nullable().optional(),
  })
  .refine((r) => r.from <= r.to, { message: "from must be <= to", path: ["to"] })
  .refine((r) => daysBetween(r.from, r.to) < 366 * 3, { message: "range too long", path: ["to"] });

// Все ручные правки пользователя — приложение само склеивает их в диапазоны
api.get("/overrides", async (c) => {
  const list = await dayOverrides.find({ userId: c.get("userId") }, { projection: publicProjection }).sort({ localDate: -1 }).toArray();
  return c.json({ overrides: list });
});

// "Был в стране X с ... по ..." — одна правка на каждый день диапазона
api.put("/overrides/range", zValidator("json", rangeBody), async (c) => {
  const userId = c.get("userId");
  const body = c.req.valid("json");
  const now = new Date().toISOString();
  const name = countryName(body.countryCode);
  const ops = [];
  for (let d = body.from; d <= body.to; d = addDays(d, 1)) {
    ops.push({
      replaceOne: {
        filter: { userId, localDate: d },
        replacement: {
          userId,
          localDate: d,
          countryCode: body.countryCode,
          countryName: name,
          city: body.city || null,
          note: body.note || null,
          createdAt: now,
        },
        upsert: true,
      },
    });
  }
  const res = await dayOverrides.bulkWrite(ops, { ordered: false });
  return c.json({ days: ops.length, inserted: res.upsertedCount, replaced: res.modifiedCount });
});

api.delete("/overrides/range", zValidator("query", z.object({ from: isoDate, to: isoDate })), async (c) => {
  const { from, to } = c.req.valid("query");
  const res = await dayOverrides.deleteMany({ userId: c.get("userId"), localDate: { $gte: from, $lte: to } });
  return c.json({ deleted: res.deletedCount });
});

// MARK: правила подсчёта

const ruleBody = z
  .object({
    name: z.string().trim().min(1).max(80),
    enabled: z.boolean().default(true),
    type: z.enum(["calendarYear", "rolling", "fromDate"]),
    countries: z.array(countryCode).max(250).default([]),
    limitDays: z.number().int().min(1).max(3660),
    windowDays: z.number().int().min(1).max(3660).nullable().default(null),
    startDate: isoDate.nullable().default(null),
    autoStart: z.boolean().default(false),
    mode: z.enum(["limit", "goal"]).default("limit"),
    countMode: z.enum(["any", "primary"]).default("any"),
    warnRemainingDays: z.number().int().min(0).max(3660).nullable().default(null),
    notify: z.boolean().default(true),
    sortOrder: z.number().int().default(0),
  })
  .superRefine((r, ctx) => {
    if (r.type === "rolling" && !r.windowDays) ctx.addIssue({ code: "custom", path: ["windowDays"], message: "rolling rule needs windowDays" });
    if (r.type === "fromDate" && !r.startDate && !r.autoStart) ctx.addIssue({ code: "custom", path: ["startDate"], message: "fromDate rule needs startDate or autoStart" });
  });

// insertOne дописывает _id в объект, find возвращает его — наружу не отдаём ни его, ни userId.
// autoStart появился позже — у старых документов его нет.
function publicRule({ userId: _u, _id: _i, ...r }: Rule & { _id?: unknown }) {
  return { ...r, autoStart: r.autoStart ?? false };
}

// Правила по умолчанию для нового пользователя — один раз, потом он волен всё удалить
async function ensureDefaultRules(userId: Point["userId"]) {
  const user = await users.findOne({ _id: userId }, { projection: { rulesSeeded: 1 } });
  if (!user || user.rulesSeeded) return;
  const now = new Date().toISOString();
  await rules.insertOne({
    userId,
    id: randomUUID(),
    name: "Шенген 90/180",
    enabled: true,
    type: "rolling",
    countries: SCHENGEN,
    limitDays: 90,
    windowDays: 180,
    startDate: null,
    autoStart: false,
    mode: "limit",
    countMode: "any",
    warnRemainingDays: 10,
    notify: true,
    sortOrder: 0,
    createdAt: now,
    updatedAt: now,
  });
  await users.updateOne({ _id: userId }, { $set: { rulesSeeded: true } });
}

api.get("/rules", async (c) => {
  const userId = c.get("userId");
  await ensureDefaultRules(userId);
  const list = await rules.find({ userId }).sort({ sortOrder: 1, createdAt: 1 }).toArray();
  return c.json({ rules: list.map(publicRule) });
});

api.post("/rules", zValidator("json", ruleBody), async (c) => {
  const userId = c.get("userId");
  await ensureDefaultRules(userId);
  const now = new Date().toISOString();
  const rule: Rule = { userId, id: randomUUID(), ...c.req.valid("json"), createdAt: now, updatedAt: now };
  await rules.insertOne(rule);
  return c.json({ rule: publicRule(rule) }, 201);
});

api.put("/rules/:id", zValidator("param", z.object({ id: z.string().uuid() })), zValidator("json", ruleBody), async (c) => {
  const userId = c.get("userId");
  const { id } = c.req.valid("param");
  const updated = await rules.findOneAndUpdate(
    { userId, id },
    { $set: { ...c.req.valid("json"), updatedAt: new Date().toISOString() } },
    { returnDocument: "after" },
  );
  if (!updated) throw new HTTPException(404, { message: "rule not found" });
  return c.json({ rule: publicRule(updated) });
});

api.delete("/rules/:id", zValidator("param", z.object({ id: z.string().uuid() })), async (c) => {
  const res = await rules.deleteOne({ userId: c.get("userId"), id: c.req.valid("param").id });
  return c.json({ deleted: res.deletedCount === 1 });
});

// Результаты по всем включённым правилам
api.get("/stats/rules", zValidator("query", z.object(tzQuery)), async (c) => {
  const userId = c.get("userId");
  await ensureDefaultRules(userId);
  const [{ days, today }, list] = await Promise.all([
    loadPresence(userId, c.req.valid("query").tz),
    rules.find({ userId, enabled: true }).sort({ sortOrder: 1, createdAt: 1 }).toArray(),
  ]);
  return c.json({ today, results: list.map((r) => evaluateRule(days, r, today)) });
});

// MARK: экспорт

// Полный дамп — бэкап / экспорт для бухгалтера
api.get("/export", async (c) => {
  const userId = c.get("userId");
  const [all, overrides, ruleList] = await Promise.all([
    points.find({ userId }, { projection: publicProjection }).sort({ recordedAt: 1 }).toArray(),
    dayOverrides.find({ userId }, { projection: publicProjection }).toArray(),
    rules.find({ userId }, { projection: publicProjection }).toArray(),
  ]);
  return c.json({ exportedAt: new Date().toISOString(), points: all, overrides, rules: ruleList });
});
