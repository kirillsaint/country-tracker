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

    private static func schedule(for r: RuleResult) {
        let content = UNMutableNotificationContent()
        content.title = r.name
        content.sound = .default
        switch r.status {
        case .exceeded:
            content.body = "Лимит \(pluralDays(r.limit)) исчерпан: использовано \(r.used)."
        case .reached:
            content.body = "Цель достигнута: \(pluralDays(r.used)) из \(r.limit)."
        case .warning:
            var body = "Осталось \(pluralDays(r.remaining)) из \(r.limit)."
            if let stay = r.canStayDays { body += " Можно остаться ещё \(pluralDays(stay)) подряд." }
            content.body = body
        case .ok:
            return
        }
        let request = UNNotificationRequest(identifier: "rule-\(r.ruleId)-\(r.status.rawValue)-\(r.remaining)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { log.error("notification failed: \(error.localizedDescription)") }
        }
    }
}
