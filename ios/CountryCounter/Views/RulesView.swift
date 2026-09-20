import SwiftUI

// Список правил: включить/выключить, открыть на редактирование, удалить, добавить из пресета.
struct RulesView: View {
    @Environment(AppModel.self) private var model
    @State private var newRule: RuleInput?

    var body: some View {
        List {
            if model.showSkeleton {
                ForEach(0..<3, id: \.self) { _ in SkeletonRuleCard() }
            } else if model.rules.isEmpty {
                ContentUnavailableView(
                    "No rules yet",
                    systemImage: "list.bullet.clipboard",
                    description: Text("Add a rule with “+” — for example, Schengen 90/180 or 183 days of residency.")
                )
            }
            ForEach(sortedRules) { rule in
                NavigationLink {
                    RuleEditView(rule: rule)
                } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(rule.name).font(.headline).lineLimit(2)
                                Spacer()
                                if let r = result(for: rule) {
                                    Text(verbatim: "\(r.used) / \(r.limit)")
                                        .font(.subheadline.monospacedDigit().bold())
                                        .foregroundStyle(tint(r))
                                }
                            }
                            if let r = result(for: rule) {
                                ProgressView(value: Double(min(r.used, r.limit)), total: Double(max(r.limit, 1)))
                                    .tint(tint(r))
                                Text(usageLine(r)).font(.caption).foregroundStyle(.secondary)
                            } else {
                                Text(inactiveLine(rule)).font(.caption).foregroundStyle(.secondary)
                            }
                            HStack(spacing: 6) {
                                FlagRow(codes: rule.countries, max: 8, width: 18)
                                Text(summary(rule)).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                            }
                        }
                        Toggle("", isOn: Binding(
                            get: { rule.enabled },
                            set: { on in Task { await model.setEnabled(rule, on) } }
                        ))
                        .labelsHidden()
                        .disabled(isExpired(rule))
                    }
                }
            }
            .onDelete { offsets in
                let toDelete = offsets.map { sortedRules[$0] }
                Task { for r in toDelete { await model.delete(r) } }
            }
        }
        .navigationTitle("Counting rules")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    ForEach(RulePresets.all) { preset in
                        Button {
                            newRule = preset.input
                        } label: {
                            VStack(alignment: .leading) {
                                Text(preset.title)
                                Text(preset.subtitle)
                            }
                        }
                    }
                    Divider()
                    Button("Custom rule", systemImage: "slider.horizontal.3") {
                        newRule = RuleInput(name: "", type: .rolling, countries: [], limitDays: 90, windowDays: 180)
                    }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(item: $newRule) { input in
            NavigationStack {
                RuleEditView(rule: nil, initial: input)
            }
        }
    }

    /// Активные сверху (по доле использования), затем выключенные, затем истёкшие
    private var sortedRules: [Rule] {
        model.rules.sorted { a, b in
            let ra = result(for: a), rb = result(for: b)
            switch (ra, rb) {
            case let (x?, y?): return Double(x.used) / Double(max(x.limit, 1)) > Double(y.used) / Double(max(y.limit, 1))
            case (_?, nil): return true
            case (nil, _?): return false
            default: return isExpired(a) == isExpired(b) ? a.name < b.name : !isExpired(a)
            }
        }
    }

    private func result(for rule: Rule) -> RuleResult? { model.ruleResults.first { $0.ruleId == rule.id } }

    private func isExpired(_ rule: Rule) -> Bool {
        guard let until = rule.validUntil else { return false }
        return until < DocumentInput.todayString()
    }

    private func tint(_ r: RuleResult) -> Color {
        switch r.status {
        case .ok: return .accentColor
        case .warning: return .orange
        case .exceeded: return .red
        case .reached: return .green
        }
    }

    private func usageLine(_ r: RuleResult) -> String {
        if r.type == .absence {
            return r.inCountry == false
                ? String(localized: "Away for \(pluralDays(r.used)), \(pluralDays(r.remaining)) more allowed.")
                : String(localized: "In the country — the away counter is at zero.")
        }
        if r.autoStart, r.inCountry == false { return String(localized: "Not in the country — the count restarts on entry.") }
        switch (r.mode, r.status) {
        case (.limit, .exceeded): return String(localized: "Limit exceeded by \(pluralDays(r.used - r.limit)).")
        case (.limit, _):
            if let stay = r.canStayDays { return String(localized: "\(pluralDays(r.remaining)) left, you can stay \(pluralDays(stay)) more in a row.") }
            return String(localized: "\(pluralDays(r.remaining)) left.")
        case (.goal, .reached): return String(localized: "Goal reached.")
        case (.goal, _): return String(localized: "\(pluralDays(r.remaining)) to go.")
        }
    }

    private func inactiveLine(_ rule: Rule) -> String {
        if isExpired(rule), let until = rule.validUntil { return String(localized: "Expired \(prettyFullDate(until)) — kept for history.") }
        if !rule.enabled { return String(localized: "Disabled — not counted.") }
        return String(localized: "Not evaluated yet.")
    }

    private func summary(_ r: Rule) -> String {
        let limit = pluralDays(r.limitDays)
        switch (r.mode, r.type) {
        case (_, .absence): return String(localized: "no more than \(limit) away in a row")
        case (.limit, .calendarYear): return String(localized: "no more than \(limit) per calendar year")
        case (.goal, .calendarYear): return String(localized: "goal: \(limit) per calendar year")
        case (.limit, .rolling): return String(localized: "no more than \(limit) in any \(r.windowDays ?? 0) days")
        case (.goal, .rolling): return String(localized: "goal: \(limit) in any \(r.windowDays ?? 0) days")
        case (_, .fromDate):
            let from = r.autoStart ? String(localized: "from entry") : String(localized: "from \(r.startDate.map(prettyDate) ?? "?")")
            let base = r.mode == .limit ? String(localized: "no more than \(limit) \(from)") : String(localized: "goal: \(limit) \(from)")
            if let w = r.windowDays { return base + " " + String(localized: "within \(w) days") }
            return base
        }
    }
}

extension RuleInput: Identifiable {
    var id: String { "\(name)|\(type.rawValue)|\(limitDays)|\(windowDays ?? 0)|\(countries.joined())" }
}
