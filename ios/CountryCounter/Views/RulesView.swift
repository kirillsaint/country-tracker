import SwiftUI

// Список правил: включить/выключить, открыть на редактирование, удалить, добавить из пресета.
struct RulesView: View {
    @Environment(AppModel.self) private var model
    @State private var newRule: RuleInput?

    var body: some View {
        List {
            if model.rules.isEmpty {
                ContentUnavailableView(
                    "Правил пока нет",
                    systemImage: "list.bullet.clipboard",
                    description: Text("Добавьте правило кнопкой «+» — например, Шенген 90/180 или 183 дня резидентства.")
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
        .navigationTitle("Правила подсчёта")
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
                    Button("Своё правило", systemImage: "slider.horizontal.3") {
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
        let what = r.mode == .limit ? "не больше" : "цель"
        switch r.type {
        case .calendarYear: return "\(what) \(pluralDays(r.limitDays)) за календарный год"
        case .rolling: return "\(what) \(pluralDays(r.limitDays)) в любые \(r.windowDays ?? 0) дней"
        case .fromDate:
            let end = r.windowDays.map { " в течение \($0) дней" } ?? ""
            return "\(what) \(pluralDays(r.limitDays)) с \(r.startDate.map(prettyDate) ?? "?")\(end)"
        }
    }
}

extension RuleInput: Identifiable {
    var id: String { "\(name)|\(type.rawValue)|\(limitDays)|\(windowDays ?? 0)|\(countries.joined())" }
}
