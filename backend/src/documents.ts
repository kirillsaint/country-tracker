import { randomUUID } from "node:crypto";
import type { ObjectId } from "mongodb";
import { rules } from "./db.js";
import type { DocumentRuleRole, Rule, TravelDocument } from "./types.js";

// Правила, которые порождает документ. Пересобираются при каждом сохранении документа:
// одна роль — одно правило, лишние удаляются, существующие обновляются на месте
// (id сохраняется, чтобы виджеты и ссылки не ломались).

type RuleTemplate = Pick<Rule, "type" | "limitDays" | "windowDays" | "mode" | "autoStart" | "warnRemainingDays"> & { role: DocumentRuleRole; name: string };

// Подписи для автосозданных правил — на языке приложения, который оно передаёт при сохранении
// visafree-правила именует visaInfo.ts, здесь только шаблоны виз и ВНЖ
const labels: Record<string, Record<Exclude<DocumentRuleRole, "visafree">, (doc: TravelDocument, a: number, b?: number | null) => string>> = {
  ru: {
    stay: (d, a) => `${d.name}: до ${a} дн. за въезд`,
    window: (d, a, b) => `${d.name}: ${a}/${b}`,
    presence: (d, a) => `${d.name}: не меньше ${a} дн. в году`,
    absence: (d, a) => `${d.name}: не отсутствовать дольше ${a} дн.`,
  },
  en: {
    stay: (d, a) => `${d.name}: up to ${a} days per entry`,
    window: (d, a, b) => `${d.name}: ${a}/${b}`,
    presence: (d, a) => `${d.name}: at least ${a} days a year`,
    absence: (d, a) => `${d.name}: max ${a} days away`,
  },
};

export function templatesFor(doc: TravelDocument, lang: string): RuleTemplate[] {
  const L = labels[lang] ?? labels.en;
  const out: RuleTemplate[] = [];
  if (doc.kind === "visa") {
    if (doc.maxStayDays) {
      out.push({ role: "stay", name: L.stay(doc, doc.maxStayDays), type: "fromDate", limitDays: doc.maxStayDays, windowDays: null, mode: "limit", autoStart: true, warnRemainingDays: Math.min(7, Math.max(1, Math.round(doc.maxStayDays / 10))) });
    }
    if (doc.windowLimitDays && doc.windowDays) {
      out.push({ role: "window", name: L.window(doc, doc.windowLimitDays, doc.windowDays), type: "rolling", limitDays: doc.windowLimitDays, windowDays: doc.windowDays, mode: "limit", autoStart: false, warnRemainingDays: Math.min(10, Math.round(doc.windowLimitDays / 9)) });
    }
  }
  if (doc.kind === "residence") {
    if (doc.minDaysPerYear) {
      out.push({ role: "presence", name: L.presence(doc, doc.minDaysPerYear), type: "calendarYear", limitDays: doc.minDaysPerYear, windowDays: null, mode: "goal", autoStart: false, warnRemainingDays: null });
    }
    if (doc.maxAbsenceDays) {
      out.push({ role: "absence", name: L.absence(doc, doc.maxAbsenceDays), type: "absence", limitDays: doc.maxAbsenceDays, windowDays: null, mode: "limit", autoStart: false, warnRemainingDays: Math.min(30, Math.round(doc.maxAbsenceDays / 6)) });
    }
  }
  return out;
}

export async function syncRulesForDocument(userId: ObjectId, doc: TravelDocument, lang: string): Promise<Rule[]> {
  const wanted = templatesFor(doc, lang);
  const existing = await rules.find({ userId, documentId: doc.id }).toArray();
  const now = new Date().toISOString();
  const kept: Rule[] = [];

  for (const t of wanted) {
    const prev = existing.find((r) => r.documentRole === t.role);
    const base = {
      name: t.name,
      type: t.type,
      countries: doc.countries.length ? doc.countries : [doc.countryCode],
      limitDays: t.limitDays,
      windowDays: t.windowDays,
      startDate: null,
      autoStart: t.autoStart,
      mode: t.mode,
      countMode: "any" as const,
      validUntil: doc.validTo,
      updatedAt: now,
    };
    if (prev?.customized) {
      // правило переписано пользователем — оставляем как есть, обновляем только срок документа
      const updated = await rules.findOneAndUpdate({ userId, id: prev.id }, { $set: { validUntil: doc.validTo, updatedAt: now } }, { returnDocument: "after" });
      if (updated) kept.push(updated);
    } else if (prev) {
      // пользовательские настройки уведомлений и включённости не трогаем
      const updated = await rules.findOneAndUpdate({ userId, id: prev.id }, { $set: base }, { returnDocument: "after" });
      if (updated) kept.push(updated);
    } else {
      const rule: Rule = {
        userId,
        id: randomUUID(),
        enabled: true,
        warnRemainingDays: t.warnRemainingDays,
        notify: true,
        sortOrder: 0,
        documentId: doc.id,
        documentRole: t.role,
        customized: false,
        createdAt: now,
        ...base,
      };
      await rules.insertOne(rule);
      kept.push(rule);
    }
  }

  // роли, которые документу больше не нужны: автоправила удаляем, переписанные пользователем — оставляем
  const keepIds = new Set(kept.map((r) => r.id));
  await rules.deleteMany({ userId, documentId: doc.id, id: { $nin: [...keepIds] }, customized: { $ne: true } });
  const orphans = await rules.find({ userId, documentId: doc.id, id: { $nin: [...keepIds] } }).toArray();
  return [...kept, ...orphans];
}

/// Вернуть автоправилу значения из документа (сброс пользовательских правок)
export async function resetRuleFromDocument(userId: ObjectId, rule: Rule, doc: TravelDocument, lang: string): Promise<Rule | null> {
  await rules.updateOne({ userId, id: rule.id }, { $set: { customized: false } });
  const synced = await syncRulesForDocument(userId, doc, lang);
  return synced.find((r) => r.id === rule.id) ?? null;
}

export async function deleteRulesForDocument(userId: ObjectId, documentId: string) {
  await rules.deleteMany({ userId, documentId });
}
