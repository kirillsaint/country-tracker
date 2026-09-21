import CoreLocation
import Foundation
import UserNotifications
import os

// После визита в рекомендованное или сохранённое место — вопрос «как вам?» уведомлением.
// Работает от мониторинга визитов iOS: уезжаем из точки, которая ближе 120 м к известному месту,
// пробыв там хотя бы 25 минут — значит, скорее всего, были внутри.
@MainActor
enum PlaceVisits {
    private static let log = Logger(subsystem: "ge.kirillsaint.stamps", category: "places")
    private static let knownKey = "placeVisits.known"
    private static let askedKey = "placeVisits.asked"

    struct Known: Codable { let id: String; let name: String; let lat: Double; let lon: Double }

    /// Запомнить места, о которых стоит спросить (последние рекомендации + сохранённые), не больше 60
    static func remember(_ places: [Known]) {
        var list = (try? JSONDecoder().decode([Known].self, from: UserDefaults.standard.data(forKey: knownKey) ?? Data())) ?? []
        for p in places where !list.contains(where: { $0.id == p.id }) { list.append(p) }
        if list.count > 60 { list.removeFirst(list.count - 60) }
        UserDefaults.standard.set(try? JSONEncoder().encode(list), forKey: knownKey)
    }

    static func forget(_ id: String) {
        var list = (try? JSONDecoder().decode([Known].self, from: UserDefaults.standard.data(forKey: knownKey) ?? Data())) ?? []
        list.removeAll { $0.id == id }
        UserDefaults.standard.set(try? JSONEncoder().encode(list), forKey: knownKey)
    }

    private static let nearbyKey = "placeVisits.nearbyAsked"

    /// Проходим в 300 м от сохранённого места — короткое напоминание, не чаще раза в 3 дня на место.
    /// Только сохранённые (не подборки): о них человек явно сказал «хочу сюда».
    static func checkNearby(coordinate: CLLocationCoordinate2D, saved: [Known]) {
        guard !saved.isEmpty else { return }
        let here = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        var asked = (UserDefaults.standard.dictionary(forKey: nearbyKey) as? [String: Double]) ?? [:]
        let now = Date().timeIntervalSince1970
        for p in saved where here.distance(from: CLLocation(latitude: p.lat, longitude: p.lon)) <= 300 {
            if let last = asked[p.id], now - last < 3 * 86_400 { continue }
            asked[p.id] = now
            let content = UNMutableNotificationContent()
            content.title = String(localized: "\(p.name) is nearby")
            content.body = String(localized: "You saved it for later — it’s about 300 m away.")
            content.sound = .default
            content.userInfo = ["openPlace": p.id]
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "place-near-\(p.id)", content: content, trigger: nil)) { error in
                if let error { log.error("nearby prompt failed: \(error.localizedDescription)") }
            }
            log.info("nearby saved place: \(p.name)")
        }
        UserDefaults.standard.set(asked, forKey: nearbyKey)
    }

    /// Сохранённые места хранятся отдельно от «известных», чтобы напоминать только о них
    private static let savedKey = "placeVisits.saved"
    static func rememberSaved(_ places: [Known]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(places), forKey: savedKey)
    }
    static var savedList: [Known] {
        (try? JSONDecoder().decode([Known].self, from: UserDefaults.standard.data(forKey: savedKey) ?? Data())) ?? []
    }

    /// Вызывается из LocationTracker при завершённом визите
    static func check(coordinate: CLLocationCoordinate2D, arrival: Date?, departure: Date?) {
        guard let arrival, let departure, departure.timeIntervalSince(arrival) >= 25 * 60 else { return }
        let list = (try? JSONDecoder().decode([Known].self, from: UserDefaults.standard.data(forKey: knownKey) ?? Data())) ?? []
        guard !list.isEmpty else { return }
        let here = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        guard let hit = list.min(by: { here.distance(from: CLLocation(latitude: $0.lat, longitude: $0.lon)) < here.distance(from: CLLocation(latitude: $1.lat, longitude: $1.lon)) }),
              here.distance(from: CLLocation(latitude: hit.lat, longitude: hit.lon)) <= 120 else { return }
        var asked = UserDefaults.standard.stringArray(forKey: askedKey) ?? []
        guard !asked.contains(hit.id) else { return }
        asked.append(hit.id)
        UserDefaults.standard.set(Array(asked.suffix(200)), forKey: askedKey)

        let content = UNMutableNotificationContent()
        content.title = String(localized: "How was \(hit.name)?")
        content.body = String(localized: "Rate it — the recommendations get better with every rating.")
        content.sound = .default
        content.userInfo = ["ratePlace": hit.id, "placeName": hit.name]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "place-rate-\(hit.id)", content: content, trigger: nil)) { error in
            if let error { log.error("place rating prompt failed: \(error.localizedDescription)") }
        }
        log.info("asked to rate \(hit.name)")
    }
}
