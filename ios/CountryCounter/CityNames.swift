import CoreLocation
import Foundation
import Observation

// Перевод названий городов на язык приложения. В базе города хранятся по-английски (так их отдаёт
// геокодер и так они группируются), а показываются на языке телефона. Офлайн-справочника городов
// в iOS нет, поэтому перевод спрашиваем у геокодера по одному разу и кэшируем навсегда.
// Пока перевода нет — показывается английское имя, строка обновится сама, когда он придёт.
@MainActor
@Observable
final class CityNames {
    static let shared = CityNames()

    /// «язык|страна|город в нижнем регистре» → перевод
    private(set) var names: [String: String]

    @ObservationIgnored private var queue: [Item] = []
    @ObservationIgnored private var queued: Set<String> = []
    @ObservationIgnored private var running = false

    private struct Item { let key: String; let city: String; let country: String; let lang: String }

    private static let storeKey = "cityNamesCache"
    /// Язык приложения; для английского перевод не нужен
    static var lang: String { Locale.current.language.languageCode?.identifier ?? "en" }

    private init() {
        names = UserDefaults.standard.dictionary(forKey: Self.storeKey) as? [String: String] ?? [:]
    }

    /// Имя города для показа. Неизвестное — ставит в очередь на перевод и пока возвращает как есть.
    func display(_ city: String?, country: String) -> String? {
        guard let city, !city.isEmpty, city != "—" else { return city }
        let lang = Self.lang
        guard lang != "en" else { return city }
        let key = "\(lang)|\(country)|\(city.lowercased())"
        if let known = names[key] { return known }
        if !queued.contains(key) {
            queued.insert(key)
            queue.append(Item(key: key, city: city, country: country, lang: lang))
            // не трогаем наблюдаемое состояние из body — очередь двигаем следующим тиком
            Task { @MainActor in self.pump() }
        }
        return city
    }

    private func pump() {
        guard !running, !queue.isEmpty else { return }
        running = true
        let item = queue.removeFirst()
        Task { @MainActor in
            if let translated = await Self.lookup(city: item.city, country: item.country, lang: item.lang) {
                names[item.key] = translated
                UserDefaults.standard.set(names, forKey: Self.storeKey)
            } else {
                // не нашли или нет сети: в этом запуске больше не спрашиваем, в следующем попробуем снова
            }
            // геокодер не любит частые запросы — пауза между ними
            try? await Task.sleep(for: .seconds(1))
            running = false
            pump()
        }
    }

    /// Спросить у геокодера имя города на нужном языке. Результат берём, только если он в той же стране.
    private static func lookup(city: String, country: String, lang: String) async -> String? {
        let countryEn = Locale(identifier: "en_US").localizedString(forRegionCode: country) ?? country
        let geocoder = CLGeocoder()
        let placemarks = try? await geocoder.geocodeAddressString("\(city), \(countryEn)", in: nil, preferredLocale: Locale(identifier: lang))
        guard let p = placemarks?.first, p.isoCountryCode?.uppercased() == country.uppercased() else { return nil }
        let name = p.locality ?? p.subAdministrativeArea ?? p.name
        guard let name, !name.isEmpty else { return nil }
        return name
    }

    /// Каноническое английское имя для ручного ввода («Дубай» → «Dubai»), чтобы город группировался
    /// с точками с устройства. Не нашли — оставляем как ввели.
    static func canonicalEnglish(_ typed: String, country: String) async -> String {
        let trimmed = typed.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return trimmed }
        return await lookup(city: trimmed, country: country, lang: "en_US") ?? trimmed
    }
}

// MARK: - Словарь на сервере

extension CityNames {
    /// Забрать переводы городов из истории с сервера (справочник GeoNames). Сервер — источник истины:
    /// его имена перекрывают то, что раньше угадал геокодер. Вызывается при каждом обновлении данных.
    func sync() async {
        let lang = Self.lang
        guard lang != "en", let client = try? APIClient.fromSettings() else { return }
        guard let remote = try? await client.cityNames(lang: lang) else { return }
        var changed = false
        for (key, localized) in remote where names["\(lang)|\(key)"] != localized {
            names["\(lang)|\(key)"] = localized
            changed = true
        }
        if changed { UserDefaults.standard.set(names, forKey: Self.storeKey) }
    }

    /// Запомнить перевод, пришедший вместе с результатом поиска, чтобы выбранный город сразу показывался по-русски
    func remember(country: String, name: String, localized: String?) {
        guard let localized, Self.lang != "en" else { return }
        let key = "\(Self.lang)|\(country)|\(name.lowercased())"
        guard names[key] != localized else { return }
        names[key] = localized
        UserDefaults.standard.set(names, forKey: Self.storeKey)
    }
}

// MARK: - Починка старых записей

extension CityNames {
    private static let repairedKey = "cityNamesRepaired"

    /// Города, записанные не латиницей (например «Дубай» от геокодера на русском языке телефона),
    /// один раз переименовываются в английские во всей истории на сервере. Возвращает, было ли что-то переименовано.
    static func repairNonLatin(_ cities: [CityStat]) async -> Bool {
        var done = Set(UserDefaults.standard.stringArray(forKey: repairedKey) ?? [])
        var changed = false
        var seen = Set<String>()
        for c in cities {
            let key = "\(c.countryCode)|\(c.city)"
            guard c.city != "—", !done.contains(key), seen.insert(key).inserted, isNonLatin(c.city) else { continue }
            let english = await canonicalEnglish(c.city, country: c.countryCode)
            if english != c.city, !isNonLatin(english) {
                if let n = try? await APIClient.fromSettings().renameCity(countryCode: c.countryCode, from: c.city, to: english), n > 0 {
                    changed = true
                }
            }
            // и удачу, и неудачу запоминаем — не долбить геокодер при каждом запуске
            done.insert(key)
            UserDefaults.standard.set(Array(done), forKey: repairedKey)
        }
        return changed
    }

    /// Есть ли в названии буквы не латинского алфавита (кириллица, арабица и т.п.)
    static func isNonLatin(_ s: String) -> Bool {
        s.range(of: "[^\\p{Latin}\\p{Common}\\p{Inherited}]", options: .regularExpression) != nil
    }
}

extension String {
    /// Город на языке приложения (см. CityNames)
    @MainActor
    func cityDisplayName(country: String) -> String {
        CityNames.shared.display(self, country: country) ?? self
    }
}
