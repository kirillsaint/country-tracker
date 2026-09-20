import SwiftUI

// Продление визы / ВНЖ: тот же документ, новые даты. Старый срок уходит в историю документа,
// правила пересобираются под новый срок, основания въезда остаются привязанными.
struct RenewDocumentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let document: TravelDocument
    @State private var updateStart: Bool
    @State private var validFrom: Date
    @State private var validTo: Date
    @State private var saving = false
    @State private var error: String?

    init(document: TravelDocument) {
        self.document = document
        let oldTo = document.validTo.flatMap(Self.parse) ?? Date()
        let oldFrom = document.validFrom.flatMap(Self.parse)
        // новый срок начинается на следующий день после старого и длится столько же, но не меньше года
        let start = Calendar.current.date(byAdding: .day, value: 1, to: oldTo) ?? oldTo
        let previousDays = oldFrom.map { Calendar.current.dateComponents([.day], from: $0, to: oldTo).day ?? 0 } ?? 0
        let newTo = Calendar.current.date(byAdding: .day, value: max(previousDays, 365), to: start) ?? start
        _updateStart = State(initialValue: document.validFrom != nil)
        _validFrom = State(initialValue: start)
        _validTo = State(initialValue: newTo)
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Current period") {
                    Text(verbatim: "\(document.validFrom.map(prettyFullDate) ?? "…") – \(document.validTo.map(prettyFullDate) ?? "…")")
                }
            }
            Section {
                Toggle("New start date", isOn: $updateStart)
                if updateStart {
                    DatePicker("From", selection: $validFrom, displayedComponents: .date)
                }
                DatePicker("Valid until", selection: $validTo, in: (updateStart ? validFrom : .distantPast)..., displayedComponents: .date)
            } footer: {
                Text("The document keeps its rules and history; the old dates are saved as a previous period.")
            }
            if let error {
                Section { Text(error).foregroundStyle(.red).font(.footnote) }
            }
        }
        .navigationTitle("Renew")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: validFrom) { _, f in if validTo < f { validTo = f } }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(action: save) {
                    if saving { ProgressView() } else { Text("Save") }
                }
                .disabled(saving)
            }
        }
    }

    private func save() {
        saving = true
        error = nil
        Task {
            do {
                try await model.renewDocument(document, validFrom: updateStart ? Self.format(validFrom) : nil, validTo: Self.format(validTo))
                await model.refresh()
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            saving = false
        }
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f
    }()
    private static func parse(_ s: String) -> Date? { formatter.date(from: s) }
    private static func format(_ d: Date) -> String { formatter.string(from: d) }
}
