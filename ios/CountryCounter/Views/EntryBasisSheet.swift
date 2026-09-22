import SwiftUI

// "Как въехали": одно нажатие на вариант — основание сохранено, лист закрывается. Варианты собираются
// из документов, применимых к стране; визу, ВНЖ или паспорт можно завести прямо отсюда со страной
// и паспортом уже подставленными. Для безвиза правила подсчёта нейросеть исследует сама в фоне
// и применяет, если их ещё нет; результат приходит уведомлением.
struct EntryBasisSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let segment: Segment
    let previous: CurrentStatus.EntryRef?
    let regimeRef: CurrentStatus.RegimeRef?
    private let existing: Entry?
    @State private var note: String
    /// id варианта, который сейчас сохраняется
    @State private var saving: String?
    @State private var error: String?
    @State private var newDocument: NewDocument?

    private struct NewDocument: Identifiable {
        let kind: DocumentKind
        var id: String { kind.rawValue }
    }

    init(segment: Segment, existing: Entry?, previous: CurrentStatus.EntryRef? = nil, regimeRef: CurrentStatus.RegimeRef? = nil) {
        self.segment = segment
        self.previous = previous
        self.regimeRef = regimeRef
        self.existing = existing
        _note = State(initialValue: existing?.note ?? "")
    }

    private var options: [EntryOption] {
        EntryOption.options(for: segment.countryCode, documents: model.documents, previous: previous)
    }

    private func isCurrent(_ o: EntryOption) -> Bool {
        existing?.basis == o.basis && existing?.documentId == o.document?.id
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    FlagView(code: segment.countryCode, width: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(segment.countryCode.countryDisplayName(fallback: segment.countryName)).font(.headline)
                        Text(verbatim: segment.from == segment.to ? prettyDate(segment.from) : "\(prettyDate(segment.from)) – \(prettyDate(segment.to))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                ForEach(options) { o in
                    Button {
                        Task { await choose(basis: o.basis, document: o.document, optionId: o.id) }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: o.isRepeat ? "arrow.counterclockwise" : o.basis.systemImage).frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(o.isRepeat ? String(localized: "Same as last time: \(o.basis.title)") : o.basis.title).foregroundStyle(.primary)
                                if let d = o.document {
                                    Text(verbatim: "\(d.countryCode.flagEmoji) \(d.name)").font(.caption).foregroundStyle(.secondary)
                                } else if o.basis == .visa_free, model.passports.isEmpty {
                                    Text("Add a passport below so the rules can be looked up for it.").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if saving == o.id {
                                ProgressView()
                            } else if isCurrent(o) {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                            }
                        }
                    }
                    .disabled(saving != nil)
                }
            } header: {
                Text("Entered as")
            } footer: {
                Text("Tap an option — it’s saved right away. For visa-free entry the assistant looks up the stay limits and adds the counting rule itself; you’ll get a notification.")
            }

            Section {
                if model.passports.isEmpty {
                    Button { newDocument = NewDocument(kind: .passport) } label: { Label("Add a passport…", systemImage: "plus.circle") }
                }
                Button { newDocument = NewDocument(kind: .visa) } label: { Label("Entered with a visa — add it…", systemImage: "plus.circle") }
                Button { newDocument = NewDocument(kind: .residence) } label: { Label("Have a residence permit — add it…", systemImage: "plus.circle") }
            } header: {
                Text("No matching document?")
            } footer: {
                Text("The country and passport are filled in; after saving, the stay is marked with that document.")
            }
            .disabled(saving != nil)

            if existing != nil {
                Section {
                    TextField("Note (optional)", text: $note, axis: .vertical)
                }

                // Смена статуса без пересечения границы: получил ВНЖ / визу, будучи в стране
                Section {
                    ForEach(model.switches(for: segment)) { e in
                        HStack(spacing: 12) {
                            Image(systemName: e.basis.homeSystemImage).foregroundStyle(e.basis.tint).frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(e.basis.title)
                                Text(String(localized: "from \(prettyFullDate(e.date))")).font(.caption).foregroundStyle(.secondary)
                                if let d = model.document(id: e.documentId) {
                                    Text(verbatim: "\(d.countryCode.flagEmoji) \(d.name)").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                        }
                        .swipeActions {
                            Button("Delete", role: .destructive) {
                                Task { try? await model.deleteEntry(countryCode: segment.countryCode, date: e.date) }
                            }
                        }
                    }
                    NavigationLink {
                        BasisSwitchView(segment: segment)
                    } label: {
                        Label("Status changed during this stay…", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(segment.from == segment.to)
                } header: {
                    Text("Changes during the stay")
                } footer: {
                    Text("For a residence permit or visa obtained without leaving the country. From that date, days no longer count toward the visa-free or previous visa limits.")
                }
            }

            Section {
                NavigationLink {
                    RegimeView(countryCode: segment.countryCode, initialPassportId: existing?.documentId)
                } label: {
                    Label("Entry rules for this country", systemImage: "list.bullet.rectangle")
                }
                if existing != nil {
                    Button("Clear basis", role: .destructive) {
                        Task {
                            do {
                                try await model.deleteEntry(countryCode: segment.countryCode, date: segment.from)
                                dismiss()
                            } catch { self.error = error.localizedDescription }
                        }
                    }
                }
            }

            if let error {
                Section { Text(error).foregroundStyle(.red).font(.footnote) }
            }
        }
        .navigationTitle("Entry basis")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button(existing == nil ? "Cancel" : "Done") { dismiss() } }
            if let existing {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save note") { Task { await choose(basis: existing.basis, document: model.document(id: existing.documentId), optionId: "note") } }
                        .disabled(saving != nil || note.trimmingCharacters(in: .whitespaces) == (existing.note ?? ""))
                }
            }
        }
        .sheet(item: $newDocument) { item in
            NavigationStack {
                DocumentEditView(
                    document: nil,
                    kind: item.kind,
                    presetCountry: item.kind == .passport ? nil : segment.countryCode,
                    presetPassportId: model.passports.first?.id
                ) { doc in
                    // паспорт этой страны — гражданин, чужой — безвиз; виза и ВНЖ — по документу
                    let basis: EntryBasis = switch item.kind {
                    case .passport: doc.countryCode == segment.countryCode ? .citizen : .visa_free
                    case .visa: .visa
                    case .residence: .residence
                    }
                    Task { await choose(basis: basis, document: doc, optionId: "new") }
                }
            }
        }
    }

    /// Сохранить основание и закрыть лист. Безвиз: проверка условий нейросетью в фоне; если правил для
    /// этого паспорта и страны ещё нет, сервер применит результат сам, если они устарели — перепроверит.
    private func choose(basis: EntryBasis, document: TravelDocument?, optionId: String) async {
        saving = optionId
        error = nil
        defer { saving = nil }
        let trimmed = note.trimmingCharacters(in: .whitespaces)
        do {
            try await model.setEntry(countryCode: segment.countryCode, date: segment.from, basis: basis, documentId: document?.id, note: trimmed.isEmpty ? nil : trimmed)
            if basis == .visa_free, let passportId = document?.id, model.aiEnabled {
                let regime = model.regime(passportId: passportId, country: segment.countryCode)
                let fresh = regime?.lastCheckedAt.map { (daysBetween(String($0.prefix(10)), DocumentInput.todayString()) ?? 0) < model.regimeFreshDays } ?? false
                if regime?.active == nil || !fresh {
                    if let (check, applied) = try? await APIClient.fromSettings().startRegimeCheck(passportId: passportId, country: segment.countryCode, force: false, autoApply: true) {
                        RegimeChecks.remember(check, passportId: passportId)
                        if applied { await model.refresh() }
                    }
                }
            }
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// Бейдж основания в строке хронологии
struct EntryBadge: View {
    let entry: Entry
    let document: TravelDocument?

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: entry.basis.systemImage)
            Text(entry.basis.title)
            if let document, entry.basis != .citizen { Text(document.countryCode.flagEmoji) }
        }
        .font(.caption2)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Capsule().fill(Color.accentColor.opacity(0.12)))
        .foregroundStyle(.tint)
    }
}
