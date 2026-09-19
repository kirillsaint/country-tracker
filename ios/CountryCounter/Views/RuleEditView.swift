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
            Section("Name") {
                TextField("For example, Schengen 90/180", text: $draft.name)
            }

            Section {
                Picker("Mode", selection: $draft.mode) {
                    ForEach(RuleMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Period", selection: $draft.type) {
                    ForEach(RuleType.allCases) { Text($0.title).tag($0) }
                }
                DaysField(title: draft.mode == .limit ? "No more than" : "Need to reach", value: $draft.limitDays)
                if draft.type == .rolling {
                    DaysField(title: "In any", value: windowBinding, range: 2...3660)
                }
                if draft.type == .fromDate {
                    Toggle("Detect entry date automatically", isOn: $draft.autoStart)
                    if !draft.autoStart {
                        DatePicker("Starting on", selection: $startDate, displayedComponents: .date)
                    }
                    Toggle("Limit the period", isOn: Binding(
                        get: { draft.windowDays != nil },
                        set: { draft.windowDays = $0 ? (draft.windowDays ?? 90) : nil }
                    ))
                    if draft.windowDays != nil {
                        DaysField(title: "Duration", value: windowBinding)
                    }
                }
            } header: {
                Text("How to count")
            } footer: {
                Text(howToCountFooter)
            }

            Section {
                NavigationLink {
                    CountryPickerView(selection: $draft.countries)
                } label: {
                    HStack {
                        Text("Countries")
                        Spacer()
                        if draft.countries.isEmpty {
                            Text("Any").foregroundStyle(.secondary)
                        } else {
                            FlagRow(codes: draft.countries, max: 5, width: 20)
                        }
                    }
                }
                Picker("A day counts as", selection: $draft.countMode) {
                    ForEach(CountMode.allCases) { Text($0.title).tag($0) }
                }
            } footer: {
                Text("“Any presence” — the day counts if you were in the country for at least part of it; that’s how almost all visa rules work. “Main country of the day” — only if it was the last country that day.")
            }

            Section {
                Toggle("Warn in advance", isOn: $warnEnabled)
                if warnEnabled {
                    DaysField(title: "When this many days are left", value: $warnDays, range: 0...3660)
                }
                Toggle("Notifications for this rule", isOn: $draft.notify)
                Toggle("Rule enabled", isOn: $draft.enabled)
            } header: {
                Text("Warnings")
            } footer: {
                if draft.mode == .goal {
                    Text("For a goal, the notification comes once — when it is reached.")
                }
            }

            if let error {
                Section { Text(error).foregroundStyle(.red).font(.footnote) }
            }

            if rule != nil {
                Section {
                    Button("Delete rule", role: .destructive) { confirmDelete = true }
                }
            }
        }
        .navigationTitle(rule == nil ? "New rule" : "Rule")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if rule == nil {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(action: save) {
                    if saving { ProgressView() } else { Text("Save") }
                }
                .disabled(saving || draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .confirmationDialog("Delete this rule?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                guard let rule else { return }
                Task {
                    await model.delete(rule)
                    dismiss()
                }
            }
        }
    }

    private var howToCountFooter: String {
        var text = draft.mode == .limit
            ? String(localized: "Limit: must not be exceeded (visas, 90/180).") + " " + draft.type.hint
            : String(localized: "Goal: must be reached (for example, 183 days for residency).") + " " + draft.type.hint
        if draft.type == .fromDate && draft.autoStart {
            text += " " + String(localized: "The entry date is the first day of your current uninterrupted stay in the selected countries: leave and come back — the count starts over. If the data is inaccurate, turn the automation off and set the date by hand.")
        }
        return text
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
            input.startDate = input.autoStart ? nil : Self.format(startDate)
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
