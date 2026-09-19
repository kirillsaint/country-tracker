import SwiftUI

// Список правил: включить/выключить, открыть на редактирование, удалить, добавить из пресета.
struct RulesView: View {
    @Environment(AppModel.self) private var model
    @State private var newRule: RuleInput?

    var body: some View {
        List {
            if model.rules.isEmpty {
                ContentUnavailableView(
                    "No rules yet",
                    systemImage: "list.bullet.clipboard",
                    description: Text("Add a rule with “+” — for example, Schengen 90/180 or 183 days of residency.")
                )
            }
            ForEach(model.rules) { rule in
                NavigationLink {
                    RuleEditView(rule: rule)
                } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(rule.name).font(.headline)
                            Text(summary(rule)).font(.caption).foregroundStyle(.secondary)
                            FlagRow(codes: rule.countries, max: 8, width: 18)
                        }
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { rule.enabled },
                            set: { on in Task { await model.setEnabled(rule, on) } }
                        ))
                        .labelsHidden()
                    }
                }
            }
            .onDelete { offsets in
                let toDelete = offsets.map { model.rules[$0] }
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

    private func summary(_ r: Rule) -> String {
        let limit = pluralDays(r.limitDays)
        switch (r.mode, r.type) {
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
