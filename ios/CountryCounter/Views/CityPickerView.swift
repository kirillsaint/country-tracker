import SwiftUI

// Выбор города для ручной записи. Произвольный ввод не нужен: города берутся из справочника GeoNames
// на сервере (поиск по любому написанию, в том числе по-русски) и из собственной истории.
// Сохраняется английское имя — так город группируется с точками с устройства.
struct CityPickerView: View {
    let country: String
    /// города этой страны из истории пользователя, по убыванию дней
    var known: [String] = []
    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var results: [CityOption] = []
    @State private var loading = false
    @State private var error: String?

    private var knownFiltered: [String] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return known }
        return known.filter { $0.lowercased().hasPrefix(q) || $0.cityDisplayName(country: country).lowercased().hasPrefix(q) }
    }

    var body: some View {
        List {
            if !selection.isEmpty, query.isEmpty {
                Section {
                    Button(role: .destructive) {
                        selection = ""
                        dismiss()
                    } label: {
                        Label("No city", systemImage: "xmark.circle")
                    }
                }
            }

            if !knownFiltered.isEmpty {
                Section("From your history") {
                    ForEach(knownFiltered, id: \.self) { name in
                        row(name: name, region: nil)
                    }
                }
            }

            Section {
                if results.isEmpty, !loading {
                    Text(query.isEmpty ? "No cities in the directory for this country." : "Nothing found — try another spelling or the English name.")
                        .foregroundStyle(.secondary).font(.footnote)
                }
                ForEach(results) { c in
                    row(name: c.name, region: c.region)
                }
                if loading { HStack { Spacer(); ProgressView(); Spacer() } }
            } header: {
                Text(query.isEmpty ? "Largest cities" : "Cities")
            } footer: {
                if let error {
                    Text(error).foregroundStyle(.red)
                } else {
                    Text("City directory: GeoNames (CC BY 4.0). Type any spelling — Russian works too.")
                }
            }
        }
        .navigationTitle("City")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: Text("Search city"))
        .task(id: query) {
            // небольшая пауза, чтобы не дёргать сервер на каждую букву
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await search()
        }
    }

    private func row(name: String, region: String?) -> some View {
        Button {
            selection = name
            dismiss()
        } label: {
            HStack {
                let shown = name.cityDisplayName(country: country)
                VStack(alignment: .leading, spacing: 2) {
                    Text(shown).foregroundStyle(.primary)
                    let caption = [shown != name ? name : nil, region].compactMap { $0 }.joined(separator: " · ")
                    if !caption.isEmpty { Text(caption).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                if selection.caseInsensitiveCompare(name) == .orderedSame {
                    Image(systemName: "checkmark").foregroundStyle(.tint)
                }
            }
        }
    }

    private func search() async {
        loading = true
        error = nil
        do {
            let found = try await APIClient.fromSettings().cities(country: country, query: query)
            // то, что уже есть в истории, не дублируем
            let knownLower = Set(known.map { $0.lowercased() })
            results = found.filter { !knownLower.contains($0.name.lowercased()) }
        } catch {
            if !error.isCancellation { self.error = error.localizedDescription }
        }
        loading = false
    }
}
