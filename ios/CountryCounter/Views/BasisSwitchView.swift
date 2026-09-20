import SwiftUI

// Смена статуса внутри пребывания: был по безвизу, получил ВНЖ — граница не пересекалась,
// но с этого дня дни считаются по новому основанию.
struct BasisSwitchView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let segment: Segment
    @State private var date: Date
    @State private var basis: EntryBasis?
    @State private var documentId: String?
    @State private var note = ""
    @State private var saving = false
    @State private var error: String?

    private let lower: String
    private let upper: String

    init(segment: Segment) {
        self.segment = segment
        let today = DocumentInput.todayString()
        lower = Self.addDay(segment.from)
        upper = min(segment.to, today)
        _date = State(initialValue: Self.parse(max(lower, upper)))
    }

    private var possible: Bool { lower <= upper }

    private var range: ClosedRange<Date> {
        Self.parse(lower)...Self.parse(max(lower, upper))
    }

    /// Сменой статуса бывают ВНЖ, виза или что-то ещё; безвиз и гражданство сменой не становятся
    private var options: [EntryOption] {
        EntryOption.options(for: segment.countryCode, documents: model.documents, previous: nil)
            .filter { [EntryBasis.residence, .visa, .other].contains($0.basis) }
    }

    var body: some View {
        Form {
            Section {
                if possible {
                    DatePicker("Since", selection: $date, in: range, displayedComponents: .date)
                } else {
                    Text("Not possible for a one-day stay.").foregroundStyle(.secondary)
                }
            } footer: {
                Text("The day the new status took effect — usually the issue date of the permit. It must be after the arrival day.")
            }

            Section("New status") {
                ForEach(options) { o in
                    Button {
                        basis = o.basis
                        documentId = o.document?.id
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: o.basis.homeSystemImage).foregroundStyle(o.basis.tint).frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(o.basis.title).foregroundStyle(.primary)
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
            }

            Section {
                TextField("Note (optional)", text: $note, axis: .vertical)
            }

            if let error {
                Section { Text(error).foregroundStyle(.red).font(.footnote) }
            }
        }
        .navigationTitle("Status change")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(action: save) {
                    if saving { ProgressView() } else { Text("Save") }
                }
                .disabled(saving || basis == nil || !possible)
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
                try await model.setEntry(countryCode: segment.countryCode, date: Self.format(date), basis: basis, documentId: documentId,
                                         note: trimmed.isEmpty ? nil : trimmed, kind: .statusChange)
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
    private static func parse(_ s: String) -> Date { formatter.date(from: s) ?? Date() }
    private static func format(_ d: Date) -> String { formatter.string(from: d) }
    private static func addDay(_ s: String) -> String {
        format(Calendar.current.date(byAdding: .day, value: 1, to: parse(s)) ?? parse(s))
    }
}
