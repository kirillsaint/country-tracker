import { inflateRawSync } from "node:zlib";
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
};

const CITIES_URL = "https://download.geonames.org/export/dump/cities5000.zip";
const ADMIN1_URL = "https://download.geonames.org/export/dump/admin1CodesASCII.txt";

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

let importing: Promise<void> | null = null;

/** Импортировать справочник, если коллекция пуста (или просят пересобрать). Не бросает — сервер стартует и без него. */
export function ensureCities(): Promise<void> {
  if (importing) return importing;
  importing = (async () => {
    try {
      const count = await cities.estimatedDocumentCount();
      if (count > 0 && process.env.CITIES_REIMPORT !== "1") return;
      console.log("cities: importing GeoNames cities5000…");
      const [zip, admin1Text] = await Promise.all([download(CITIES_URL), download(ADMIN1_URL)]);
      const list = parseCities(unzipSingle(zip).toString("utf8"), parseAdmin1(admin1Text.toString("utf8")));
      await cities.deleteMany({});
      for (let i = 0; i < list.length; i += 5000) {
        await cities.insertMany(list.slice(i, i + 5000), { ordered: false });
      }
      await citiesMeta.updateOne({ _id: "geonames" }, { $set: { source: CITIES_URL, importedAt: new Date().toISOString(), count: list.length } }, { upsert: true });
      console.log(`cities: imported ${list.length}`);
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
export async function searchCities(countryCode: string, q: string, limit: number) {
  const query = q.trim().toLowerCase();
  const filter = query ? { countryCode, search: { $regex: `^${escapeRegex(query)}` } } : { countryCode };
  return cities
    .find(filter, { projection: { _id: 0, id: 1, name: 1, region: 1, lat: 1, lon: 1, population: 1 } })
    .sort({ population: -1 })
    .limit(limit)
    .toArray();
}

/** Координаты города по английскому имени — для ручных записей, у которых нет точек с устройства */
export async function cityCoords(countryCode: string, name: string): Promise<{ lat: number; lon: number } | null> {
  const c = await cities.findOne({ countryCode, search: name.toLowerCase() }, { projection: { lat: 1, lon: 1 }, sort: { population: -1 } });
  return c ? { lat: c.lat, lon: c.lon } : null;
}
