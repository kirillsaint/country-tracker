import { randomUUID } from "node:crypto";
import type { ObjectId } from "mongodb";
import { config } from "./config.js";
import { regimeChecks, regimes, rules } from "./db.js";
import { isAiEnabled, researchRegime } from "./ai.js";
import type { Regime, RegimeCheck, RegimeConstraint, RegimeDraft, RegimeVersion, Rule } from "./types.js";

// Режим въезда: подтверждённые пользователем условия безвиза для пары паспорт → страна,
// правила подсчёта из них, версии при изменениях, фоновые проверки через нейросеть с кэшем.

const today = () => new Date().toISOString().slice(0, 10);
const regionName = (lang: string, code: string) => new Intl.DisplayNames([lang], { type: "region" }).of(code) ?? code;

// MARK: имена правил

function constraintName(lang: string, country: string, c: RegimeConstraint): string {
  const name = regionName(lang, country);
  if (lang === "ru") {
    switch (c.type) {
      case "perEntry": return `Безвиз ${name}: ${c.limitDays} дн. за въезд`;
      case "rolling": return `Безвиз ${name}: ${c.limitDays}/${c.windowDays}`;
      case "calendarYear": return `Безвиз ${name}: ${c.limitDays} дн. в году`;
      case "fromDate": return `Безвиз ${name}: ${c.limitDays} дн. с ${c.startDate ?? "даты"}`;
    }
  }
  switch (c.type) {
    case "perEntry": return `Visa-free ${name}: ${c.limitDays} days per entry`;
    case "rolling": return `Visa-free ${name}: ${c.limitDays}/${c.windowDays}`;
    case "calendarYear": return `Visa-free ${name}: ${c.limitDays} days a year`;
    case "fromDate": return `Visa-free ${name}: ${c.limitDays} days from ${c.startDate ?? "date"}`;
  }
}

// MARK: сравнение версий

const key = (c: RegimeConstraint) => `${c.type}|${c.limitDays}|${c.windowDays ?? ""}|${c.startDate ?? ""}`;

export function sameConstraints(a: RegimeConstraint[], b: RegimeConstraint[]): boolean {
  const ka = a.map(key).sort();
  const kb = b.map(key).sort();
  return ka.length === kb.length && ka.every((k, i) => k === kb[i]);
}

function describe(lang: string, c: RegimeConstraint): string {
  if (lang === "ru") {
    switch (c.type) {
      case "perEntry": return `${c.limitDays} дн. за въезд`;
      case "rolling": return `${c.limitDays} в любые ${c.windowDays}`;
      case "calendarYear": return `${c.limitDays} дн. в году`;
      case "fromDate": return `${c.limitDays} дн. с ${c.startDate}`;
    }
  }
  switch (c.type) {
    case "perEntry": return `${c.limitDays} days per entry`;
    case "rolling": return `${c.limitDays} in any ${c.windowDays}`;
    case "calendarYear": return `${c.limitDays} days a year`;
    case "fromDate": return `${c.limitDays} days from ${c.startDate}`;
  }
}

export type RegimeDiff = { changed: boolean; added: string[]; removed: string[]; requirementChanged: string | null };

export function diffVersions(lang: string, current: RegimeVersion | null, draft: RegimeDraft): RegimeDiff {
  if (!current) return { changed: true, added: draft.constraints.map((c) => describe(lang, c)), removed: [], requirementChanged: null };
  const cur = new Map(current.constraints.map((c) => [key(c), c]));
  const next = new Map(draft.constraints.map((c) => [key(c), c]));
  const added = [...next.entries()].filter(([k]) => !cur.has(k)).map(([, c]) => describe(lang, c));
  const removed = [...cur.entries()].filter(([k]) => !next.has(k)).map(([, c]) => describe(lang, c));
  const requirementChanged = current.requirement !== draft.requirement ? `${current.requirement} → ${draft.requirement}` : null;
  return { changed: added.length > 0 || removed.length > 0 || !!requirementChanged, added, removed, requirementChanged };
}

// MARK: правила из версии

async function syncRules(userId: ObjectId, regime: Regime, lang: string): Promise<Rule[]> {
  const now = new Date().toISOString();
  const active = regime.active;
  const existing = await rules.find({ userId, regimeId: regime.id }).toArray();
  const activeIds = new Set(active?.constraints.map((c) => c.id) ?? []);

  // Правила старых версий: выключаем и закрываем датой окончания версии, но не удаляем — история
  for (const r of existing) {
    if (r.constraintId && activeIds.has(r.constraintId)) continue;
    const version = regime.history.find((v) => v.constraints.some((c) => c.id === r.constraintId));
    const validUntil = version?.effectiveTo ?? active?.effectiveFrom ?? today();
    if (r.enabled || r.validUntil !== validUntil) {
      await rules.updateOne({ userId, id: r.id }, { $set: { enabled: false, validUntil, updatedAt: now } });
    }
  }

  const out: Rule[] = [];
  for (const c of active?.constraints ?? []) {
    const prev = existing.find((r) => r.constraintId === c.id);
    const base = {
      name: constraintName(lang, regime.countryCode, c),
      type: (c.type === "perEntry" ? "fromDate" : c.type) as Rule["type"],
      countries: [regime.countryCode],
      limitDays: c.limitDays,
      windowDays: c.type === "rolling" || c.type === "fromDate" ? c.windowDays : null,
      startDate: c.type === "fromDate" ? c.startDate : null,
      autoStart: c.type === "perEntry",
      mode: "limit" as const,
      countMode: "any" as const,
      validFrom: active!.effectiveFrom,
      validUntil: null,
      updatedAt: now,
    };
    if (prev) {
      const updated = await rules.findOneAndUpdate({ userId, id: prev.id }, { $set: { ...base, enabled: true } }, { returnDocument: "after" });
      if (updated) out.push(updated);
    } else {
      const rule: Rule = {
        userId,
        id: randomUUID(),
        enabled: true,
        warnRemainingDays: Math.min(30, Math.max(3, Math.round(c.limitDays / 10))),
        notify: true,
        sortOrder: 0,
        documentId: null,
        documentRole: null,
        regimeId: regime.id,
        constraintId: c.id,
        customized: false,
        createdAt: now,
        ...base,
      };
      await rules.insertOne(rule);
      out.push(rule);
    }
  }
  return out;
}

// MARK: сохранение версии

export type VersionInput = Omit<RegimeVersion, "id" | "effectiveFrom" | "effectiveTo" | "confirmedAt">;

/**
 * Подтвердить условия. Если они совпадают с активной версией — только отметка "проверено";
 * если отличаются — активная версия закрывается сегодняшним днём и уходит в history.
 */
export async function confirmVersion(
  userId: ObjectId,
  passport: { id: string; countryCode: string },
  countryCode: string,
  input: VersionInput,
  lang: string,
): Promise<{ regime: Regime; rules: Rule[]; changed: boolean }> {
  const now = new Date().toISOString();
  const day = today();
  const found = await regimes.findOne({ userId, passportId: passport.id, countryCode });
  let regime: Regime | null = found;
  let changed = true;

  if (regime?.active && sameConstraints(regime.active.constraints, input.constraints) && regime.active.requirement === input.requirement) {
    // условия те же — обновляем метаданные и условия-чеклист, версию не плодим
    changed = false;
    const merged: RegimeVersion = {
      ...regime.active,
      conditions: mergeConditions(regime.active.conditions, input.conditions),
      sources: input.sources.length ? input.sources : regime.active.sources,
      notes: input.notes ?? regime.active.notes,
      origin: input.origin,
      model: input.model ?? regime.active.model,
      confirmedAt: now,
    };
    regime = (await regimes.findOneAndUpdate(
      { userId, id: regime.id },
      { $set: { active: merged, lastCheckedAt: now, updatedAt: now } },
      { returnDocument: "after" },
    ))!;
  } else {
    const version: RegimeVersion = { id: randomUUID(), ...input, effectiveFrom: day, effectiveTo: null, confirmedAt: now };
    if (regime) {
      const history = regime.active ? [...regime.history, { ...regime.active, effectiveTo: day }] : regime.history;
      regime = (await regimes.findOneAndUpdate(
        { userId, id: regime.id },
        { $set: { active: version, history, lastCheckedAt: now, updatedAt: now } },
        { returnDocument: "after" },
      ))!;
    } else {
      const created: Regime = {
        userId, id: randomUUID(), passportId: passport.id, passportCode: passport.countryCode, countryCode,
        active: version, history: [], lastCheckedAt: now, createdAt: now, updatedAt: now,
      };
      await regimes.insertOne(created);
      regime = created;
    }
  }
  const generated = await syncRules(userId, regime!, lang);
  return { regime: regime!, rules: generated, changed };
}

// сохраняем отметки "сделано" у условий с тем же текстом
function mergeConditions(prev: RegimeVersion["conditions"], next: RegimeVersion["conditions"]) {
  return next.map((c) => {
    const old = prev.find((p) => p.id === c.id || p.text === c.text);
    return { ...c, done: c.done || (old?.done ?? false) };
  });
}

export async function deleteRegime(userId: ObjectId, regimeId: string) {
  await regimes.deleteOne({ userId, id: regimeId });
  await rules.deleteMany({ userId, regimeId });
}

export function isStale(regime: Regime | null): boolean {
  if (!regime?.lastCheckedAt) return true;
  return Date.now() - Date.parse(regime.lastCheckedAt) > config.regimeFreshDays * 86_400_000;
}

// MARK: проверки через нейросеть

const runningChecks = new Set<string>();

/// Свежий готовый результат по паре (общий кэш для всех пользователей), если есть
export async function cachedCheck(passportCode: string, countryCode: string, lang: string): Promise<RegimeCheck | null> {
  const cutoff = new Date(Date.now() - config.regimeFreshDays * 86_400_000).toISOString();
  return regimeChecks.findOne(
    { passportCode, countryCode, lang, status: "done", finishedAt: { $gte: cutoff } },
    { sort: { finishedAt: -1 } },
  );
}

/// Запустить проверку (или вернуть уже идущую / свежую из кэша)
export async function startCheck(passportCode: string, countryCode: string, lang: string, force: boolean): Promise<RegimeCheck> {
  if (!force) {
    const cached = await cachedCheck(passportCode, countryCode, lang);
    if (cached) return cached;
  }
  const inFlight = await regimeChecks.findOne({ passportCode, countryCode, lang, status: { $in: ["queued", "running"] } }, { sort: { requestedAt: -1 } });
  if (inFlight) return inFlight;

  const check: RegimeCheck = {
    id: randomUUID(), passportCode, countryCode, lang, status: isAiEnabled() ? "queued" : "failed",
    model: config.openRouterModel, requestedAt: new Date().toISOString(), finishedAt: null, draft: null,
    error: isAiEnabled() ? null : "AI is not configured on the server (OPENROUTER_API_KEY)", raw: null,
  };
  await regimeChecks.insertOne(check);
  if (isAiEnabled()) void runCheck(check);
  return check;
}

async function runCheck(check: RegimeCheck) {
  if (runningChecks.has(check.id)) return;
  runningChecks.add(check.id);
  await regimeChecks.updateOne({ id: check.id }, { $set: { status: "running" } });
  try {
    const { draft, raw, model } = await researchRegime(check.passportCode, check.countryCode, check.lang);
    await regimeChecks.updateOne({ id: check.id }, { $set: { status: "done", draft, raw, model, finishedAt: new Date().toISOString() } });
    console.log(`regime check ${check.passportCode}->${check.countryCode}: ${draft.requirement}, ${draft.constraints.length} constraints`);
  } catch (e) {
    const message = (e as Error).message.slice(0, 500);
    console.warn(`regime check ${check.passportCode}->${check.countryCode} failed: ${message}`);
    await regimeChecks.updateOne({ id: check.id }, { $set: { status: "failed", error: message, finishedAt: new Date().toISOString() } });
  } finally {
    runningChecks.delete(check.id);
  }
}

/// При старте сервера подхватить проверки, оборванные перезапуском
export async function resumeChecks() {
  const stuck = await regimeChecks.find({ status: { $in: ["queued", "running"] } }).toArray();
  for (const c of stuck) void runCheck(c);
}
