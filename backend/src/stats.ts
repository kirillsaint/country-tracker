import type { DayOverride, Point, Rule } from "./types.js";

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

  for (const o of overrides) {
    days.set(o.localDate, [
      {
        countryCode: o.countryCode,
        countryName: o.countryName,
        city: o.city,
        inferred: false,
        overridden: true,
      },
    ]);
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
  city: string | null;
  from: string;
  to: string;
  days: number;
};

// Непрерывные отрезки по основной стране дня — для ленты "март: Тбилиси, апрель: Алматы".
export function timeline(days: DailyPresence, from: string, to: string): Segment[] {
  const out: Segment[] = [];
  let prevDate: string | null = null;
  for (const d of datesInRange(days, from, to)) {
    const p = primaryOf(days.get(d))!;
    const last = out[out.length - 1];
    const contiguous = prevDate !== null && daysBetween(prevDate, d) === 1;
    if (last && contiguous && last.countryCode === p.countryCode) {
      last.to = d;
      last.days++;
      last.city ??= p.city;
    } else {
      out.push({
        countryCode: p.countryCode,
        countryName: p.countryName,
        city: p.city,
        from: d,
        to: d,
        days: 1,
      });
    }
    prevDate = d;
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
  // fromDate + autoStart: найденная дата въезда (null, если в стране ещё не были)
  entryDate: string | null;
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

function dayMatches(list: Presence[] | undefined, rule: Rule): boolean {
  if (!list || list.length === 0) return false;
  if (rule.countries.length === 0) return true;
  if (rule.countMode === "primary") return rule.countries.includes(primaryOf(list)!.countryCode);
  return list.some((p) => rule.countries.includes(p.countryCode));
}

/**
 * Дата въезда для autoStart: первый день последнего непрерывного пребывания в странах правила.
 * Берём последний подходящий день не позже сегодня и идём назад, пока дни идут подряд.
 * Нет ни одного подходящего дня — null.
 */
function detectEntryDate(days: DailyPresence, rule: Rule, today: string): string | null {
  const dates = [...days.keys()].filter((d) => d <= today).sort();
  let last: string | null = null;
  for (let i = dates.length - 1; i >= 0; i--) {
    if (dayMatches(days.get(dates[i]), rule)) {
      last = dates[i];
      break;
    }
  }
  if (!last) return null;
  let start = last;
  for (let d = addDays(last, -1); dayMatches(days.get(d), rule); d = addDays(d, -1)) start = d;
  return start;
}

function periodOf(days: DailyPresence, rule: Rule, today: string): { start: string; end: string; entryDate: string | null } {
  switch (rule.type) {
    case "calendarYear":
      return { start: `${today.slice(0, 4)}-01-01`, end: `${today.slice(0, 4)}-12-31`, entryDate: null };
    case "rolling":
      return { start: addDays(today, -((rule.windowDays ?? 180) - 1)), end: today, entryDate: null };
    case "fromDate": {
      const entryDate = rule.autoStart ? detectEntryDate(days, rule, today) : null;
      const start = (rule.autoStart ? entryDate : rule.startDate) ?? today;
      return { start, end: rule.windowDays ? addDays(start, rule.windowDays - 1) : "9999-12-31", entryDate };
    }
  }
}

export function evaluateRule(days: DailyPresence, rule: Rule, today: string): RuleResult {
  const { start, end, entryDate } = periodOf(days, rule, today);
  const matched = new Set<string>();
  for (const d of datesInRange(days, start, end < today ? end : today)) {
    if (dayMatches(days.get(d), rule)) matched.add(d);
  }
  const used = matched.size;
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
    } else {
      canStayDays = Math.min(remaining, daysLeftInPeriod);
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
    entryDate,
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
      const city = p.city ?? "—";
      const key = `${p.countryCode}|${city}`;
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
