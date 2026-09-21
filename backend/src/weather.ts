import { placeCache } from "./db.js";

// Погода сейчас — Open-Meteo, бесплатно и без ключа. Нужна рекомендациям: в дождь и жару
// подборка уходит в помещения сама. Кэш 30 минут по округлённым координатам.

export type Weather = {
  tempC: number;
  precipitationMm: number;
  windKmh: number;
  code: number;
  // короткое описание по-английски для промпта; локализует приложение по коду
  summary: string;
  isRainy: boolean;
  isHot: boolean;
  isCold: boolean;
};

const CODES: Record<number, string> = {
  0: "clear", 1: "mostly clear", 2: "partly cloudy", 3: "overcast", 45: "fog", 48: "fog",
  51: "light drizzle", 53: "drizzle", 55: "heavy drizzle", 61: "light rain", 63: "rain", 65: "heavy rain",
  66: "freezing rain", 67: "freezing rain", 71: "light snow", 73: "snow", 75: "heavy snow", 77: "snow grains",
  80: "rain showers", 81: "rain showers", 82: "violent rain showers", 85: "snow showers", 86: "snow showers",
  95: "thunderstorm", 96: "thunderstorm with hail", 99: "thunderstorm with hail",
};

export async function weatherNow(lat: number, lon: number): Promise<Weather | null> {
  const key = `weather|${lat.toFixed(2)}|${lon.toFixed(2)}`;
  const hit = await placeCache.findOne({ key });
  if (hit && hit.expiresAt > new Date()) return hit.data as Weather;
  try {
    const url = `https://api.open-meteo.com/v1/forecast?latitude=${lat.toFixed(3)}&longitude=${lon.toFixed(3)}&current=temperature_2m,precipitation,weather_code,wind_speed_10m&timezone=auto`;
    const res = await fetch(url, { signal: AbortSignal.timeout(8_000) });
    if (!res.ok) return null;
    const j = (await res.json()) as { current?: { temperature_2m: number; precipitation: number; weather_code: number; wind_speed_10m: number } };
    const c = j.current;
    if (!c) return null;
    const w: Weather = {
      tempC: Math.round(c.temperature_2m),
      precipitationMm: c.precipitation,
      windKmh: Math.round(c.wind_speed_10m),
      code: c.weather_code,
      summary: CODES[c.weather_code] ?? "unknown",
      isRainy: c.precipitation >= 0.5 || c.weather_code >= 51,
      isHot: c.temperature_2m >= 35,
      isCold: c.temperature_2m <= -5,
    };
    await placeCache.updateOne({ key }, { $set: { data: w, expiresAt: new Date(Date.now() + 30 * 60_000) } }, { upsert: true });
    return w;
  } catch {
    return null;
  }
}
