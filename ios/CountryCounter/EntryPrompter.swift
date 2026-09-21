import Foundation
import UIKit
import UserNotifications
import WidgetKit
import os

extension Notification.Name {
    /// Основание въезда задано из уведомления — экранам пора обновиться
    static let entryBasisChanged = Notification.Name("entryBasisChanged")
}

// Вариант ответа на "как въехали?" — общий для уведомления и экрана в приложении
struct EntryOption: Identifiable, Equatable {
    let basis: EntryBasis
    let document: TravelDocument?
    /// "как в прошлый раз"
    let isRepeat: Bool
    /// безвиз, условия которого давно не проверялись — предложить перепроверку
    var recheck: Bool = false

    var id: String { "\(basis.rawValue)|\(document?.id ?? "")|\(isRepeat)|\(recheck)" }

    var title: String {
        var t = basis.title
        if let document, basis != .citizen, basis != .transit, basis != .other {
            t += " \(document.countryCode.flagEmoji)"
        }
        if isRepeat { t = String(localized: "Same as last time: \(t)") }
        if recheck { t = String(localized: "\(t) · re-check rules") }
        return t
    }

    /// Все применимые к стране варианты в порядке вероятности
    static func options(for country: String, documents: [TravelDocument], previous: CurrentStatus.EntryRef?) -> [EntryOption] {
        var out: [EntryOption] = []
        if let previous, previous.basis != .transit, previous.basis != .other {
            let doc = documents.first { $0.id == previous.documentId }
            if previous.documentId == nil || doc != nil {
                out.append(EntryOption(basis: previous.basis, document: doc, isRepeat: true))
            }
        }
        let passports = documents.filter { $0.kind == .passport }
        for p in passports where p.countryCode == country { out.append(EntryOption(basis: .citizen, document: p, isRepeat: false)) }
        for d in documents where d.kind == .residence && d.covers(country) { out.append(EntryOption(basis: .residence, document: d, isRepeat: false)) }
        for d in documents where d.kind == .visa && d.covers(country) { out.append(EntryOption(basis: .visa, document: d, isRepeat: false)) }
        for p in passports where p.countryCode != country { out.append(EntryOption(basis: .visa_free, document: p, isRepeat: false)) }
        if passports.isEmpty { out.append(EntryOption(basis: .visa_free, document: nil, isRepeat: false)) }
        out.append(EntryOption(basis: .transit, document: nil, isRepeat: false))
        out.append(EntryOption(basis: .other, document: nil, isRepeat: false))
        // без дублей (повтор может совпасть с обычным вариантом)
        var seen = Set<String>()
        return out.filter { seen.insert("\($0.basis.rawValue)|\($0.document?.id ?? "")").inserted }
    }
}

// Спрашивает "как въехали?" уведомлением с кнопками, как только сервер сообщил о пребывании
// без основания. Один раз на (страна, дата въезда).
@MainActor
enum EntryPrompter {
    private static let log = Logger(subsystem: "ge.kirillsaint.stamps", category: "entry")
    private static let promptedKey = "entryPromptedKey"
    private static let categoryPrefix = "entry-basis|"

    /// Фоновый путь: после отправки точек — узнать, не появилась ли новая страна
    static func check() async {
        guard let client = try? APIClient.fromSettings() else { return }
        guard let current = try? await client.current(), current.needsEntryBasis else { return }
        let documents = (try? await client.documents()) ?? []
        await promptIfNeeded(current: current, documents: documents)
    }

    static func promptIfNeeded(current: CurrentStatus, documents: [TravelDocument]) async {
        guard current.needsEntryBasis else { return }
        let key = "\(current.countryCode)|\(current.since)"
        guard UserDefaults.standard.string(forKey: promptedKey) != key else { return }
        guard await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .authorized else { return }
        UserDefaults.standard.set(key, forKey: promptedKey)

        // До четырёх кнопок: самое вероятное сверху, транзит и "другое" — всегда.
        // Если режим безвиза для страны не проверялся дольше порога — кнопка безвиза заодно запускает перепроверку.
        let stale = current.regime?.stale ?? true
        var picks = EntryOption.options(for: current.countryCode, documents: documents, previous: current.previousEntry).map { o in
            var o = o
            if o.basis == .visa_free, stale { o.recheck = true }
            return o
        }
        let tail = picks.filter { $0.basis == .transit || $0.basis == .other }
        picks = Array(picks.filter { $0.basis != .transit && $0.basis != .other }.prefix(2)) + tail
        picks = Array(picks.prefix(4))

        let actions = picks.map { o in
            UNNotificationAction(
                identifier: "\(o.basis.rawValue)|\(o.document?.id ?? "")|\(o.recheck ? "check" : "")",
                title: o.title,
                options: o.basis == .other ? [.foreground] : []
            )
        }
        let categoryId = categoryPrefix + key
        let category = UNNotificationCategory(identifier: categoryId, actions: actions, intentIdentifiers: [], options: [])
        let center = UNUserNotificationCenter.current()
        let existing = await center.notificationCategories().filter { !$0.identifier.hasPrefix(categoryPrefix) }
        center.setNotificationCategories(existing.union([category]))

        let content = UNMutableNotificationContent()
        let country = current.countryCode.countryDisplayName(fallback: current.countryName)
        content.title = String(localized: "You’re in \(country)")
        content.body = String(localized: "How did you enter? This sets the stay-limit rule.")
        content.sound = .default
        content.categoryIdentifier = categoryId
        content.userInfo = ["country": current.countryCode, "since": current.since]
        let request = UNNotificationRequest(identifier: "entry-\(key)", content: content, trigger: nil)
        do {
            try await center.add(request)
            log.info("entry prompt scheduled for \(key)")
        } catch {
            log.error("entry prompt failed: \(error.localizedDescription)")
        }
    }

    /// Ответ на кнопку уведомления
    static func handle(_ response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let country = info["country"] as? String, let since = info["since"] as? String else { return }
        let parts = response.actionIdentifier.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count >= 2, let basis = EntryBasis(rawValue: String(parts[0])) else { return }
        let documentId = parts[1].isEmpty ? nil : String(parts[1])
        let recheck = parts.count >= 3 && parts[2] == "check"
        // "Другое…" открывает приложение — там пользователь выберет сам
        if basis == .other {
            Router.shared.pending = .entryBasis(country: country)
            return
        }

        guard let client = try? APIClient.fromSettings() else { return }
        do {
            _ = try await client.setEntry(countryCode: country, date: since, basis: basis, documentId: documentId, note: nil)
            // Безвиз: запустить проверку условий нейросетью (в фоне); результат придёт уведомлением
            if basis == .visa_free, let documentId, recheck {
                let check = try await client.startRegimeCheck(passportId: documentId, country: country, force: false)
                RegimeChecks.remember(check, passportId: documentId)
            }
            NotificationCenter.default.post(name: .entryBasisChanged, object: nil)
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            log.error("entry basis from notification failed: \(error.localizedDescription)")
        }
    }
}

// Делегат уведомлений: показывать баннер в открытом приложении и обрабатывать кнопки
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        // Тап по самому уведомлению (не по кнопке) — открыть нужный экран
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            if info["regimeCheck"] != nil, let country = info["country"] as? String {
                await MainActor.run { Router.shared.pending = .regime(country: country, passportId: info["passportId"] as? String) }
                return
            }
            if info["since"] != nil, let country = info["country"] as? String {
                await MainActor.run { Router.shared.pending = .entryBasis(country: country) }
                return
            }
            if let placeId = info["ratePlace"] as? String {
                await MainActor.run { Router.shared.pending = .ratePlace(id: placeId, name: info["placeName"] as? String ?? "") }
                return
            }
            return
        }
        await EntryPrompter.handle(response)
    }
}
