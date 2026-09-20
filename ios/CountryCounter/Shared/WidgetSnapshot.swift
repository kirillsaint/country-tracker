import Foundation

// Снимок данных для виджетов. Приложение пишет его в контейнер App Group после каждого
// обновления статистики; виджет (отдельный процесс без сети и без Keychain) только читает.
// Файл общий для таргетов приложения и виджета.
struct WidgetSnapshot: Codable, Equatable {
    struct Current: Codable, Equatable {
        let countryCode: String
        let countryName: String?
        let city: String?
        let since: String
        let daysInRow: Int
        let daysThisYear: Int
    }

    struct Rule: Codable, Equatable, Identifiable {
        let id: String
        let name: String
        let mode: RuleMode
        let countries: [String]
        let used: Int
        let limit: Int
        let remaining: Int
        let canStayDays: Int?
        let status: RuleStatus
        let periodEnd: String
        let inCountry: Bool?
    }

    /// Дата "сегодня" (YYYY-MM-DD, местная), на которую посчитаны дни — виджет добавляет прошедшие сутки сам
    let today: String
    let generatedAt: Date
    let current: Current?
    let rules: [Rule]
    let countriesThisYear: Int
    let countriesAllTime: Int

    static let appGroup = "group.ge.kirillsaint.stamps.shared"
    static let fileName = "widget-snapshot.json"

    static var fileURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent(fileName)
    }

    static func load() -> WidgetSnapshot? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(WidgetSnapshot.self, from: data)
    }

    func save() {
        guard let url = Self.fileURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(self) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Сколько полных суток прошло с момента снимка — на столько выросли "дней подряд" и "в этом году",
    /// если человек никуда не уехал (а если уехал, приложение проснётся и перепишет снимок).
    func daysElapsed(asOf date: Date = Date()) -> Int {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        guard let snapshotDay = f.date(from: today) else { return 0 }
        let todayDay = f.date(from: f.string(from: date)) ?? date
        return max(0, Int((todayDay.timeIntervalSince(snapshotDay) / 86_400).rounded()))
    }
}
