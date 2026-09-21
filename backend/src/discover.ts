import { randomUUID } from "node:crypto";
import type { ObjectId } from "mongodb";
import { z } from "zod";
import { completeJson, isAiEnabled } from "./ai.js";
import { discoverLog, placeDismissals, placeRatings, placeSaves, tastePreferences, tasteProfiles } from "./db.js";
import { CATEGORY_TYPES, distanceM, photoUrl, placeDetails, searchNearby, searchText, type Place } from "./places.js";
import { weatherNow, type Weather } from "./weather.js";

// «Чем заняться»: справочник Google даёт кандидатов с фактами, нейросеть выбирает из них под запрос,
// контекст и профиль вкусов пользователя и объясняет каждый выбор. Придумать место модель не может —
// она видит только идентификаторы кандидатов, чужие отбрасываются.

export type Category = keyof typeof CATEGORY_TYPES;

export type PlaceRating = {
  userId: ObjectId;
  placeId: string;
  name: string;
  countryCode: string | null;
  city: string | null;
  category: string | null;
  stars: number;
  // необязательные параметры по типу места: food, service, value, noise, scenery, crowd, interest, kids… (1–5)
  facets: Record<string, number>;
  tags: string[];
  note: string | null;
  wouldReturn: boolean | null;
  visitedAt: string | null;
  createdAt: string;
  updatedAt: string;
};

export type PlaceSave = {
  userId: ObjectId;
  placeId: string;
  name: string;
  lat: number;
  lon: number;
  countryCode: string | null;
  city: string | null;
  savedAt: string;
};

export type PlaceDismissal = { userId: ObjectId; placeId: string; at: string };

export type TasteProfile = {
  userId: ObjectId;
  // три абзаца «что нравится этому человеку» — модель переписывает, когда накопились новые оценки
  text: string;
  ratingsCount: number;
  lang: string;
  updatedAt: string;
};

/** Ответы мини-теста о вкусах — структурная часть профиля, работает с первого дня, до всяких оценок */
export type TastePreferences = {
  userId: ObjectId;
  cuisines: string[];
  vibe: "quiet" | "lively" | "any";
  budget: "cheap" | "mid" | "high" | "any";
  company: "solo" | "couple" | "friends" | "family";
  priorities: string[];
  dietary: string[];
  avoid: string[];
  discovery: "famous" | "hidden" | "mix";
  note: string | null;
  updatedAt: string;
};

export type DiscoverLog = {
  userId: ObjectId;
  id: string;
  at: string;
  query: string | null;
  category: string | null;
  lat: number;
  lon: number;
  shown: string[];
  source: "ai" | "basic";
};

export type Recommendation = Place & {
  distanceM: number;
  reason: string | null;
  tags: string[];
  photoUrls: { url: string; author: string | null }[];
  user: { stars: number | null; saved: boolean };
};

export type DiscoverRequest = {
  // откуда строить ссылки на фото
  baseUrl: string;
  lat: number;
  lon: number;
  query: string | null;
  category: Category | null;
  radiusM: number;
  openNow: boolean;
  lang: string;
  localTime: string | null;
};

const picksSchema = z.object({
  picks: z.array(z.object({ id: z.string(), reason: z.string().max(300), tags: z.array(z.string().max(30)).max(4) })).max(10),
  summary: z.string().max(400),
});
const picksJsonSchema = {
  type: "object",
  additionalProperties: false,
  required: ["picks", "summary"],
  properties: {
    picks: {
      type: "array",
      items: {
        type: "object",
        additionalProperties: false,
        required: ["id", "reason", "tags"],
        properties: { id: { type: "string" }, reason: { type: "string" }, tags: { type: "array", items: { type: "string" } } },
      },
    },
    summary: { type: "string" },
  },
};

function basicScore(p: Place): number {
  // Байесовская поправка: место с 4.9 и 12 отзывами не должно обгонять 4.6 с двумя тысячами
  const r = p.rating ?? 3.5;
  const n = p.ratingCount ?? 0;
  return (r * n + 4.2 * 30) / (n + 30);
}

function withUser(p: Place, req: DiscoverRequest, ratings: Map<string, PlaceRating>, saved: Set<string>): Recommendation {
  return {
    ...p,
    distanceM: distanceM(req.lat, req.lon, p.lat, p.lon),
    reason: null,
    tags: [],
    photoUrls: p.photos.slice(0, 3).map((ph) => ({ url: photoUrl(req.baseUrl, ph.name, 800), author: ph.author })),
    user: { stars: ratings.get(p.id)?.stars ?? null, saved: saved.has(p.id) },
  };
}

export async function userState(userId: ObjectId) {
  const [ratings, saves, dismissals] = await Promise.all([
    placeRatings.find({ userId }).toArray(),
    placeSaves.find({ userId }).toArray(),
    placeDismissals.find({ userId }).toArray(),
  ]);
  return {
    ratings: new Map(ratings.map((r) => [r.placeId, r])),
    saved: new Set(saves.map((s) => s.placeId)),
    dismissed: new Set(dismissals.map((d) => d.placeId)),
    ratingList: ratings,
  };
}

/** Ответы теста текстом для промпта */
export function preferencesForPrompt(p: TastePreferences | null): string | null {
  if (!p) return null;
  const lines = [
    p.cuisines.length ? `Favourite cuisines: ${p.cuisines.join(", ")}` : null,
    p.vibe !== "any" ? `Prefers ${p.vibe === "quiet" ? "quiet, calm places" : "lively, buzzing places"}` : null,
    p.budget !== "any" ? `Budget: ${p.budget === "cheap" ? "inexpensive" : p.budget === "mid" ? "mid-range" : "upscale is fine"}` : null,
    `Usually travels: ${p.company}`,
    p.priorities.length ? `Cares most about: ${p.priorities.join(", ")}` : null,
    p.dietary.length ? `Dietary: ${p.dietary.join(", ")}` : null,
    p.avoid.length ? `Avoid: ${p.avoid.join(", ")}` : null,
    p.discovery !== "mix" ? (p.discovery === "hidden" ? "Prefers hidden gems over famous spots" : "Prefers well-known, proven spots") : null,
    p.note ? `In their own words: ${p.note}` : null,
  ].filter(Boolean);
  return lines.length ? lines.join("\n") : null;
}

/** Профиль вкусов: пересобирается моделью, когда с прошлого раза прибавилось ≥3 оценки */
export async function tasteProfile(userId: ObjectId, ratings: PlaceRating[], lang: string): Promise<string | null> {
  if (ratings.length < 3) return null;
  const existing = await tasteProfiles.findOne({ userId });
  if (existing && ratings.length - existing.ratingsCount < 3 && existing.lang === lang) return existing.text;
  if (!isAiEnabled()) return existing?.text ?? null;
  const lines = ratings
    .slice()
    .sort((a, b) => b.updatedAt.localeCompare(a.updatedAt))
    .slice(0, 80)
    .map((r) => `${r.stars}/5 ${r.name} (${[r.category, r.city, r.countryCode].filter(Boolean).join(", ")})${Object.keys(r.facets).length ? " facets " + JSON.stringify(r.facets) : ""}${r.tags.length ? " tags " + r.tags.join("/") : ""}${r.wouldReturn === false ? " would-not-return" : ""}${r.note ? ` note: ${r.note}` : ""}`);
  const language = lang === "ru" ? "Russian" : "English";
  try {
    const out = (await completeJson({
      system: `You write a short taste profile of a traveller from their place ratings, to be used by a recommender. 2-3 short paragraphs in ${language}: what they clearly like and dislike (cuisines, atmosphere, price, noise, crowds, kinds of activities), how they rate (generous or strict), what to avoid recommending. Only conclusions supported by the ratings; no names of places.`,
      user: lines.join("\n"),
      name: "taste_profile",
      schema: { type: "object", additionalProperties: false, required: ["text"], properties: { text: { type: "string" } } },
    })) as { text: string };
    await tasteProfiles.updateOne({ userId }, { $set: { text: out.text, ratingsCount: ratings.length, lang, updatedAt: new Date().toISOString() } }, { upsert: true });
    return out.text;
  } catch {
    return existing?.text ?? null;
  }
}

/** Оценки для промпта: чтобы модель могла сказать «похоже на X, которому вы поставили 5» */
function ratedForPrompt(ratings: PlaceRating[]): string | null {
  const top = ratings
    .slice()
    .sort((a, b) => b.updatedAt.localeCompare(a.updatedAt))
    .slice(0, 20)
    .map((r) => `${r.stars}/5 ${r.name}${r.category ? ` (${r.category})` : ""}${r.tags.length ? ` — ${r.tags.join(", ")}` : ""}`);
  return top.length ? top.join("\n") : null;
}

function weatherLine(w: Weather | null): string | null {
  if (!w) return null;
  const hints = [w.isRainy ? "it is raining — prefer indoor places" : null, w.isHot ? "it is very hot — prefer indoor or shaded, evening outdoors" : null, w.isCold ? "it is freezing — prefer indoor" : null].filter(Boolean);
  return `Weather now: ${w.tempC}°C, ${w.summary}${hints.length ? `. ${hints.join("; ")}` : ""}`;
}

export async function discover(userId: ObjectId, req: DiscoverRequest): Promise<{ recommendations: Recommendation[]; summary: string | null; source: "ai" | "basic"; weather: Weather | null }> {
  const [state, weather, prefs] = await Promise.all([userState(userId), weatherNow(req.lat, req.lon), tastePreferences.findOne({ userId })]);
  const stated = preferencesForPrompt(prefs);
  // «удиви меня» в дождь или жару — сразу закрытые места
  const badWeather = !!weather && (weather.isRainy || weather.isHot || weather.isCold);
  const category = req.category ?? "any";
  const types = category === "any" && badWeather ? CATEGORY_TYPES.rainy : CATEGORY_TYPES[category];
  const candidatesRaw = req.query
    ? await searchText(req.query, req.lat, req.lon, req.radiusM, req.lang, req.openNow)
    : await searchNearby(req.lat, req.lon, req.radiusM, types, req.lang);
  // «не интересно» и плохо оценённое не показываем; если открыто сейчас важно — отсекаем закрытые
  const candidates = candidatesRaw
    .filter((p) => !state.dismissed.has(p.id))
    .filter((p) => (state.ratings.get(p.id)?.stars ?? 5) >= 3)
    .filter((p) => !req.openNow || p.openNow !== false)
    .map((p) => withUser(p, req, state.ratings, state.saved));

  let picks: Recommendation[];
  let summary: string | null = null;
  let source: "ai" | "basic" = "basic";

  if (isAiEnabled() && candidates.length > 0) {
    try {
      const profile = await tasteProfile(userId, state.ratingList, req.lang);
      const language = req.lang === "ru" ? "Russian" : "English";
      const list = candidates.map((c) =>
        JSON.stringify({
          id: c.id, name: c.name, type: c.primaryType, types: c.types.slice(0, 5), rating: c.rating, reviews: c.ratingCount, price: c.priceLevel,
          openNow: c.openNow, distanceM: c.distanceM, summary: c.summary, userStars: c.user.stars, saved: c.user.saved,
        }),
      );
      const rated = ratedForPrompt(state.ratingList);
      const ctx = [
        req.query ? `Request: "${req.query}"${req.category && req.category !== "any" ? ` (category: ${req.category})` : ""}` : `Category: ${req.category ?? "any"}`,
        req.localTime ? `Local time: ${req.localTime}` : null,
        weatherLine(weather),
        req.openNow ? "Must be open now." : null,
        stated ? `Stated preferences (from a short quiz):\n${stated}` : null,
        profile ? `Taste profile (from ratings):\n${profile}` : stated ? null : "No ratings yet — assume a curious traveller who values quality over hype.",
        rated ? `Places this person rated (use them for comparisons like "similar to X, which you rated 5/5"):\n${rated}` : null,
      ].filter(Boolean).join("\n");
      const out = picksSchema.parse(
        await completeJson({
          system: `You are a local friend recommending places. Choose the best 6-8 candidates for this person and moment. Rules: pick ONLY ids from the candidate list; prefer variety (not six similar cafes); weigh rating with review count; respect distance and opening status; use the taste profile; places the user already rated highly are fine to remind about but say so. For each pick write one concrete sentence in ${language} explaining why THIS person would like it now (no generic praise), and 1-3 short tags in ${language}. summary: one sentence in ${language} about the selection. Never invent places or facts not in the data.`,
          user: `${ctx}\n\nCandidates:\n${list.join("\n")}`,
          name: "recommendations",
          schema: picksJsonSchema,
          timeoutMs: 90_000,
        }),
      );
      const byId = new Map(candidates.map((c) => [c.id, c]));
      picks = out.picks.flatMap((p) => {
        const c = byId.get(p.id);
        return c ? [{ ...c, reason: p.reason, tags: p.tags }] : [];
      });
      // модель вернула мало — добираем лучшими по рейтингу
      if (picks.length < 4) {
        const have = new Set(picks.map((p) => p.id));
        for (const c of candidates.sort((a, b) => basicScore(b) - basicScore(a))) if (!have.has(c.id) && picks.length < 6) picks.push(c);
      }
      summary = out.summary;
      source = "ai";
    } catch (e) {
      console.error("discover: ai ranking failed —", e instanceof Error ? e.message : e);
      picks = candidates.sort((a, b) => basicScore(b) - basicScore(a)).slice(0, 8);
    }
  } else {
    picks = candidates.sort((a, b) => basicScore(b) - basicScore(a)).slice(0, 8);
  }

  await discoverLog.insertOne({ userId, id: randomUUID(), at: new Date().toISOString(), query: req.query, category: req.category, lat: req.lat, lon: req.lon, shown: picks.map((p) => p.id), source });
  return { recommendations: picks, summary, source, weather };
}

// MARK: маршрут на полдня

export type ItineraryStop = Recommendation & { start: string; end: string };

const itinerarySchema = z.object({
  title: z.string().max(80),
  summary: z.string().max(400),
  stops: z.array(z.object({ id: z.string(), start: z.string().max(5), end: z.string().max(5), reason: z.string().max(300) })).min(2).max(5),
});
const itineraryJsonSchema = {
  type: "object",
  additionalProperties: false,
  required: ["title", "summary", "stops"],
  properties: {
    title: { type: "string" },
    summary: { type: "string" },
    stops: {
      type: "array",
      items: {
        type: "object",
        additionalProperties: false,
        required: ["id", "start", "end", "reason"],
        properties: { id: { type: "string" }, start: { type: "string" }, end: { type: "string" }, reason: { type: "string" } },
      },
    },
  },
};

/** Связка из 3–4 мест с временем: кофе → прогулка → ужин. Кандидаты из нескольких категорий, модель строит порядок. */
export async function itinerary(userId: ObjectId, req: DiscoverRequest & { hours: number; startTime: string; note: string | null }): Promise<{ title: string; summary: string; stops: ItineraryStop[]; weather: Weather | null }> {
  if (!isAiEnabled()) throw new Error("assistant is not configured");
  const [state, weather, prefs] = await Promise.all([userState(userId), weatherNow(req.lat, req.lon), tastePreferences.findOne({ userId })]);
  const badWeather = !!weather && (weather.isRainy || weather.isHot || weather.isCold);
  const cats: Category[] = badWeather ? ["coffee", "culture", "rainy", "eat"] : ["coffee", "walk", "culture", "eat"];
  const lists = await Promise.all(cats.map((c) => searchNearby(req.lat, req.lon, req.radiusM, CATEGORY_TYPES[c], req.lang)));
  const seen = new Set<string>();
  const candidates: Recommendation[] = [];
  const add = (p: Place, tag: string) => {
    if (seen.has(p.id) || state.dismissed.has(p.id) || (state.ratings.get(p.id)?.stars ?? 5) < 3) return;
    seen.add(p.id);
    candidates.push({ ...withUser(p, req, state.ratings, state.saved), tags: [tag] });
  };
  // пожелание пользователя: «обязательно зайти в Roasters» — ищем названные места текстовым поиском,
  // чтобы они точно оказались среди кандидатов; сохранённые рядом тоже добавляем
  if (req.note) {
    const wished = await searchText(req.note, req.lat, req.lon, Math.max(req.radiusM, 5000), req.lang, false).catch(() => [] as Place[]);
    // у сетей несколько филиалов — берём ближайшие, а не те, что Google поставил первыми
    wished.sort((a, b) => distanceM(req.lat, req.lon, a.lat, a.lon) - distanceM(req.lat, req.lon, b.lat, b.lon));
    for (const p of wished.slice(0, 5)) add(p, "mentioned-by-user");
  }
  const savedNearby = [...state.saved].slice(0, 15);
  for (const id of savedNearby) {
    const p = await placeDetails(id, req.lang).catch(() => null);
    if (p && distanceM(req.lat, req.lon, p.lat, p.lon) <= req.radiusM * 2) add(p, "saved");
  }
  for (const [i, list] of lists.entries()) {
    for (const p of list.slice(0, 10)) add(p, cats[i]);
  }
  if (candidates.length < 3) throw new Error("not enough places nearby");
  const profile = await tasteProfile(userId, state.ratingList, req.lang);
  const language = req.lang === "ru" ? "Russian" : "English";
  const list = candidates.map((c) => JSON.stringify({ id: c.id, name: c.name, kind: c.tags?.[0], type: c.primaryType, rating: c.rating, reviews: c.ratingCount, price: c.priceLevel, openNow: c.openNow, distanceM: c.distanceM, lat: c.lat, lon: c.lon, hours: c.hours.slice(0, 2), userStars: c.user.stars }));
  const ctx = [
    `Plan a ${req.hours}-hour outing starting at ${req.startTime} local time from the user's location (${req.lat.toFixed(4)}, ${req.lon.toFixed(4)}).`,
    req.note ? `The user's wishes for this outing (highest priority; if they name a place that is among the candidates, it MUST be a stop, and the rest of the plan is built around it): "${req.note}"` : null,
    req.localTime ? `Today: ${req.localTime}` : null,
    weatherLine(weather),
    preferencesForPrompt(prefs) ? `Stated preferences:\n${preferencesForPrompt(prefs)}` : null,
    profile ? `Taste profile:\n${profile}` : null,
    ratedForPrompt(state.ratingList) ? `Rated places:\n${ratedForPrompt(state.ratingList)}` : null,
  ].filter(Boolean).join("\n");
  const out = itinerarySchema.parse(
    await completeJson({
      system: `You are a local friend planning a short outing. Pick 3-4 stops ONLY from the candidates, in a sensible order. Candidates tagged "mentioned-by-user" match the user's wishes and "saved" are places the user saved — prefer them when they fit: geographically compact (each next stop within walking distance or a short ride), plausible timing with start/end as HH:MM in local time within the given window, a natural rhythm (e.g. coffee → walk or museum → dinner), respect opening status. Use the taste profile. For each stop one concrete sentence in ${language} why it fits this plan and this person. title: 3-6 words in ${language}. summary: one sentence in ${language}. Never invent places.`,
      user: `${ctx}\n\nCandidates:\n${list.join("\n")}`,
      name: "itinerary",
      schema: itineraryJsonSchema,
      timeoutMs: 90_000,
    }),
  );
  const byId = new Map(candidates.map((c) => [c.id, c]));
  const stops: ItineraryStop[] = out.stops.flatMap((s) => {
    const c = byId.get(s.id);
    return c ? [{ ...c, reason: s.reason, tags: [], start: s.start, end: s.end }] : [];
  });
  if (stops.length < 2) throw new Error("could not build a route");
  await discoverLog.insertOne({ userId, id: randomUUID(), at: new Date().toISOString(), query: `itinerary ${req.hours}h${req.note ? `: ${req.note}` : ""}`, category: null, lat: req.lat, lon: req.lon, shown: stops.map((s) => s.id), source: "ai" });
  return { title: out.title, summary: out.summary, stops, weather };
}
