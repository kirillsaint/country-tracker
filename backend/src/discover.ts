import { randomUUID } from "node:crypto";
import type { ObjectId } from "mongodb";
import { z } from "zod";
import { completeJson, isAiEnabled } from "./ai.js";
import { discoverLog, placeDismissals, placeRatings, placeSaves, tasteProfiles } from "./db.js";
import { CATEGORY_TYPES, distanceM, photoUrl, searchNearby, searchText, type Place } from "./places.js";

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

export async function discover(userId: ObjectId, req: DiscoverRequest): Promise<{ recommendations: Recommendation[]; summary: string | null; source: "ai" | "basic" }> {
  const state = await userState(userId);
  const candidatesRaw = req.query
    ? await searchText(req.query, req.lat, req.lon, req.radiusM, req.lang, req.openNow)
    : await searchNearby(req.lat, req.lon, req.radiusM, CATEGORY_TYPES[req.category ?? "any"], req.lang);
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
      const ctx = [
        req.query ? `Request: "${req.query}"` : `Category: ${req.category ?? "any"}`,
        req.localTime ? `Local time: ${req.localTime}` : null,
        req.openNow ? "Must be open now." : null,
        profile ? `Taste profile:\n${profile}` : "No ratings yet — assume a curious traveller who values quality over hype.",
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
  return { recommendations: picks, summary, source };
}
