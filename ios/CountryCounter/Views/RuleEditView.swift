import SwiftUI

// Редактор одного правила. rule == nil — создание.
struct RuleEditView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let rule: Rule?
    @State private var draft: RuleInput
    @State private var startDate: Date
    @State private var warnEnabled: Bool
    @State private var warnDays: Int
    @State private var saving = false
    @State private var error: String?
    @State private var confirmDelete = false

    init(rule: Rule?, initial: RuleInput? = nil) {
        self.rule = rule
        let input = rule?.input ?? initial ?? RuleInput(name: "", type: .rolling, countries: [], limitDays: 90, windowDays: 180)
        _draft = State(initialValue: input)
        _startDate = State(initialValue: Self.parse(input.startDate) ?? Date())
        _warnEnabled = State(initialValue: input.warnRemainingDays != nil)
        _warnDays = State(initialValue: input.warnRemainingDays ?? 10)
    }

    var body: some View {
        Form {
            Section("Название") {
                TextField("Например, Шенген 90/180", text: $draft.name)
            }

            Section {
                Picker("Режим", selection: $draft.mode) {
                    ForEach(RuleMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Период", selection: $draft.type) {
                    ForEach(RuleType.allCases) { Text($0.title).tag($0) }
                }
                Stepper(value: $draft.limitDays, in: 1...3660) {
                    LabeledContent(draft.mode == .limit ? "Не больше" : "Нужно набрать", value: pluralDays(draft.limitDays))
                }
                if draft.type == .rolling {
                    Stepper(value: windowBinding, in: 2...3660) {
                        LabeledContent("В любые", value: pluralDays(windowBinding.wrappedValue))
                    }
                }
                if draft.type == .fromDate {
                    DatePicker("Начиная с", selection: $startDate, displayedComponents: .date)
                    Toggle("Ограничить период", isOn: Binding(
                        get: { draft.windowDays != nil },
                        set: { draft.windowDays = $0 ? (draft.windowDays ?? 90) : nil }
                    ))
                    if draft.windowDays != nil {
                        Stepper(value: windowBinding, in: 1...3660) {
                            LabeledContent("Длительность", value: pluralDays(windowBinding.wrappedValue))
                        }
                    }
                }
            } header: {
                Text("Как считать")
            } footer: {
                Text(draft.mode == .limit
                     ? "Лимит: нельзя превышать (визы, 90/180). " + draft.type.hint
                     : "Цель: нужно набрать (например, 183 дня для резидентства). " + draft.type.hint)
            }

            Section {
                NavigationLink {
                    CountryPickerView(selection: $draft.countries)
                } label: {
                    HStack {
                        Text("Страны")
                        Spacer()
                        if draft.countries.isEmpty {
                            Text("Любая").foregroundStyle(.secondary)
                        } else {
                            FlagRow(codes: draft.countries, max: 5, width: 20)
                        }
                    }
                }
                Picker("День засчитывается", selection: $draft.countMode) {
                    ForEach(CountMode.allCases) { Text($0.title).tag($0) }
                }
            } footer: {
                Text("«Любой заход» — день считается, если в этот день вы были в стране хотя бы часть дня; так работают почти все визовые правила. «Основная страна дня» — только если это последняя страна за день.")
            }

            Section {
                Toggle("Предупреждать заранее", isOn: $warnEnabled)
                if warnEnabled {
                    Stepper(value: $warnDays, in: 0...3660) {
                        LabeledContent("Когда осталось", value: pluralDays(warnDays))
                    }
                }
                Toggle("Уведомления по этому правилу", isOn: $draft.notify)
                Toggle("Правило включено", isOn: $draft.enabled)
            } header: {
                Text("Предупреждения")
            } footer: {
                if draft.mode == .goal {
                    Text("Для цели уведомление приходит один раз — когда она достигнута.")
                }
            }

            if let error {
                Section { Text(error).foregroundStyle(.red).font(.footnote) }
            }

            if rule != nil {
                Section {
                    Button("Удалить правило", role: .destructive) { confirmDelete = true }
                }
            }
        }
        .navigationTitle(rule == nil ? "Новое правило" : "Правило")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if rule == nil {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(action: save) {
                    if saving { ProgressView() } else { Text("Сохранить") }
                }
                .disabled(saving || draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .confirmationDialog("Удалить правило?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Удалить", role: .destructive) {
                guard let rule else { return }
                Task {
                    await model.delete(rule)
                    dismiss()
                }
            }
        }
    }

    private var windowBinding: Binding<Int> {
        Binding(get: { draft.windowDays ?? 180 }, set: { draft.windowDays = $0 })
    }

    private func save() {
        var input = draft
        input.name = input.name.trimmingCharacters(in: .whitespaces)
        input.warnRemainingDays = warnEnabled ? warnDays : nil
        switch input.type {
        case .calendarYear:
            input.windowDays = nil
            input.startDate = nil
        case .rolling:
            input.windowDays = input.windowDays ?? 180
            input.startDate = nil
        case .fromDate:
            input.startDate = Self.format(startDate)
        }
        saving = true
        error = nil
        Task {
            do {
                try await model.save(input, id: rule?.id)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            saving = false
        }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f
    }()

    private static func parse(_ s: String?) -> Date? { s.flatMap { dateFormatter.date(from: $0) } }
    private static func format(_ d: Date) -> String { dateFormatter.string(from: d) }
}
