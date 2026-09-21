import { createInterface } from "node:readline";
import { Readable } from "node:stream";
import { createInflateRaw, inflateRawSync } from "node:zlib";
import { cities, citiesMeta } from "./db.js";

// Справочник городов для выбора в ручной записи: GeoNames cities5000 (все населённые пункты
// от 5 000 жителей, ~60 тысяч), лицензия CC BY 4.0. Скачивается и импортируется в Mongo сам при первом
// старте с пустой коллекцией; повторный импорт — CITIES_REIMPORT=1 или удалить коллекцию cities.

export type City = {
  id: number;
  // английское имя — им подписываются точки и ручные записи
  name: string;
  countryCode: string;
  // регион (штат/область) для различения одноимённых городов
  region: string | null;
  lat: number;
  lon: number;
  population: number;
  // все варианты имени в нижнем регистре, включая другие языки («дубай»), для поиска по префиксу
  search: string[];
  // переводы из GeoNames alternateNamesV2 по языкам: { ru: "Дубай" } — единственный источник переводов
  i18n?: Record<string, string>;
};

const CITIES_URL = "https://download.geonames.org/export/dump/cities5000.zip";
const ADMIN1_URL = "https://download.geonames.org/export/dump/admin1CodesASCII.txt";
// ~200 МБ, тянем потоком по HTTP Range, оставляем только нужные языки для наших городов
const ALT_NAMES_URL = "https://download.geonames.org/export/dump/alternateNamesV2.zip";
// языки переводов (кроме английского — им подписаны сами города); CITY_LANGS=ru,de
const LANGS = (process.env.CITY_LANGS ?? "ru").split(",").map((l) => l.trim()).filter(Boolean);

/** Единственный файл из zip-архива без внешних зависимостей: читаем central directory, распаковываем deflate. */
function unzipSingle(buf: Buffer): Buffer {
  let eocd = -1;
  for (let i = buf.length - 22; i >= Math.max(0, buf.length - 65_557); i--) {
    if (buf.readUInt32LE(i) === 0x06054b50) {
      eocd = i;
      break;
    }
  }
  if (eocd < 0) throw new Error("zip: end of central directory not found");
  const cd = buf.readUInt32LE(eocd + 16);
  if (buf.readUInt32LE(cd) !== 0x02014b50) throw new Error("zip: bad central directory");
  const method = buf.readUInt16LE(cd + 10);
  const compressedSize = buf.readUInt32LE(cd + 20);
  const localOffset = buf.readUInt32LE(cd + 42);
  if (buf.readUInt32LE(localOffset) !== 0x04034b50) throw new Error("zip: bad local header");
  const nameLen = buf.readUInt16LE(localOffset + 26);
  const extraLen = buf.readUInt16LE(localOffset + 28);
  const start = localOffset + 30 + nameLen + extraLen;
  const data = buf.subarray(start, start + compressedSize);
  if (method === 8) return inflateRawSync(data);
  if (method === 0) return Buffer.from(data);
  throw new Error(`zip: unsupported compression ${method}`);
}

async function download(url: string): Promise<Buffer> {
  const res = await fetch(url, { headers: { "user-agent": "country-counter/1.0" } });
  if (!res.ok) throw new Error(`${url}: HTTP ${res.status}`);
  return Buffer.from(await res.arrayBuffer());
}

function parseAdmin1(text: string): Map<string, string> {
  const out = new Map<string, string>();
  for (const line of text.split("\n")) {
    const [code, name] = line.split("\t");
    if (code && name) out.set(code, name);
  }
  return out;
}

function parseCities(text: string, admin1: Map<string, string>): City[] {
  const out: City[] = [];
  for (const line of text.split("\n")) {
    if (!line) continue;
    const f = line.split("\t");
    // 0 id, 1 name, 2 asciiname, 3 alternatenames, 4 lat, 5 lon, 6 class, 7 code, 8 country, 10 admin1, 14 population
    const id = Number(f[0]);
    const name = f[1];
    const countryCode = f[8];
    if (!id || !name || !countryCode) continue;
    // alternatenames — все языки вперемешку; у крупных городов их сотни, русское имя может быть далеко
    // в списке, поэтому берём все (до 400 — защита от аномалий)
    const alts = f[3] ? f[3].split(",").slice(0, 400) : [];
    const search = [...new Set([name, f[2], ...alts].filter(Boolean).map((s) => s.toLowerCase().trim()))];
    out.push({
      id,
      name,
      countryCode,
      region: admin1.get(`${countryCode}.${f[10]}`) ?? null,
      lat: Number(f[4]),
      lon: Number(f[5]),
      population: Number(f[14]) || 0,
      search,
    });
  }
  return out;
}

// MARK: переводы

async function fetchRange(url: string, start: number, end: number): Promise<Response> {
  const res = await fetch(url, { headers: { range: `bytes=${start}-${end}`, "user-agent": "country-counter/1.0" } });
  if (res.status !== 206) throw new Error(`${url}: range not supported (HTTP ${res.status})`);
  return res;
}

/** Где в zip лежат сжатые байты нужного файла — по central directory, не скачивая архив целиком */
async function locateZipEntry(url: string, fileName: string): Promise<{ start: number; end: number; method: number }> {
  const head = await fetch(url, { method: "HEAD", headers: { "user-agent": "country-counter/1.0" } });
  const size = Number(head.headers.get("content-length"));
  if (!size) throw new Error(`${url}: no content-length`);
  const tailStart = Math.max(0, size - 65_557 - 22);
  const tail = Buffer.from(await (await fetchRange(url, tailStart, size - 1)).arrayBuffer());
  let eocd = -1;
  for (let i = tail.length - 22; i >= 0; i--) {
    if (tail.readUInt32LE(i) === 0x06054b50) {
      eocd = i;
      break;
    }
  }
  if (eocd < 0) throw new Error("zip: end of central directory not found");
  const cdSize = tail.readUInt32LE(eocd + 12);
  const cdOffset = tail.readUInt32LE(eocd + 16);
  const cd = Buffer.from(await (await fetchRange(url, cdOffset, cdOffset + cdSize - 1)).arrayBuffer());
  let p = 0;
  while (p + 46 <= cd.length && cd.readUInt32LE(p) === 0x02014b50) {
    const method = cd.readUInt16LE(p + 10);
    const compressedSize = cd.readUInt32LE(p + 20);
    const nameLen = cd.readUInt16LE(p + 28);
    const extraLen = cd.readUInt16LE(p + 30);
    const commentLen = cd.readUInt16LE(p + 32);
    const localOffset = cd.readUInt32LE(p + 42);
    const name = cd.subarray(p + 46, p + 46 + nameLen).toString("utf8");
    if (name === fileName) {
      const lh = Buffer.from(await (await fetchRange(url, localOffset, localOffset + 29)).arrayBuffer());
      const start = localOffset + 30 + lh.readUInt16LE(26) + lh.readUInt16LE(28);
      return { start, end: start + compressedSize - 1, method };
    }
    p += 46 + nameLen + extraLen + commentLen;
  }
  throw new Error(`zip: ${fileName} not found`);
}

/**
 * Переводы городов из alternateNamesV2: для каждого нашего города и языка — предпочтительное имя
 * (isPreferredName), иначе обычное, в последнюю очередь разговорное/историческое.
 */
async function importTranslations(langs: string[]): Promise<number> {
  const ids = new Set<number>();
  for await (const c of cities.find({}, { projection: { _id: 0, id: 1 } })) ids.add(c.id);
  const wanted = new Set(langs);
  // id|lang -> [score, name]
  const best = new Map<string, [number, string]>();

  const entry = await locateZipEntry(ALT_NAMES_URL, "alternateNamesV2.txt");
  if (entry.method !== 8) throw new Error(`zip: unsupported compression ${entry.method}`);
  const res = await fetchRange(ALT_NAMES_URL, entry.start, entry.end);
  if (!res.body) throw new Error("zip: empty body");
  const lines = createInterface({ input: Readable.fromWeb(res.body as import("node:stream/web").ReadableStream).pipe(createInflateRaw()), crlfDelay: Infinity });
  for await (const line of lines) {
    // 0 alternateNameId, 1 geonameid, 2 isolanguage, 3 name, 4 preferred, 5 short, 6 colloquial, 7 historic
    const f = line.split("\t");
    const lang = f[2];
    if (!wanted.has(lang)) continue;
    const id = Number(f[1]);
    if (!ids.has(id)) continue;
    const name = f[3]?.trim();
    if (!name) continue;
    const score = f[4] === "1" ? 3 : f[6] === "1" || f[7] === "1" ? 0 : f[5] === "1" ? 1 : 2;
    const key = `${id}|${lang}`;
    const prev = best.get(key);
    if (!prev || score > prev[0]) best.set(key, [score, name]);
  }

  const ops = [...best].map(([key, [, name]]) => {
    const [id, lang] = key.split("|");
    return { updateOne: { filter: { id: Number(id) }, update: { $set: { [`i18n.${lang}`]: name } } } };
  });
  for (let i = 0; i < ops.length; i += 5000) await cities.bulkWrite(ops.slice(i, i + 5000), { ordered: false });
  return ops.length;
}

let importing: Promise<void> | null = null;

/** Импортировать справочник, если коллекция пуста (или просят пересобрать). Не бросает — сервер стартует и без него. */
export function ensureCities(): Promise<void> {
  if (importing) return importing;
  importing = (async () => {
    try {
      const count = await cities.estimatedDocumentCount();
      const reimport = process.env.CITIES_REIMPORT === "1";
      if (count === 0 || reimport) {
        console.log("cities: importing GeoNames cities5000…");
        const [zip, admin1Text] = await Promise.all([download(CITIES_URL), download(ADMIN1_URL)]);
        const list = parseCities(unzipSingle(zip).toString("utf8"), parseAdmin1(admin1Text.toString("utf8")));
        await cities.deleteMany({});
        for (let i = 0; i < list.length; i += 5000) {
          await cities.insertMany(list.slice(i, i + 5000), { ordered: false });
        }
        await citiesMeta.updateOne({ _id: "geonames" }, { $set: { source: CITIES_URL, importedAt: new Date().toISOString(), count: list.length, i18n: [] } }, { upsert: true });
        console.log(`cities: imported ${list.length}`);
      }
      // переводы: докачиваем языки, которых ещё нет
      const meta = await citiesMeta.findOne({ _id: "geonames" });
      const have = new Set(meta?.i18n ?? []);
      const missing = LANGS.filter((l) => !have.has(l));
      if (missing.length) {
        console.log(`cities: importing translations (${missing.join(", ")}) from alternateNamesV2…`);
        const n = await importTranslations(missing);
        await citiesMeta.updateOne({ _id: "geonames" }, { $set: { i18n: [...have, ...missing], i18nAt: new Date().toISOString() } });
        console.log(`cities: translations imported: ${n}`);
      }
    } catch (e) {
      console.error("cities: import failed —", e instanceof Error ? e.message : e);
    } finally {
      importing = null;
    }
  })();
  return importing;
}

function escapeRegex(s: string): string {
  return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

/** Города страны: по префиксу любого из имён, крупные первыми. Без запроса — просто самые крупные. */
export async function searchCities(countryCode: string, q: string, limit: number, lang: string | null) {
  const query = q.trim().toLowerCase();
  const filter = query ? { countryCode, search: { $regex: `^${escapeRegex(query)}` } } : { countryCode };
  const list = await cities
    .find(filter, { projection: { _id: 0, id: 1, name: 1, region: 1, lat: 1, lon: 1, population: 1, i18n: 1 } })
    .sort({ population: -1 })
    .limit(limit)
    .toArray();
  return list.map(({ i18n, ...c }) => ({ ...c, localized: lang ? i18n?.[lang] ?? null : null }));
}

/** Перевод английского имени города на язык; null — нет в справочнике */
export async function localizedCityName(countryCode: string, name: string, lang: string): Promise<string | null> {
  const c = await cities.findOne({ countryCode, search: name.toLowerCase(), [`i18n.${lang}`]: { $exists: true } }, { projection: { i18n: 1 }, sort: { population: -1 } });
  return c?.i18n?.[lang] ?? null;
}

/** Координаты города по английскому имени — для ручных записей, у которых нет точек с устройства */
export async function cityCoords(countryCode: string, name: string): Promise<{ lat: number; lon: number } | null> {
  const c = await cities.findOne({ countryCode, search: name.toLowerCase() }, { projection: { lat: 1, lon: 1 }, sort: { population: -1 } });
  return c ? { lat: c.lat, lon: c.lon } : null;
}
