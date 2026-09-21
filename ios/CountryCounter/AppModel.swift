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
            self.current = try await current
            self.countries = try await countries
            self.cities = try await cities
            self.timeline = try await timeline
            self.rules = try await rules
            self.ruleResults = try await ruleResults
            self.manualRanges = try await manualRanges
            self.documents = try await documents
            self.entries = try await entries
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
        return doc
        await refreshRuleResults()
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
            ?? Segment(countryCode: c.countryCode, countryName: c.countryName, city: c.city, from: c.since, to: c.lastSeen, days: c.daysInRow)
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
