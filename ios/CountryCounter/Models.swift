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
    // координаты для карты; nil у городов, известных только из ручных записей
    let lat: Double?
    let lon: Double?
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
        case .calendarYear: return String(localized: "Calendar year")
        case .rolling: return String(localized: "Rolling window")
        case .fromDate: return String(localized: "From a date")
        }
    }

    var hint: String {
        switch self {
        case .calendarYear: return String(localized: "Counts days from January 1 to December 31.")
        case .rolling: return String(localized: "In any N consecutive days (for example, 90 out of 180 for Schengen).")
        case .fromDate: return String(localized: "A fixed period starting on a chosen date — for example, a visa term.")
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
    let createdAt: String
    let updatedAt: String

    var input: RuleInput {
        RuleInput(
            name: name, enabled: enabled, type: type, countries: countries, limitDays: limitDays,
            windowDays: windowDays, startDate: startDate, autoStart: autoStart, mode: mode, countMode: countMode,
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
    struct Stay: Codable, Equatable {
        let from: String
        let to: String
        let days: Int
    }

    let autoStart: Bool
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

