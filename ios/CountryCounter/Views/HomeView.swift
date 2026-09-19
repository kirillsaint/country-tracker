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
                            "No data yet",
                            systemImage: "globe",
                            description: Text("The first point is recorded automatically. Or tap “Record a point now” in Settings.")
                        )
                    }
                }

                Section {
                    if model.ruleResults.isEmpty {
                        NavigationLink {
                            RulesView()
                        } label: {
                            Label("Add a counting rule", systemImage: "plus.circle")
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
                        Text("Rules")
                        Spacer()
                        NavigationLink("All") { RulesView() }
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
                        Text("Countries this year")
                    } footer: {
                        if model.pendingCount > 0 {
                            Text("\(pluralPoints(model.pendingCount)) waiting to be uploaded")
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
                Label("“Always” location access needed", systemImage: "location.slash")
                    .font(.headline)
                Text("Now: \(tracker.authorization.label). Without “Always”, the app only learns about a move when you open it.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if tracker.authorization == .denied || tracker.authorization == .authorizedWhenInUse {
                    Button("Open iOS Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                } else {
                    Button("Allow") { tracker.requestPermission() }
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
                stat(value: pluralDays(c.daysInRow), caption: String(localized: "in a row, since \(prettyDate(c.since))"))
                stat(value: pluralDays(c.daysThisYear), caption: String(localized: "this year"))
            }
        }
        .padding(.vertical, 6)
    }

    private func countryRow(_ c: CountryStat) -> some View {
        HStack(spacing: 12) {
            FlagView(code: c.countryCode, width: 36)
            VStack(alignment: .leading) {
                Text(c.countryCode.countryDisplayName(fallback: c.countryName))
                Text(verbatim: "\(prettyDate(c.firstDay)) – \(prettyDate(c.lastDay))")
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
                Text(verbatim: "\(result.used) / \(result.limit)")
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
            var s: String
            if result.periodEnd.hasPrefix("9999") {
                s = String(localized: "Not in the country now — the count restarts on entry: \(pluralDays(result.limit)).")
            } else {
                let window = (daysBetween(result.periodStart, result.periodEnd) ?? 0) + 1
                s = String(localized: "Not in the country now — the count restarts on entry: \(pluralDays(result.limit)) within \(pluralDays(window)).")
            }
            if let stay = result.lastStay {
                s += " " + String(localized: "Previous stay: \(prettyDate(stay.from)) – \(prettyDate(stay.to)), \(pluralDays(stay.days)).")
            }
            return s
        }
        switch (result.mode, result.status) {
        case (.limit, .exceeded):
            return String(localized: "Limit exceeded by \(pluralDays(result.used - result.limit)).") + " " + period
        case (.limit, _):
            if let stay = result.canStayDays {
                return String(localized: "\(pluralDays(result.remaining)) left, you can stay \(pluralDays(stay)) more in a row.") + " " + period
            }
            return String(localized: "\(pluralDays(result.remaining)) left.") + " " + period
        case (.goal, .reached):
            return String(localized: "Goal reached.") + " " + period
        case (.goal, _):
            if result.reachable == false {
                return String(localized: "No longer reachable in this period: not enough days until \(prettyDate(result.periodEnd)).") + " " + period
            }
            return String(localized: "\(pluralDays(result.remaining)) to go.") + " " + period
        }
    }

    private var period: String {
        switch result.type {
        case .calendarYear:
            return String(localized: "Year \(String(result.periodStart.prefix(4))).")
        case .rolling:
            return String(localized: "Window \(prettyDate(result.periodStart)) – \(prettyDate(result.periodEnd)).")
        case .fromDate:
            if result.autoStart && result.entryDate == nil {
                return String(localized: "The count starts on your first day in the country.")
            }
            let open = result.periodEnd.hasPrefix("9999")
            switch (result.autoStart, open) {
            case (true, true): return String(localized: "Since entry on \(prettyDate(result.periodStart)).")
            case (true, false): return String(localized: "Since entry on \(prettyDate(result.periodStart)) until \(prettyDate(result.periodEnd)).")
            case (false, true): return String(localized: "Since \(prettyDate(result.periodStart)).")
            case (false, false): return String(localized: "From \(prettyDate(result.periodStart)) until \(prettyDate(result.periodEnd)).")
            }
        }
    }
}
