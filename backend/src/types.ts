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
  // правило порождено режимом въезда (безвиз): regimeId + id ограничения версии
  regimeId: string | null;
  constraintId: string | null;
  // дни раньше этой даты не считаются — правило вступило в силу с новой версии режима
  validFrom: string | null;
  // пользователь правил автосозданное правило руками — при пересборке документа его не трогаем
  customized: boolean;
  // после этой даты правило считается истёкшим и в расчётах не участвует (срок визы/ВНЖ)
  validUntil: string | null;
  createdAt: string;
  updatedAt: string;
};

export type DocumentRuleRole = "stay" | "window" | "presence" | "absence";

// MARK: режимы въезда (безвиз по паспорту)

export type ConstraintType = "perEntry" | "rolling" | "calendarYear" | "fromDate";

export type RegimeConstraint = {
  id: string;
  type: ConstraintType;
  limitDays: number;
  windowDays: number | null;
  startDate: string | null;
  note: string | null;
};

export type ConditionKind = "registration" | "passportValidity" | "insurance" | "funds" | "ticket" | "other";

// Условие въезда, не считающееся в днях: "зарегистрироваться в течение 3 дней", "паспорт 6 месяцев"
export type RegimeCondition = {
  id: string;
  kind: ConditionKind;
  text: string;
  // для registration: напомнить через N дней после въезда
  withinDays: number | null;
  done: boolean;
};

export type RegimeSource = {
  url: string;
  title: string | null;
  // официальный домен (МИД, консульство, gov)
  official: boolean;
  quote: string | null;
};

export type RegimeRequirement = "visa_free" | "e_visa" | "visa_on_arrival" | "visa_required" | "unknown";

// Одна версия режима. При изменении условий старая уходит в history с effectiveTo.
export type RegimeVersion = {
  id: string;
  requirement: RegimeRequirement;
  constraints: RegimeConstraint[];
  conditions: RegimeCondition[];
  sources: RegimeSource[];
  origin: "user" | "ai";
  model: string | null;
  notes: string | null;
  effectiveFrom: string;
  effectiveTo: string | null;
  confirmedAt: string;
};

export type Regime = {
  userId: ObjectId;
  id: string;
  passportId: string;
  passportCode: string;
  countryCode: string;
  active: RegimeVersion | null;
  history: RegimeVersion[];
  lastCheckedAt: string | null;
  createdAt: string;
  updatedAt: string;
};

// Черновик от нейросети — то, что пользователь проверяет перед добавлением
export type RegimeDraft = {
  requirement: RegimeRequirement;
  constraints: RegimeConstraint[];
  conditions: RegimeCondition[];
  sources: RegimeSource[];
  summary: string;
  // на какую дату актуальна информация / когда менялась
  asOf: string | null;
  recentChange: string | null;
  confidence: "high" | "medium" | "low";
};

// Запуск проверки: фоновая задача + кэш результата по паре (паспорт, страна), общий для всех
export type RegimeCheck = {
  id: string;
  passportCode: string;
  countryCode: string;
  lang: string;
  status: "queued" | "running" | "done" | "failed";
  model: string;
  requestedAt: string;
  finishedAt: string | null;
  draft: RegimeDraft | null;
  error: string | null;
  raw: string | null;
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
  // однократная виза уже потрачена: правила закрываются датой usedAt, напоминаний об истечении нет
  used: boolean;
  usedAt: string | null;
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
  // предыдущие сроки действия — заполняется при продлении (POST /documents/:id/renew)
  history?: DocumentPeriod[];
  createdAt: string;
  updatedAt: string;
};

export type DocumentPeriod = { validFrom: string | null; validTo: string | null; renewedAt: string };

// Основание въезда: привязано к отрезку пребывания (страна + дата въезда)
export type EntryBasis = "citizen" | "visa_free" | "visa" | "residence" | "transit" | "other";

export type Entry = {
  userId: ObjectId;
  id: string;
  countryCode: string;
  // дата въезда = первый день отрезка, YYYY-MM-DD
  date: string;
  // arrival — основание с момента въезда; switch — смена статуса внутри того же пребывания
  // без пересечения границы (получил ВНЖ, будучи в стране по безвизу). Нет поля = arrival.
  kind?: "arrival" | "switch";
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
  // первый день диапазона, которым создана правка: в день с двумя странами основной считается та,
  // чей диапазон начался позже (день перелёта — обеим, прилетели — во вторую)
  rangeFrom: string;
  createdAt: string;
};

// Что уходит в ответах API (без внутренних полей)
export const publicProjection = { _id: 0, userId: 0 } as const;
