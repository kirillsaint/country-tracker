import type { ObjectId } from "mongodb";

export type Provider = "apple" | "google";

export type ProviderLink = {
  // стабильный id пользователя у провайдера (claim `sub`)
  sub: string;
  email: string | null;
  linkedAt: string;
};

export type User = {
  _id: ObjectId;
  email: string | null;
  name: string | null;
  apple: ProviderLink | null;
  google: ProviderLink | null;
  // правила по умолчанию уже созданы (чтобы не пересоздавать, если пользователь всё удалил)
  rulesSeeded?: boolean;
  createdAt: string;
};

// Правило подсчёта дней: "не больше 90 дней в любые 180 в Шенгене",
// "183 дня за календарный год в Грузии", "60 дней с даты въезда" и т.п.
export type RuleType =
  // окно = календарный год
  | "calendarYear"
  // скользящее окно из windowDays дней, заканчивающееся сегодня
  | "rolling"
  // фиксированный период: с startDate на windowDays дней (или бессрочно, если windowDays = null)
  | "fromDate";

export type Rule = {
  userId: ObjectId;
  id: string;
  name: string;
  enabled: boolean;
  type: RuleType;
  // ISO alpha-2; пусто = любая страна (считаем все дни)
  countries: string[];
  limitDays: number;
  windowDays: number | null;
  startDate: string | null;
  // limit — нельзя превышать (визы, 90/180); goal — нужно набрать (резидентство)
  mode: "limit" | "goal";
  // any — день считается, если в этот день был хоть один заход в страну;
  // primary — только если это основная страна дня (последняя за день)
  countMode: "any" | "primary";
  // предупреждать (подсветка + уведомление), когда осталось <= N дней
  warnRemainingDays: number | null;
  // слать ли уведомления по этому правилу
  notify: boolean;
  sortOrder: number;
  createdAt: string;
  updatedAt: string;
};

// Сессия = непрозрачный токен, который приложение хранит в Keychain. В базе лежит только его хеш.
export type Session = {
  tokenHash: string;
  userId: ObjectId;
  device: string | null;
  createdAt: string;
  lastUsedAt: string;
};

// Сырая точка, как её прислало устройство. Никогда не удаляем и не правим —
// вся статистика пересчитывается из этих документов.
export type Point = {
  userId: ObjectId;
  // uuid, который генерирует устройство; защита от дублей при ретраях
  clientId: string;
  lat: number;
  lon: number;
  accuracy: number | null;
  // ISO 8601 в UTC
  recordedAt: string;
  // смещение таймзоны устройства в момент записи, минуты
  tzOffsetMin: number;
  // календарная дата по местному времени устройства, YYYY-MM-DD
  localDate: string;
  source: "visit" | "significant" | "hourly" | "foreground" | "manual";
  // для visit: когда приехали / уехали
  arrivalAt: string | null;
  departureAt: string | null;
  // определяется на сервере оффлайн по координатам
  countryCode: string | null;
  countryName: string | null;
  // приходит с устройства (CLGeocoder), best-effort
  city: string | null;
  region: string | null;
  deviceId: string | null;
  createdAt: string;
};

// Ручная правка: "в этот день я на самом деле был в X".
// Перекрывает всё, что посчитано из точек.
export type DayOverride = {
  userId: ObjectId;
  localDate: string;
  countryCode: string;
  countryName: string | null;
  city: string | null;
  note: string | null;
  createdAt: string;
};

// Что уходит в ответах API (без внутренних полей)
export const publicProjection = { _id: 0, userId: 0 } as const;
