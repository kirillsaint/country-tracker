import { feature } from "@rapideditor/country-coder";

export type CountryInfo = { code: string; name: string } | null;

// Оффлайн-определение страны по координатам (границы зашиты в пакет, ~1 МБ).
// Возвращает null в океане / нейтральных водах.
export function countryAt(lat: number, lon: number): CountryInfo {
  const f = feature([lon, lat], { level: "country" });
  if (!f?.properties.iso1A2) return null;
  return { code: f.properties.iso1A2, name: f.properties.nameEn };
}

export function countryName(code: string): string | null {
  const f = feature(code);
  return f?.properties.nameEn ?? null;
}

// YYYY-MM-DD по местному времени устройства
export function localDateOf(recordedAtIso: string, tzOffsetMin: number): string {
  const t = new Date(recordedAtIso).getTime() + tzOffsetMin * 60_000;
  return new Date(t).toISOString().slice(0, 10);
}
