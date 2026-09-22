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
import { applyCheckForUser, cachedCheck, confirmVersion, deleteRegime, diffVersions, isStale, startCheck, subscribeAutoApply } from "./regimes.js";
import { countryAt, countryName, localDateOf } from "./geo.js";
import { cityCoords, localizedCityName, searchCities } from "./cities.js";
import { CATEGORY_TYPES, isPlacesEnabled, photoUrl, placeDetails, resolvePhoto, verifyPhoto } from "./places.js";
import { discover, itinerary, userState, type PlaceRating, type PlaceSave } from "./discover.js";
import { getJob, startJob } from "./jobs.js";
import { weatherNow } from "./weather.js";
import { placeDismissals, placeRatings, placeSaves, tastePreferences } from "./db.js";
import {
  addDays,
  buildDailyPresence,
  cityStats,
  countryStats,
  currentStatus,
  daysBetween,
  evaluateRule,
  primaryOf,
  timeline, buildBasisIndex } from "./stats.js";
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

const langParam = z.string().regex(/^[a-z]{2,3}$/);

// Справочник городов (GeoNames) для выбора в ручной записи: ?country=AE&q=дуб — по префиксу любого имени,
// без q — самые крупные города страны
api.get("/cities", zValidator("query", z.object({ country: countryCode, q: z.string().trim().max(100).default(""), limit: z.coerce.number().int().min(1).max(100).default(40), lang: langParam.optional() })), async (c) => {
  const { country, q, limit, lang } = c.req.valid("query");
  return c.json({ cities: await searchCities(country, q, limit, lang && lang !== "en" ? lang : null) });
});

// Переводы городов из истории пользователя на язык приложения. Источник только справочник
// GeoNames на сервере (никакого пользовательского ввода), ключ «страна|английское имя в нижнем регистре».
api.get("/city-names", zValidator("query", z.object({ lang: langParam })), async (c) => {
  const userId = c.get("userId");
  const { lang } = c.req.valid("query");
  const [fromPoints, fromOverrides] = await Promise.all([
    points.aggregate<{ _id: { countryCode: string; city: string } }>([{ $match: { userId, city: { $ne: null }, countryCode: { $ne: null } } }, { $group: { _id: { countryCode: "$countryCode", city: "$city" } } }]).toArray(),
    dayOverrides.aggregate<{ _id: { countryCode: string; city: string } }>([{ $match: { userId, city: { $ne: null } } }, { $group: { _id: { countryCode: "$countryCode", city: "$city" } } }]).toArray(),
  ]);
  const pairs = new Map<string, { countryCode: string; city: string }>();
  for (const x of [...fromPoints, ...fromOverrides]) pairs.set(`${x._id.countryCode}|${x._id.city.toLowerCase()}`, x._id);
  const names: Record<string, string> = {};
  await Promise.all(
    [...pairs].map(async ([key, p]) => {
      const localized = await localizedCityName(p.countryCode, p.city, lang);
      if (localized) names[key] = localized;
    }),
  );
  return c.json({ names });
});

// Переименовать город во всей истории: точки с устройства и ручные правки. Нужно приложению,
// чтобы привести старые записи к английскому написанию («Дубай» → «Dubai»); исходное имя сохраняется в cityRaw.
const renameCityBody = z.object({
  countryCode,
  from: z.string().trim().min(1).max(200),
  to: z.string().trim().min(1).max(200),
});
api.post("/cities/rename", zValidator("json", renameCityBody), async (c) => {
  const userId = c.get("userId");
  const { countryCode: cc, from, to } = c.req.valid("json");
  if (from === to) return c.json({ points: 0, overrides: 0 });
  const [p, o] = await Promise.all([
    points.updateMany({ userId, countryCode: cc, city: from }, [{ $set: { cityRaw: { $ifNull: ["$cityRaw", "$city"] }, city: to } }]),
    dayOverrides.updateMany({ userId, countryCode: cc, city: from }, { $set: { city: to } }),
  ]);
  return c.json({ points: p.modifiedCount, overrides: o.modifiedCount });
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
  const cities = await Promise.all(
    stats.map(async (s) => {
      const p = byKey.get(`${s.countryCode}|${s.city}`);
      if (p) return { ...s, lat: Number(p.lat.toFixed(4)), lon: Number(p.lon.toFixed(4)) };
      // город только из ручных записей — координаты из справочника
      const g = s.city === "—" ? null : await cityCoords(s.countryCode, s.city);
      return { ...s, lat: g?.lat ?? null, lon: g?.lon ?? null };
    }),
  );
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
  const previous = await entries.find({ userId, countryCode: current.countryCode, date: { $lt: current.since }, kind: { $ne: "switch" } }).sort({ date: -1 }).limit(1).toArray();
  // Смена статуса внутри текущего пребывания (например, получил ВНЖ): действует последняя
  const switched = await entries.find({ userId, countryCode: current.countryCode, kind: "switch", date: { $gt: current.since, $lte: today } }).sort({ date: -1 }).limit(1).toArray();
  const strip = (e: Entry | null) => (e ? { basis: e.basis, documentId: e.documentId, date: e.date, kind: e.kind ?? "arrival" } : null);
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
      switched: strip(switched[0] ?? null),
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
  // до 50 лет одной записью — например, «жил в стране с рождения»
  .refine((r) => daysBetween(r.from, r.to) < 366 * 50, { message: "range too long (max 50 years)", path: ["to"] });

// Все ручные правки пользователя — приложение само склеивает их в диапазоны
api.get("/overrides", async (c) => {
  const list = await dayOverrides.find({ userId: c.get("userId") }, { projection: publicProjection }).sort({ localDate: -1 }).toArray();
  return c.json({ overrides: list });
});

// Те же правки, но склеенные в периоды «с … по …»: подряд идущие дни одной страны с одинаковыми
// городом и заметкой. Приложению нужны именно периоды — запись на 40 лет иначе весила бы мегабайты.
api.get("/overrides/ranges", async (c) => {
  const list = await dayOverrides
    .find({ userId: c.get("userId") }, { projection: { _id: 0, localDate: 1, countryCode: 1, countryName: 1, city: 1, note: 1 } })
    .sort({ countryCode: 1, localDate: 1 })
    .toArray();
  type Range = { from: string; to: string; countryCode: string; countryName: string | null; city: string | null; note: string | null; days: number };
  const out: Range[] = [];
  for (const o of list) {
    const last = out[out.length - 1];
    if (last && last.countryCode === o.countryCode && last.city === o.city && last.note === o.note && daysBetween(last.to, o.localDate) === 1) {
      last.to = o.localDate;
      last.days++;
    } else {
      out.push({ from: o.localDate, to: o.localDate, countryCode: o.countryCode, countryName: o.countryName, city: o.city, note: o.note, days: 1 });
    }
  }
  out.sort((a, b) => (a.from < b.from ? 1 : a.from > b.from ? -1 : 0));
  return c.json({ ranges: out });
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

api.get("/rules", async (c) => {
  const userId = c.get("userId");
  const list = await rules.find({ userId }).sort({ sortOrder: 1, createdAt: 1 }).toArray();
  return c.json({ rules: list.map(publicRule) });
});

api.post("/rules", zValidator("json", ruleBody), async (c) => {
  const userId = c.get("userId");
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
  const [{ days, today }, list, entryList] = await Promise.all([
    loadPresence(userId, c.req.valid("query").tz),
    rules.find({ userId, enabled: true }).sort({ sortOrder: 1, createdAt: 1 }).toArray(),
    entries.find({ userId }).toArray(),
  ]);
  const active = list.filter((r) => !r.validUntil || r.validUntil >= today);
  const basis = buildBasisIndex(days, entryList);
  return c.json({ today, results: active.map((r) => evaluateRule(days, r, today, basis)) });
});

// MARK: «Чем заняться» — рекомендации мест

const discoverBody = z.object({
  lat: z.number().min(-90).max(90),
  lon: z.number().min(-180).max(180),
  query: z.string().trim().max(200).nullable().default(null),
  category: z.enum(Object.keys(CATEGORY_TYPES) as [string, ...string[]]).nullable().default(null),
  radiusKm: z.number().min(0.3).max(50).default(3),
  openNow: z.boolean().default(false),
  lang: z.enum(["ru", "en"]).default("en"),
  // локальное время пользователя «Sat 19:30» — для «сейчас вечер, лучше бар, чем музей»
  localTime: z.string().max(40).nullable().default(null),
  // sync — дождаться и подборки модели в этом же запросе (для отладки)
  sync: z.boolean().default(false),
});
// Ответ приходит сразу: быстрая подборка по справочнику. Если нейросеть включена и ответа для этого места
// ещё нет в кэше, вместе с ней отдаётся jobId — приложение показывает быстрый список и опрашивает задачу,
// а когда модель выберет и объяснит места, подменяет список
api.post("/discover", zValidator("json", discoverBody), async (c) => {
  if (!isPlacesEnabled()) throw new HTTPException(503, { message: "places are not configured" });
  const b = c.req.valid("json");
  const userId = c.get("userId");
  const { quick, refine } = await discover(userId, { baseUrl: baseUrl(c), lat: b.lat, lon: b.lon, query: b.query || null, category: (b.category as keyof typeof CATEGORY_TYPES) ?? null, radiusM: Math.round(b.radiusKm * 1000), openNow: b.openNow, lang: b.lang, localTime: b.localTime });
  if (b.sync && refine) return c.json({ ...(await refine()), jobId: null });
  const jobId = refine ? await startJob(userId, "discover", refine) : null;
  return c.json({ ...quick, jobId });
});

// Статус задачи: queued / running / done (+ result) / failed (+ error)
api.get("/jobs/:id", zValidator("param", z.object({ id: z.string().uuid() })), async (c) => {
  const job = await getJob(c.get("userId"), c.req.valid("param").id);
  if (!job) throw new HTTPException(404, { message: "job not found" });
  return c.json({ id: job.id, kind: job.kind, status: job.status, result: job.result, error: job.error });
});

api.get("/discover/status", (c) => c.json({ enabled: isPlacesEnabled() }));

// Погода в точке — для карточки «другой город» до того, как сделан поиск
api.get("/weather", zValidator("query", z.object({ lat: z.coerce.number().min(-90).max(90), lon: z.coerce.number().min(-180).max(180) })), async (c) => {
  const q = c.req.valid("query");
  return c.json({ weather: await weatherNow(q.lat, q.lon) });
});

// MARK: обновления приложения через Self Store

type LatestBuild = { version: string; buildNumber: string; notes: string | null; url: string };
let latestBuildCache: { at: number; value: LatestBuild | null } | null = null;
/** Последняя сборка в Self Store; ответ магазина кэшируется на 5 минут, чтобы не ходить туда при каждом запуске */
async function latestBuild(): Promise<LatestBuild | null> {
  if (!config.selfStoreUrl || !config.selfStoreAppId) return null;
  if (latestBuildCache && Date.now() - latestBuildCache.at < 5 * 60_000) return latestBuildCache.value;
  const res = await fetch(`${config.selfStoreUrl}/api/apps/${encodeURIComponent(config.selfStoreAppId)}/latest`, { signal: AbortSignal.timeout(8_000) });
  if (!res.ok) throw new Error(`self store ${res.status}`);
  const j = (await res.json()) as { latest: { version: string; buildNumber: string; notes: string | null } | null; url: string };
  const value = j.latest ? { version: j.latest.version, buildNumber: j.latest.buildNumber, notes: j.latest.notes, url: j.url } : null;
  latestBuildCache = { at: Date.now(), value };
  return value;
}

// Приложение присылает свою версию и сборку, сервер отвечает, есть ли новее и где взять
api.get("/app/update", zValidator("query", z.object({ version: z.string().max(40), build: z.string().max(40) })), async (c) => {
  const q = c.req.valid("query");
  let latest: LatestBuild | null;
  try {
    latest = await latestBuild();
  } catch (e) {
    console.error("update check:", e instanceof Error ? e.message : e);
    return c.json({ available: false });
  }
  if (!latest) return c.json({ available: false });
  return c.json({ available: isNewer(latest, q), latest });
});

/** Новее ли сборка магазина: сначала версия по частям (0.1.10 > 0.1.9), при равенстве — номер сборки */
function isNewer(latest: { version: string; buildNumber: string }, mine: { version: string; build: string }): boolean {
  const parts = (v: string) => v.split(".").map((x) => Number.parseInt(x, 10) || 0);
  const a = parts(latest.version);
  const b = parts(mine.version);
  for (let i = 0; i < Math.max(a.length, b.length); i++) {
    const d = (a[i] ?? 0) - (b[i] ?? 0);
    if (d !== 0) return d > 0;
  }
  return (Number.parseInt(latest.buildNumber, 10) || 0) > (Number.parseInt(mine.build, 10) || 0);
}

// Мини-тест о вкусах: ответы хранятся структурно и уходят в промпт рекомендаций
const tasteBody = z.object({
  cuisines: z.array(z.string().trim().min(1).max(30)).max(20).default([]),
  vibe: z.enum(["quiet", "lively", "any"]).default("any"),
  budget: z.enum(["cheap", "mid", "high", "any"]).default("any"),
  company: z.enum(["solo", "couple", "friends", "family"]).default("solo"),
  priorities: z.array(z.string().trim().min(1).max(30)).max(10).default([]),
  dietary: z.array(z.string().trim().min(1).max(30)).max(10).default([]),
  avoid: z.array(z.string().trim().min(1).max(30)).max(10).default([]),
  discovery: z.enum(["famous", "hidden", "mix"]).default("mix"),
  note: z.string().trim().max(300).nullable().default(null),
});
api.get("/taste", async (c) => {
  const p = await tastePreferences.findOne({ userId: c.get("userId") });
  if (!p) return c.json({ preferences: null });
  const { userId: _u, _id: _i, ...pub } = p;
  return c.json({ preferences: pub });
});
api.put("/taste", zValidator("json", tasteBody), async (c) => {
  const userId = c.get("userId");
  const doc = { userId, ...c.req.valid("json"), updatedAt: new Date().toISOString() };
  await tastePreferences.replaceOne({ userId }, doc, { upsert: true });
  const { userId: _u, ...pub } = doc;
  return c.json({ preferences: pub });
});

// Маршрут на полдня: 3–4 места по порядку со временем
const itineraryBody = z.object({
  lat: z.number().min(-90).max(90),
  lon: z.number().min(-180).max(180),
  hours: z.number().int().min(2).max(8).default(4),
  startTime: z.string().regex(/^\d{2}:\d{2}$/),
  radiusKm: z.number().min(0.5).max(20).default(3),
  lang: z.enum(["ru", "en"]).default("en"),
  localTime: z.string().max(40).nullable().default(null),
  // пожелания: «обязательно зайти в X», «ужин у воды»
  note: z.string().trim().max(300).nullable().default(null),
  // дата плана; null — сегодня
  date: isoDate.nullable().default(null),
  sync: z.boolean().default(false),
});
api.post("/itinerary", zValidator("json", itineraryBody), async (c) => {
  if (!isPlacesEnabled()) throw new HTTPException(503, { message: "places are not configured" });
  const b = c.req.valid("json");
  const userId = c.get("userId");
  const run = () => itinerary(userId, { baseUrl: baseUrl(c), lat: b.lat, lon: b.lon, query: null, category: null, radiusM: Math.round(b.radiusKm * 1000), openNow: false, lang: b.lang, localTime: b.localTime, hours: b.hours, startTime: b.startTime, note: b.note || null, date: b.date });
  if (b.sync) {
    try {
      return c.json(await run());
    } catch (e) {
      throw new HTTPException(502, { message: e instanceof Error ? e.message : "itinerary failed" });
    }
  }
  return c.json({ jobId: await startJob(userId, "itinerary", run) }, 202);
});

/** Адрес для ссылок наружу: PUBLIC_BASE_URL на проде, иначе origin запроса (dev: http://localhost:3000) */
function baseUrl(c: { req: { url: string; header: (n: string) => string | undefined } }): string {
  if (config.publicBaseUrl) return config.publicBaseUrl;
  const u = new URL(c.req.url);
  const proto = c.req.header("x-forwarded-proto") ?? u.protocol.replace(":", "");
  return `${proto}://${u.host}`;
}

const langQuery = z.object({ lang: z.enum(["ru", "en"]).default("en") });
const placeParam = z.object({ id: z.string().min(1).max(300) });

// Фото: подписанная ссылка без сессии (AsyncImage не умеет заголовки) → редирект на картинку Google.
// Отдельный роутер, монтируется в index.ts до api — иначе его перехватит requireSession.
export const photos = new Hono();
photos.get("/api/places/photo", zValidator("query", z.object({ name: z.string().min(1).max(500), w: z.coerce.number().int().min(100).max(1600), exp: z.coerce.number().int(), sig: z.string().length(32) })), async (c) => {
  const { name, w, exp, sig } = c.req.valid("query");
  if (!verifyPhoto(name, w, exp, sig)) throw new HTTPException(403, { message: "bad signature" });
  return c.redirect(await resolvePhoto(name, w), 302);
});

async function placeCard(userId: Point["userId"], id: string, lang: string, base: string) {
  const p = await placeDetails(id, lang);
  if (!p) throw new HTTPException(404, { message: "place not found" });
  const state = await userState(userId);
  return { ...p, photoUrls: p.photos.slice(0, 3).map((ph) => ({ url: photoUrl(base, ph.name, 800), author: ph.author })), user: { stars: state.ratings.get(id)?.stars ?? null, saved: state.saved.has(id) } };
}

api.get("/places/saved", zValidator("query", langQuery), async (c) => {
  const userId = c.get("userId");
  const list = await placeSaves.find({ userId }).sort({ savedAt: -1 }).toArray();
  return c.json({ places: list.map(({ userId: _u, _id: _i, ...s }) => s) });
});

api.get("/places/rated", async (c) => {
  const list = await placeRatings.find({ userId: c.get("userId") }).sort({ updatedAt: -1 }).toArray();
  return c.json({ ratings: list.map(({ userId: _u, _id: _i, ...r }) => r) });
});

api.get("/places/:id", zValidator("param", placeParam), zValidator("query", langQuery), async (c) => {
  return c.json({ place: await placeCard(c.get("userId"), c.req.valid("param").id, c.req.valid("query").lang, baseUrl(c)) });
});

const ratingBody = z.object({
  name: z.string().trim().min(1).max(200),
  countryCode: countryCode.nullable().default(null),
  city: z.string().trim().max(200).nullable().default(null),
  category: z.string().trim().max(40).nullable().default(null),
  stars: z.number().int().min(1).max(5),
  facets: z.record(z.string().max(30), z.number().int().min(1).max(5)).default({}),
  tags: z.array(z.string().trim().min(1).max(30)).max(10).default([]),
  note: z.string().trim().max(500).nullable().default(null),
  wouldReturn: z.boolean().nullable().default(null),
  visitedAt: isoDate.nullable().default(null),
});
api.put("/places/:id/rating", zValidator("param", placeParam), zValidator("json", ratingBody), async (c) => {
  const userId = c.get("userId");
  const { id } = c.req.valid("param");
  const b = c.req.valid("json");
  const now = new Date().toISOString();
  const prev = await placeRatings.findOne({ userId, placeId: id });
  const doc: PlaceRating = { userId, placeId: id, ...b, createdAt: prev?.createdAt ?? now, updatedAt: now };
  await placeRatings.replaceOne({ userId, placeId: id }, doc, { upsert: true });
  const { userId: _u, ...pub } = doc;
  return c.json({ rating: pub });
});
api.delete("/places/:id/rating", zValidator("param", placeParam), async (c) => {
  const res = await placeRatings.deleteOne({ userId: c.get("userId"), placeId: c.req.valid("param").id });
  return c.json({ deleted: res.deletedCount === 1 });
});

const saveBody = z.object({
  name: z.string().trim().min(1).max(200),
  lat: z.number(),
  lon: z.number(),
  countryCode: countryCode.nullable().default(null),
  city: z.string().trim().max(200).nullable().default(null),
});
api.put("/places/:id/save", zValidator("param", placeParam), zValidator("json", saveBody), async (c) => {
  const userId = c.get("userId");
  const { id } = c.req.valid("param");
  const doc: PlaceSave = { userId, placeId: id, ...c.req.valid("json"), savedAt: new Date().toISOString() };
  await placeSaves.replaceOne({ userId, placeId: id }, doc, { upsert: true });
  await placeDismissals.deleteOne({ userId, placeId: id });
  const { userId: _u, ...pub } = doc;
  return c.json({ saved: pub });
});
api.delete("/places/:id/save", zValidator("param", placeParam), async (c) => {
  const res = await placeSaves.deleteOne({ userId: c.get("userId"), placeId: c.req.valid("param").id });
  return c.json({ deleted: res.deletedCount === 1 });
});

api.post("/places/:id/dismiss", zValidator("param", placeParam), async (c) => {
  const userId = c.get("userId");
  const { id } = c.req.valid("param");
  await placeDismissals.updateOne({ userId, placeId: id }, { $set: { at: new Date().toISOString() } }, { upsert: true });
  return c.json({ dismissed: true });
});
api.delete("/places/:id/dismiss", zValidator("param", placeParam), async (c) => {
  await placeDismissals.deleteOne({ userId: c.get("userId"), placeId: c.req.valid("param").id });
  return c.json({ dismissed: false });
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
    // однократная виза уже использована (только для entries = single)
    used: z.boolean().default(false),
    // с какого дня считать потраченной (например, конец поездки); по умолчанию — день, когда флаг включили
    usedAt: isoDate.nullable().default(null),
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
  // документы, созданные до появления флага
  return { ...d, used: d.used ?? false, usedAt: d.usedAt ?? null, history: d.history ?? [] };
}

function documentFromBody(userId: Point["userId"], id: string, body: z.infer<typeof documentBody>, prev: TravelDocument | null): TravelDocument {
  const { lang: _lang, ...rest } = body;
  const countries = rest.kind === "passport" ? [rest.countryCode] : (rest.countries.length ? rest.countries : [rest.countryCode]);
  const used = rest.kind === "visa" && rest.entries === "single" && rest.used;
  // дата, с которой виза считается потраченной: фиксируем при первом включении, чтобы правила закрылись один раз
  const usedAt = used ? (rest.usedAt ?? prev?.usedAt ?? new Date().toISOString().slice(0, 10)) : null;
  return { userId, id, ...rest, used, usedAt, countries, history: prev?.history ?? [], createdAt: prev?.createdAt ?? new Date().toISOString(), updatedAt: new Date().toISOString() };
}

api.get("/documents", async (c) => {
  const list = await documents.find({ userId: c.get("userId") }).sort({ kind: 1, createdAt: 1 }).toArray();
  return c.json({ documents: list.map(publicDocument) });
});

api.post("/documents", zValidator("json", documentBody), async (c) => {
  const userId = c.get("userId");
  const body = c.req.valid("json");
  const doc = documentFromBody(userId, randomUUID(), body, null);
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
  const doc = documentFromBody(userId, id, body, prev);
  await documents.replaceOne({ userId, id }, doc);
  const generated = await syncRulesForDocument(userId, doc, body.lang);
  return c.json({ document: publicDocument(doc), rules: generated.map(publicRule) });
});

// Продление визы / ВНЖ одной кнопкой: прежний срок уходит в history, правила пересобираются
// под новые даты (тот же документ — основания въезда и пользовательские правки правил сохраняются)
const renewBody = z
  .object({
    validFrom: isoDate.nullable().default(null),
    validTo: isoDate,
    lang: z.enum(["ru", "en"]).default("en"),
  })
  .superRefine((d, ctx) => {
    if (d.validFrom && d.validFrom > d.validTo) ctx.addIssue({ code: "custom", path: ["validTo"], message: "validTo must be >= validFrom" });
  });

api.post("/documents/:id/renew", zValidator("param", z.object({ id: z.string().uuid() })), zValidator("json", renewBody), async (c) => {
  const userId = c.get("userId");
  const { id } = c.req.valid("param");
  const body = c.req.valid("json");
  const prev = await documents.findOne({ userId, id });
  if (!prev) throw new HTTPException(404, { message: "document not found" });
  if (prev.kind === "passport") throw new HTTPException(400, { message: "only visas and residence permits can be renewed" });
  const now = new Date().toISOString();
  const doc: TravelDocument = {
    ...prev,
    validFrom: body.validFrom ?? prev.validFrom,
    validTo: body.validTo,
    // продлённая виза снова годна к использованию
    used: false,
    usedAt: null,
    history: [...(prev.history ?? []), { validFrom: prev.validFrom, validTo: prev.validTo, renewedAt: now }],
    updatedAt: now,
  };
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
  // switch — смена статуса внутри пребывания без пересечения границы; дата = день смены
  kind: z.enum(["arrival", "switch"]).default("arrival"),
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
      kind: body.kind,
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
function publicCheck({ _id: _i, raw: _r, autoApply: _a, ...c }: RegimeCheck & { _id?: unknown }) {
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
  months: z.number().int().min(1).max(24).nullable().default(null),
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
  // autoApply — применить результат как правила сразу, без просмотра (только если правил ещё нет)
  zValidator("json", z.object({ lang: z.enum(["ru", "en"]).default("en"), force: z.boolean().default(false), autoApply: z.boolean().default(false) })),
  async (c) => {
    const userId = c.get("userId");
    const { passportId, country } = c.req.valid("param");
    const passport = await passportOr404(userId, passportId);
    const { lang, force, autoApply } = c.req.valid("json");
    const check = await startCheck(passport.countryCode, country, lang, force);
    let applied = false;
    if (autoApply) {
      if (check.status === "done") applied = await applyCheckForUser(userId, passportId, check);
      else if (check.status === "queued" || check.status === "running") await subscribeAutoApply(check.id, { userId, passportId, lang });
    }
    return c.json({ check: publicCheck(check), applied }, check.status === "done" ? 200 : 202);
  },
);

// Состояние проверки + диф с активной версией режима (если пользователь дал passportId)
api.get("/regime-checks/:id", zValidator("param", z.object({ id: z.string().uuid() })), zValidator("query", z.object({ passportId: z.string().uuid().optional() })), async (c) => {
  const userId = c.get("userId");
  const check = await regimeChecks.findOne({ id: c.req.valid("param").id });
  if (!check) throw new HTTPException(404, { message: "check not found" });
  const { passportId } = c.req.valid("query");
  const regime = passportId ? await regimes.findOne({ userId, passportId, countryCode: check.countryCode }) : null;
  const applied = !!regime?.active?.checkId && regime.active.checkId === check.id;
  // правила уже применены из этой проверки — дифа нет по определению
  const diff = check.draft && !applied ? diffVersions(check.lang, regime?.active ?? null, check.draft) : null;
  return c.json({ check: publicCheck(check), diff, applied });
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
