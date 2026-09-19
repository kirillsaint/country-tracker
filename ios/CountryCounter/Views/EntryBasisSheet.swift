import SwiftUI

// "Как въехали": основание для отрезка пребывания. Варианты собираются из документов,
// применимых к стране: свой паспорт, ВНЖ, визы, безвиз по одному из паспортов, транзит.
struct EntryBasisSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let segment: Segment
    let previous: CurrentStatus.EntryRef?
    @State private var basis: EntryBasis?
    @State private var documentId: String?
    @State private var note: String
    @State private var saving = false
    @State private var error: String?
    @State private var info: String?

    init(segment: Segment, existing: Entry?, previous: CurrentStatus.EntryRef? = nil) {
        self.segment = segment
        self.previous = previous
        _basis = State(initialValue: existing?.basis)
        _documentId = State(initialValue: existing?.documentId)
        _note = State(initialValue: existing?.note ?? "")
    }

    private var options: [EntryOption] {
        EntryOption.options(for: segment.countryCode, documents: model.documents, previous: previous)
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
                        basis = o.basis
                        documentId = o.document?.id
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: o.isRepeat ? "arrow.counterclockwise" : o.basis.systemImage).frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(o.isRepeat ? String(localized: "Same as last time: \(o.basis.title)") : o.basis.title).foregroundStyle(.primary)
                                if let d = o.document {
                                    Text(verbatim: "\(d.countryCode.flagEmoji) \(d.name)").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if basis == o.basis && documentId == o.document?.id {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                            }
                        }
                    }
                }
            } header: {
                Text("Entered as")
            } footer: {
                if basis == .visa_free {
                    Text("A stay-limit rule will be created from the visa reference for this passport. You can check or change it in “Entry conditions”.")
                }
            }

            NavigationLink {
                CountryInfoView(countryCode: segment.countryCode)
            } label: {
                Label("Entry conditions for this country", systemImage: "list.bullet.rectangle")
            }

            Section {
                TextField("Note (optional)", text: $note, axis: .vertical)
            }

            if let info {
                Section { Text(info).foregroundStyle(.secondary).font(.footnote) }
            }
            if let error {
                Section { Text(error).foregroundStyle(.red).font(.footnote) }
            }

            if model.entry(for: segment) != nil {
                Section {
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
        }
        .navigationTitle("Entry basis")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(action: save) {
                    if saving { ProgressView() } else { Text("Save") }
                }
                .disabled(saving || basis == nil)
            }
        }
    }

    private func save() {
        guard let basis else { return }
        saving = true
        error = nil
        let trimmed = note.trimmingCharacters(in: .whitespaces)
        Task {
            do {
                try await model.setEntry(countryCode: segment.countryCode, date: segment.from, basis: basis, documentId: documentId, note: trimmed.isEmpty ? nil : trimmed)
                if basis == .visa_free, let documentId {
                    // Правило безвиза по справочнику; если справочник молчит — просто сохраняем основание
                    if let rule = try? await model.ensureVisaFreeRule(country: segment.countryCode, passportId: documentId) {
                        info = String(localized: "Rule created: \(rule.name)")
                        try? await Task.sleep(for: .seconds(1))
                    }
                }
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            saving = false
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
