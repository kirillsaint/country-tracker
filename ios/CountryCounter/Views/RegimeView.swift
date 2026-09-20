import SwiftUI

// Режим въезда в страну по паспорту: подтверждённые условия безвиза, чек-лист, источники,
// история версий; заполнение вручную или нейросетью с последующей проверкой пользователем.
struct RegimeView: View {
    @Environment(AppModel.self) private var model
    let countryCode: String
    var initialPassportId: String? = nil

    @State private var passportId: String?
    @State private var info: RegimeInfoResponse?
    @State private var loading = false
    @State private var error: String?
    @State private var editor: RegimeVersionInput?
    @State private var editorOrigin = "user"
    @State private var check: RegimeCheck?
    @State private var diff: RegimeDiff?
    @State private var checking = false
    @State private var confirmDelete = false
    @State private var showHistory = false

    private var passport: TravelDocument? { model.document(id: passportId) }
    private var regime: Regime? { passportId.flatMap { model.regime(passportId: $0, country: countryCode) } }
    private var active: RegimeVersion? { regime?.active }

    var body: some View {
        List {
            header
            if model.passports.isEmpty {
                Section {
                    Text("Add a passport in Documents first — entry rules depend on citizenship.").foregroundStyle(.secondary)
                }
            } else if info?.isCitizen == true {
                Section { Label("Your citizenship — no stay limit.", systemImage: "person.crop.circle.badge.checkmark") }
            } else {
                regimeSection
                if let a = active, !a.conditions.isEmpty { conditionsSection(a) }
                if let a = active, !a.sources.isEmpty { sourcesSection(a.sources) }
                checkSection
                if let r = regime, !r.history.isEmpty { historySection(r) }
                if let docs = info?.documents, !docs.isEmpty {
                    Section("Your documents for this country") {
                        ForEach(docs) { d in
                            NavigationLink { DocumentEditView(document: d) } label: { Label(d.name, systemImage: d.kind.systemImage) }
                        }
                    }
                }
                if regime != nil {
                    Section { Button("Delete entry rules", role: .destructive) { confirmDelete = true } }
                }
            }
            if let error { Section { Text(error).foregroundStyle(.red).font(.footnote) } }
        }
        .navigationTitle("Entry rules")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if passportId == nil { passportId = initialPassportId ?? model.passports.first?.id }
            await load()
        }
        // паспорта могли догрузиться позже открытия экрана (например, сразу после запуска)
        .onChange(of: model.passports.map(\.id)) { _, ids in
            if passportId == nil || !ids.contains(passportId!) { passportId = initialPassportId.flatMap { ids.contains($0) ? $0 : nil } ?? ids.first }
        }
        .onChange(of: passportId) { _, _ in Task { await load() } }
        .refreshable { await load() }
        .sheet(item: $editor) { input in
            NavigationStack {
                RegimeEditorView(initial: input, title: active == nil ? "New entry rules" : "Edit entry rules") { result in
                    await save(result)
                }
            }
        }
        .confirmationDialog("Delete entry rules for this country?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let regime { Task { await model.deleteRegime(regime); await load() } }
            }
        }
        .task(id: check?.id) { await pollCheck() }
    }

    // MARK: - Секции

    private var header: some View {
        Section {
            HStack(spacing: 12) {
                FlagView(code: countryCode, width: 44)
                Text(countryCode.countryDisplayName(fallback: nil)).font(.title2.bold())
            }
            if model.passports.count > 1 {
                Picker("Passport", selection: $passportId) {
                    ForEach(model.passports) { p in
                        Text(verbatim: "\(p.countryCode.flagEmoji) \(p.name)").tag(String?.some(p.id))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var regimeSection: some View {
        Section {
            if let a = active {
                HStack {
                    Label(a.requirement.title, systemImage: a.requirement.allowsEntry ? "checkmark.seal.fill" : "xmark.seal.fill")
                        .foregroundStyle(a.requirement.allowsEntry ? .green : .red).font(.headline)
                    Spacer()
                    if let r = regime, model.rules.contains(where: { $0.regimeId == r.id && $0.enabled }) {
                        NavigationLink("Rules") { RulesView() }.font(.footnote)
                    }
                }
                if a.constraints.isEmpty && a.requirement.allowsEntry {
                    Text("No stay limits recorded.").foregroundStyle(.secondary)
                }
                ForEach(a.constraints) { c in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.summary)
                        if let n = c.note, !n.isEmpty { Text(n).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                if let n = a.notes, !n.isEmpty { Text(n).font(.footnote).foregroundStyle(.secondary) }
                Button("Edit", systemImage: "pencil") {
                    editorOrigin = "user"
                    editor = RegimeVersionInput(requirement: a.requirement, constraints: a.constraints, conditions: a.conditions, sources: a.sources, origin: "user", model: nil, notes: a.notes)
                }
            } else {
                Text("Entry rules for this passport aren’t recorded yet. Fill them in automatically — the assistant searches official sources and you confirm — or by hand.")
                    .font(.footnote).foregroundStyle(.secondary)
                if model.aiEnabled {
                    Button { Task { await startCheck(force: false) } } label: {
                        Label("Fill in automatically", systemImage: "sparkles")
                    }
                    .disabled(checking || check?.status == .queued || check?.status == .running)
                }
                Button("Fill in by hand", systemImage: "square.and.pencil") {
                    editorOrigin = "user"
                    editor = RegimeVersionInput(requirement: .visa_free, constraints: [RegimeConstraint(type: .perEntry, limitDays: 30)], conditions: [], sources: [], origin: "user", model: nil, notes: nil)
                }
            }
        } header: {
            Text("Entry rules")
        } footer: {
            if let a = active, let r = regime { Text(statusLine(a, r)) }
        }
    }

    private func statusLine(_ a: RegimeVersion, _ r: Regime) -> String {
        let origin = a.origin == "ai" ? String(localized: "assistant (\(a.model ?? "AI")), confirmed by you") : String(localized: "entered by you")
        var s = String(localized: "Confirmed \(prettyFullDate(String(a.confirmedAt.prefix(10)))) · \(origin).")
        if let last = r.lastCheckedAt {
            let days = daysBetween(String(last.prefix(10)), DocumentInput.todayString()) ?? 0
            s += " " + (info?.stale == true
                ? String(localized: "Last checked \(pluralDays(days)) ago — worth re-checking.")
                : (days == 0 ? String(localized: "Checked today.") : String(localized: "Checked \(pluralDays(days)) ago.")))
        }
        return s
    }

    private func conditionsSection(_ a: RegimeVersion) -> some View {
        Section {
            ForEach(a.conditions) { c in
                Button {
                    if let regime { Task { await model.setCondition(regime, c, done: !c.done) } }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: c.done ? "checkmark.circle.fill" : "circle").foregroundStyle(c.done ? .green : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.text).foregroundStyle(.primary).strikethrough(c.done)
                            HStack(spacing: 6) {
                                Label(c.kind.title, systemImage: c.kind.systemImage)
                                if let w = c.withinDays { Text(String(localized: "within \(pluralDays(w)) of entry")) }
                            }
                            .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            Text("Conditions")
        } footer: {
            if a.conditions.contains(where: { $0.kind == .registration && $0.withinDays != nil }) {
                Text("For registration deadlines the app reminds you a day before, counting from your entry date.")
            }
        }
    }

    private func sourcesSection(_ sources: [RegimeSource]) -> some View {
        Section("Sources") {
            ForEach(sources) { s in
                Link(destination: URL(string: s.url) ?? URL(string: "https://example.com")!) {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: s.official ? "checkmark.shield.fill" : "link").foregroundStyle(s.official ? .green : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.title ?? s.url).font(.footnote).foregroundStyle(.primary).lineLimit(2)
                            Text(hostOf(s.url)).font(.caption2).foregroundStyle(.secondary)
                            if let q = s.quote, !q.isEmpty { Text("“\(q)”").font(.caption2).foregroundStyle(.tertiary).lineLimit(3) }
                        }
                    }
                }
            }
        }
    }

    private func hostOf(_ url: String) -> String { URL(string: url)?.host() ?? url }

    @ViewBuilder
    private var checkSection: some View {
        if let check {
            Section {
                switch check.status {
                case .queued, .running:
                    HStack(spacing: 12) {
                        ProgressView()
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Searching official sources…").font(.headline)
                            Text("Usually 20–60 seconds. You can leave — a notification will arrive when it’s done.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                case .failed:
                    Label(check.error ?? String(localized: "Automatic research failed."), systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.footnote)
                    Button("Try again") { Task { await startCheck(force: true) } }
                case .done:
                    if let d = check.draft { draftReview(d, check) }
                }
            } header: {
                Text("Assistant result")
            }
        } else if active != nil, model.aiEnabled {
            Section {
                Button { Task { await startCheck(force: true) } } label: {
                    Label("Re-check current rules", systemImage: "arrow.triangle.2.circlepath")
                }
            } footer: {
                Text("The assistant searches again and shows what changed. Nothing is applied without your confirmation.")
            }
        }
    }

    @ViewBuilder
    private func draftReview(_ d: RegimeDraft, _ check: RegimeCheck) -> some View {
        HStack {
            Label(d.requirement.title, systemImage: d.requirement.allowsEntry ? "checkmark.seal" : "xmark.seal")
                .foregroundStyle(d.requirement.allowsEntry ? .green : .red)
            Spacer()
            Text(confidenceTitle(d.confidence)).font(.caption).foregroundStyle(.secondary)
        }
        Text(d.summary).font(.footnote)
        if let change = d.recentChange, !change.isEmpty {
            Label(change, systemImage: "clock.arrow.circlepath").font(.footnote).foregroundStyle(.orange)
        }
        ForEach(d.constraints) { c in
            VStack(alignment: .leading, spacing: 2) {
                Text(c.summary)
                if let n = c.note, !n.isEmpty { Text(n).font(.caption).foregroundStyle(.secondary) }
            }
        }
        ForEach(d.conditions) { c in
            Label(c.text, systemImage: c.kind.systemImage).font(.footnote).foregroundStyle(.secondary)
        }
        if let diff, active != nil {
            if diff.changed {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Differs from your current rules:").font(.caption.bold())
                    ForEach(diff.added, id: \.self) { Text(verbatim: "+ \($0)").font(.caption).foregroundStyle(.green) }
                    ForEach(diff.removed, id: \.self) { Text(verbatim: "− \($0)").font(.caption).foregroundStyle(.red) }
                    if let r = diff.requirementChanged { Text(verbatim: r).font(.caption).foregroundStyle(.orange) }
                }
            } else {
                Label("Matches your current rules.", systemImage: "checkmark.circle").font(.footnote).foregroundStyle(.green)
            }
        }
        if !d.sources.isEmpty {
            ForEach(d.sources) { s in
                Link(destination: URL(string: s.url) ?? URL(string: "https://example.com")!) {
                    Label(hostOf(s.url), systemImage: s.official ? "checkmark.shield.fill" : "link").font(.caption)
                }
            }
        }
        if active != nil, diff?.changed == false {
            Button("Mark as checked", systemImage: "checkmark") { Task { await markChecked(d, check) } }
        } else {
            Button(active == nil ? "Review and add" : "Review and apply changes", systemImage: "checkmark.circle") {
                editorOrigin = "ai"
                editor = RegimeVersionInput(requirement: d.requirement, constraints: d.constraints, conditions: d.conditions, sources: d.sources, origin: "ai", model: check.model, notes: d.summary)
            }
            if active != nil {
                Button("Keep mine", role: .cancel) { self.check = nil; self.diff = nil }
            }
        }
    }

    private func confidenceTitle(_ c: String) -> String {
        switch c {
        case "high": return String(localized: "high confidence")
        case "medium": return String(localized: "medium confidence")
        default: return String(localized: "low confidence")
        }
    }

    private func historySection(_ r: Regime) -> some View {
        Section {
            DisclosureGroup(isExpanded: $showHistory) {
                ForEach(r.history.reversed()) { v in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: "\(prettyFullDate(v.effectiveFrom)) – \(v.effectiveTo.map(prettyFullDate) ?? "…")").font(.caption).foregroundStyle(.secondary)
                        ForEach(v.constraints) { c in Text(c.summary).font(.footnote) }
                    }
                }
            } label: {
                Text("Previous versions (\(r.history.count))")
            }
        } footer: {
            Text("Past stays are evaluated against the rules that were in force at the time.")
        }
    }

    // MARK: - Действия

    private func load() async {
        guard let passportId else { return }
        loading = true
        defer { loading = false }
        do {
            let r = try await APIClient.fromSettings().regimeInfo(passportId: passportId, country: countryCode)
            info = r
            if let reg = r.regime, let i = model.regimes.firstIndex(where: { $0.id == reg.id }) { model.regimes[i] = reg }
            else if let reg = r.regime { model.regimes.append(reg) }
            // свежий результат из общего кэша — показать сразу, без повторного запроса
            if check == nil, let cached = r.cachedCheck, cached.status == .done, r.regime == nil {
                check = cached
                diff = nil
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func startCheck(force: Bool) async {
        guard let passportId else { return }
        checking = true
        defer { checking = false }
        do {
            let c = try await APIClient.fromSettings().startRegimeCheck(passportId: passportId, country: countryCode, force: force)
            check = c
            diff = nil
            RegimeChecks.remember(c, passportId: passportId)
            if c.status == .done { await refreshDiff() }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func pollCheck() async {
        guard let id = check?.id, check?.status == .queued || check?.status == .running else {
            if check?.status == .done, diff == nil { await refreshDiff() }
            return
        }
        for _ in 0..<60 {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, let passportId else { return }
            if let (c, d) = try? await APIClient.fromSettings().regimeCheck(id: id, passportId: passportId) {
                check = c
                diff = d
                if c.status == .done || c.status == .failed {
                    RegimeChecks.pending.removeAll { $0.checkId == id }
                    return
                }
            }
        }
    }

    private func refreshDiff() async {
        guard let id = check?.id, let passportId else { return }
        if let (c, d) = try? await APIClient.fromSettings().regimeCheck(id: id, passportId: passportId) {
            check = c
            diff = d
        }
    }

    private func save(_ input: RegimeVersionInput) async {
        guard let passportId else { return }
        var input = input
        input.origin = editorOrigin
        do {
            _ = try await model.confirmRegime(passportId: passportId, country: countryCode, input)
            check = nil
            diff = nil
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func markChecked(_ d: RegimeDraft, _ check: RegimeCheck) async {
        guard let passportId, let a = active else { return }
        let input = RegimeVersionInput(requirement: a.requirement, constraints: a.constraints, conditions: a.conditions, sources: d.sources.isEmpty ? a.sources : d.sources, origin: "ai", model: check.model, notes: a.notes)
        do {
            _ = try await model.confirmRegime(passportId: passportId, country: countryCode, input)
            self.check = nil
            diff = nil
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Редактор версии

struct RegimeEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let title: LocalizedStringKey
    let onSave: (RegimeVersionInput) async -> Void
    @State private var draft: RegimeVersionInput
    @State private var saving = false

    init(initial: RegimeVersionInput, title: LocalizedStringKey, onSave: @escaping (RegimeVersionInput) async -> Void) {
        _draft = State(initialValue: initial)
        self.title = title
        self.onSave = onSave
    }

    var body: some View {
        Form {
            Section {
                Picker("Entry", selection: $draft.requirement) {
                    ForEach(RegimeRequirement.allCases) { Text($0.title).tag($0) }
                }
            } footer: {
                if !draft.requirement.allowsEntry { Text("With a visa required, add the visa itself in Documents — its limits become rules there.") }
            }

            Section {
                ForEach($draft.constraints) { $c in
                    ConstraintRow(constraint: $c)
                }
                .onDelete { draft.constraints.remove(atOffsets: $0) }
                Menu {
                    Button("N days per entry") { draft.constraints.append(RegimeConstraint(type: .perEntry, limitDays: 30)) }
                    Button("N days in any M") { draft.constraints.append(RegimeConstraint(type: .rolling, limitDays: 90, windowDays: 180)) }
                    Button("N days per calendar year") { draft.constraints.append(RegimeConstraint(type: .calendarYear, limitDays: 180)) }
                    Button("N days from a date") { draft.constraints.append(RegimeConstraint(type: .fromDate, limitDays: 90, windowDays: 90, startDate: DocumentInput.todayString())) }
                } label: {
                    Label("Add a limit", systemImage: "plus.circle")
                }
            } header: {
                Text("Stay limits")
            } footer: {
                Text("A country can have several limits at once — for example, 60 days per entry and 90 in any 180. Each becomes its own counting rule.")
            }

            Section {
                ForEach($draft.conditions) { $c in
                    VStack(alignment: .leading, spacing: 6) {
                        Picker("Kind", selection: $c.kind) {
                            ForEach(ConditionKind.allCases) { Text($0.title).tag($0) }
                        }
                        TextField("Condition", text: $c.text, axis: .vertical)
                        if c.kind == .registration {
                            DaysField(title: "Within days of entry", value: Binding(get: { c.withinDays ?? 3 }, set: { c.withinDays = $0 }), range: 1...365)
                        }
                    }
                }
                .onDelete { draft.conditions.remove(atOffsets: $0) }
                Button("Add a condition", systemImage: "plus.circle") {
                    draft.conditions.append(RegimeCondition(kind: .registration, text: "", withinDays: 3))
                }
            } header: {
                Text("Conditions")
            } footer: {
                Text("Registration, passport validity, insurance — anything that isn’t a day count.")
            }

            Section("Notes") {
                TextField("Notes (optional)", text: Binding(get: { draft.notes ?? "" }, set: { draft.notes = $0.isEmpty ? nil : $0 }), axis: .vertical)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    saving = true
                    Task {
                        var out = draft
                        out.conditions = out.conditions.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
                        await onSave(out)
                        saving = false
                        dismiss()
                    }
                } label: {
                    if saving { ProgressView() } else { Text("Confirm") }
                }
                .disabled(saving || (draft.requirement.allowsEntry && draft.constraints.contains { $0.type == .rolling && ($0.windowDays ?? 0) < 2 }))
            }
        }
    }
}

private struct ConstraintRow: View {
    @Binding var constraint: RegimeConstraint

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Type", selection: $constraint.type) {
                ForEach(ConstraintType.allCases) { Text($0.title).tag($0) }
            }
            .onChange(of: constraint.type) { _, t in
                if t == .rolling, constraint.windowDays == nil { constraint.windowDays = 180 }
                if t == .fromDate, constraint.startDate == nil { constraint.startDate = DocumentInput.todayString(); constraint.windowDays = constraint.windowDays ?? constraint.limitDays }
            }
            DaysField(title: "No more than", value: $constraint.limitDays)
            if constraint.type == .rolling {
                DaysField(title: "In any", value: Binding(get: { constraint.windowDays ?? 180 }, set: { constraint.windowDays = $0 }), range: 2...3660)
            }
            if constraint.type == .fromDate {
                DatePicker("Starting on", selection: Binding(
                    get: { Self.parse(constraint.startDate) ?? Date() },
                    set: { constraint.startDate = Self.format($0) }
                ), displayedComponents: .date)
                DaysField(title: "Period length", value: Binding(get: { constraint.windowDays ?? constraint.limitDays }, set: { constraint.windowDays = $0 }))
            }
            TextField("Note (optional)", text: Binding(get: { constraint.note ?? "" }, set: { constraint.note = $0.isEmpty ? nil : $0 }))
                .font(.footnote)
        }
    }

    private static let f: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f }()
    private static func parse(_ s: String?) -> Date? { s.flatMap { f.date(from: $0) } }
    private static func format(_ d: Date) -> String { f.string(from: d) }
}

// Выбор страны → режим (из вкладки «Документы»)
struct CountryLookupView: View {
    @State private var selection: [String]

    init(initial: String? = nil) {
        _selection = State(initialValue: initial.map { [$0] } ?? [])
    }

    var body: some View {
        if let code = selection.first {
            RegimeView(countryCode: code)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Countries", systemImage: "chevron.left") { selection = [] }
                    }
                }
        } else {
            CountryPickerView(selection: $selection, single: true, dismissOnSelect: false)
        }
    }
}
