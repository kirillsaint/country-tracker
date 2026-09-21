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
