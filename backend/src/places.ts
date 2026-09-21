import { createHash, createHmac } from "node:crypto";
import { config } from "./config.js";
import { placeCache } from "./db.js";

// Google Places API (New): факты о местах — фото, рейтинг, часы, координаты. Ключ живёт только здесь;
// приложение ходит через наш сервер. По условиям Google данные кэшируем не дольше суток (лимит 30 дней),
// фото не сохраняем вовсе — отдаём подписанной ссылкой на наш прокси, который редиректит к Google.

export const isPlacesEnabled = () => config.googlePlacesApiKey.length > 0;

export type Photo = { name: string; author: string | null; width: number; height: number };

export type Place = {
  id: string;
  name: string;
  address: string | null;
  lat: number;
  lon: number;
  rating: number | null;
  ratingCount: number | null;
  // 0 бесплатно … 4 очень дорого
  priceLevel: number | null;
  primaryType: string | null;
  types: string[];
  openNow: boolean | null;
  hours: string[];
  photos: Photo[];
  website: string | null;
  mapsUrl: string | null;
  phone: string | null;
  summary: string | null;
};

const BASE = "https://places.googleapis.com/v1";
const FIELDS = [
  "id", "displayName", "formattedAddress", "location", "rating", "userRatingCount", "priceLevel", "primaryType", "types",
  "currentOpeningHours.openNow", "regularOpeningHours.weekdayDescriptions", "photos", "websiteUri", "googleMapsUri",
  "editorialSummary", "internationalPhoneNumber",
];
const CACHE_HOURS = 24;

// Категории приложения → типы Google для поиска рядом (Table A)
export const CATEGORY_TYPES: Record<string, string[]> = {
  eat: ["restaurant"],
  coffee: ["cafe", "coffee_shop", "bakery"],
  walk: ["park", "tourist_attraction", "hiking_area", "garden"],
  culture: ["museum", "art_gallery", "historical_landmark", "performing_arts_theater"],
  nightlife: ["bar", "night_club", "wine_bar", "pub"],
  kids: ["amusement_park", "zoo", "aquarium", "playground", "water_park"],
  shop: ["shopping_mall", "market", "book_store"],
  rainy: ["museum", "shopping_mall", "art_gallery", "spa", "movie_theater", "bowling_alley"],
  any: ["tourist_attraction", "restaurant", "cafe", "park", "museum"],
};

const PRICE: Record<string, number> = {
  PRICE_LEVEL_FREE: 0,
  PRICE_LEVEL_INEXPENSIVE: 1,
  PRICE_LEVEL_MODERATE: 2,
  PRICE_LEVEL_EXPENSIVE: 3,
  PRICE_LEVEL_VERY_EXPENSIVE: 4,
};

type RawPlace = {
  id: string;
  displayName?: { text?: string };
  formattedAddress?: string;
  location?: { latitude: number; longitude: number };
  rating?: number;
  userRatingCount?: number;
  priceLevel?: string;
  primaryType?: string;
  types?: string[];
  currentOpeningHours?: { openNow?: boolean };
  regularOpeningHours?: { weekdayDescriptions?: string[] };
  photos?: { name: string; widthPx?: number; heightPx?: number; authorAttributions?: { displayName?: string }[] }[];
  websiteUri?: string;
  googleMapsUri?: string;
  editorialSummary?: { text?: string };
  internationalPhoneNumber?: string;
};

function normalize(p: RawPlace): Place | null {
  if (!p.id || !p.location) return null;
  return {
    id: p.id,
    name: p.displayName?.text ?? "",
    address: p.formattedAddress ?? null,
    lat: p.location.latitude,
    lon: p.location.longitude,
    rating: p.rating ?? null,
    ratingCount: p.userRatingCount ?? null,
    priceLevel: p.priceLevel ? (PRICE[p.priceLevel] ?? null) : null,
    primaryType: p.primaryType ?? null,
    types: p.types ?? [],
    openNow: p.currentOpeningHours?.openNow ?? null,
    hours: p.regularOpeningHours?.weekdayDescriptions ?? [],
    photos: (p.photos ?? []).slice(0, 5).map((ph) => ({ name: ph.name, author: ph.authorAttributions?.[0]?.displayName ?? null, width: ph.widthPx ?? 0, height: ph.heightPx ?? 0 })),
    website: p.websiteUri ?? null,
    mapsUrl: p.googleMapsUri ?? null,
    phone: p.internationalPhoneNumber ?? null,
    summary: p.editorialSummary?.text ?? null,
  };
}

async function google<T>(path: string, init: { method: "GET" | "POST"; body?: unknown; fields: string }): Promise<T> {
  const res = await fetch(`${BASE}${path}`, {
    method: init.method,
    headers: {
      "content-type": "application/json",
      "X-Goog-Api-Key": config.googlePlacesApiKey,
      "X-Goog-FieldMask": init.fields,
    },
    body: init.body ? JSON.stringify(init.body) : undefined,
    signal: AbortSignal.timeout(20_000),
  });
  const text = await res.text();
  if (!res.ok) throw new Error(`google places ${res.status}: ${text.slice(0, 300)}`);
  return JSON.parse(text) as T;
}

async function cached<T>(key: string, load: () => Promise<T>): Promise<T> {
  const hit = await placeCache.findOne({ key });
  if (hit && hit.expiresAt > new Date()) return hit.data as T;
  const data = await load();
  await placeCache.updateOne({ key }, { $set: { data, expiresAt: new Date(Date.now() + CACHE_HOURS * 3_600_000) } }, { upsert: true });
  return data;
}

function round(n: number): number {
  // ~100 м — достаточно для кэша и не отдаём Google точное место
  return Math.round(n * 1000) / 1000;
}

/** Места рядом по категории (до 20), популярные первыми */
export async function searchNearby(lat: number, lon: number, radiusM: number, types: string[], lang: string): Promise<Place[]> {
  const key = `nearby|${round(lat)}|${round(lon)}|${radiusM}|${types.join(",")}|${lang}`;
  return cached(key, async () => {
    const r = await google<{ places?: RawPlace[] }>("/places:searchNearby", {
      method: "POST",
      fields: FIELDS.map((f) => `places.${f}`).join(","),
      body: {
        includedTypes: types,
        maxResultCount: 20,
        rankPreference: "POPULARITY",
        languageCode: lang,
        locationRestriction: { circle: { center: { latitude: round(lat), longitude: round(lon) }, radius: radiusM } },
      },
    });
    return (r.places ?? []).map(normalize).filter((p): p is Place => p !== null);
  });
}

/** Свободный запрос («тихая кофейня с розетками») с привязкой к месту */
export async function searchText(query: string, lat: number, lon: number, radiusM: number, lang: string, openNow: boolean): Promise<Place[]> {
  const key = `text|${query.toLowerCase()}|${round(lat)}|${round(lon)}|${radiusM}|${lang}|${openNow ? 1 : 0}`;
  return cached(key, async () => {
    const r = await google<{ places?: RawPlace[] }>("/places:searchText", {
      method: "POST",
      fields: FIELDS.map((f) => `places.${f}`).join(","),
      body: {
        textQuery: query,
        maxResultCount: 20,
        languageCode: lang,
        ...(openNow ? { openNow: true } : {}),
        locationBias: { circle: { center: { latitude: round(lat), longitude: round(lon) }, radius: radiusM } },
      },
    });
    return (r.places ?? []).map(normalize).filter((p): p is Place => p !== null);
  });
}

/** Карточка одного места (для сохранённых и оценённых) */
export async function placeDetails(id: string, lang: string): Promise<Place | null> {
  const key = `place|${id}|${lang}`;
  return cached(key, async () => {
    const r = await google<RawPlace>(`/places/${encodeURIComponent(id)}?languageCode=${lang}`, { method: "GET", fields: FIELDS.join(",") });
    return normalize(r);
  });
}

// MARK: фото через подписанную ссылку (ключ Google наружу не выходит, чужие не тратят нашу квоту)

const photoSecret = () => createHash("sha256").update(`${config.googlePlacesApiKey}|photo`).digest();

export function photoUrl(baseUrl: string, name: string, width: number): string {
  const exp = Math.floor(Date.now() / 1000) + 24 * 3600;
  const sig = createHmac("sha256", photoSecret()).update(`${name}|${width}|${exp}`).digest("hex").slice(0, 32);
  const q = new URLSearchParams({ name, w: String(width), exp: String(exp), sig });
  return `${baseUrl}/api/places/photo?${q}`;
}

export function verifyPhoto(name: string, width: number, exp: number, sig: string): boolean {
  if (exp < Date.now() / 1000) return false;
  const expected = createHmac("sha256", photoSecret()).update(`${name}|${width}|${exp}`).digest("hex").slice(0, 32);
  return expected === sig;
}

/** Реальная ссылка на картинку у Google (короткоживущая, без ключа) */
export async function resolvePhoto(name: string, width: number): Promise<string> {
  const res = await fetch(`${BASE}/${name}/media?maxWidthPx=${width}&skipHttpRedirect=true&key=${config.googlePlacesApiKey}`, { signal: AbortSignal.timeout(15_000) });
  const text = await res.text();
  if (!res.ok) throw new Error(`google photo ${res.status}: ${text.slice(0, 200)}`);
  return (JSON.parse(text) as { photoUri: string }).photoUri;
}

export function distanceM(lat1: number, lon1: number, lat2: number, lon2: number): number {
  const R = 6_371_000;
  const toRad = (x: number) => (x * Math.PI) / 180;
  const dLat = toRad(lat2 - lat1);
  const dLon = toRad(lon2 - lon1);
  const a = Math.sin(dLat / 2) ** 2 + Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLon / 2) ** 2;
  return Math.round(2 * R * Math.asin(Math.sqrt(a)));
}
