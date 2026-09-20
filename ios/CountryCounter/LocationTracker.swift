import CoreLocation
import Foundation
import UIKit
import os

// Единственный источник точек. Три канала:
//  1. Visit monitoring — iOS сама сообщает "приехал в место / уехал". Почти не ест батарею.
//  2. Significant location changes — переезды на ~500 м+ / смена соты. Ловит смену города/страны.
//  3. Одиночные запросы — раз в час из BGAppRefreshTask и при открытии приложения.
// Для 1 и 2 iOS поднимет приложение в фоне даже если его выгрузили, поэтому трекер
// стартует в init() App.
final class LocationTracker: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = LocationTracker()

    struct Event: Identifiable, Equatable {
        let id = UUID()
        let date: Date
        let text: String
    }

    @Published private(set) var authorization: CLAuthorizationStatus = .notDetermined
    @Published private(set) var recentEvents: [Event] = []
    @Published private(set) var lastPoint: PendingPoint?

    private let manager = CLLocationManager()
    private let geocoder = CLGeocoder()
    private let log = Logger(subsystem: "ge.kirillsaint.stamps", category: "location")

    private var oneShot: (source: PendingPoint.Source, continuation: CheckedContinuation<Bool, Never>)?
    private var lastSignificantAt: Date?

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.pausesLocationUpdatesAutomatically = false
        manager.showsBackgroundLocationIndicator = false
    }

    // MARK: - Управление

    func start() {
        authorization = manager.authorizationStatus
        startMonitoringIfAuthorized()
    }

    func requestPermission() {
        // Если разрешения ещё нет, iOS покажет диалог "при использовании", а запрос на
        // "всегда" всплывёт сам позже. Если уже есть "при использовании" — сразу спросит "всегда".
        manager.requestAlwaysAuthorization()
    }

    var hasAlwaysPermission: Bool { authorization == .authorizedAlways }
    var hasAnyPermission: Bool { authorization == .authorizedAlways || authorization == .authorizedWhenInUse }

    private func startMonitoringIfAuthorized() {
        guard hasAnyPermission else { return }
        manager.allowsBackgroundLocationUpdates = true
        if CLLocationManager.significantLocationChangeMonitoringAvailable() {
            manager.startMonitoringSignificantLocationChanges()
        }
        manager.startMonitoringVisits()
        note(String(localized: "Monitoring started"))
    }

    /// Запросить одну точку (для ежечасного BGTask и кнопки "записать сейчас").
    /// Возвращает false, если не удалось за разумное время.
    @MainActor
    func requestOneShot(source: PendingPoint.Source) async -> Bool {
        guard hasAnyPermission else { return false }
        if oneShot != nil { return false }
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask { @MainActor in
                await withCheckedContinuation { cont in
                    self.oneShot = (source, cont)
                    self.manager.requestLocation()
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(25))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            await MainActor.run {
                if let pending = self.oneShot {
                    self.oneShot = nil
                    pending.continuation.resume(returning: false)
                }
            }
            return first
        }
    }

    /// При открытии приложения записываем точку, но не чаще раза в 30 минут.
    @MainActor
    func recordForegroundIfNeeded() async {
        if let last = AppSettings.lastForegroundPointAt, Date().timeIntervalSince(last) < 30 * 60 { return }
        if await requestOneShot(source: .foreground) {
            AppSettings.lastForegroundPointAt = Date()
        }
    }

    // MARK: - CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorization = manager.authorizationStatus
        note(String(localized: "Permission: \(authorization.label)"))
        startMonitoringIfAuthorized()
    }

    func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        let arrival = visit.arrivalDate == .distantPast ? nil : visit.arrivalDate
        let departure = visit.departureDate == .distantFuture ? nil : visit.departureDate
        // При отъезде фиксируем момент отъезда: так закрывается интервал пребывания.
        let recordedAt = min(departure ?? arrival ?? Date(), Date())
        let location = CLLocation(
            coordinate: visit.coordinate,
            altitude: 0,
            horizontalAccuracy: visit.horizontalAccuracy,
            verticalAccuracy: -1,
            timestamp: recordedAt
        )
        note(departure == nil ? String(localized: "Visit: arrived") : String(localized: "Visit: departed"))
        record(location, source: .visit, arrival: arrival, departure: departure)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }

        if let pending = oneShot {
            oneShot = nil
            note(String(localized: "Point on request (\(pending.source.rawValue))"))
            record(location, source: pending.source, arrival: nil, departure: nil)
            pending.continuation.resume(returning: true)
            return
        }

        // Significant changes иногда приходят пачкой — не плодим точки чаще, чем раз в 5 минут.
        if let last = lastSignificantAt, Date().timeIntervalSince(last) < 5 * 60 { return }
        lastSignificantAt = Date()
        note(String(localized: "Significant location change"))
        record(location, source: .significant, arrival: nil, departure: nil)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        log.error("location error: \(error.localizedDescription)")
        note(String(localized: "Error: \(error.localizedDescription)"))
        if let pending = oneShot {
            oneShot = nil
            pending.continuation.resume(returning: false)
        }
    }

    // MARK: - Запись точки

    private func record(_ location: CLLocation, source: PendingPoint.Source, arrival: Date?, departure: Date?) {
        // Если нас подняли в фоне, у нас есть секунд десять. Просим ещё немного на геокодинг и сеть.
        let bgTask = UIApplication.shared.beginBackgroundTask(withName: "record-point")
        Task { @MainActor in
            defer { UIApplication.shared.endBackgroundTask(bgTask) }

            var point = PendingPoint(
                clientId: UUID().uuidString,
                lat: location.coordinate.latitude,
                lon: location.coordinate.longitude,
                accuracy: location.horizontalAccuracy >= 0 ? location.horizontalAccuracy : nil,
                recordedAt: location.timestamp,
                tzOffsetMin: TimeZone.current.secondsFromGMT(for: location.timestamp) / 60,
                source: source,
                arrivalAt: arrival,
                departureAt: departure,
                city: nil,
                region: nil,
                deviceId: UIDevice.current.identifierForVendor?.uuidString
            )

            if let placemark = await reverseGeocode(location) {
                point.city = placemark.locality ?? placemark.subAdministrativeArea
                point.region = placemark.administrativeArea
            }

            await PendingQueue.shared.enqueue(point)
            lastPoint = point
            log.info("queued \(source.rawValue) point \(point.city ?? "?")")
            await Uploader.flush()
        }
    }

    // Страну сервер определит сам по координатам; с устройства нужен только город. Best-effort.
    private func reverseGeocode(_ location: CLLocation) async -> CLPlacemark? {
        await withTaskGroup(of: CLPlacemark?.self) { group in
            group.addTask { [geocoder] in
                try? await geocoder.reverseGeocodeLocation(location).first
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(8))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private func note(_ text: String) {
        let event = Event(date: Date(), text: text)
        Task { @MainActor in
            recentEvents.insert(event, at: 0)
            if recentEvents.count > 50 { recentEvents.removeLast() }
        }
    }
}

extension CLAuthorizationStatus {
    var label: String {
        switch self {
        case .notDetermined: return String(localized: "not requested")
        case .restricted: return String(localized: "restricted")
        case .denied: return String(localized: "denied")
        case .authorizedAlways: return String(localized: "always")
        case .authorizedWhenInUse: return String(localized: "while using")
        @unknown default: return String(localized: "unknown")
        }
    }
}
