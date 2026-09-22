import type { DayOverride, Entry, EntryBasis, Point, Rule } from "./types.js";

export type Presence = {
  countryCode: string;
  countryName: string | null;
  city: string | null;
  // true, если день не подтверждён точкой, а достроен по соседним точкам
  inferred: boolean;
  overridden: boolean;
};

// Дата -> страны, в которых человек был в этот день (в порядке появления).
// Последняя в списке считается "основной" страной дня.
export type DailyPresence = Map<string, Presence[]>;

export function todayIso(): string {
  return new Date().toISOString().slice(0, 10);
}

export function addDays(date: string, n: number): string {
  const t = Date.UTC(+date.slice(0, 4), +date.slice(5, 7) - 1, +date.slice(8, 10)) + n * 86_400_000;
  return new Date(t).toISOString().slice(0, 10);
}

export function daysBetween(a: string, b: string): number {
  return Math.round((Date.parse(b) - Date.parse(a)) / 86_400_000);
}

/**
 * Собирает присутствие по дням из сырых точек.
 * Точки могут быть редкими (visit monitoring не шлёт ничего, пока стоишь на месте),
 * поэтому дни между двумя соседними точками приписываются стране более ранней точки:
 * если 1 марта я был в Тбилиси, а 10 марта — в Алматы, то 2–9 марта считаются Грузией.
 * Хвост от последней точки до сегодня тоже достраивается — предполагаем, что человек
 * всё ещё там, где его видели последний раз.
 */
export function buildDailyPresence(
  points: Point[],
  overrides: DayOverride[],
  until: string = todayIso(),
): DailyPresence {
  const days: DailyPresence = new Map();

  const add = (date: string, p: Presence) => {
    const list = days.get(date) ?? [];
    const existing = list.find((x) => x.countryCode === p.countryCode);
    if (existing) {
      // реальная точка сильнее достроенной
      if (existing.inferred && !p.inferred) {
        existing.inferred = false;
        existing.city = p.city ?? existing.city;
      }
      return;
    }
    list.push(p);
    days.set(date, list);
  };

  const located = points
    .filter((p) => p.countryCode)
    .sort((a, b) => a.recordedAt.localeCompare(b.recordedAt));

  for (let i = 0; i < located.length; i++) {
    const p = located[i];
    add(p.localDate, {
      countryCode: p.countryCode!,
      countryName: p.countryName,
      city: p.city,
      inferred: false,
      overridden: false,
    });

    const nextDate = i + 1 < located.length ? located[i + 1].localDate : addDays(until, 1);
    for (let d = addDays(p.localDate, 1); d < nextDate; d = addDays(d, 1)) {
      add(d, {
        countryCode: p.countryCode!,
        countryName: p.countryName,
        city: p.city,
        inferred: true,
        overridden: false,
      });
    }
  }

  // Ручные правки перекрывают точки за свой день. Если правок на день две (день перелёта),
  // основная страна — из диапазона, начавшегося позже; при равенстве — созданная позже.
  const byDay = new Map<string, DayOverride[]>();
  for (const o of overrides) byDay.set(o.localDate, [...(byDay.get(o.localDate) ?? []), o]);
  for (const [date, list] of byDay) {
    list.sort((a, b) => (a.rangeFrom ?? a.localDate).localeCompare(b.rangeFrom ?? b.localDate) || a.createdAt.localeCompare(b.createdAt));
    days.set(
      date,
      list.map((o) => ({ countryCode: o.countryCode, countryName: o.countryName, city: o.city, inferred: false, overridden: true })),
    );
  }

  return days;
}

export function primaryOf(list: Presence[] | undefined): Presence | null {
  return list && list.length ? list[list.length - 1] : null;
}

function* datesInRange(days: DailyPresence, from: string, to: string) {
  const sorted = [...days.keys()].sort();
  for (const d of sorted) {
    if (d < from) continue;
    if (d > to) break;
    yield d;
  }
}

export type CountryStat = {
  countryCode: string;
  countryName: string | null;
  days: number;
  firstDay: string;
  lastDay: string;
};

// Сколько дней в каждой стране за период. День, в который были две страны,
// засчитывается обеим — так работают почти все правила резидентства.
export function countryStats(days: DailyPresence, from: string, to: string): CountryStat[] {
  const acc = new Map<string, CountryStat>();
  for (const d of datesInRange(days, from, to)) {
    for (const p of days.get(d)!) {
      const s = acc.get(p.countryCode);
      if (s) {
        s.days++;
        s.lastDay = d;
        s.countryName ??= p.countryName;
      } else {
        acc.set(p.countryCode, {
          countryCode: p.countryCode,
          countryName: p.countryName,
          days: 1,
          firstDay: d,
          lastDay: d,
        });
      }
    }
  }
  return [...acc.values()].sort((a, b) => b.days - a.days);
}

export type Segment = {
  countryCode: string;
  countryName: string | null;
  // город, где провели больше всего дней отрезка
  city: string | null;
  // все города отрезка с числом дней, по убыванию — «Тбилиси 100 · Батуми 6 · Зугдиди 4»
  cities: { city: string; days: number }[];
  // остановки внутри пребывания по порядку: Тбилиси 24 янв – 1 апр, Батуми 1–5 апр, Тбилиси 5 апр – 21 мая.
  // День без города продолжает текущую остановку
  stops: Stop[];
  from: string;
  to: string;
  days: number;
};

export type Stop = { city: string | null; from: string; to: string; days: number };

// Непрерывные отрезки по основной стране дня — для ленты "март: Тбилиси, апрель: Алматы".
// Внутри страны по городам не режем: город у автоматических точек плавает (пригороды, соседние
// районы), и лента рассыпалась бы на осколки. Вместо этого у отрезка список городов с днями.
export function timeline(days: DailyPresence, from: string, to: string): Segment[] {
  const out: Segment[] = [];
  const cityDays: Map<string, number>[] = [];
  let prevDate: string | null = null;
  for (const d of datesInRange(days, from, to)) {
    const p = primaryOf(days.get(d))!;
    const last = out[out.length - 1];
    const contiguous = prevDate !== null && daysBetween(prevDate, d) === 1;
    const city = p.city?.trim() || null;
    if (last && contiguous && last.countryCode === p.countryCode) {
      last.to = d;
      last.days++;
      const stop = last.stops[last.stops.length - 1];
      if (city && stop.city && city !== stop.city) {
        last.stops.push({ city, from: d, to: d, days: 1 });
      } else {
        stop.to = d;
        stop.days++;
        stop.city ??= city;
      }
    } else {
      out.push({ countryCode: p.countryCode, countryName: p.countryName, city: null, cities: [], stops: [{ city, from: d, to: d, days: 1 }], from: d, to: d, days: 1 });
      cityDays.push(new Map());
    }
    if (city) {
      const m = cityDays[cityDays.length - 1];
      m.set(city, (m.get(city) ?? 0) + 1);
    }
    prevDate = d;
  }
  for (const [i, seg] of out.entries()) {
    seg.cities = [...cityDays[i].entries()].map(([city, n]) => ({ city, days: n })).sort((a, b) => b.days - a.days);
    seg.city = seg.cities[0]?.city ?? null;
  }
  // День перелёта принадлежит обеим странам: у той, откуда уехали, он не основной и в отрезок не попал.
  // Дотягиваем конец отрезка на такие дни, чтобы «Турция 21–31 мая» и «Грузия с 31 мая» показывались честно.
  for (const seg of out) {
    for (let next = addDays(seg.to, 1); next <= to; next = addDays(next, 1)) {
      const list = days.get(next);
      if (!list || primaryOf(list)!.countryCode === seg.countryCode || !list.some((p) => p.countryCode === seg.countryCode)) break;
      seg.to = next;
      seg.days++;
      const stop = seg.stops[seg.stops.length - 1];
      stop.to = next;
      stop.days++;
    }
  }
  return out.reverse();
}

export function currentStatus(days: DailyPresence, today: string = todayIso()) {
  const dates = [...days.keys()].filter((d) => d <= today).sort();
  const lastDate = dates[dates.length - 1];
  if (!lastDate) return null;
  const p = primaryOf(days.get(lastDate))!;

  let since = lastDate;
  for (let i = dates.length - 2; i >= 0; i--) {
    const prev = primaryOf(days.get(dates[i]))!;
    if (prev.countryCode !== p.countryCode || daysBetween(dates[i], since) !== 1) break;
    since = dates[i];
  }

  const yearStart = `${today.slice(0, 4)}-01-01`;
  const thisYear = countryStats(days, yearStart, today).find((s) => s.countryCode === p.countryCode);

  return {
    countryCode: p.countryCode,
    countryName: p.countryName,
    city: p.city,
    since,
    daysInRow: daysBetween(since, today) + 1,
    daysThisYear: thisYear?.days ?? 0,
    lastSeen: lastDate,
  };
}

// MARK: правила подсчёта

export type RuleResult = {
  ruleId: string;
  name: string;
  mode: Rule["mode"];
  type: Rule["type"];
  countries: string[];
  notify: boolean;
  warnRemainingDays: number | null;
  autoStart: boolean;
  documentId: string | null;
  regimeId: string | null;
  validFrom: string | null;
  validUntil: string | null;
  // fromDate + autoStart: дата текущего въезда (null, если сейчас не в стране)
  entryDate: string | null;
  // fromDate + autoStart: находимся ли сейчас в странах правила
  inCountry: boolean | null;
  // fromDate + autoStart, когда не в стране: последний заезд — справочно
  lastStay: { from: string; to: string; days: number } | null;
  // границы периода, по которому идёт подсчёт (для rolling — текущее окно)
  periodStart: string;
  periodEnd: string;
  used: number;
  limit: number;
  // limit: сколько дней ещё можно провести; goal: сколько ещё нужно набрать
  remaining: number;
  // limit: сколько дней подряд, начиная с завтра, можно оставаться, не нарушив правило
  canStayDays: number | null;
  // goal: успеть ли набрать лимит до конца периода, если остаться
  reachable: boolean | null;
  status: "ok" | "warning" | "exceeded" | "reached";
};

// MARK: основание по дням

export type DayBasis = { basis: EntryBasis; documentId: string | null };
// страна -> дата -> основание пребывания в этот день
export type BasisIndex = Map<string, Map<string, DayBasis>>;

/**
 * Раскладывает основания въезда по дням. Для каждой страны берём непрерывные пребывания и внутри
 * каждого действует последняя запись (въезд или смена статуса) с датой не позже дня. Дни до первой
 * записи пребывания остаются без основания — такие дни считаются во всех правилах.
 */
export function buildBasisIndex(days: DailyPresence, list: Entry[]): BasisIndex {
  const index: BasisIndex = new Map();
  const byCountry = new Map<string, Entry[]>();
  for (const e of list) {
    const arr = byCountry.get(e.countryCode) ?? [];
    arr.push(e);
    byCountry.set(e.countryCode, arr);
  }
  const dates = [...days.keys()].sort();
  for (const [cc, entriesOfCountry] of byCountry) {
    const sorted = entriesOfCountry.slice().sort((a, b) => a.date.localeCompare(b.date));
    const perDay = new Map<string, DayBasis>();
    let current: Entry | null = null;
    let prevDate: string | null = null;
    let stayStart: string | null = null;
    for (const d of dates) {
      if (!days.get(d)!.some((p) => p.countryCode === cc)) continue;
      // разрыв в присутствии — новое пребывание, записи прежних пребываний не переносятся
      if (!prevDate || daysBetween(prevDate, d) !== 1) {
        current = null;
        stayStart = d;
      }
      prevDate = d;
      for (const e of sorted) if (e.date >= stayStart! && e.date <= d && (!current || e.date >= current.date)) current = e;
      if (current) perDay.set(d, { basis: current.basis, documentId: current.documentId });
    }
    index.set(cc, perDay);
  }
  return index;
}

/**
 * Считается ли день с таким основанием в правиле. Правило безвиза не считает дни под ВНЖ, визой
 * или гражданством; правило визы — дни под другой визой, ВНЖ, безвизом или гражданством.
 * День без основания считается везде.
 */
function basisAllowed(rule: Rule, b: DayBasis | undefined): boolean {
  if (!b) return true;
  if (rule.regimeId) return b.basis !== "citizen" && b.basis !== "residence" && b.basis !== "visa";
  if (rule.documentId && (rule.documentRole === "stay" || rule.documentRole === "window")) {
    if (b.basis === "visa") return b.documentId == null || b.documentId === rule.documentId;
    return b.basis === "transit" || b.basis === "other";
  }
  return true;
}

function dayMatches(list: Presence[] | undefined, rule: Rule, date: string, basis?: BasisIndex): boolean {
  if (!list || list.length === 0) return false;
  if (rule.countries.length === 0) return true;
  const ok = (p: Presence) => rule.countries.includes(p.countryCode) && basisAllowed(rule, basis?.get(p.countryCode)?.get(date));
  if (rule.countMode === "primary") return ok(primaryOf(list)!);
  return list.some(ok);
}

/**
 * Последнее непрерывное пребывание в странах правила: берём последний подходящий день
 * не позже сегодня и идём назад, пока дни идут подряд. Нет ни одного — null.
 */
function lastStayOf(days: DailyPresence, rule: Rule, today: string, basis?: BasisIndex): { from: string; to: string; days: number } | null {
  const dates = [...days.keys()].filter((d) => d <= today).sort();
  let to: string | null = null;
  for (let i = dates.length - 1; i >= 0; i--) {
    if (dayMatches(days.get(dates[i]), rule, dates[i], basis)) {
      to = dates[i];
      break;
    }
  }
  if (!to) return null;
  let from = to;
  for (let d = addDays(to, -1); dayMatches(days.get(d), rule, d, basis); d = addDays(d, -1)) from = d;
  return { from, to, days: daysBetween(from, to) + 1 };
}

type Period = {
  start: string;
  end: string;
  entryDate: string | null;
  inCountry: boolean | null;
  lastStay: RuleResult["lastStay"];
};

function periodOf(days: DailyPresence, rule: Rule, today: string, basis?: BasisIndex): Period {
  const none = { entryDate: null, inCountry: null, lastStay: null };
  switch (rule.type) {
    case "absence": {
      // Считаем дни подряд ВНЕ стран правила, заканчивая сегодня. Период — текущее отсутствие.
      const stay = lastStayOf(days, rule, today, basis);
      const inCountry = !!stay && (stay.to === today || (stay.to === addDays(today, -1) && !days.has(today)));
      if (!stay || inCountry) {
        return { start: today, end: addDays(today, rule.limitDays - 1), entryDate: null, inCountry: !!stay, lastStay: stay };
      }
      const start = addDays(stay.to, 1);
      return { start, end: addDays(start, rule.limitDays - 1), entryDate: null, inCountry: false, lastStay: stay };
    }
    case "calendarYear":
      return { start: `${today.slice(0, 4)}-01-01`, end: `${today.slice(0, 4)}-12-31`, ...none };
    case "rolling":
      return { start: addDays(today, -((rule.windowDays ?? 180) - 1)), end: today, ...none };
    case "fromDate": {
      const endFrom = (start: string) => (rule.windowDays ? addDays(start, rule.windowDays - 1) : "9999-12-31");
      if (!rule.autoStart) {
        const start = rule.startDate ?? today;
        return { start, end: endFrom(start), ...none };
      }
      const stay = lastStayOf(days, rule, today, basis);
      // "Сейчас в стране" = последний подходящий день — сегодня (или вчера, если за сегодня данных ещё нет)
      const inCountry = !!stay && (stay.to === today || (stay.to === addDays(today, -1) && !days.has(today)));
      if (inCountry) {
        return { start: stay!.from, end: endFrom(stay!.from), entryDate: stay!.from, inCountry: true, lastStay: stay };
      }
      // Выехали: отсчёт сброшен, период начнётся с будущего въезда. Считаем как будто въезд сегодня,
      // чтобы used = 0 и canStayDays = полный лимит.
      return { start: today, end: endFrom(today), entryDate: null, inCountry: false, lastStay: stay };
    }
  }
}

export function evaluateRule(days: DailyPresence, rule: Rule, today: string, basis?: BasisIndex): RuleResult {
  // validFrom/validUntil правила — только запись о том, какая версия условий когда действовала.
  // Считаются все фактические дни: смена условий не обнуляет уже проведённое время в окне.
  // basis — основания по дням: дни под другим статусом (ВНЖ вместо безвиза) в правило не идут.
  const { start, end, entryDate, inCountry, lastStay } = periodOf(days, rule, today, basis);
  const matched = new Set<string>();
  for (const d of datesInRange(days, start, end < today ? end : today)) {
    if (dayMatches(days.get(d), rule, d, basis)) matched.add(d);
  }
  // absence: использовано = дней подряд вне страны (сегодня включительно); в стране — 0
  // absence: использовано = дней подряд вне страны (сегодня включительно);
  // в стране или вообще ещё не были в ней по данным — 0
  const used = rule.type === "absence"
    ? (inCountry === false && lastStay ? daysBetween(start, today) + 1 : 0)
    : matched.size;
  const limit = rule.limitDays;
  const remaining = Math.max(0, limit - used);
  const daysLeftInPeriod = end > today ? daysBetween(today, end) : 0;

  let canStayDays: number | null = null;
  let reachable: boolean | null = null;

  if (rule.mode === "limit") {
    if (rule.type === "rolling") {
      // Идём по дням вперёд, считая, что каждый следующий день проведём в зоне,
      // пока в окне, заканчивающемся этим днём, не станет больше лимита.
      const window = rule.windowDays ?? 180;
      let stay = 0;
      for (let d = addDays(today, 1); stay < 400; d = addDays(d, 1)) {
        const winStart = addDays(d, -(window - 1));
        let inWindow = 0;
        for (let x = winStart; x <= today; x = addDays(x, 1)) if (matched.has(x)) inWindow++;
        const simulated = daysBetween(today, d);
        if (inWindow + simulated > limit) break;
        stay++;
      }
      canStayDays = stay;
    } else if (rule.type === "absence") {
      canStayDays = remaining;
    } else {
      // вне страны период ещё не начался — сегодняшний день тоже доступен
      canStayDays = Math.min(remaining, inCountry === false ? daysLeftInPeriod + 1 : daysLeftInPeriod);
    }
  } else {
    reachable = used >= limit || used + daysLeftInPeriod >= limit;
  }

  let status: RuleResult["status"] = "ok";
  if (used >= limit) status = rule.mode === "limit" ? "exceeded" : "reached";
  else if (rule.mode === "limit" && rule.warnRemainingDays != null && remaining <= rule.warnRemainingDays) status = "warning";

  return {
    ruleId: rule.id,
    name: rule.name,
    mode: rule.mode,
    type: rule.type,
    countries: rule.countries,
    notify: rule.notify,
    warnRemainingDays: rule.warnRemainingDays,
    autoStart: rule.autoStart ?? false,
    documentId: rule.documentId ?? null,
    regimeId: rule.regimeId ?? null,
    validFrom: rule.validFrom ?? null,
    validUntil: rule.validUntil ?? null,
    entryDate,
    inCountry,
    lastStay,
    periodStart: start,
    periodEnd: end,
    used,
    limit,
    remaining,
    canStayDays,
    reachable,
    status,
  };
}

// MARK: города

export type CityStat = {
  city: string;
  countryCode: string;
  countryName: string | null;
  days: number;
  firstDay: string;
  lastDay: string;
};

// Дни по городам. Город известен только из точек с устройства, поэтому дни без города
// собираются в "—" внутри страны.
export function cityStats(days: DailyPresence, from: string, to: string): CityStat[] {
  const acc = new Map<string, CityStat>();
  for (const d of datesInRange(days, from, to)) {
    const seen = new Set<string>();
    for (const p of days.get(d)!) {
      const city = p.city?.trim() || "—";
      // регистр и пробелы не делают город другим; показываем написание, встреченное первым
      const key = `${p.countryCode}|${city.toLowerCase()}`;
      if (seen.has(key)) continue;
      seen.add(key);
      const s = acc.get(key);
      if (s) {
        s.days++;
        s.lastDay = d;
      } else {
        acc.set(key, { city, countryCode: p.countryCode, countryName: p.countryName, days: 1, firstDay: d, lastDay: d });
      }
    }
  }
  return [...acc.values()].sort((a, b) => b.days - a.days);
}
