import SwiftUI

// Ручные записи: "был в стране X (город) с ... по ...". Перекрывают автоматический расчёт
// за эти дни — для истории до установки приложения и для правок, когда GPS наврал.
struct ManualEntriesView: View {
    @Environment(AppModel.self) private var model
    @State private var showAdd = false
    @State private var editing: ManualRange?

    var body: some View {
        List {
            if model.manualRanges.isEmpty {
                ContentUnavailableView(
                    "No manual entries",
                    systemImage: "square.and.pencil",
                    description: Text("Add trips from before you installed the app, or fix days where location was wrong.")
                )
            }
            ForEach(model.manualRanges) { r in
                Button {
                    editing = r
                } label: {
                HStack(spacing: 12) {
                    FlagView(code: r.countryCode, width: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.countryCode.countryDisplayName(fallback: r.countryName)).font(.headline)
                        if let city = r.city, !city.isEmpty {
                            Text(city).foregroundStyle(.secondary)
                        }
                        Text(verbatim: r.from == r.to ? prettyDate(r.from) : "\(prettyDate(r.from)) – \(prettyDate(r.to))")
                            .font(.caption).foregroundStyle(.secondary)
                        if let note = r.note, !note.isEmpty {
                            Text(note).font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    Spacer()
                    Text(pluralDays(r.days)).monospacedDigit().foregroundStyle(.secondary)
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .onDelete { offsets in
                let toDelete = offsets.map { model.manualRanges[$0] }
                Task { for r in toDelete { await model.delete(r) } }
            }
        }
        .sheet(item: $editing) { r in
            NavigationStack { ManualEntryEditView(existing: r) }
        }
        .navigationTitle("Manual entries")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add", systemImage: "plus") { showAdd = true }
            }
        }
        .sheet(isPresented: $showAdd) {
            NavigationStack { ManualEntryEditView() }
        }
    }
}

struct ManualEntryEditView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    /// nil — новая запись
    let existing: ManualRange?
    @State private var countries: [String]
    @State private var city: String
    @State private var note: String
    @State private var from: Date
    @State private var to: Date
    @State private var saving = false
    @State private var error: String?
    @State private var confirmDelete = false

    init(existing: ManualRange? = nil) {
        self.existing = existing
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        _countries = State(initialValue: existing.map { [$0.countryCode] } ?? [])
        _city = State(initialValue: existing?.city ?? "")
        _note = State(initialValue: existing?.note ?? "")
        _from = State(initialValue: existing.flatMap { f.date(from: $0.from) } ?? Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date())
        _to = State(initialValue: existing.flatMap { f.date(from: $0.to) } ?? Date())
    }

    private var country: String? { countries.first }

    var body: some View {
        Form {
            Section {
                NavigationLink {
                    CountryPickerView(selection: $countries, single: true)
                } label: {
                    HStack {
                        Text("Country")
                        Spacer()
                        if let country {
                            FlagView(code: country, width: 24)
                            Text(country.countryDisplayName(fallback: nil)).foregroundStyle(.secondary)
                        } else {
                            Text("Choose").foregroundStyle(.secondary)
                        }
                    }
                }
                TextField("City (optional)", text: $city)
            }

            Section {
                DatePicker("From", selection: $from, in: ...Date(), displayedComponents: .date)
                DatePicker("To", selection: $to, in: from...Date(), displayedComponents: .date)
            } footer: {
                Text("Inclusive. Days in this range count as spent in the selected country, whatever location data says. A travel day can belong to two entries: end one on the 17th and start the next on the 17th — that day counts for both, with the later country as the main one.")
            }

            Section {
                TextField("Note (optional)", text: $note, axis: .vertical)
            }

            if let error {
                Section { Text(error).foregroundStyle(.red).font(.footnote) }
            }

            if existing != nil {
                Section {
                    Button("Delete entry", role: .destructive) { confirmDelete = true }
                }
            }
        }
        .confirmationDialog("Delete this entry?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                guard let existing else { return }
                Task {
                    await model.delete(existing)
                    dismiss()
                }
            }
        }
        .navigationTitle(existing == nil ? "New entry" : "Edit entry")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(action: save) {
                    if saving { ProgressView() } else { Text("Save") }
                }
                .disabled(saving || country == nil)
            }
        }
        .onChange(of: from) { _, newFrom in if to < newFrom { to = newFrom } }
    }

    private func save() {
        guard let country else { return }
        saving = true
        error = nil
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let trimmedCity = city.trimmingCharacters(in: .whitespaces)
        let trimmedNote = note.trimmingCharacters(in: .whitespaces)
        Task {
            do {
                if let existing {
                    try await model.updateRange(
                        existing, from: f.string(from: from), to: f.string(from: to), countryCode: country,
                        city: trimmedCity.isEmpty ? nil : trimmedCity, note: trimmedNote.isEmpty ? nil : trimmedNote
                    )
                } else {
                    try await model.addRange(
                        from: f.string(from: from), to: f.string(from: to), countryCode: country,
                        city: trimmedCity.isEmpty ? nil : trimmedCity, note: trimmedNote.isEmpty ? nil : trimmedNote
                    )
                }
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            saving = false
        }
    }
}
