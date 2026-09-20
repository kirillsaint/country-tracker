import Foundation
import UserNotifications
import os

// Проверки режима нейросетью идут на сервере в фоне; приложение помнит запущенные и, когда результат
// готов, показывает уведомление "Готово: Турция — проверить". Опрос — при каждом обновлении данных
// (в том числе фоновом) и в самом экране режима, пока он открыт.
enum RegimeChecks {
    private static let log = Logger(subsystem: "ge.kirillsaint.stamps", category: "regime-check")
    private static let pendingKey = "pendingRegimeChecks"

    struct Pending: Codable, Equatable {
        let checkId: String
        let passportId: String
        let countryCode: String
        let startedAt: Date
    }

    static var pending: [Pending] {
        get { (UserDefaults.standard.data(forKey: pendingKey)).flatMap { try? JSONDecoder().decode([Pending].self, from: $0) } ?? [] }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: pendingKey) }
    }

    static func remember(_ check: RegimeCheck, passportId: String) {
        guard check.status == .queued || check.status == .running else { return }
        var list = pending.filter { $0.checkId != check.id }
        list.append(Pending(checkId: check.id, passportId: passportId, countryCode: check.countryCode, startedAt: Date()))
        pending = list
    }

    /// Проверить запущенные; готовые — снять и уведомить
    static func processPending() async {
        let list = pending
        guard !list.isEmpty, let client = try? APIClient.fromSettings() else { return }
        var remaining: [Pending] = []
        for p in list {
            guard let (check, diff) = try? await client.regimeCheck(id: p.checkId, passportId: p.passportId) else {
                remaining.append(p)
                continue
            }
            switch check.status {
            case .queued, .running:
                // зависшие дольше получаса забываем
                if Date().timeIntervalSince(p.startedAt) < 30 * 60 { remaining.append(p) }
            case .done:
                notify(check: check, diff: diff, passportId: p.passportId)
            case .failed:
                notifyFailure(check: check)
            }
        }
        pending = remaining
    }

    private static func notify(check: RegimeCheck, diff: RegimeDiff?, passportId: String) {
        let country = check.countryCode.countryDisplayName(fallback: nil)
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Entry rules: \(country)")
        if let diff, !diff.changed {
            content.body = String(localized: "Checked — no changes. Tap to see the sources.")
        } else if let d = check.draft {
            let parts = d.constraints.map(\.summary)
            content.body = parts.isEmpty
                ? String(localized: "Research finished — review the result.")
                : String(localized: "Found: \(parts.joined(separator: ", ")). Review and confirm.")
        } else {
            content.body = String(localized: "Research finished — review the result.")
        }
        content.sound = .default
        content.userInfo = ["regimeCheck": check.id, "country": check.countryCode, "passportId": passportId]
        add(content, id: "regime-check-\(check.id)")
    }

    private static func notifyFailure(check: RegimeCheck) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Entry rules: \(check.countryCode.countryDisplayName(fallback: nil))")
        content.body = String(localized: "Automatic research failed. You can fill the rules in by hand.")
        add(content, id: "regime-check-failed-\(check.id)")
    }

    private static func add(_ content: UNMutableNotificationContent, id: String) {
        Task {
            guard await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .authorized else { return }
            try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        }
    }
}
