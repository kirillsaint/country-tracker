import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var model
    @ObservedObject private var tracker = LocationTracker.shared
    @State private var showDiscover = false
    @State private var showMap = false
    @State private var basisSegment: Segment?

    var body: some View {
        NavigationStack {
            List {
                if !tracker.hasAlwaysPermission {
                    permissionBanner
                }
                if let current = model.current, current.needsEntryBasis, let seg = model.currentSegment {
                    Section {
                        Button {
                            basisSegment = seg
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "airplane.arrival").font(.title2).foregroundStyle(.tint)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("How did you enter \(current.countryCode.countryDisplayName(fallback: current.countryName))?")
                                        .font(.headline).foregroundStyle(.primary)
                                    Text("Pick the basis — it sets the stay-limit rule.").font(.footnote).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                            }
                        }
                    }
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
                    } else if model.showSkeleton {
                        SkeletonCurrentCard()
                    } else {
                        ContentUnavailableView(
                            "No data yet",
                            systemImage: "globe",
                            description: Text("The first point is recorded automatically. Or tap “Record a point now” in Settings.")
                        )
                    }
                }

                Section {
                    if model.showSkeleton {
                        SkeletonRuleCard()
                    } else if model.ruleResults.isEmpty {
                        NavigationLink {
                            RulesView()
                        } label: {
                            Label("Add a counting rule", systemImage: "plus.circle")
                        }
                    } else if relevantResults.isEmpty {
                        NavigationLink {
                            RulesView()
                        } label: {
                            Label("No rules apply to this country. See all rules", systemImage: "list.bullet")
                                .font(.footnote)
                        }
                    }
                    ForEach(relevantResults) { result in
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
                        Text(model.current == nil ? "Rules" : "Rules for this country")
                        Spacer()
                        NavigationLink(model.showSkeleton ? String(localized: "All") : String(localized: "All (\(model.rules.count))")) { RulesView() }
                            .font(.caption)
                            .textCase(nil)
                    }
                }

                Section {
                    Button {
                        showDiscover = true
                    } label: {
                        Label("Find something to do", systemImage: "sparkles")
                            .font(.headline)
                    }
                    .disabled(!model.discoverEnabled && !model.showSkeleton)
                    if !model.discoverEnabled, !model.showSkeleton {
                        Text("Recommendations are off: the server has no Google Places key.").font(.footnote).foregroundStyle(.secondary)
                    }
                    if model.recommendations.isEmpty, model.discoverEnabled, tracker.lastPoint != nil {
                        ForEach(0..<2, id: \.self) { _ in SkeletonRow(flag: 72, lines: 3) }
                    }
                    ForEach(model.recommendations.prefix(3)) { r in
                        NavigationLink {
                            PlaceDetailView(place: r)
                        } label: {
                            PlaceRow(place: r)
                        }
                    }
                    if model.recommendations.count > 3 {
                        Button("All \(model.recommendations.count) picks") { showDiscover = true }.font(.footnote)
                    }
                } header: {
                    Text("What to do?")
                } footer: {
                    if model.pendingCount > 0 {
                        Text("\(pluralPoints(model.pendingCount)) waiting to be uploaded")
                    } else if model.discoverRefining {
                        Text("Refining for your taste…")
                    } else if let s = model.discoverSummary, !model.recommendations.isEmpty {
                        Text(s)
                    }
                }
            }
            .navigationTitle("Stamps")
            .refreshable { await model.refresh() }
            .toolbar {
                if model.isLoading { ProgressView() }
                Button("Map", systemImage: "map") { showMap = true }
            }
            .sheet(isPresented: $showMap) { MapScreen() }
            .sheet(isPresented: $showDiscover) { NavigationStack { DiscoverView() } }
            // подборка «рядом» появляется сама, как только есть координата. Отдельная задача, не привязанная
            // к вью: иначе каждая новая точка перезапускала бы её и обрывала запрос на полпути
            .task(id: model.discoverEnabled) {
                guard model.discoverEnabled else { return }
                Task { @MainActor in
                    for _ in 0..<60 where tracker.lastPoint == nil { try? await Task.sleep(for: .milliseconds(500)) }
                    if let p = tracker.lastPoint { await model.autoDiscoverIfNeeded(lat: p.lat, lon: p.lon) }
                }
            }
            .onAppear {
                #if DEBUG
                // xcrun simctl launch … -debugDiscover coffee — сразу открыть «Чем заняться» и запустить поиск
                if UserDefaults.standard.string(forKey: "debugDiscover") != nil { showDiscover = true }
                // -debugDiscoverHome coffee — подборка прямо на главной, без экрана поиска
                if let c = UserDefaults.standard.string(forKey: "debugDiscoverHome"), let cat = DiscoverCategory(rawValue: c) {
                    Task {
                        for _ in 0..<20 where tracker.lastPoint == nil { try? await Task.sleep(for: .milliseconds(500)) }
                        if let p = tracker.lastPoint { try? await model.discover(lat: p.lat, lon: p.lon, query: nil, category: cat, radiusKm: 3, openNow: false) }
                    }
                }
                #endif
            }
            .sheet(item: $basisSegment) { seg in
                NavigationStack { EntryBasisSheet(segment: seg, existing: model.entry(for: seg), previous: model.current?.previousEntry, regimeRef: model.current?.regime) }
            }
        }
    }

    /// Правила, касающиеся текущей страны; правило без стран («любая») касается всех
    private var relevantResults: [RuleResult] {
        guard let cur = model.current else { return model.ruleResults }
        return model.ruleResults.filter { r in
            (r.countries.isEmpty || r.countries.contains(cur.countryCode)) && applies(r, to: cur.basisNow)
        }
    }

    /// Правило безвиза не про пребывание по ВНЖ/визе/гражданству, правило визы — не про безвиз и не про другую визу
    private func applies(_ r: RuleResult, to basis: CurrentStatus.EntryRef?) -> Bool {
        guard let basis else { return true }
        if r.regimeId != nil { return ![.citizen, .residence, .visa].contains(basis.basis) }
        if let docId = r.documentId, model.document(id: docId)?.kind == .visa {
            if basis.basis == .visa { return basis.documentId == nil || basis.documentId == docId }
            return basis.basis == .transit || basis.basis == .other
        }
        return true
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
                        Text(city.cityDisplayName(country: c.countryCode)).font(.title3).foregroundStyle(.secondary)
                    }
                }
            }
            HStack(spacing: 16) {
                stat(value: pluralDays(c.daysInRow), caption: String(localized: "in a row, since \(prettyDate(c.since))"))
                stat(value: pluralDays(c.daysThisYear), caption: String(localized: "this year"))
            }
            HStack(spacing: 12) {
                if let e = c.basisNow {
                    // нажатие открывает основание пребывания: поменять или отметить смену статуса
                    Button {
                        basisSegment = model.currentSegment
                    } label: {
                        // текст в цвет значка: безвиз зелёный, ВНЖ индиго и т.д.
                        Label {
                            Text(e.isSwitch ? String(localized: "\(e.basis.title) · since \(prettyDate(e.date))") : e.basis.title)
                                .foregroundStyle(e.basis.tint)
                        } icon: {
                            Image(systemName: e.basis.homeSystemImage).foregroundStyle(e.basis.tint)
                        }
                        .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .tint(e.basis.tint)
                    // основание не выбрано — ссылка на условия въезда прижимается к левому краю
                    Spacer()
                }
                NavigationLink {
                    RegimeView(countryCode: c.countryCode, initialPassportId: c.regime?.passportId)
                } label: {
                    Label(c.regime?.stale == true ? "Entry rules · re-check" : "Entry rules", systemImage: "list.bullet.rectangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
        if result.type == .absence {
            if result.inCountry != false {
                return String(localized: "In the country — the away counter is at zero. Allowed: up to \(pluralDays(result.limit)) away in a row.")
            }
            if result.status == .exceeded {
                return String(localized: "Away for \(pluralDays(result.used)) — over the limit of \(pluralDays(result.limit)).")
            }
            return String(localized: "Away for \(pluralDays(result.used)), \(pluralDays(result.remaining)) more allowed.")
        }
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
        case .absence:
            return ""
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

extension EntryBasis {
    /// Цвет значка основания на главной: безвиз — зелёный, виза — синий и т.д.
    var tint: Color {
        switch self {
        case .citizen: return .teal
        case .visa_free: return .green
        case .visa: return .blue
        case .residence: return .indigo
        case .transit: return .orange
        case .other: return .secondary
        }
    }

    /// Залитый вариант значка для цветного отображения
    var homeSystemImage: String {
        switch self {
        case .citizen: return "person.crop.circle.fill"
        case .visa_free: return "checkmark.seal.fill"
        case .visa: return "doc.text.fill"
        case .residence: return "house.fill"
        case .transit: return "airplane"
        case .other: return "questionmark.circle.fill"
        }
    }
}
