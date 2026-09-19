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
    var overrides: [DayOverride] = []
    var manualRanges: [ManualRange] { ManualRange.group(overrides) }
    // Для карты "за всё время" — грузится при первом открытии карты и обновляется вместе с остальным
    var allTimeCountries: [CountryStat] = []
    var allTimeCities: [CityStat] = []
    private var allTimeLoaded = false
    var pendingCount = 0
    var isLoading = false
    var errorMessage: String?
    var lastRefresh: Date?

    func refresh() async {
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
            async let timeline = client.timeline()
            async let rules = client.rules()
            async let ruleResults = client.ruleResults()
            async let overrides = client.overrides()
            self.current = try await current
            self.countries = try await countries
            self.cities = try await cities
            self.timeline = try await timeline
            self.rules = try await rules
            self.ruleResults = try await ruleResults
            self.overrides = try await overrides
            errorMessage = nil
            lastRefresh = Date()
            if allTimeLoaded { await loadAllTime() }
            publishWidgetSnapshot()
            await RuleNotifier.evaluate(self.ruleResults)
        } catch {
            errorMessage = error.localizedDescription
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
        do { try await save(input, id: rule.id) } catch { errorMessage = error.localizedDescription }
    }

    func delete(_ rule: Rule) async {
        do {
            try await APIClient.fromSettings().deleteRule(id: rule.id)
            rules.removeAll { $0.id == rule.id }
            ruleResults.removeAll { $0.ruleId == rule.id }
        } catch {
            errorMessage = error.localizedDescription
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
            current: current.map {
                WidgetSnapshot.Current(countryCode: $0.countryCode, countryName: $0.countryName, city: $0.city,
                                       since: $0.since, daysInRow: $0.daysInRow, daysThisYear: $0.daysThisYear)
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
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Ручные записи

    func addRange(from: String, to: String, countryCode: String, city: String?, note: String?) async throws {
        try await APIClient.fromSettings().setRange(from: from, to: to, countryCode: countryCode, city: city, note: note)
        await refresh()
    }

    func delete(_ range: ManualRange) async {
        do {
            try await APIClient.fromSettings().deleteRange(from: range.from, to: range.to)
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
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
