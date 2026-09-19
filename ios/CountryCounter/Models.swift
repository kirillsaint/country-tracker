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
    let countryCode: String
    let countryName: String?
    let city: String?
    let since: String
    let daysInRow: Int
    let daysThisYear: Int
    let lastSeen: String
}

struct Segment: Codable, Identifiable, Hashable {
    var id: String { "\(from)-\(countryCode)" }
    let countryCode: String
    let countryName: String?
    let city: String?
    let from: String
    let to: String
    let days: Int
}

struct CityStat: Codable, Identifiable, Hashable {
    var id: String { "\(countryCode)|\(city)" }
    let city: String
    let countryCode: String
    let countryName: String?
    let days: Int
    let firstDay: String
    let lastDay: String
}

// MARK: - Ручные записи

struct DayOverride: Codable, Identifiable, Equatable {
    var id: String { localDate }
    let localDate: String
    let countryCode: String
    let countryName: String?
    let city: String?
    let note: String?
    let createdAt: String
}

// Подряд идущие правки с одинаковой страной/городом/заметкой — одна запись "с ... по ..."
struct ManualRange: Identifiable, Equatable {
    var id: String { "\(from)-\(to)-\(countryCode)" }
    let from: String
    let to: String
    let countryCode: String
    let countryName: String?
    let city: String?
    let note: String?

    var days: Int { (daysBetween(from, to) ?? 0) + 1 }

    static func group(_ overrides: [DayOverride]) -> [ManualRange] {
        let sorted = overrides.sorted { $0.localDate < $1.localDate }
        var out: [ManualRange] = []
        for o in sorted {
            if let last = out.last,
               last.countryCode == o.countryCode, last.city == o.city, last.note == o.note,
               daysBetween(last.to, o.localDate) == 1 {
                out[out.count - 1] = ManualRange(from: last.from, to: o.localDate, countryCode: last.countryCode, countryName: last.countryName, city: last.city, note: last.note)
            } else {
                out.append(ManualRange(from: o.localDate, to: o.localDate, countryCode: o.countryCode, countryName: o.countryName, city: o.city, note: o.note))
            }
        }
        return out.reversed()
    }
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
    case calendarYear, rolling, fromDate
    var id: String { rawValue }

    var title: String {
        switch self {
        case .calendarYear: return "Календарный год"
        case .rolling: return "Скользящее окно"
        case .fromDate: return "С даты"
        }
    }

    var hint: String {
        switch self {
        case .calendarYear: return "Считаются дни с 1 января по 31 декабря."
        case .rolling: return "В любые N подряд идущих дней (например, 90 из 180 для Шенгена)."
        case .fromDate: return "Фиксированный период с выбранной даты — например, срок визы."
        }
    }
}

enum RuleMode: String, Codable, CaseIterable, Identifiable {
    case limit, goal
    var id: String { rawValue }
    var title: String { self == .limit ? "Лимит" : "Цель" }
}

enum CountMode: String, Codable, CaseIterable, Identifiable {
    case any, primary
    var id: String { rawValue }
    var title: String { self == .any ? "Любой заход" : "Основная страна дня" }
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
    var mode: RuleMode = .limit
    var countMode: CountMode = .any
    var warnRemainingDays: Int?
    var notify: Bool = true
    var sortOrder: Int = 0
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
    var mode: RuleMode
    var countMode: CountMode
    var warnRemainingDays: Int?
    var notify: Bool
    var sortOrder: Int
    let createdAt: String
    let updatedAt: String

    var input: RuleInput {
        RuleInput(
            name: name, enabled: enabled, type: type, countries: countries, limitDays: limitDays,
            windowDays: windowDays, startDate: startDate, mode: mode, countMode: countMode,
            warnRemainingDays: warnRemainingDays, notify: notify, sortOrder: sortOrder
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

    static let all: [Preset] = [
        Preset(
            id: "schengen", title: "Шенген 90/180", subtitle: "Не больше 90 дней в любые 180",
            input: RuleInput(name: "Шенген 90/180", type: .rolling, countries: schengen, limitDays: 90, windowDays: 180, warnRemainingDays: 10)
        ),
        Preset(
            id: "residency", title: "Налоговое резидентство", subtitle: "183 дня за календарный год",
            input: RuleInput(name: "Резидентство", type: .calendarYear, countries: [], limitDays: 183, mode: .goal)
        ),
        Preset(
            id: "visa-free-365", title: "Безвиз 365 дней", subtitle: "Например, Грузия: 365 дней в году",
            input: RuleInput(name: "Безвиз", type: .rolling, countries: [], limitDays: 365, windowDays: 365, warnRemainingDays: 30)
        ),
        Preset(
            id: "visa", title: "Виза с даты въезда", subtitle: "N дней с конкретной даты",
            input: RuleInput(name: "Виза", type: .fromDate, countries: [], limitDays: 30, windowDays: 90, startDate: todayString(), warnRemainingDays: 5)
        ),
        Preset(
            id: "uk", title: "Великобритания 180/365", subtitle: "Не больше 180 дней в любые 365",
            input: RuleInput(name: "UK 180/365", type: .rolling, countries: ["GB"], limitDays: 180, windowDays: 365, warnRemainingDays: 15)
        ),
    ]

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

    /// Локализованное имя страны по ISO-коду, с фолбэком на имя с сервера.
    func countryDisplayName(fallback: String?) -> String {
        Locale.current.localizedString(forRegionCode: self) ?? fallback ?? self
    }
}

func pluralDays(_ n: Int) -> String {
    let mod10 = n % 10, mod100 = n % 100
    if mod10 == 1 && mod100 != 11 { return "\(n) день" }
    if (2...4).contains(mod10) && !(12...14).contains(mod100) { return "\(n) дня" }
    return "\(n) дней"
}
