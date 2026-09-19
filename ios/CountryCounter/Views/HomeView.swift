import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var model
    @ObservedObject private var tracker = LocationTracker.shared
    @AppStorage(AppSettings.showCountriesSectionKey) private var showCountries = true

    var body: some View {
        NavigationStack {
            List {
                if !tracker.hasAlwaysPermission {
                    permissionBanner
                }
                if let error = model.errorMessage {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }

                Section {
                    if let current = model.current {
                        currentCard(current)
                    } else {
                        ContentUnavailableView(
                            "Пока нет данных",
                            systemImage: "globe",
                            description: Text("Первая точка запишется автоматически. Или нажмите «Записать точку сейчас» в настройках.")
                        )
                    }
                }

                Section {
                    if model.ruleResults.isEmpty {
                        NavigationLink {
                            RulesView()
                        } label: {
                            Label("Добавить правило подсчёта", systemImage: "plus.circle")
                        }
                    }
                    ForEach(model.ruleResults) { result in
                        NavigationLink {
                            if let rule = model.rule(id: result.ruleId) {
                                RuleEditView(rule: rule)
                            }
                        } label: {
                            RuleCard(result: result)
                        }
                    }
                } header: {
                    HStack {
                        Text("Правила")
                        Spacer()
                        NavigationLink("Все") { RulesView() }
                            .font(.caption)
                            .textCase(nil)
                    }
                }

                if showCountries {
                    Section {
                        ForEach(model.countries) { c in
                            countryRow(c)
                        }
                    } header: {
                        Text("Страны в этом году")
                    } footer: {
                        if model.pendingCount > 0 {
                            Text("\(pluralPoints(model.pendingCount)) ждут отправки на сервер")
                        }
                    }
                }
            }
            .navigationTitle("Country Counter")
            .refreshable { await model.refresh() }
            .toolbar {
                if model.isLoading { ProgressView() }
            }
        }
    }

    // MARK: - Блоки

    private var permissionBanner: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label("Нужна геолокация «Всегда»", systemImage: "location.slash")
                    .font(.headline)
                Text("Сейчас: \(tracker.authorization.label). Без режима «Всегда» приложение узнает о переезде только когда вы его откроете.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if tracker.authorization == .denied || tracker.authorization == .authorizedWhenInUse {
                    Button("Открыть настройки iOS") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                } else {
                    Button("Разрешить") { tracker.requestPermission() }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func currentCard(_ c: CurrentStatus) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 14) {
                FlagView(code: c.countryCode, width: 84)
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.countryCode.countryDisplayName(fallback: c.countryName))
                        .font(.title.bold())
                    if let city = c.city {
                        Text(city).font(.title3).foregroundStyle(.secondary)
                    }
                }
            }
            HStack(spacing: 16) {
                stat(value: pluralDays(c.daysInRow), caption: "подряд, с \(prettyDate(c.since))")
                stat(value: pluralDays(c.daysThisYear), caption: "в этом году")
            }
        }
        .padding(.vertical, 6)
    }

    private func countryRow(_ c: CountryStat) -> some View {
        HStack(spacing: 12) {
            FlagView(code: c.countryCode, width: 36)
            VStack(alignment: .leading) {
                Text(c.countryCode.countryDisplayName(fallback: c.countryName))
                Text("\(prettyDate(c.firstDay)) – \(prettyDate(c.lastDay))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(pluralDays(c.days)).monospacedDigit().foregroundStyle(.secondary)
        }
    }

    private func stat(value: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.headline.monospacedDigit())
            Text(caption).font(.caption).foregroundStyle(.secondary)
        }
    }
}

// Карточка результата правила: имя, флаги, прогресс, пояснение
struct RuleCard: View {
    let result: RuleResult

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(result.name).font(.headline)
                Spacer()
                Text("\(result.used) / \(result.limit)")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(tint)
            }
            FlagRow(codes: result.countries)
            ProgressView(value: Double(min(result.used, result.limit)), total: Double(max(result.limit, 1)))
                .tint(tint)
            Text(caption).font(.footnote).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var tint: Color {
        switch result.status {
        case .ok: return .accentColor
        case .warning: return .orange
        case .exceeded: return .red
        case .reached: return .green
        }
    }

    private var caption: String {
        // Правило "с въезда", а мы сейчас не в стране: отсчёт сброшен
        if result.autoStart, result.inCountry == false {
            var s = "Сейчас не в стране — при въезде отсчёт начнётся с нуля: \(pluralDays(result.limit))"
            if !result.periodEnd.hasPrefix("9999") { s += " в течение \(pluralDays((daysBetween(result.periodStart, result.periodEnd) ?? 0) + 1))" }
            s += "."
            if let stay = result.lastStay {
                s += " Прошлый заезд: \(prettyDate(stay.from)) – \(prettyDate(stay.to)), \(pluralDays(stay.days))."
            }
            return s
        }
        switch (result.mode, result.status) {
        case (.limit, .exceeded):
            return "Лимит превышен на \(pluralDays(result.used - result.limit)). \(period)"
        case (.limit, _):
            var s = "Осталось \(pluralDays(result.remaining))"
            if let stay = result.canStayDays { s += ", можно остаться ещё \(pluralDays(stay)) подряд" }
            return s + ". " + period
        case (.goal, .reached):
            return "Цель достигнута. \(period)"
        case (.goal, _):
            if result.reachable == false { return "В этом периоде уже недостижимо: не хватит дней до \(prettyDate(result.periodEnd)). " + period }
            return "До цели \(pluralDays(result.remaining)). \(period)"
        }
    }

    private var period: String {
        switch result.type {
        case .calendarYear: return "Год \(result.periodStart.prefix(4))."
        case .rolling: return "Окно \(prettyDate(result.periodStart)) – \(prettyDate(result.periodEnd))."
        case .fromDate:
            if result.autoStart && result.entryDate == nil {
                return "Отсчёт начнётся с первого дня в стране."
            }
            let from = result.autoStart ? "С въезда \(prettyDate(result.periodStart))" : "С \(prettyDate(result.periodStart))"
            return result.periodEnd.hasPrefix("9999")
                ? "\(from)."
                : "\(from) до \(prettyDate(result.periodEnd))."
        }
    }
}

func prettyDate(_ iso: String) -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    guard let d = f.date(from: iso) else { return iso }
    return d.formatted(.dateTime.day().month(.abbreviated))
}

func pluralPoints(_ n: Int) -> String {
    let mod10 = n % 10, mod100 = n % 100
    if mod10 == 1 && mod100 != 11 { return "\(n) точка" }
    if (2...4).contains(mod10) && !(12...14).contains(mod100) { return "\(n) точки" }
    return "\(n) точек"
}
