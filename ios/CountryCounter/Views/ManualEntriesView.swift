import SwiftUI

// Ручные записи: "был в стране X (город) с ... по ...". Перекрывают автоматический расчёт
// за эти дни — для истории до установки приложения и для правок, когда GPS наврал.
struct ManualEntriesView: View {
    @Environment(AppModel.self) private var model
    @State private var showAdd = false

    var body: some View {
        List {
            if model.manualRanges.isEmpty {
                ContentUnavailableView(
                    "Ручных записей нет",
                    systemImage: "square.and.pencil",
                    description: Text("Добавьте поездки до установки приложения или поправьте дни, где геолокация ошиблась.")
                )
            }
            ForEach(model.manualRanges) { r in
                HStack(spacing: 12) {
                    FlagView(code: r.countryCode, width: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.countryCode.countryDisplayName(fallback: r.countryName)).font(.headline)
                        if let city = r.city, !city.isEmpty {
                            Text(city).foregroundStyle(.secondary)
                        }
                        Text(r.from == r.to ? prettyDate(r.from) : "\(prettyDate(r.from)) – \(prettyDate(r.to))")
                            .font(.caption).foregroundStyle(.secondary)
                        if let note = r.note, !note.isEmpty {
                            Text(note).font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    Spacer()
                    Text(pluralDays(r.days)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .onDelete { offsets in
                let toDelete = offsets.map { model.manualRanges[$0] }
                Task { for r in toDelete { await model.delete(r) } }
            }
        }
        .navigationTitle("Ручные записи")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Добавить", systemImage: "plus") { showAdd = true }
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

    @State private var countries: [String] = []
    @State private var city = ""
    @State private var note = ""
    @State private var from = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
    @State private var to = Date()
    @State private var saving = false
    @State private var error: String?

    private var country: String? { countries.first }

    var body: some View {
        Form {
            Section {
                NavigationLink {
                    CountryPickerView(selection: $countries, single: true)
                } label: {
                    HStack {
                        Text("Страна")
                        Spacer()
                        if let country {
                            FlagView(code: country, width: 24)
                            Text(country.countryDisplayName(fallback: nil)).foregroundStyle(.secondary)
                        } else {
                            Text("Выбрать").foregroundStyle(.secondary)
                        }
                    }
                }
                TextField("Город (необязательно)", text: $city)
            }

            Section {
                DatePicker("С", selection: $from, in: ...Date(), displayedComponents: .date)
                DatePicker("По", selection: $to, in: from...Date(), displayedComponents: .date)
            } footer: {
                Text("Включительно. Дни в этом диапазоне будут считаться проведёнными в выбранной стране, что бы ни говорила геолокация.")
            }

            Section {
                TextField("Заметка (необязательно)", text: $note, axis: .vertical)
            }

            if let error {
                Section { Text(error).foregroundStyle(.red).font(.footnote) }
            }
        }
        .navigationTitle("Новая запись")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(action: save) {
                    if saving { ProgressView() } else { Text("Сохранить") }
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
                try await model.addRange(
                    from: f.string(from: from), to: f.string(from: to), countryCode: country,
                    city: trimmedCity.isEmpty ? nil : trimmedCity, note: trimmedNote.isEmpty ? nil : trimmedNote
                )
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            saving = false
        }
    }
}
