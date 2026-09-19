import { randomUUID } from "node:crypto";
import { feature } from "@rapideditor/country-coder";
import type { ObjectId } from "mongodb";
import { config } from "./config.js";
import { documents, rules, visaCache } from "./db.js";
import { ALL_COUNTRIES } from "./presets.js";
import type { Rule, RuleType, VisaCacheEntry, VisaRequirement } from "./types.js";

// Справочник визовых режимов: Orizn Visa API + кэш в Mongo.
// Пары "паспорт → страна" выкачиваются при добавлении паспорта и обновляются раз в неделю.
// Справочник — подсказка: число дней он даёт, а как оно считается (за въезд / в окне / за год)
// выводится эвристикой и подтверждается пользователем.

export const REFRESH_AFTER_MS = 7 * 24 * 60 * 60 * 1000;
const CONCURRENCY = 4;
const REQUIREMENTS: VisaRequirement[] = ["visa_free", "e_visa", "visa_on_arrival", "eta", "visa_required", "no_admission"];

export const isEnabled = () => config.oriznApiKey.length > 0;

export function alpha3(alpha2: string): string | null {
  return feature(alpha2)?.properties.iso1A3 ?? null;
}

// MARK: запрос одной пары

class QuotaExceeded extends Error {}

async function fetchPair(passport: string, destination: string): Promise<VisaCacheEntry> {
  const p3 = alpha3(passport);
  const d3 = alpha3(destination);
  const now = new Date().toISOString();
  const empty: VisaCacheEntry = {
    passport, destination, fetchedAt: now, requirement: null, visaFreeDays: null, description: null, maxStay: null,
    extensionNotes: null, extensionPossible: null, maxExtensionDays: null, passportValidityMonths: null, source: null,
    verified: null, sourceUrl: null, lastVerifiedAt: null, requirementStatus: null, requirementStatusNote: null, overstayNotes: null, raw: null,
  };
  if (!p3 || !d3) return empty;

  const url = `${config.oriznBaseUrl}/api/v1/visa?passport=${p3}&destination=${d3}&lang=en`;
  const res = await fetch(url, { headers: { "x-api-key": config.oriznApiKey, accept: "application/json" }, signal: AbortSignal.timeout(15_000) });
  if (res.status === 404) return empty;
  if (res.status === 429) throw new QuotaExceeded(`orizn quota exceeded: ${await res.text()}`);
  if (!res.ok) throw new Error(`orizn ${res.status}: ${(await res.text()).slice(0, 200)}`);

  const body = (await res.json()) as { data?: Record<string, any> };
  const d = body.data ?? {};
  const requirement = REQUIREMENTS.includes(d.requirement) ? (d.requirement as VisaRequirement) : "unknown";
  return {
    ...empty,
    requirement,
    visaFreeDays: typeof d.visa_free_days === "number" ? d.visa_free_days : null,
    description: d.description ?? null,
    maxStay: d.max_stay ?? null,
    extensionNotes: d.extension_rules?.notes ?? d.extension?.details ?? null,
    extensionPossible: d.extension_rules?.extension_possible ?? d.extension?.possible ?? null,
    maxExtensionDays: d.extension_rules?.max_extension_days ?? null,
    passportValidityMonths: d.passport_validity_months ?? null,
    source: d.source ?? null,
    verified: d.verified ?? null,
    sourceUrl: d.source_url ?? null,
    lastVerifiedAt: d.last_verified_at ?? null,
    requirementStatus: d.requirement_status ?? null,
    requirementStatusNote: d.requirement_status_note ?? null,
    overstayNotes: d.overstay_penalty?.details ?? null,
    raw: d,
  };
}

/// Запись из кэша; при промахе или устаревании — запрос к Orizn (если включён)
export async function getPair(passport: string, destination: string, opts: { allowStale?: boolean } = {}): Promise<VisaCacheEntry | null> {
  const cached = await visaCache.findOne({ passport, destination });
  const fresh = cached && Date.now() - Date.parse(cached.fetchedAt) < REFRESH_AFTER_MS;
  if (cached && (fresh || opts.allowStale || !isEnabled())) return cached;
  if (!isEnabled()) return null;
  try {
    const entry = await fetchPair(passport, destination);
    await visaCache.replaceOne({ passport, destination }, entry, { upsert: true });
    return entry;
  } catch (e) {
    console.warn(`visa-info ${passport}->${destination}: ${(e as Error).message}`);
    return cached ?? null;
  }
}

// MARK: массовая выкачка

const running = new Set<string>();

/// Выкачать все направления для паспорта (пропуская свежие). Работает в фоне, повторный вызов игнорируется.
export function prefetchPassport(passport: string) {
  if (!isEnabled() || running.has(passport)) return;
  running.add(passport);
  (async () => {
    try {
      const cutoff = new Date(Date.now() - REFRESH_AFTER_MS).toISOString();
      const fresh = new Set(
        (await visaCache.find({ passport, fetchedAt: { $gte: cutoff } }, { projection: { destination: 1 } }).toArray()).map((x) => x.destination),
      );
      const todo = ALL_COUNTRIES.filter((c) => c !== passport && !fresh.has(c));
      console.log(`visa-info: prefetch ${passport}, ${todo.length} destinations`);
      let i = 0;
      let stop = false;
      await Promise.all(
        Array.from({ length: CONCURRENCY }, async () => {
          while (!stop && i < todo.length) {
            const dest = todo[i++];
            try {
              const entry = await fetchPair(passport, dest);
              await visaCache.replaceOne({ passport, destination: dest }, entry, { upsert: true });
            } catch (e) {
              if (e instanceof QuotaExceeded) { stop = true; console.warn(e.message); }
              else console.warn(`visa-info ${passport}->${dest}: ${(e as Error).message}`);
            }
            await new Promise((r) => setTimeout(r, 150));
          }
        }),
      );
      console.log(`visa-info: prefetch ${passport} done`);
    } finally {
      running.delete(passport);
    }
  })();
}

/// Еженедельное обновление: все паспорта всех пользователей
export async function refreshStalePassports() {
  if (!isEnabled()) return;
  const passports = await documents.distinct("countryCode", { kind: "passport" });
  for (const p of passports) prefetchPassport(p);
}

export function startRefreshJob() {
  if (!isEnabled()) {
    console.warn("ORIZN_API_KEY is empty: visa reference is disabled");
    return;
  }
  // Первый прогон — через минуту после старта, затем каждые 6 часов (устаревшие пары старше недели)
  setTimeout(() => void refreshStalePassports(), 60_000);
  setInterval(() => void refreshStalePassports(), 6 * 60 * 60 * 1000);
}

export async function cacheStatus(passport: string) {
  const total = ALL_COUNTRIES.length - 1;
  const cutoff = new Date(Date.now() - REFRESH_AFTER_MS).toISOString();
  const [cached, fresh, latest] = await Promise.all([
    visaCache.countDocuments({ passport }),
    visaCache.countDocuments({ passport, fetchedAt: { $gte: cutoff } }),
    visaCache.find({ passport }).sort({ fetchedAt: -1 }).limit(1).toArray(),
  ]);
  return { passport, total, cached, fresh, lastFetchedAt: latest[0]?.fetchedAt ?? null, inProgress: running.has(passport), enabled: isEnabled() };
}

// MARK: эвристика типа правила

export type RuleSuggestion = {
  type: RuleType;
  limitDays: number;
  windowDays: number | null;
  // почему именно так — показывается пользователю
  reason: string;
  confidence: "high" | "medium" | "low";
};

const ENTRY_OK: VisaRequirement[] = ["visa_free", "visa_on_arrival", "eta", "e_visa"];

export function suggestRule(e: VisaCacheEntry): RuleSuggestion | null {
  if (!e.requirement || !ENTRY_OK.includes(e.requirement)) return null;
  const days = e.visaFreeDays;
  if (!days || days <= 0) return null;
  const text = [e.description, e.maxStay, e.extensionNotes, e.overstayNotes].filter(Boolean).join(" \n ");

  // "90 days in any 180", "90 days within 180", "90 out of 180", "90/180"
  const win = text.match(/(\d{2,3})\s*(?:days?)?\s*(?:in|within|per|out of|of)\s*(?:any|every|a rolling|a|each)?\s*(\d{3})[-\s]*(?:day|days)?\s*(?:period|window)?/i)
    ?? text.match(/\b(\d{2,3})\s*\/\s*(\d{3})\b/);
  if (win) {
    const l = Number(win[1]);
    const w = Number(win[2]);
    if (l < w && w <= 730) return { type: "rolling", limitDays: l, windowDays: w, reason: `${l}/${w}: ${win[0].trim()}`, confidence: "medium" };
  }
  // "180 days per calendar year", "per year"
  const year = text.match(/(\d{2,3})\s*days?\s*(?:total\s*)?(?:per|in a|in any|each|a)\s*(?:calendar\s*)?year/i);
  if (year) {
    const l = Number(year[1]);
    return { type: "calendarYear", limitDays: l, windowDays: null, reason: year[0].trim(), confidence: "medium" };
  }
  // По умолчанию — за въезд; длинные сроки (>= 180) почти всегда именно такие
  return {
    type: "fromDate",
    limitDays: days,
    windowDays: days >= 180 ? days : null,
    reason: `${days} days per entry`,
    confidence: days >= 180 ? "medium" : "low",
  };
}

// MARK: правило безвиза, привязанное к паспорту

const regionName = (lang: string, code: string) => new Intl.DisplayNames([lang], { type: "region" }).of(code) ?? code;

function visaFreeName(lang: string, dest: string, s: { type: RuleType; limitDays: number; windowDays: number | null }): string {
  const country = regionName(lang, dest);
  if (lang === "ru") {
    if (s.type === "rolling") return `Безвиз ${country}: ${s.limitDays}/${s.windowDays}`;
    if (s.type === "calendarYear") return `Безвиз ${country}: ${s.limitDays} дн. в году`;
    return `Безвиз ${country}: ${s.limitDays} дн. с въезда`;
  }
  if (s.type === "rolling") return `Visa-free ${country}: ${s.limitDays}/${s.windowDays}`;
  if (s.type === "calendarYear") return `Visa-free ${country}: ${s.limitDays} days a year`;
  return `Visa-free ${country}: ${s.limitDays} days per entry`;
}

export async function findVisaFreeRule(userId: ObjectId, passportId: string, dest: string) {
  return rules.findOne({ userId, documentId: passportId, documentRole: "visafree", countries: [dest] });
}

/**
 * Создать (или вернуть существующее) правило безвиза для пары паспорт → страна.
 * override — параметры, подтверждённые пользователем; без него берётся подсказка справочника.
 * Правило помечается customized, чтобы пересборка документа-паспорта его не удалила.
 */
export async function ensureVisaFreeRule(
  userId: ObjectId,
  passportId: string,
  passportCode: string,
  dest: string,
  lang: string,
  override?: { type: RuleType; limitDays: number; windowDays: number | null },
): Promise<Rule | null> {
  const existing = await findVisaFreeRule(userId, passportId, dest);
  const now = new Date().toISOString();
  let params = override ?? null;
  if (!params) {
    const entry = await getPair(passportCode, dest, { allowStale: true });
    const s = entry ? suggestRule(entry) : null;
    if (!s) return existing;
    params = { type: s.type, limitDays: s.limitDays, windowDays: s.windowDays };
  }
  const base = {
    name: visaFreeName(lang, dest, params),
    type: params.type,
    countries: [dest],
    limitDays: params.limitDays,
    windowDays: params.windowDays,
    startDate: null,
    autoStart: params.type === "fromDate",
    mode: "limit" as const,
    countMode: "any" as const,
    updatedAt: now,
  };
  if (existing) {
    if (!override) return existing;
    const updated = await rules.findOneAndUpdate({ userId, id: existing.id }, { $set: base }, { returnDocument: "after" });
    return updated;
  }
  const rule: Rule = {
    userId,
    id: randomUUID(),
    enabled: true,
    warnRemainingDays: Math.min(30, Math.max(3, Math.round(params.limitDays / 10))),
    notify: true,
    sortOrder: 0,
    documentId: passportId,
    documentRole: "visafree",
    customized: true,
    validUntil: null,
    createdAt: now,
    ...base,
  };
  await rules.insertOne(rule);
  return rule;
}
