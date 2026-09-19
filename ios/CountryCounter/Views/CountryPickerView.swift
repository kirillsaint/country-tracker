import SwiftUI

// Выбор стран с поиском. Список — все ISO-регионы из системной локали.
// single = true — выбирается одна страна, и экран закрывается.
struct CountryPickerView: View {
    @Binding var selection: [String]
    var single = false
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private static let all: [(code: String, name: String)] = {
        Locale.Region.isoRegions
            .map(\.identifier)
            .filter { $0.count == 2 && $0.allSatisfy(\.isLetter) }
            .compactMap { code in
                Locale.current.localizedString(forRegionCode: code).map { (code: code, name: $0) }
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }()

    private var filtered: [(code: String, name: String)] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return Self.all }
        return Self.all.filter { $0.name.localizedCaseInsensitiveContains(q) || $0.code.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        List {
            if !single {
                Section {
                    Button("Schengen (\(RulePresets.schengen.count))") { selection = RulePresets.schengen }
                    Button("Clear — any country", role: .destructive) { selection = [] }
                        .disabled(selection.isEmpty)
                } footer: {
                    Text(selection.isEmpty ? "Nothing selected: days in any country are counted." : "Selected: \(selection.count)")
                }

                if !selection.isEmpty && query.isEmpty {
                    Section("Selected") {
                        ForEach(selection.sorted(), id: \.self) { code in
                            row(code: code, name: code.countryDisplayName(fallback: nil))
                        }
                    }
                }
            }

            Section(query.isEmpty ? "All countries" : "Found") {
                ForEach(filtered, id: \.code) { item in
                    row(code: item.code, name: item.name)
                }
            }
        }
        .searchable(text: $query, prompt: "Country or code")
        .navigationTitle(single ? "Country" : "Countries")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(code: String, name: String) -> some View {
        Button {
            if single {
                selection = [code]
                dismiss()
            } else if let i = selection.firstIndex(of: code) {
                selection.remove(at: i)
            } else {
                selection.append(code)
            }
        } label: {
            HStack(spacing: 12) {
                FlagView(code: code, width: 30)
                Text(name).foregroundStyle(.primary)
                Spacer()
                Text(code).font(.caption).foregroundStyle(.secondary)
                if selection.contains(code) {
                    Image(systemName: "checkmark").foregroundStyle(.tint)
                }
            }
        }
    }
}
