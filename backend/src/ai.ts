import { randomUUID } from "node:crypto";
import { z } from "zod";
import { config } from "./config.js";
import type { RegimeDraft } from "./types.js";

// Запрос к нейросети через OpenRouter: найти в вебе актуальные условия безвизового въезда
// для пары "гражданство → страна" и вернуть их строго в нашей структуре.
// Ответ — черновик; правилом он становится только после подтверждения пользователем.

export const isAiEnabled = () => config.openRouterApiKey.length > 0;

const draftSchema = z.object({
  requirement: z.enum(["visa_free", "e_visa", "visa_on_arrival", "visa_required", "unknown"]),
  constraints: z
    .array(
      z.object({
        type: z.enum(["perEntry", "rolling", "calendarYear", "fromDate"]),
        limitDays: z.number().int().min(1).max(3660),
        windowDays: z.number().int().min(2).max(3660).nullable(),
        note: z.string().max(300).nullable(),
      }),
    )
    .max(6),
  conditions: z
    .array(
      z.object({
        kind: z.enum(["registration", "passportValidity", "insurance", "funds", "ticket", "other"]),
        text: z.string().min(1).max(300),
        withinDays: z.number().int().min(1).max(365).nullable(),
        months: z.number().int().min(1).max(24).nullable(),
      }),
    )
    .max(10),
  sources: z
    .array(
      z.object({
        url: z.string().url(),
        title: z.string().max(200).nullable(),
        official: z.boolean(),
        quote: z.string().max(400).nullable(),
      }),
    )
    .max(10),
  summary: z.string().min(1).max(1200),
  asOf: z.string().nullable(),
  recentChange: z.string().max(400).nullable(),
  confidence: z.enum(["high", "medium", "low"]),
});

// JSON Schema для structured output OpenRouter (зеркало zod-схемы выше)
const jsonSchema = {
  type: "object",
  additionalProperties: false,
  required: ["requirement", "constraints", "conditions", "sources", "summary", "asOf", "recentChange", "confidence"],
  properties: {
    requirement: { type: "string", enum: ["visa_free", "e_visa", "visa_on_arrival", "visa_required", "unknown"] },
    constraints: {
      type: "array",
      items: {
        type: "object",
        additionalProperties: false,
        required: ["type", "limitDays", "windowDays", "note"],
        properties: {
          type: { type: "string", enum: ["perEntry", "rolling", "calendarYear", "fromDate"] },
          limitDays: { type: "integer" },
          windowDays: { type: ["integer", "null"] },
          note: { type: ["string", "null"] },
        },
      },
    },
    conditions: {
      type: "array",
      items: {
        type: "object",
        additionalProperties: false,
        required: ["kind", "text", "withinDays", "months"],
        properties: {
          kind: { type: "string", enum: ["registration", "passportValidity", "insurance", "funds", "ticket", "other"] },
          text: { type: "string" },
          withinDays: { type: ["integer", "null"] },
          months: { type: ["integer", "null"] },
        },
      },
    },
    sources: {
      type: "array",
      items: {
        type: "object",
        additionalProperties: false,
        required: ["url", "title", "official", "quote"],
        properties: {
          url: { type: "string" },
          title: { type: ["string", "null"] },
          official: { type: "boolean" },
          quote: { type: ["string", "null"] },
        },
      },
    },
    summary: { type: "string" },
    asOf: { type: ["string", "null"] },
    recentChange: { type: ["string", "null"] },
    confidence: { type: "string", enum: ["high", "medium", "low"] },
  },
};

const regionName = (lang: string, code: string) => new Intl.DisplayNames([lang], { type: "region" }).of(code) ?? code;

function systemPrompt(lang: string): string {
  const language = lang === "ru" ? "Russian" : "English";
  return `You are a meticulous immigration-rules researcher. Use web search to find the CURRENT visa-free (or visa-on-arrival / e-visa) entry rules for a given passport nationality visiting a given country, as applied to ordinary tourists.

Rules for your answer:
- Prefer official sources: the destination's ministry of foreign affairs, immigration/border agency, embassy or consulate pages, government portals. Mark them "official": true. Use travel sites only to corroborate, marked "official": false.
- Express every stay limit as a constraint in this exact vocabulary:
  - "perEntry": at most limitDays per entry (the count restarts on each entry). windowDays null.
  - "rolling": at most limitDays within any windowDays consecutive days (e.g. 90/180).
  - "calendarYear": at most limitDays per calendar year. windowDays null.
  - "fromDate": at most limitDays counted from a fixed date. windowDays = length of the period. Rare; use only when the rule is tied to a specific date.
  A country can have SEVERAL constraints at once (e.g. Turkey for Russians: 60 days per entry AND 90 days in any 180). List all that apply.
- If entry is visa_required or no visa-free option exists, return requirement accordingly with an empty constraints list.
- conditions = requirements that are not day counts: registration within N days (kind "registration", withinDays N), passport validity (kind "passportValidity", months = how many months the passport must remain valid on entry, e.g. 6; null if the rule only says "valid for the stay"), mandatory insurance, proof of funds, return ticket. Keep each short. withinDays and months are null when not applicable.
- summary: 2-4 sentences in ${language} for a traveller. Mention if rules changed recently (recentChange) and the date the information is valid for (asOf, ISO date or null).
- confidence: high only when an official source explicitly states the numbers.
- Never invent URLs. Only include sources you actually found.
Return ONLY the JSON object matching the schema, no prose around it.`;
}

export type AiResult = { draft: RegimeDraft; raw: string; model: string };

export async function researchRegime(passportCode: string, countryCode: string, lang: string): Promise<AiResult> {
  if (!isAiEnabled()) throw new Error("OPENROUTER_API_KEY is not set");
  const today = new Date().toISOString().slice(0, 10);
  const user = `Passport nationality: ${regionName("en", passportCode)} (${passportCode}). Destination country: ${regionName("en", countryCode)} (${countryCode}). Today: ${today}. Purpose: tourism, ordinary passport. Find the current entry rules and stay limits.`;

  const body = {
    model: config.openRouterModel,
    plugins: [{ id: "web" }],
    temperature: 0.1,
    messages: [
      { role: "system", content: systemPrompt(lang) },
      { role: "user", content: user },
    ],
    response_format: { type: "json_schema", json_schema: { name: "entry_regime", strict: true, schema: jsonSchema } },
  };

  const res = await fetch(`${config.openRouterBaseUrl}/chat/completions`, {
    method: "POST",
    headers: {
      authorization: `Bearer ${config.openRouterApiKey}`,
      "content-type": "application/json",
      "HTTP-Referer": "https://country-tracker.kirillsaint.ge",
      "X-Title": "Country Counter",
    },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(180_000),
  });
  const text = await res.text();
  if (!res.ok) throw new Error(`openrouter ${res.status}: ${text.slice(0, 300)}`);

  const json = JSON.parse(text) as { choices?: { message?: { content?: string | { text?: string }[] } }[]; model?: string };
  const content = json.choices?.[0]?.message?.content;
  const raw = typeof content === "string" ? content : Array.isArray(content) ? content.map((c) => c.text ?? "").join("") : "";
  const parsed = draftSchema.parse(extractJson(raw));
  const draft: RegimeDraft = {
    ...parsed,
    constraints: parsed.constraints.map((c) => ({ id: randomUUID(), startDate: null, ...c })),
    conditions: parsed.conditions.map((c) => ({ id: randomUUID(), done: false, ...c })),
  };
  return { draft, raw, model: json.model ?? config.openRouterModel };
}

/** Общий вызов модели со строгой JSON-схемой (без веб-поиска, если не просят). Возвращает распарсенный объект. */
export async function completeJson(opts: { system: string; user: string; name: string; schema: unknown; web?: boolean; timeoutMs?: number; temperature?: number }): Promise<unknown> {
  if (!isAiEnabled()) throw new Error("OPENROUTER_API_KEY is not set");
  const body = {
    model: config.openRouterModel,
    ...(opts.web ? { plugins: [{ id: "web" }] } : {}),
    temperature: opts.temperature ?? 0.2,
    messages: [
      { role: "system", content: opts.system },
      { role: "user", content: opts.user },
    ],
    response_format: { type: "json_schema", json_schema: { name: opts.name, strict: true, schema: opts.schema } },
  };
  const res = await fetch(`${config.openRouterBaseUrl}/chat/completions`, {
    method: "POST",
    headers: {
      authorization: `Bearer ${config.openRouterApiKey}`,
      "content-type": "application/json",
      "HTTP-Referer": "https://country-tracker.kirillsaint.ge",
      "X-Title": "Country Counter",
    },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(opts.timeoutMs ?? 60_000),
  });
  const text = await res.text();
  if (!res.ok) throw new Error(`openrouter ${res.status}: ${text.slice(0, 300)}`);
  const json = JSON.parse(text) as { choices?: { message?: { content?: string | { text?: string }[] } }[] };
  const content = json.choices?.[0]?.message?.content;
  const raw = typeof content === "string" ? content : Array.isArray(content) ? content.map((c) => c.text ?? "").join("") : "";
  return extractJson(raw);
}

// Модель иногда оборачивает JSON в ```json … ``` или добавляет текст — вырезаем первый объект
function extractJson(raw: string): unknown {
  try {
    return JSON.parse(raw);
  } catch {
    const start = raw.indexOf("{");
    const end = raw.lastIndexOf("}");
    if (start < 0 || end <= start) throw new Error("model returned no JSON");
    return JSON.parse(raw.slice(start, end + 1));
  }
}
