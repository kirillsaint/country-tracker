import { randomUUID } from "node:crypto";
import { Hono } from "hono";
import { zValidator } from "@hono/zod-validator";
import { HTTPException } from "hono/http-exception";
import { z } from "zod";
import { type AuthEnv, requireSession } from "./auth.js";
import { dayOverrides, documents, entries, points, regimeChecks, regimes, rules, users } from "./db.js";
import { deleteRulesForDocument, resetRuleFromDocument, syncRulesForDocument } from "./documents.js";
import { config } from "./config.js";
import { isAiEnabled } from "./ai.js";
import { cachedCheck, confirmVersion, deleteRegime, diffVersions, isStale, startCheck } from "./regimes.js";
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
import { type Entry, type Point, type Regime, type RegimeCheck, type Rule, type TravelDocument, publicProjection } from "./types.js";

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
  const userId = c.get("userId");
  const { days, today } = await loadPresence(userId, c.req.valid("query").tz);
  const current = currentStatus(days, today);
  if (!current) return c.json({ today, current: null });

  // Основание текущего пребывания: есть ли запись для (страна, дата въезда)
  let entry: Entry | null = await entries.findOne({ userId, countryCode: current.countryCode, date: current.since });
  if (!entry) {
    // Страна своего паспорта — основание очевидно, ставим сами
    const passport = await documents.findOne({ userId, kind: "passport", countryCode: current.countryCode });
    if (passport) {
      const now = new Date().toISOString();
      const created: Entry = { userId, id: randomUUID(), countryCode: current.countryCode, date: current.since, basis: "citizen", documentId: passport.id, note: null, createdAt: now, updatedAt: now };
      await entries.replaceOne({ userId, countryCode: current.countryCode, date: current.since }, created, { upsert: true });
      entry = created;
    }
  }
  // "Как в прошлый раз": последнее основание для этой же страны до текущего въезда
  const previous = await entries.find({ userId, countryCode: current.countryCode, date: { $lt: current.since } }).sort({ date: -1 }).limit(1).toArray();
  const strip = (e: Entry | null) => (e ? { basis: e.basis, documentId: e.documentId, date: e.date } : null);
  // Режим безвиза для этой страны по паспорту въезда (или первому паспорту): есть ли и не устарел ли
  const passportId = entry?.basis === "visa_free" && entry.documentId
    ? entry.documentId
    : (await documents.findOne({ userId, kind: "passport" }, { sort: { createdAt: 1 } }))?.id ?? null;
  const regime = passportId ? await regimes.findOne({ userId, passportId, countryCode: current.countryCode }) : null;
  return c.json({
    today,
    current: {
      ...current,
      entry: strip(entry),
      previousEntry: strip(previous[0] ?? null),
      entryPending: !entry,
      regime: passportId ? { passportId, regimeId: regime?.id ?? null, lastCheckedAt: regime?.lastCheckedAt ?? null, stale: isStale(regime) } : null,
    },
  });
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
      rangeFrom: date,
      createdAt: new Date().toISOString(),
    };
    await dayOverrides.deleteMany({ userId, localDate: date });
    await dayOverrides.insertOne(doc);
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
        filter: { userId, localDate: d, countryCode: body.countryCode },
        replacement: {
          userId,
          localDate: d,
          countryCode: body.countryCode,
          countryName: name,
          city: body.city || null,
          note: body.note || null,
          rangeFrom: body.from,
          createdAt: now,
        },
        upsert: true,
      },
    });
  }
  const res = await dayOverrides.bulkWrite(ops, { ordered: false });
  return c.json({ days: ops.length, inserted: res.upsertedCount, replaced: res.modifiedCount });
});

api.delete("/overrides/range", zValidator("query", z.object({ from: isoDate, to: isoDate, countryCode: countryCode.optional() })), async (c) => {
  const { from, to, countryCode: cc } = c.req.valid("query");
  const res = await dayOverrides.deleteMany({ userId: c.get("userId"), localDate: { $gte: from, $lte: to }, ...(cc && { countryCode: cc }) });
  return c.json({ deleted: res.deletedCount });
});

// MARK: правила подсчёта

const ruleBody = z
  .object({
    name: z.string().trim().min(1).max(80),
    enabled: z.boolean().default(true),
    type: z.enum(["calendarYear", "rolling", "fromDate", "absence"]),
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
    validUntil: isoDate.nullable().default(null),
  })
  .superRefine((r, ctx) => {
    if (r.type === "absence" && r.countries.length === 0) ctx.addIssue({ code: "custom", path: ["countries"], message: "absence rule needs countries" });
    if (r.type === "rolling" && !r.windowDays) ctx.addIssue({ code: "custom", path: ["windowDays"], message: "rolling rule needs windowDays" });
    if (r.type === "fromDate" && !r.startDate && !r.autoStart) ctx.addIssue({ code: "custom", path: ["startDate"], message: "fromDate rule needs startDate or autoStart" });
  });

// insertOne дописывает _id в объект, find возвращает его — наружу не отдаём ни его, ни userId.
// autoStart появился позже — у старых документов его нет.
function publicRule({ userId: _u, _id: _i, ...r }: Rule & { _id?: unknown }) {
  return {
    ...r,
    autoStart: r.autoStart ?? false,
    documentId: r.documentId ?? null,
    documentRole: r.documentRole ?? null,
    regimeId: r.regimeId ?? null,
    constraintId: r.constraintId ?? null,
    customized: r.customized ?? false,
    validFrom: r.validFrom ?? null,
    validUntil: r.validUntil ?? null,
  };
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
    documentId: null,
    documentRole: null,
    regimeId: null,
    constraintId: null,
    validFrom: null,
    customized: false,
    validUntil: null,
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
  const rule: Rule = { userId, id: randomUUID(), documentId: null, documentRole: null, regimeId: null, constraintId: null, validFrom: null, customized: false, ...c.req.valid("json"), createdAt: now, updatedAt: now };
  await rules.insertOne(rule);
  return c.json({ rule: publicRule(rule) }, 201);
});

api.put("/rules/:id", zValidator("param", z.object({ id: z.string().uuid() })), zValidator("json", ruleBody), async (c) => {
  const userId = c.get("userId");
  const { id } = c.req.valid("param");
  const prev = await rules.findOne({ userId, id });
  if (!prev) throw new HTTPException(404, { message: "rule not found" });
  const body = c.req.valid("json");
  // Правка автоправила руками закрепляет его: документ больше не перезапишет эти значения.
  // Переключение enabled/notify правкой не считаем.
  const substantive = (["type", "countries", "limitDays", "windowDays", "startDate", "autoStart", "mode", "countMode", "name"] as const)
    .some((k) => JSON.stringify(body[k]) !== JSON.stringify(prev[k]));
  const customized = (prev.documentId || prev.regimeId) ? (prev.customized || substantive) : false;
  const updated = await rules.findOneAndUpdate(
    { userId, id },
    { $set: { ...body, customized, updatedAt: new Date().toISOString() } },
    { returnDocument: "after" },
  );
  return c.json({ rule: publicRule(updated!) });
});

// Сбросить пользовательские правки автоправила к значениям из документа
api.post("/rules/:id/reset", zValidator("param", z.object({ id: z.string().uuid() })), zValidator("json", z.object({ lang: z.enum(["ru", "en"]).default("en") })), async (c) => {
  const userId = c.get("userId");
  const { id } = c.req.valid("param");
  const rule = await rules.findOne({ userId, id });
  if (!rule) throw new HTTPException(404, { message: "rule not found" });
  if (!rule.documentId) throw new HTTPException(400, { message: "rule is not generated from a document" });
  const doc = await documents.findOne({ userId, id: rule.documentId });
  if (!doc) throw new HTTPException(404, { message: "source document not found" });
  const restored = await resetRuleFromDocument(userId, rule, doc, c.req.valid("json").lang);
  if (!restored) throw new HTTPException(410, { message: "document no longer produces this rule" });
  return c.json({ rule: publicRule(restored) });
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
  const active = list.filter((r) => !r.validUntil || r.validUntil >= today);
  return c.json({ today, results: active.map((r) => evaluateRule(days, r, today)) });
});

// MARK: документы (паспорта, визы, ВНЖ)

const documentBody = z
  .object({
    kind: z.enum(["passport", "visa", "residence"]),
    name: z.string().trim().min(1).max(80),
    countryCode,
    countries: z.array(countryCode).max(250).default([]),
    passportId: z.string().uuid().nullable().default(null),
    validFrom: isoDate.nullable().default(null),
    validTo: isoDate.nullable().default(null),
    entries: z.enum(["single", "multiple"]).nullable().default(null),
    maxStayDays: z.number().int().min(1).max(3660).nullable().default(null),
    windowLimitDays: z.number().int().min(1).max(3660).nullable().default(null),
    windowDays: z.number().int().min(2).max(3660).nullable().default(null),
    residenceType: z.enum(["temporary", "permanent"]).nullable().default(null),
    minDaysPerYear: z.number().int().min(1).max(366).nullable().default(null),
    maxAbsenceDays: z.number().int().min(1).max(3660).nullable().default(null),
    note: z.string().trim().max(500).nullable().default(null),
    // язык подписей автосозданных правил
    lang: z.enum(["ru", "en"]).default("en"),
  })
  .superRefine((d, ctx) => {
    if (d.validFrom && d.validTo && d.validFrom > d.validTo) ctx.addIssue({ code: "custom", path: ["validTo"], message: "validTo must be >= validFrom" });
    if ((d.windowLimitDays == null) !== (d.windowDays == null)) ctx.addIssue({ code: "custom", path: ["windowDays"], message: "windowLimitDays and windowDays go together" });
  });

function publicDocument({ userId: _u, _id: _i, ...d }: TravelDocument & { _id?: unknown }) {
  return d;
}

function documentFromBody(userId: Point["userId"], id: string, body: z.infer<typeof documentBody>, createdAt: string): TravelDocument {
  const { lang: _lang, ...rest } = body;
  const countries = rest.kind === "passport" ? [rest.countryCode] : (rest.countries.length ? rest.countries : [rest.countryCode]);
  return { userId, id, ...rest, countries, createdAt, updatedAt: new Date().toISOString() };
}

api.get("/documents", async (c) => {
  const list = await documents.find({ userId: c.get("userId") }).sort({ kind: 1, createdAt: 1 }).toArray();
  return c.json({ documents: list.map(publicDocument) });
});

api.post("/documents", zValidator("json", documentBody), async (c) => {
  const userId = c.get("userId");
  const body = c.req.valid("json");
  const doc = documentFromBody(userId, randomUUID(), body, new Date().toISOString());
  await documents.insertOne(doc);
  const generated = await syncRulesForDocument(userId, doc, body.lang);
  return c.json({ document: publicDocument(doc), rules: generated.map(publicRule) }, 201);
});

api.put("/documents/:id", zValidator("param", z.object({ id: z.string().uuid() })), zValidator("json", documentBody), async (c) => {
  const userId = c.get("userId");
  const { id } = c.req.valid("param");
  const body = c.req.valid("json");
  const prev = await documents.findOne({ userId, id });
  if (!prev) throw new HTTPException(404, { message: "document not found" });
  const doc = documentFromBody(userId, id, body, prev.createdAt);
  await documents.replaceOne({ userId, id }, doc);
  const generated = await syncRulesForDocument(userId, doc, body.lang);
  return c.json({ document: publicDocument(doc), rules: generated.map(publicRule) });
});

api.delete("/documents/:id", zValidator("param", z.object({ id: z.string().uuid() })), async (c) => {
  const userId = c.get("userId");
  const { id } = c.req.valid("param");
  const res = await documents.deleteOne({ userId, id });
  await deleteRulesForDocument(userId, id);
  // визы и ВНЖ, выданные по удалённому паспорту, остаются, но теряют привязку
  await documents.updateMany({ userId, passportId: id }, { $set: { passportId: null } });
  await entries.updateMany({ userId, documentId: id }, { $set: { documentId: null } });
  return c.json({ deleted: res.deletedCount === 1 });
});

// MARK: основания въезда

const entryBody = z.object({
  basis: z.enum(["citizen", "visa_free", "visa", "residence", "transit", "other"]),
  documentId: z.string().uuid().nullable().default(null),
  note: z.string().trim().max(500).nullable().default(null),
});

function publicEntry({ userId: _u, _id: _i, ...e }: Entry & { _id?: unknown }) {
  return e;
}

api.get("/entries", async (c) => {
  const list = await entries.find({ userId: c.get("userId") }).sort({ date: -1 }).toArray();
  return c.json({ entries: list.map(publicEntry) });
});

// Основание для отрезка "страна + дата въезда" — создать или заменить
api.put(
  "/entries/:countryCode/:date",
  zValidator("param", z.object({ countryCode, date: isoDate })),
  zValidator("json", entryBody),
  async (c) => {
    const userId = c.get("userId");
    const { countryCode: cc, date } = c.req.valid("param");
    const body = c.req.valid("json");
    const now = new Date().toISOString();
    const prev = await entries.findOne({ userId, countryCode: cc, date });
    const entry: Entry = {
      userId,
      id: prev?.id ?? randomUUID(),
      countryCode: cc,
      date,
      basis: body.basis,
      documentId: body.documentId,
      note: body.note,
      createdAt: prev?.createdAt ?? now,
      updatedAt: now,
    };
    await entries.replaceOne({ userId, countryCode: cc, date }, entry, { upsert: true });
    return c.json({ entry: publicEntry(entry) });
  },
);

api.delete("/entries/:countryCode/:date", zValidator("param", z.object({ countryCode, date: isoDate })), async (c) => {
  const { countryCode: cc, date } = c.req.valid("param");
  const res = await entries.deleteOne({ userId: c.get("userId"), countryCode: cc, date });
  return c.json({ deleted: res.deletedCount === 1 });
});

// MARK: режимы въезда (безвиз)

function publicRegime({ userId: _u, _id: _i, ...r }: Regime & { _id?: unknown }) {
  return r;
}
function publicCheck({ _id: _i, raw: _r, ...c }: RegimeCheck & { _id?: unknown }) {
  return c;
}

const constraintBody = z.object({
  id: z.string().min(1).max(64).optional(),
  type: z.enum(["perEntry", "rolling", "calendarYear", "fromDate"]),
  limitDays: z.number().int().min(1).max(3660),
  windowDays: z.number().int().min(2).max(3660).nullable().default(null),
  startDate: isoDate.nullable().default(null),
  note: z.string().trim().max(300).nullable().default(null),
});
const conditionBody = z.object({
  id: z.string().min(1).max(64).optional(),
  kind: z.enum(["registration", "passportValidity", "insurance", "funds", "ticket", "other"]),
  text: z.string().trim().min(1).max(300),
  withinDays: z.number().int().min(1).max(365).nullable().default(null),
  done: z.boolean().default(false),
});
const versionBody = z
  .object({
    requirement: z.enum(["visa_free", "e_visa", "visa_on_arrival", "visa_required", "unknown"]).default("visa_free"),
    constraints: z.array(constraintBody).max(6).default([]),
    conditions: z.array(conditionBody).max(10).default([]),
    sources: z.array(z.object({ url: z.string().url(), title: z.string().max(200).nullable().default(null), official: z.boolean().default(false), quote: z.string().max(400).nullable().default(null) })).max(10).default([]),
    origin: z.enum(["user", "ai"]).default("user"),
    model: z.string().max(100).nullable().default(null),
    notes: z.string().trim().max(1200).nullable().default(null),
    lang: z.enum(["ru", "en"]).default("en"),
  })
  .superRefine((v, ctx) => {
    v.constraints.forEach((c, i) => {
      if (c.type === "rolling" && !c.windowDays) ctx.addIssue({ code: "custom", path: ["constraints", i, "windowDays"], message: "rolling needs windowDays" });
      if (c.type === "fromDate" && !c.startDate) ctx.addIssue({ code: "custom", path: ["constraints", i, "startDate"], message: "fromDate needs startDate" });
    });
  });

async function passportOr404(userId: Point["userId"], passportId: string) {
  const p = await documents.findOne({ userId, id: passportId, kind: "passport" });
  if (!p) throw new HTTPException(404, { message: "passport not found" });
  return p;
}

// Все режимы пользователя
api.get("/regimes", async (c) => {
  const list = await regimes.find({ userId: c.get("userId") }).sort({ updatedAt: -1 }).toArray();
  return c.json({ aiEnabled: isAiEnabled(), freshDays: config.regimeFreshDays, regimes: list.map(publicRegime) });
});

// Режим для страны по паспорту + документы на страну + свежая проверка из кэша (если была)
api.get("/regimes/:passportId/:country", zValidator("param", z.object({ passportId: z.string().uuid(), country: countryCode })), zValidator("query", z.object({ lang: z.enum(["ru", "en"]).default("en") })), async (c) => {
  const userId = c.get("userId");
  const { passportId, country } = c.req.valid("param");
  const passport = await passportOr404(userId, passportId);
  const regime = await regimes.findOne({ userId, passportId, countryCode: country });
  const check = await cachedCheck(passport.countryCode, country, c.req.valid("query").lang);
  const covering = await documents.find({ userId, kind: { $in: ["visa", "residence"] }, countries: country }).toArray();
  return c.json({
    aiEnabled: isAiEnabled(),
    isCitizen: passport.countryCode === country,
    regime: regime ? publicRegime(regime) : null,
    stale: isStale(regime),
    cachedCheck: check ? publicCheck(check) : null,
    documents: covering.map(publicDocument),
  });
});

// Подтвердить условия (вручную или из черновика нейросети)
api.put("/regimes/:passportId/:country", zValidator("param", z.object({ passportId: z.string().uuid(), country: countryCode })), zValidator("json", versionBody), async (c) => {
  const userId = c.get("userId");
  const { passportId, country } = c.req.valid("param");
  const passport = await passportOr404(userId, passportId);
  const { lang, ...body } = c.req.valid("json");
  const input = {
    ...body,
    constraints: body.constraints.map((x) => ({ ...x, id: x.id ?? randomUUID() })),
    conditions: body.conditions.map((x) => ({ ...x, id: x.id ?? randomUUID() })),
  };
  const result = await confirmVersion(userId, { id: passport.id, countryCode: passport.countryCode }, country, input, lang);
  return c.json({ regime: publicRegime(result.regime), rules: result.rules.map(publicRule), changed: result.changed });
});

api.delete("/regimes/:id", zValidator("param", z.object({ id: z.string().uuid() })), async (c) => {
  await deleteRegime(c.get("userId"), c.req.valid("param").id);
  return c.json({ deleted: true });
});

// Отметить условие чек-листа
api.post(
  "/regimes/:id/conditions/:conditionId",
  zValidator("param", z.object({ id: z.string().uuid(), conditionId: z.string() })),
  zValidator("json", z.object({ done: z.boolean() })),
  async (c) => {
    const userId = c.get("userId");
    const { id, conditionId } = c.req.valid("param");
    const updated = await regimes.findOneAndUpdate(
      { userId, id, "active.conditions.id": conditionId },
      { $set: { "active.conditions.$.done": c.req.valid("json").done, updatedAt: new Date().toISOString() } },
      { returnDocument: "after" },
    );
    if (!updated) throw new HTTPException(404, { message: "condition not found" });
    return c.json({ regime: publicRegime(updated) });
  },
);

// Запустить проверку нейросетью (фон). force — не брать свежий результат из кэша
api.post(
  "/regimes/:passportId/:country/check",
  zValidator("param", z.object({ passportId: z.string().uuid(), country: countryCode })),
  zValidator("json", z.object({ lang: z.enum(["ru", "en"]).default("en"), force: z.boolean().default(false) })),
  async (c) => {
    const userId = c.get("userId");
    const { passportId, country } = c.req.valid("param");
    const passport = await passportOr404(userId, passportId);
    const { lang, force } = c.req.valid("json");
    const check = await startCheck(passport.countryCode, country, lang, force);
    return c.json({ check: publicCheck(check) }, check.status === "done" ? 200 : 202);
  },
);

// Состояние проверки + диф с активной версией режима (если пользователь дал passportId)
api.get("/regime-checks/:id", zValidator("param", z.object({ id: z.string().uuid() })), zValidator("query", z.object({ passportId: z.string().uuid().optional() })), async (c) => {
  const userId = c.get("userId");
  const check = await regimeChecks.findOne({ id: c.req.valid("param").id });
  if (!check) throw new HTTPException(404, { message: "check not found" });
  const { passportId } = c.req.valid("query");
  const regime = passportId ? await regimes.findOne({ userId, passportId, countryCode: check.countryCode }) : null;
  const diff = check.draft ? diffVersions(check.lang, regime?.active ?? null, check.draft) : null;
  return c.json({ check: publicCheck(check), diff });
});

// MARK: экспорт

// Полный дамп — бэкап / экспорт для бухгалтера
api.get("/export", async (c) => {
  const userId = c.get("userId");
  const [all, overrides, ruleList, docs, entryList] = await Promise.all([
    points.find({ userId }, { projection: publicProjection }).sort({ recordedAt: 1 }).toArray(),
    dayOverrides.find({ userId }, { projection: publicProjection }).toArray(),
    rules.find({ userId }, { projection: publicProjection }).toArray(),
    documents.find({ userId }, { projection: publicProjection }).toArray(),
    entries.find({ userId }, { projection: publicProjection }).toArray(),
  ]);
  return c.json({ exportedAt: new Date().toISOString(), points: all, overrides, rules: ruleList, documents: docs, entries: entryList });
});
