import Foundation
import UserNotifications
import os

// Локальные уведомления по правилам: "осталось N дней", "лимит исчерпан", "цель достигнута".
// Проверка запускается после каждого обновления статистики — и из приложения, и из фона
// после отправки точек. Чтобы не спамить, помним, о каком значении уже сообщали.
enum RuleNotifier {
    private static let log = Logger(subsystem: "ge.kirillsaint.countrycounter", category: "notify")
    private static let stateKey = "ruleNotifierState"

    static func requestPermission() async -> Bool {
        let center = UNUserNotificationCenter.current()
        if let granted = try? await center.requestAuthorization(options: [.alert, .sound, .badge]) {
            return granted
        }
        return false
    }

    static func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// Загрузить результаты с сервера и оценить. Для фона, где нет AppModel.
    static func check() async {
        guard let client = try? APIClient.fromSettings(), let results = try? await client.ruleResults() else { return }
        await evaluate(results)
    }

    static func evaluate(_ results: [RuleResult]) async {
        guard AppSettings.notificationsEnabled else { return }
        guard await authorizationStatus() == .authorized else { return }

        // ruleId -> последнее значение remaining, о котором уведомляли
        var state = UserDefaults.standard.dictionary(forKey: stateKey) as? [String: Int] ?? [:]
        let activeIds = Set(results.map(\.ruleId))
        state = state.filter { activeIds.contains($0.key) }

        for r in results where r.notify {
            let shouldNotify: Bool
            switch r.status {
            case .ok:
                state[r.ruleId] = nil
                continue
            case .warning, .exceeded, .reached:
                // Уведомляем, когда состояние впервые стало тревожным или remaining уменьшился
                shouldNotify = state[r.ruleId].map { r.remaining < $0 } ?? true
            }
            guard shouldNotify else { continue }
            state[r.ruleId] = r.remaining
            schedule(for: r)
        }

        UserDefaults.standard.set(state, forKey: stateKey)
    }

    // MARK: документы

    private static let docStateKey = "documentNotifierState"

    /// Напоминания об истечении паспортов, виз и ВНЖ: за 30 дней, за 7 дней и в день истечения — по разу.
    static func evaluateDocuments(_ docs: [TravelDocument]) async {
        guard AppSettings.notificationsEnabled, await authorizationStatus() == .authorized else { return }
        var state = UserDefaults.standard.dictionary(forKey: docStateKey) as? [String: Int] ?? [:]
        let ids = Set(docs.map(\.id))
        state = state.filter { ids.contains($0.key) }
        for d in docs {
            guard let left = d.daysUntilExpiry else { continue }
            let stage = left <= 0 ? 3 : left <= 7 ? 2 : left <= 30 ? 1 : 0
            guard stage > 0, (state[d.id] ?? 0) < stage else { continue }
            state[d.id] = stage
            let content = UNMutableNotificationContent()
            content.title = d.name
            content.sound = .default
            content.body = left <= 0
                ? String(localized: "Expired on \(prettyFullDate(d.validTo ?? "")).")
                : String(localized: "Expires in \(pluralDays(left)) — \(prettyFullDate(d.validTo ?? "")).")
            let request = UNNotificationRequest(identifier: "doc-\(d.id)-\(stage)", content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request) { error in
                if let error { log.error("document notification failed: \(error.localizedDescription)") }
            }
        }
        UserDefaults.standard.set(state, forKey: docStateKey)
    }

    private static func schedule(for r: RuleResult) {
        let content = UNMutableNotificationContent()
        content.title = r.name
        content.sound = .default
        switch r.status {
        case .exceeded:
            content.body = String(localized: "The limit of \(pluralDays(r.limit)) is used up: \(r.used) used.")
        case .reached:
            content.body = String(localized: "Goal reached: \(pluralDays(r.used)) of \(r.limit).")
        case .warning:
            if let stay = r.canStayDays {
                content.body = String(localized: "\(pluralDays(r.remaining)) of \(r.limit) left. You can stay \(pluralDays(stay)) more in a row.")
            } else {
                content.body = String(localized: "\(pluralDays(r.remaining)) of \(r.limit) left.")
            }
        case .ok:
            return
        }
        let request = UNNotificationRequest(identifier: "rule-\(r.ruleId)-\(r.status.rawValue)-\(r.remaining)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { log.error("notification failed: \(error.localizedDescription)") }
        }
    }
}
