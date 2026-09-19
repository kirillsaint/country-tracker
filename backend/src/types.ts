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
  | "fromDate"
  // максимум дней подряд ВНЕ стран правила (обязательство ВНЖ/ПМЖ не отсутствовать дольше N)
  | "absence";

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
  // только для fromDate: дата начала = первый день текущего непрерывного пребывания в странах
  // правила (определяется по данным); выехал и вернулся — отсчёт начинается заново
  autoStart: boolean;
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
  // правило порождено документом (визой / ВНЖ): documentId + роль внутри документа.
  // Такие правила пересоздаются при изменении документа и удаляются вместе с ним.
  documentId: string | null;
  documentRole: DocumentRuleRole | null;
  // пользователь правил автосозданное правило руками — при пересборке документа его не трогаем
  customized: boolean;
  // после этой даты правило считается истёкшим и в расчётах не участвует (срок визы/ВНЖ)
  validUntil: string | null;
  createdAt: string;
  updatedAt: string;
};

// visafree — правило безвиза, привязанное к паспорту (по данным справочника или подтверждённое пользователем)
export type DocumentRuleRole = "stay" | "window" | "presence" | "absence" | "visafree";

// MARK: справочник визовых режимов (кэш ответов Orizn)

export type VisaRequirement = "visa_free" | "e_visa" | "visa_on_arrival" | "eta" | "visa_required" | "no_admission" | "unknown";

export type VisaCacheEntry = {
  // ISO alpha-2
  passport: string;
  destination: string;
  fetchedAt: string;
  // null — у справочника нет данных по паре (404)
  requirement: VisaRequirement | null;
  visaFreeDays: number | null;
  description: string | null;
  maxStay: string | null;
  // заметки, из которых извлекаются "90 in any 180", "180 per calendar year"
  extensionNotes: string | null;
  extensionPossible: boolean | null;
  maxExtensionDays: number | null;
  passportValidityMonths: number | null;
  source: string | null;
  verified: boolean | null;
  sourceUrl: string | null;
  lastVerifiedAt: string | null;
  requirementStatus: string | null;
  requirementStatusNote: string | null;
  overstayNotes: string | null;
  // полный ответ — на будущее, чтобы не перезапрашивать
  raw: unknown;
};

// MARK: документы

export type DocumentKind = "passport" | "visa" | "residence";

export type TravelDocument = {
  userId: ObjectId;
  id: string;
  kind: DocumentKind;
  name: string;
  // passport: страна гражданства; visa/residence: страна документа
  countryCode: string;
  // visa/residence: все страны, где документ действует (зона), минимум [countryCode]
  countries: string[];
  // visa/residence: по какому паспорту выдан
  passportId: string | null;
  validFrom: string | null;
  validTo: string | null;
  // visa
  entries: "single" | "multiple" | null;
  // максимум дней за один въезд
  maxStayDays: number | null;
  // лимит в скользящем окне, например 90 из 180
  windowLimitDays: number | null;
  windowDays: number | null;
  // residence
  residenceType: "temporary" | "permanent" | null;
  // обязательства: минимум дней в стране за год / максимум непрерывного отсутствия
  minDaysPerYear: number | null;
  maxAbsenceDays: number | null;
  note: string | null;
  createdAt: string;
  updatedAt: string;
};

// Основание въезда: привязано к отрезку пребывания (страна + дата въезда)
export type EntryBasis = "citizen" | "visa_free" | "visa" | "residence" | "transit" | "other";

export type Entry = {
  userId: ObjectId;
  id: string;
  countryCode: string;
  // дата въезда = первый день отрезка, YYYY-MM-DD
  date: string;
  basis: EntryBasis;
  documentId: string | null;
  note: string | null;
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
