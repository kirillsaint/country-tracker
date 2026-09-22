import Foundation

// Точка, которую устройство отправляет на сервер (зеркало pointSchema в бэкенде).
struct PendingPoint: Codable, Identifiable, Equatable {
    enum Source: String, Codable {
        case visit, significant, hourly, foreground, manual
    }

    var id: String { clientId }

    let clientId: String
    let lat: Double
    let lon: Double
    let accuracy: Double?
    let recordedAt: Date
    let tzOffsetMin: Int
    let source: Source
    let arrivalAt: Date?
    let departureAt: Date?
    var city: String?
    var region: String?
    let deviceId: String?
}

// MARK: - Ответы API

struct CountryStat: Codable, Identifiable, Hashable {
    var id: String { countryCode }
    let countryCode: String
    let countryName: String?
    let days: Int
    let firstDay: String
    let lastDay: String
}

struct CurrentStatus: Codable, Equatable {
    struct EntryRef: Codable, Equatable {
        let basis: EntryBasis
        let documentId: String?
        let date: String
        // arrival — с момента въезда, statusChange — смена статуса внутри пребывания
        var kind: EntryKind?
        var isSwitch: Bool { kind == .statusChange }
    }

    let countryCode: String
    let countryName: String?
    let city: String?
    let since: String
    let daysInRow: Int
    let daysThisYear: Int
    let lastSeen: String
    struct RegimeRef: Codable, Equatable {
        let passportId: String
        let regimeId: String?
        let lastCheckedAt: String?
        let stale: Bool
    }

    // основание текущего пребывания; nil + entryPending — пора спросить "как въехали?"
    let entry: EntryRef?
    // смена статуса внутри пребывания без пересечения границы (получил ВНЖ по безвизу)
    var switched: EntryRef?
    let previousEntry: EntryRef?
    let entryPending: Bool?

    /// Действующее сейчас основание: смена статуса, если была, иначе основание въезда
    var basisNow: EntryRef? { switched ?? entry }
    // режим безвиза для этой страны: есть ли и не пора ли перепроверить
    let regime: RegimeRef?

    var needsEntryBasis: Bool { entryPending ?? false }
}

struct Segment: Codable, Identifiable, Hashable {
    var id: String { "\(from)-\(countryCode)" }
    let countryCode: String
    let countryName: String?
    /// город с наибольшим числом дней
    let city: String?
    /// все города отрезка с днями, по убыванию; nil у отрезков, собранных на устройстве
    var cities: [CityDays]?
    /// остановки по порядку внутри пребывания (Тбилиси → Батуми → Тбилиси); nil — собрано на устройстве
    var stops: [Stop]?
    let from: String
    let to: String
    let days: Int

    struct CityDays: Codable, Hashable { let city: String; let days: Int }
    struct Stop: Codable, Hashable { let city: String?; let from: String; let to: String; let days: Int }

    /// Пребывание как отдельные поездки по городам — для хронологии. Один город — сам отрезок
    var byStop: [Segment] {
        guard let stops, stops.count > 1 else { return [self] }
        return stops.map { Segment(countryCode: countryCode, countryName: countryName, city: $0.city, cities: nil, stops: nil, from: $0.from, to: $0.to, days: $0.days) }
    }
}

struct CityStat: Codable, Identifiable, Hashable {
    var id: String { "\(countryCode)|\(city)" }
    let city: String
    let countryCode: String
    let countryName: String?
    let days: Int
    let firstDay: String
    let lastDay: String
    // координаты для карты; nil у городов, известных только из ручных записей
    let lat: Double?
    let lon: Double?
}

// MARK: - Срез за год

struct YearStats: Equatable {
    /// nil — за всё время
    let year: Int?
    let countries: [CountryStat]
    let cities: [CityStat]
    let segments: [Segment]

    /// Учтённых дней (каждый день один раз — по основной стране)
    var totalDays: Int { segments.reduce(0) { $0 + $1.days } }
    var longestStay: Segment? { segments.max { $0.days < $1.days } }
    /// Поездок = отрезков в хронологии
    var trips: Int { segments.count }
}

extension Segment {
    /// Разрезать отрезок по границам календарных лет — для группировки хронологии по годам
    func splitByYear() -> [Segment] {
        guard let fromYear = Int(from.prefix(4)), let toYear = Int(to.prefix(4)), fromYear != toYear else { return [self] }
        var out: [Segment] = []
        for y in fromYear...toYear {
            let start = y == fromYear ? from : "\(y)-01-01"
            let end = y == toYear ? to : "\(y)-12-31"
            let d = (daysBetween(start, end) ?? 0) + 1
            // города по годам не делим — показываем общий список отрезка
            out.append(Segment(countryCode: countryCode, countryName: countryName, city: city, cities: cities, stops: nil, from: start, to: end, days: d))
        }
        return out.reversed()
    }

    var year: Int { Int(from.prefix(4)) ?? 0 }
}

// MARK: - Документы (паспорта, визы, ВНЖ)

enum DocumentKind: String, Codable, CaseIterable, Identifiable {
    case passport, visa, residence
    var id: String { rawValue }

    var title: String {
        switch self {
        case .passport: return String(localized: "Passport")
        case .visa: return String(localized: "Visa")
        case .residence: return String(localized: "Residence permit")
        }
    }

    var pluralTitle: String {
        switch self {
        case .passport: return String(localized: "Passports")
        case .visa: return String(localized: "Visas")
        case .residence: return String(localized: "Residence permits")
        }
    }

    var systemImage: String {
        switch self {
        case .passport: return "person.text.rectangle"
        case .visa: return "doc.text"
        case .residence: return "house"
        }
    }
}

enum VisaEntries: String, Codable, CaseIterable, Identifiable {
    case single, multiple
    var id: String { rawValue }
    var title: String { self == .single ? String(localized: "Single entry") : String(localized: "Multiple entry") }
}

enum ResidenceType: String, Codable, CaseIterable, Identifiable {
    case temporary, permanent
    var id: String { rawValue }
    var title: String { self == .temporary ? String(localized: "Temporary (residence permit)") : String(localized: "Permanent") }
}

struct DocumentInput: Codable, Equatable {
    var kind: DocumentKind
    var name: String
    var countryCode: String
    var countries: [String] = []
    var passportId: String?
    var validFrom: String?
    var validTo: String?
    var entries: VisaEntries?
    // однократная виза уже потрачена (+ с какого дня); сервер закрывает её правила этой датой
    var used: Bool = false
    var usedAt: String?
    var maxStayDays: Int?
    var windowLimitDays: Int?
    var windowDays: Int?
    var residenceType: ResidenceType?
    var minDaysPerYear: Int?
    var maxAbsenceDays: Int?
    var note: String?
    // язык подписей автосозданных правил
    var lang: String = DocumentInput.currentLang

    static var currentLang: String { Locale.current.language.languageCode?.identifier == "ru" ? "ru" : "en" }

    static func todayString() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f.string(from: Date())
    }
}

struct TravelDocument: Codable, Identifiable, Equatable {
    let id: String
    var kind: DocumentKind
    var name: String
    var countryCode: String
    var countries: [String]
    var passportId: String?
    var validFrom: String?
    var validTo: String?
    var entries: VisaEntries?
    var used: Bool?
    var usedAt: String?
    var maxStayDays: Int?
    var windowLimitDays: Int?
    var windowDays: Int?
    var residenceType: ResidenceType?
    var minDaysPerYear: Int?
    var maxAbsenceDays: Int?
    var note: String?
    // прежние сроки действия — появляются после продления
    var history: [DocumentPeriod]?
    let createdAt: String
    let updatedAt: String

    var input: DocumentInput {
        DocumentInput(kind: kind, name: name, countryCode: countryCode, countries: countries, passportId: passportId,
                      validFrom: validFrom, validTo: validTo, entries: entries, used: used ?? false, usedAt: usedAt, maxStayDays: maxStayDays,
                      windowLimitDays: windowLimitDays, windowDays: windowDays, residenceType: residenceType,
                      minDaysPerYear: minDaysPerYear, maxAbsenceDays: maxAbsenceDays, note: note)
    }

    /// Дней до истечения; nil — бессрочный; отрицательное — уже истёк
    var daysUntilExpiry: Int? {
        guard let validTo else { return nil }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return daysBetween(f.string(from: Date()), validTo)
    }

    /// Применим ли документ к стране (паспорт — к своей стране, виза/ВНЖ — к зоне)
    func covers(_ code: String) -> Bool {
        kind == .passport ? countryCode == code : countries.contains(code)
    }

    var isSingleEntryVisa: Bool { kind == .visa && entries == .single }

    /// Хватает ли срока паспорта: на дату `on` он должен действовать ещё `months` месяцев. Бессрочный — да.
    func validFor(months: Int, on date: String = DocumentInput.todayString()) -> Bool {
        guard let validTo else { return true }
        return Self.requiredUntil(months: months, from: date) <= validTo
    }

    /// Дата, до которой паспорт должен действовать при въезде `from` с требованием `months` месяцев
    static func requiredUntil(months: Int, from date: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        guard let d = f.date(from: date), let r = Calendar.current.date(byAdding: .month, value: months, to: d) else { return date }
        return f.string(from: r)
    }

    /// Порог, ниже которого паспорт становится «проблемным» для многих стран
    static let commonPassportMonths = 6

    /// Потрачена ли однократная виза. Порядок проверки: флаг, поставленный руками; пребывание,
    /// оформленное по этой визе и уже закончившееся; ручная запись о поездке в её страну внутри срока действия.
    /// nil — не однократная виза или использование не обнаружено.
    func usage(entries: [Entry], ranges: [ManualRange], current: CurrentStatus?) -> VisaUsage? {
        guard isSingleEntryVisa else { return nil }
        if used == true { return VisaUsage(source: .flag, from: nil, to: usedAt) }
        let today = DocumentInput.todayString()
        if let e = entries.first(where: { e in
            e.documentId == id && e.basis == .visa
                && !(current?.countryCode == e.countryCode && current?.entry?.date == e.date)
        }) {
            return VisaUsage(source: .entry, from: e.date, to: nil)
        }
        if let r = ranges.first(where: { r in
            covers(r.countryCode) && r.to < today
                && (validFrom.map { r.from >= $0 } ?? true)
                && (validTo.map { r.to <= $0 } ?? true)
        }) {
            return VisaUsage(source: .manualRange, from: r.from, to: r.to)
        }
        return nil
    }
}

struct DocumentPeriod: Codable, Equatable, Identifiable {
    var id: String { renewedAt }
    let validFrom: String?
    let validTo: String?
    let renewedAt: String
}

/// Чем подтверждено, что однократная виза потрачена
struct VisaUsage: Equatable {
    enum Source { case flag, entry, manualRange }
    let source: Source
    let from: String?
    let to: String?

    /// «Used · 3 – 17 Mar 2026» / «Used · entered 3 Mar 2026» / «Used»
    var label: String {
        switch (from, to) {
        case let (f?, t?): return String(localized: "Used · \(prettyDate(f)) – \(prettyDate(t))")
        case let (f?, nil): return String(localized: "Used · entered \(prettyDate(f))")
        case let (nil, t?): return String(localized: "Used · since \(prettyDate(t))")
        default: return String(localized: "Used")
        }
    }
}

enum EntryBasis: String, Codable, CaseIterable, Identifiable {
    case citizen, visa_free, visa, residence, transit, other
    var id: String { rawValue }

    var title: String {
        switch self {
        case .citizen: return String(localized: "Citizen")
        case .visa_free: return String(localized: "Visa-free")
        case .visa: return String(localized: "Visa")
        case .residence: return String(localized: "Residence permit")
        case .transit: return String(localized: "Transit")
        case .other: return String(localized: "Other")
        }
    }

    var systemImage: String {
        switch self {
        case .citizen: return "person.crop.circle"
        case .visa_free: return "checkmark.seal"
        case .visa: return "doc.text"
        case .residence: return "house"
        case .transit: return "airplane"
        case .other: return "questionmark.circle"
        }
    }
}

enum EntryKind: String, Codable {
    case arrival
    case statusChange = "switch"
}

struct Entry: Codable, Identifiable, Equatable {
    let id: String
    let countryCode: String
    let date: String
    var kind: EntryKind?
    var isSwitch: Bool { kind == .statusChange }
    var basis: EntryBasis
    var documentId: String?
    var note: String?
    let createdAt: String
    let updatedAt: String
}

// MARK: - Режимы въезда (безвиз)

enum ConstraintType: String, Codable, CaseIterable, Identifiable {
    case perEntry, rolling, calendarYear, fromDate
    var id: String { rawValue }

    var title: String {
        switch self {
        case .perEntry: return String(localized: "Per entry")
        case .rolling: return String(localized: "In a rolling window")
        case .calendarYear: return String(localized: "Per calendar year")
        case .fromDate: return String(localized: "From a date")
        }
    }
}

enum ConditionKind: String, Codable, CaseIterable, Identifiable {
    case registration, passportValidity, insurance, funds, ticket, other
    var id: String { rawValue }

    var title: String {
        switch self {
        case .registration: return String(localized: "Registration")
        case .passportValidity: return String(localized: "Passport validity")
        case .insurance: return String(localized: "Insurance")
        case .funds: return String(localized: "Proof of funds")
        case .ticket: return String(localized: "Return ticket")
        case .other: return String(localized: "Other")
        }
    }

    var systemImage: String {
        switch self {
        case .registration: return "building.columns"
        case .passportValidity: return "person.text.rectangle"
        case .insurance: return "cross.case"
        case .funds: return "banknote"
        case .ticket: return "airplane.departure"
        case .other: return "checklist"
        }
    }
}

enum RegimeRequirement: String, Codable, CaseIterable, Identifiable {
    case visa_free, e_visa, visa_on_arrival, visa_required, unknown
    var id: String { rawValue }

    var title: String {
        switch self {
        case .visa_free: return String(localized: "Visa-free")
        case .e_visa: return String(localized: "E-visa")
        case .visa_on_arrival: return String(localized: "Visa on arrival")
        case .visa_required: return String(localized: "Visa required")
        case .unknown: return String(localized: "Unknown")
        }
    }

    var allowsEntry: Bool { [.visa_free, .e_visa, .visa_on_arrival].contains(self) }
}

struct RegimeConstraint: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var type: ConstraintType
    var limitDays: Int
    var windowDays: Int?
    var startDate: String?
    var note: String?

    var summary: String {
        switch type {
        case .perEntry: return String(localized: "\(pluralDays(limitDays)) per entry")
        case .rolling: return String(localized: "\(pluralDays(limitDays)) in any \(windowDays ?? 0) days")
        case .calendarYear: return String(localized: "\(pluralDays(limitDays)) per calendar year")
        case .fromDate: return String(localized: "\(pluralDays(limitDays)) from \(startDate.map(prettyDate) ?? "—")")
        }
    }
}

struct RegimeCondition: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var kind: ConditionKind
    var text: String
    var withinDays: Int?
    /// для passportValidity: сколько месяцев паспорт должен действовать на момент въезда
    var months: Int?
    var done: Bool = false
}

struct RegimeSource: Codable, Identifiable, Equatable {
    var id: String { url }
    let url: String
    let title: String?
    let official: Bool
    let quote: String?
}

struct RegimeVersion: Codable, Identifiable, Equatable {
    let id: String
    var requirement: RegimeRequirement
    var constraints: [RegimeConstraint]
    var conditions: [RegimeCondition]
    var sources: [RegimeSource]
    var origin: String
    var model: String?
    var notes: String?
    let effectiveFrom: String
    let effectiveTo: String?
    let confirmedAt: String
    /// проверка нейросетью, из которой версия применена автоматически
    var checkId: String?
}

struct Regime: Codable, Identifiable, Equatable {
    let id: String
    let passportId: String
    let passportCode: String
    let countryCode: String
    var active: RegimeVersion?
    var history: [RegimeVersion]
    var lastCheckedAt: String?
    let createdAt: String
    let updatedAt: String

    /// Версия, действовавшая в указанную дату — для истории поездок
    func version(on date: String) -> RegimeVersion? {
        if let a = active, a.effectiveFrom <= date { return a }
        return history.last { $0.effectiveFrom <= date && ($0.effectiveTo ?? "9999") > date }
    }
}

// Черновик нейросети
struct RegimeDraft: Codable, Equatable {
    var requirement: RegimeRequirement
    var constraints: [RegimeConstraint]
    var conditions: [RegimeCondition]
    var sources: [RegimeSource]
    let summary: String
    let asOf: String?
    let recentChange: String?
    let confidence: String
}

enum CheckStatus: String, Codable { case queued, running, done, failed }

struct RegimeCheck: Codable, Identifiable, Equatable {
    let id: String
    let passportCode: String
    let countryCode: String
    let lang: String
    let status: CheckStatus
    let model: String
    let requestedAt: String
    let finishedAt: String?
    let draft: RegimeDraft?
    let error: String?
}

struct RegimeDiff: Codable, Equatable {
    let changed: Bool
    let added: [String]
    let removed: [String]
    let requirementChanged: String?
}

struct RegimeInfoResponse: Codable {
    let aiEnabled: Bool
    let isCitizen: Bool
    let regime: Regime?
    let stale: Bool
    let cachedCheck: RegimeCheck?
    let documents: [TravelDocument]
}

// Что уходит на сервер при подтверждении версии
struct RegimeVersionInput: Codable, Identifiable {
    var id: String { "\(requirement.rawValue)|\(constraints.map(\.id).joined())|\(origin)" }
    var requirement: RegimeRequirement
    var constraints: [RegimeConstraint]
    var conditions: [RegimeCondition]
    var sources: [RegimeSource]
    var origin: String
    var model: String?
    var notes: String?
    var lang: String = DocumentInput.currentLang
}

// MARK: - Ручные записи

/// Город из справочника GeoNames на сервере
struct CityOption: Codable, Identifiable, Hashable {
    let id: Int
    let name: String
    let region: String?
    let lat: Double
    let lon: Double
    let population: Int
    // перевод на язык приложения из справочника; nil — нет
    let localized: String?
}

// Ручная запись "был в стране с ... по ...": сервер сам склеивает дни в периоды (GET /overrides/ranges)
struct ManualRange: Codable, Identifiable, Equatable {
    var id: String { "\(from)-\(to)-\(countryCode)" }
    let from: String
    let to: String
    let countryCode: String
    let countryName: String?
    let city: String?
    let note: String?

    let days: Int
}

private let isoDayFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.timeZone = TimeZone(identifier: "UTC")
    return f
}()

func daysBetween(_ a: String, _ b: String) -> Int? {
    guard let da = isoDayFormatter.date(from: a), let db = isoDayFormatter.date(from: b) else { return nil }
    return Int((db.timeIntervalSince(da) / 86_400).rounded())
}

// MARK: - Правила подсчёта

enum RuleType: String, Codable, CaseIterable, Identifiable {
    case calendarYear, rolling, fromDate, absence
    var id: String { rawValue }

    var title: String {
        switch self {
        case .calendarYear: return String(localized: "Calendar year")
        case .rolling: return String(localized: "Rolling window")
        case .fromDate: return String(localized: "From a date")
        case .absence: return String(localized: "Days away")
        }
    }

    var hint: String {
        switch self {
        case .calendarYear: return String(localized: "Counts days from January 1 to December 31.")
        case .rolling: return String(localized: "In any N consecutive days (for example, 90 out of 180 for Schengen).")
        case .fromDate: return String(localized: "A fixed period starting on a chosen date — for example, a visa term.")
        case .absence: return String(localized: "Counts consecutive days spent outside the selected countries — a residence permit obligation not to be away longer than N days.")
        }
    }
}

enum RuleMode: String, Codable, CaseIterable, Identifiable {
    case limit, goal
    var id: String { rawValue }
    var title: String { self == .limit ? String(localized: "Limit") : String(localized: "Goal") }
}

enum CountMode: String, Codable, CaseIterable, Identifiable {
    case any, primary
    var id: String { rawValue }
    var title: String { self == .any ? String(localized: "Any presence") : String(localized: "Main country of the day") }
}

// То, что редактируется и отправляется на сервер
struct RuleInput: Codable, Equatable {
    var name: String
    var enabled: Bool = true
    var type: RuleType
    var countries: [String]
    var limitDays: Int
    var windowDays: Int?
    var startDate: String?
    // fromDate: дата въезда определяется по данным — начало текущего непрерывного пребывания
    var autoStart: Bool = false
    var mode: RuleMode = .limit
    var countMode: CountMode = .any
    var warnRemainingDays: Int?
    var notify: Bool = true
    var sortOrder: Int = 0
    var validUntil: String?
}

struct Rule: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    var enabled: Bool
    var type: RuleType
    var countries: [String]
    var limitDays: Int
    var windowDays: Int?
    var startDate: String?
    var autoStart: Bool
    var mode: RuleMode
    var countMode: CountMode
    var warnRemainingDays: Int?
    var notify: Bool
    var sortOrder: Int
    var validUntil: String?
    // правило создано из документа (визы / ВНЖ) или режима въезда; customized — пользователь его переписал
    var documentId: String?
    var documentRole: String?
    var regimeId: String?
    var constraintId: String?
    var validFrom: String?
    var customized: Bool?
    let createdAt: String
    let updatedAt: String

    var isFromDocument: Bool { documentId != nil }
    var isCustomized: Bool { customized ?? false }

    var input: RuleInput {
        RuleInput(
            name: name, enabled: enabled, type: type, countries: countries, limitDays: limitDays,
            windowDays: windowDays, startDate: startDate, autoStart: autoStart, mode: mode, countMode: countMode,
            warnRemainingDays: warnRemainingDays, notify: notify, sortOrder: sortOrder, validUntil: validUntil
        )
    }
}

enum RuleStatus: String, Codable {
    case ok, warning, exceeded, reached
}

struct RuleResult: Codable, Identifiable, Equatable {
    var id: String { ruleId }
    let ruleId: String
    let name: String
    let mode: RuleMode
    let type: RuleType
    let countries: [String]
    let notify: Bool
    let warnRemainingDays: Int?
    struct Stay: Codable, Equatable {
        let from: String
        let to: String
        let days: Int
    }

    let autoStart: Bool
    let documentId: String?
    let regimeId: String?
    let validFrom: String?
    let validUntil: String?
    let entryDate: String?
    let inCountry: Bool?
    let lastStay: Stay?
    let periodStart: String
    let periodEnd: String
    let used: Int
    let limit: Int
    let remaining: Int
    let canStayDays: Int?
    let reachable: Bool?
    let status: RuleStatus
}

enum RulePresets {
    static let schengen = [
        "AT", "BE", "BG", "HR", "CZ", "DK", "EE", "FI", "FR", "DE", "GR", "HU", "IS", "IT", "LV",
        "LI", "LT", "LU", "MT", "NL", "NO", "PL", "PT", "RO", "SK", "SI", "ES", "SE", "CH",
    ]

    struct Preset: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let input: RuleInput
    }

    static var all: [Preset] {
        [
            Preset(
                id: "schengen", title: String(localized: "Schengen 90/180"), subtitle: String(localized: "No more than 90 days in any 180"),
                input: RuleInput(name: String(localized: "Schengen 90/180"), type: .rolling, countries: schengen, limitDays: 90, windowDays: 180, warnRemainingDays: 10)
            ),
            Preset(
                id: "residency", title: String(localized: "Tax residency"), subtitle: String(localized: "183 days per calendar year"),
                input: RuleInput(name: String(localized: "Residency"), type: .calendarYear, countries: [], limitDays: 183, mode: .goal)
            ),
            Preset(
                id: "georgia", title: String(localized: "Georgia visa-free 365"), subtitle: String(localized: "365 days from entry, resets when you leave"),
                input: RuleInput(name: String(localized: "Georgia visa-free"), type: .fromDate, countries: ["GE"], limitDays: 365, windowDays: 365, autoStart: true, warnRemainingDays: 30)
            ),
            Preset(
                id: "visa", title: String(localized: "Visa from entry date"), subtitle: String(localized: "N days from entering the country"),
                input: RuleInput(name: String(localized: "Visa"), type: .fromDate, countries: [], limitDays: 30, windowDays: 90, autoStart: true, warnRemainingDays: 5)
            ),
            Preset(
                id: "uk", title: String(localized: "United Kingdom 180/365"), subtitle: String(localized: "No more than 180 days in any 365"),
                input: RuleInput(name: String(localized: "UK 180/365"), type: .rolling, countries: ["GB"], limitDays: 180, windowDays: 365, warnRemainingDays: 15)
            ),
        ]
    }

    static func todayString() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }
}

struct UploadResult: Codable {
    let inserted: Int
    let skipped: Int
}

// MARK: - Аккаунт

enum AuthProvider: String, Codable, CaseIterable {
    case apple, google

    var title: String {
        switch self {
        case .apple: return "Apple"
        case .google: return "Google"
        }
    }
}

struct User: Codable, Equatable {
    struct Providers: Codable, Equatable {
        let apple: Bool
        let google: Bool

        func has(_ p: AuthProvider) -> Bool { p == .apple ? apple : google }
    }

    let id: String
    let email: String?
    let name: String?
    let providers: Providers
    let createdAt: String
}

struct SignInResponse: Codable {
    let token: String
    let user: User
    let created: Bool
    let autoLinked: Bool
}

// MARK: - Вспомогательное

extension String {
    /// "GE" -> "🇬🇪"
    var flagEmoji: String {
        let base: UInt32 = 127397
        return uppercased().unicodeScalars.compactMap { scalar in
            UnicodeScalar(base + scalar.value).map(String.init)
        }.joined()
    }

}

