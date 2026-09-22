import CoreLocation
import Foundation
import Observation
import WidgetKit

// Состояние экранов: всё, что приходит с сервера, плюс размер локальной очереди.
@MainActor
@Observable
final class AppModel {
    var current: CurrentStatus?
    var countries: [CountryStat] = []
    var cities: [CityStat] = []
    var timeline: [Segment] = []
    var rules: [Rule] = []
    var ruleResults: [RuleResult] = []
    var manualRanges: [ManualRange] = []

    /// Сборка в Self Store новее установленной — показать предложение обновиться
    var availableUpdate: APIClient.AppUpdate?
    @ObservationIgnored private var lastUpdateCheck: Date?

    /// Спросить сервер о новой версии. При запуске — всегда; при возврате из фона — не чаще раза в час,
    /// чтобы не дёргать при каждом переключении приложений. Ошибки молча: обновление не критично.
    func checkForUpdate(force: Bool = false) async {
        if !force, let last = lastUpdateCheck, Date().timeIntervalSince(last) < 3600 { return }
        lastUpdateCheck = Date()
        guard let client = try? APIClient.fromSettings(), let update = try? await client.checkUpdate() else { return }
        availableUpdate = update
    }

    // «Чем заняться»
    var discoverEnabled = false
    var recommendations: [Recommendation] = []
    var discoverSummary: String?
    /// Быстрая подборка уже показана, нейросеть ещё выбирает и объясняет места
    var discoverRefining = false
    var weather: Weather?
    var itinerary: Itinerary?
    /// nil — тест ещё не проходили
    var taste: TastePreferences?
    var tasteLoaded = false
    var savedPlaces: [PlaceSave] = []
    var ratedPlaces: [PlaceRating] = []
    var documents: [TravelDocument] = []
    var entries: [Entry] = []
    var regimes: [Regime] = []
    var aiEnabled = true
    var regimeFreshDays = 30
    // Для карты "за всё время" — грузится при первом открытии карты и обновляется вместе с остальным
    var allTimeCountries: [CountryStat] = []
    var allTimeCities: [CityStat] = []
    private var allTimeLoaded = false
    var pendingCount = 0
    var isLoading = false
    var errorMessage: String?
    var lastRefresh: Date?

    /// Сервер ещё ни разу не ответил — экраны показывают скелетоны вместо пустых состояний
    var showSkeleton: Bool { lastRefresh == nil && errorMessage == nil }

    /// Показать ошибку в плашке. Отмены запросов (их перебило следующее обновление) не показываем.
    private func report(_ error: Error) {
        if error.isCancellation { return }
        errorMessage = error.localizedDescription
    }

    private var refreshTask: Task<Void, Never>?

    /// Полное обновление. Параллельные вызовы (смена сцены, pull-to-refresh, уведомление) ждут одну
    /// и ту же загрузку: иначе отмена одного из вызывающих Task обрывала запросы и на экране
    /// появлялась «ошибка» «отменено».
    func refresh() async {
        if let running = refreshTask {
            await running.value
            return
        }
        let task = Task { await performRefresh() }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    private func performRefresh() async {
        loadDiscoverCache()
        pendingCount = await PendingQueue.shared.count()
        guard let client = try? APIClient.fromSettings() else {
            errorMessage = nil
            return
        }
        isLoading = true
        defer { isLoading = false }

        do {
            async let current = client.current()
            async let countries = client.countries()
            async let cities = client.cities()
            async let timeline = client.timeline(from: Self.allTimeFrom)
            async let rules = client.rules()
            async let ruleResults = client.ruleResults()
            async let manualRanges = client.manualRanges()
            async let documents = client.documents()
            async let entries = client.entries()
            async let regimes = client.regimes()
            async let discoverEnabled = client.discoverEnabled()
            async let savedPlaces = client.savedPlaces()
            async let ratedPlaces = client.ratedPlaces()
            async let taste = client.taste()
            self.current = try await current
            self.countries = try await countries
            self.cities = try await cities
            self.timeline = try await timeline
            self.rules = try await rules
            self.ruleResults = try await ruleResults
            self.manualRanges = try await manualRanges
            self.documents = try await documents
            self.entries = try await entries
            self.discoverEnabled = (try? await discoverEnabled) ?? false
            self.savedPlaces = (try? await savedPlaces) ?? []
            self.ratedPlaces = (try? await ratedPlaces) ?? []
            // try? схлопывает двойной optional: «тест не пройден» (nil) тоже успешный ответ
            do { self.taste = try await taste; self.tasteLoaded = true } catch {}
            PlaceVisits.remember(self.savedPlaces.map { PlaceVisits.Known(id: $0.placeId, name: $0.name, lat: $0.lat, lon: $0.lon) })
            PlaceVisits.rememberSaved(self.savedPlaces.map { PlaceVisits.Known(id: $0.placeId, name: $0.name, lat: $0.lat, lon: $0.lon) })
            let reg = try await regimes
            self.regimes = reg.regimes
            self.aiEnabled = reg.aiEnabled
            self.regimeFreshDays = reg.freshDays
            errorMessage = nil
            lastRefresh = Date()
            // данные изменились — годовые срезы пересчитаются при следующем обращении
            yearStatsCache.removeAll()
            if allTimeLoaded { await loadAllTime() }
            publishWidgetSnapshot()
            await RuleNotifier.evaluate(self.ruleResults)
            await RuleNotifier.evaluateDocuments(self.documents, used: usedVisaIds)
            if let now = self.current { await EntryPrompter.promptIfNeeded(current: now, documents: self.documents) }
            await RegimeChecks.processPending()
            // переводы городов: забираем общий словарь с сервера, отдаём свои
            await CityNames.shared.sync()
            // старые записи с городами не латиницей приводим к английскому и перечитываем данные
            // (performRefresh, а не refresh: тот ждёт текущую задачу и заблокировал бы сам себя)
            if await CityNames.repairNonLatin(self.cities + self.allTimeCities) { await performRefresh() }
            RuleNotifier.scheduleConditionReminders(current: self.current, regimes: self.regimes)
        } catch {
            report(error)
        }
        pendingCount = await PendingQueue.shared.count()
    }

    // MARK: - Правила

    func rule(id: String) -> Rule? { rules.first { $0.id == id } }

    func save(_ input: RuleInput, id: String?) async throws {
        let client = try APIClient.fromSettings()
        if let id {
            let updated = try await client.updateRule(id: id, input)
            if let i = rules.firstIndex(where: { $0.id == id }) { rules[i] = updated } else { rules.append(updated) }
        } else {
            rules.append(try await client.createRule(input))
        }
        await refreshRuleResults()
    }

    func setEnabled(_ rule: Rule, _ enabled: Bool) async {
        var input = rule.input
        input.enabled = enabled
        do { try await save(input, id: rule.id) } catch { report(error) }
    }

    func delete(_ rule: Rule) async {
        do {
            try await APIClient.fromSettings().deleteRule(id: rule.id)
            rules.removeAll { $0.id == rule.id }
            ruleResults.removeAll { $0.ruleId == rule.id }
        } catch {
            report(error)
        }
    }

    // MARK: - Документы и въезды

    func document(id: String?) -> TravelDocument? {
        guard let id else { return nil }
        return documents.first { $0.id == id }
    }

    var passports: [TravelDocument] { documents.filter { $0.kind == .passport } }

    /// Потрачена ли однократная виза — по флагу, основанию въезда или ручной записи о поездке
    func visaUsage(_ doc: TravelDocument) -> VisaUsage? {
        doc.usage(entries: entries, ranges: manualRanges, current: current)
    }

    var usedVisaIds: Set<String> { Set(documents.filter { visaUsage($0) != nil }.map(\.id)) }

    @discardableResult
    func saveDocument(_ input: DocumentInput, id: String?) async throws -> TravelDocument {
        let client = try APIClient.fromSettings()
        let (doc, generated): (TravelDocument, [Rule])
        if let id {
            (doc, generated) = try await client.updateDocument(id: id, input)
            if let i = documents.firstIndex(where: { $0.id == id }) { documents[i] = doc } else { documents.append(doc) }
        } else {
            (doc, generated) = try await client.createDocument(input)
            documents.append(doc)
        }
        // правила документа пересобраны на сервере — заменяем их в локальном списке
        rules.removeAll { $0.documentId == doc.id }
        rules.append(contentsOf: generated)
        await refreshRuleResults()
        return doc
    }

    func deleteDocument(_ doc: TravelDocument) async {
        do {
            try await APIClient.fromSettings().deleteDocument(id: doc.id)
            documents.removeAll { $0.id == doc.id }
            rules.removeAll { $0.documentId == doc.id }
            ruleResults.removeAll { $0.documentId == doc.id }
            for i in entries.indices where entries[i].documentId == doc.id { entries[i].documentId = nil }
        } catch {
            report(error)
        }
    }

    func resetRule(_ rule: Rule) async throws {
        let restored = try await APIClient.fromSettings().resetRule(id: rule.id)
        if let i = rules.firstIndex(where: { $0.id == rule.id }) { rules[i] = restored }
        await refreshRuleResults()
    }

    // MARK: - Режимы въезда

    func regime(passportId: String, country: String) -> Regime? {
        regimes.first { $0.passportId == passportId && $0.countryCode == country }
    }

    func confirmRegime(passportId: String, country: String, _ input: RegimeVersionInput) async throws -> (Regime, Bool) {
        let (regime, generated, changed) = try await APIClient.fromSettings().confirmRegime(passportId: passportId, country: country, input)
        if let i = regimes.firstIndex(where: { $0.id == regime.id }) { regimes[i] = regime } else { regimes.append(regime) }
        // правила режима на сервере пересобраны: старые версии выключены, новые созданы
        rules.removeAll { $0.regimeId == regime.id && $0.enabled }
        rules.append(contentsOf: generated)
        await refreshRuleResults()
        return (regime, changed)
    }

    func deleteRegime(_ regime: Regime) async {
        do {
            try await APIClient.fromSettings().deleteRegime(id: regime.id)
            regimes.removeAll { $0.id == regime.id }
            rules.removeAll { $0.regimeId == regime.id }
            ruleResults.removeAll { $0.regimeId == regime.id }
        } catch {
            report(error)
        }
    }

    func setCondition(_ regime: Regime, _ condition: RegimeCondition, done: Bool) async {
        do {
            let updated = try await APIClient.fromSettings().setCondition(regimeId: regime.id, conditionId: condition.id, done: done)
            if let i = regimes.firstIndex(where: { $0.id == regime.id }) { regimes[i] = updated }
        } catch {
            report(error)
        }
    }

    /// Отрезок текущего пребывания — для листа "как въехали?" с главного экрана
    var currentSegment: Segment? {
        guard let c = current else { return nil }
        return timeline.first { $0.countryCode == c.countryCode && $0.from == c.since }
            ?? Segment(countryCode: c.countryCode, countryName: c.countryName, city: c.city, cities: nil, stops: nil, from: c.since, to: c.lastSeen, days: c.daysInRow)
    }

    func entry(for segment: Segment) -> Entry? {
        entries.first { $0.countryCode == segment.countryCode && $0.date == segment.from && !$0.isSwitch }
    }

    /// Смены статуса внутри отрезка (после дня въезда), по дате
    func switches(for segment: Segment) -> [Entry] {
        entries
            .filter { $0.countryCode == segment.countryCode && $0.isSwitch && $0.date > segment.from && $0.date <= segment.to }
            .sorted { $0.date < $1.date }
    }

    func renewDocument(_ document: TravelDocument, validFrom: String?, validTo: String) async throws {
        let (doc, generated) = try await APIClient.fromSettings().renewDocument(id: document.id, validFrom: validFrom, validTo: validTo)
        if let i = documents.firstIndex(where: { $0.id == doc.id }) { documents[i] = doc } else { documents.append(doc) }
        rules.removeAll { $0.documentId == doc.id }
        rules.append(contentsOf: generated)
    }

    func setEntry(countryCode: String, date: String, basis: EntryBasis, documentId: String?, note: String?, kind: EntryKind = .arrival) async throws {
        let e = try await APIClient.fromSettings().setEntry(countryCode: countryCode, date: date, basis: basis, documentId: documentId, note: note, kind: kind)
        entries.removeAll { $0.countryCode == countryCode && $0.date == date }
        entries.insert(e, at: 0)
    }

    func deleteEntry(countryCode: String, date: String) async throws {
        try await APIClient.fromSettings().deleteEntry(countryCode: countryCode, date: date)
        entries.removeAll { $0.countryCode == countryCode && $0.date == date }
    }

    // MARK: - Статистика по годам

    private var yearStatsCache: [Int?: YearStats] = [:]
    private var yearStatsLoading: Set<Int?> = []

    /// Годы, за которые есть хоть какие-то данные (по всей хронологии), новые сверху. Текущий — всегда.
    var availableYears: [Int] {
        var years = Set<Int>([Calendar.current.component(.year, from: Date())])
        for s in timeline {
            if let a = Int(s.from.prefix(4)), let b = Int(s.to.prefix(4)) {
                for y in min(a, b)...max(a, b) { years.insert(y) }
            }
        }
        return years.sorted(by: >)
    }

    /// nil = за всё время
    func yearStats(for year: Int?) -> YearStats? { yearStatsCache[year] }

    func loadYearStats(for year: Int?) async {
        guard yearStatsCache[year] == nil, !yearStatsLoading.contains(year) else { return }
        guard let client = try? APIClient.fromSettings() else { return }
        yearStatsLoading.insert(year)
        defer { yearStatsLoading.remove(year) }
        let from = year.map { "\($0)-01-01" } ?? Self.allTimeFrom
        let to = year.map { "\($0)-12-31" }
        do {
            async let countries = client.countries(from: from, to: to)
            async let cities = client.cities(from: from, to: to)
            async let segments = client.timeline(from: from, to: to)
            yearStatsCache[year] = YearStats(year: year, countries: try await countries, cities: try await cities, segments: try await segments)
        } catch {
            report(error)
        }
    }

    // MARK: - Виджеты

    private func publishWidgetSnapshot() {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        let snapshot = WidgetSnapshot(
            today: f.string(from: Date()),
            generatedAt: Date(),
            current: current.map { c in
                WidgetSnapshot.Current(countryCode: c.countryCode, countryName: c.countryName, city: c.city?.cityDisplayName(country: c.countryCode),
                                       since: c.since, daysInRow: c.daysInRow, daysThisYear: c.daysThisYear)
            },
            rules: ruleResults.map {
                WidgetSnapshot.Rule(id: $0.ruleId, name: $0.name, mode: $0.mode, countries: $0.countries,
                                    used: $0.used, limit: $0.limit, remaining: $0.remaining, canStayDays: $0.canStayDays,
                                    status: $0.status, periodEnd: $0.periodEnd, inCountry: $0.inCountry)
            },
            countriesThisYear: countries.count,
            countriesAllTime: allTimeCountries.count
        )
        if snapshot != WidgetSnapshot.load() {
            snapshot.save()
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    // MARK: - Карта

    static let allTimeFrom = "1970-01-01"

    func loadAllTimeIfNeeded() async {
        guard !allTimeLoaded else { return }
        await loadAllTime()
    }

    private func loadAllTime() async {
        guard let client = try? APIClient.fromSettings() else { return }
        do {
            async let countries = client.countries(from: Self.allTimeFrom)
            async let cities = client.cities(from: Self.allTimeFrom)
            allTimeCountries = try await countries
            allTimeCities = try await cities
            allTimeLoaded = true
        } catch {
            report(error)
        }
    }

    // MARK: - Чем заняться

    /// Показывает быструю подборку сразу, а уточнение нейросетью (если сервер его запустил) ждёт в фоне
    /// и подменяет список, когда оно готово. Новый поиск отменяет ожидание предыдущего.
    func discover(lat: Double, lon: Double, query: String?, category: DiscoverCategory?, radiusKm: Double, openNow: Bool, onRefined: (@MainActor () -> Void)? = nil) async throws {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE HH:mm"
        let client = try APIClient.fromSettings()
        refineTask?.cancel()
        refineTask = nil
        discoverRefining = false
        let result = try await client.discover(lat: lat, lon: lon, query: query, category: category, radiusKm: radiusKm, openNow: openNow, localTime: f.string(from: Date()))
        apply(result)
        guard let jobId = result.jobId else { return }
        discoverRefining = true
        let task = Task { @MainActor [weak self] in
            defer { self?.discoverRefining = false }
            do {
                let refined: DiscoverResult = try await client.awaitJob(id: jobId, timeout: 120)
                guard !Task.isCancelled, let self else { return }
                self.apply(refined)
                onRefined?()
            } catch {
                // быстрая подборка уже на экране — тихо остаёмся с ней
            }
        }
        refineTask = task
    }

    private var refineTask: Task<Void, Never>?

    private func apply(_ result: DiscoverResult) {
        recommendations = result.recommendations
        discoverSummary = result.summary
        weather = result.weather
        PlaceVisits.remember(result.recommendations.map { PlaceVisits.Known(id: $0.id, name: $0.name, lat: $0.lat, lon: $0.lon) })
    }

    /// Подборка на главной без запроса: «удиви меня» рядом с текущей точкой, раз в 6 часов или при
    /// переезде дальше 2 км. Результат хранится локально, чтобы показаться сразу при следующем открытии.
    private struct DiscoverCache: Codable { let lat: Double; let lon: Double; let at: Date; let recommendations: [Recommendation]; let summary: String?; var weather: Weather? }
    private static let discoverCacheKey = "discoverCache"
    private var autoDiscovering = false

    func loadDiscoverCache() {
        guard recommendations.isEmpty, let data = UserDefaults.standard.data(forKey: Self.discoverCacheKey),
              let c = try? JSONDecoder().decode(DiscoverCache.self, from: data) else { return }
        recommendations = c.recommendations
        discoverSummary = c.summary
        if weather == nil { weather = c.weather }
    }

    func autoDiscoverIfNeeded(lat: Double, lon: Double) async {
        guard discoverEnabled, !autoDiscovering else { return }
        if let data = UserDefaults.standard.data(forKey: Self.discoverCacheKey), let c = try? JSONDecoder().decode(DiscoverCache.self, from: data) {
            let moved = CLLocation(latitude: lat, longitude: lon).distance(from: CLLocation(latitude: c.lat, longitude: c.lon))
            if Date().timeIntervalSince(c.at) < 6 * 3600, moved < 2000 { return }
        }
        autoDiscovering = true
        defer { autoDiscovering = false }
        do {
            let save: @MainActor () -> Void = { [weak self] in
                guard let self else { return }
                let cache = DiscoverCache(lat: lat, lon: lon, at: Date(), recommendations: recommendations, summary: discoverSummary, weather: weather)
                UserDefaults.standard.set(try? JSONEncoder().encode(cache), forKey: Self.discoverCacheKey)
            }
            // быстрая подборка сохраняется сразу, уточнённая — когда придёт
            try await discover(lat: lat, lon: lon, query: nil, category: .any, radiusKm: 3, openNow: false, onRefined: save)
            save()
        } catch {
            // тихо: подборка не критична, покажем прошлую или кнопку
        }
    }

    /// start — nil: через 15 минут; иначе выбранные дата и время (сервер получает дату, если она не сегодня)
    func buildItinerary(lat: Double, lon: Double, hours: Int, radiusKm: Double, note: String? = nil, start: Date? = nil) async throws {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE HH:mm"
        let hhmm = DateFormatter()
        hhmm.locale = Locale(identifier: "en_US_POSIX")
        hhmm.dateFormat = "HH:mm"
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        // без явного времени — старт через 15 минут, округлённый до четверти часа
        let startDate = start ?? Date().addingTimeInterval(15 * 60)
        let comps = Calendar.current.dateComponents([.hour, .minute], from: startDate)
        let rounded = Calendar.current.date(bySettingHour: comps.hour ?? 12, minute: ((comps.minute ?? 0) / 15) * 15, second: 0, of: startDate) ?? startDate
        let dateParam = Calendar.current.isDateInToday(rounded) ? nil : day.string(from: rounded)
        let result = try await APIClient.fromSettings().itinerary(lat: lat, lon: lon, hours: hours, startTime: hhmm.string(from: rounded), date: dateParam, radiusKm: radiusKm, localTime: f.string(from: rounded), note: note)
        itinerary = result
        if let w = result.weather { weather = w }
        PlaceVisits.remember(result.stops.map { PlaceVisits.Known(id: $0.place.id, name: $0.place.name, lat: $0.place.lat, lon: $0.place.lon) })
    }

    func saveTaste(_ p: TastePreferences) async throws {
        taste = try await APIClient.fromSettings().saveTaste(p)
        // подборка на главной пересобирается с учётом ответов
        UserDefaults.standard.removeObject(forKey: Self.discoverCacheKey)
    }

    func rating(for placeId: String) -> PlaceRating? { ratedPlaces.first { $0.placeId == placeId } }
    func isSaved(_ placeId: String) -> Bool { savedPlaces.contains { $0.placeId == placeId } }

    func rate(_ rating: PlaceRating) async throws {
        let saved = try await APIClient.fromSettings().ratePlace(rating)
        ratedPlaces.removeAll { $0.placeId == saved.placeId }
        ratedPlaces.insert(saved, at: 0)
        if let i = recommendations.firstIndex(where: { $0.id == saved.placeId }) { recommendations[i].user.stars = saved.stars }
    }

    func deleteRating(placeId: String) async throws {
        try await APIClient.fromSettings().deleteRating(placeId: placeId)
        ratedPlaces.removeAll { $0.placeId == placeId }
        if let i = recommendations.firstIndex(where: { $0.id == placeId }) { recommendations[i].user.stars = nil }
    }

    func toggleSave(_ p: Recommendation) async throws {
        let client = try APIClient.fromSettings()
        if isSaved(p.id) {
            try await client.unsavePlace(id: p.id)
            savedPlaces.removeAll { $0.placeId == p.id }
        } else {
            let s = try await client.savePlace(p, countryCode: current?.countryCode, city: current?.city)
            savedPlaces.insert(s, at: 0)
            PlaceVisits.remember([PlaceVisits.Known(id: p.id, name: p.name, lat: p.lat, lon: p.lon)])
        }
        if let i = recommendations.firstIndex(where: { $0.id == p.id }) { recommendations[i].user.saved = isSaved(p.id) }
    }

    func dismiss(_ p: Recommendation) async throws {
        try await APIClient.fromSettings().dismissPlace(id: p.id)
        recommendations.removeAll { $0.id == p.id }
        PlaceVisits.forget(p.id)
    }

    // MARK: - Ручные записи

    func addRange(from: String, to: String, countryCode: String, city: String?, note: String?) async throws {
        try await APIClient.fromSettings().setRange(from: from, to: to, countryCode: countryCode, city: city, note: note)
        await refresh()
    }

    /// Изменить запись: старый диапазон удаляется (только его страна), новый записывается
    func updateRange(_ old: ManualRange, from: String, to: String, countryCode: String, city: String?, note: String?) async throws {
        let client = try APIClient.fromSettings()
        try await client.deleteRange(from: old.from, to: old.to, countryCode: old.countryCode)
        try await client.setRange(from: from, to: to, countryCode: countryCode, city: city, note: note)
        await refresh()
    }

    func delete(_ range: ManualRange) async {
        do {
            try await APIClient.fromSettings().deleteRange(from: range.from, to: range.to, countryCode: range.countryCode)
            await refresh()
        } catch {
            report(error)
        }
    }

    private func refreshRuleResults() async {
        guard let client = try? APIClient.fromSettings() else { return }
        if let results = try? await client.ruleResults() {
            ruleResults = results
            await RuleNotifier.evaluate(results)
        }
    }
}
