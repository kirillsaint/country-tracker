import SwiftUI
import VisionKit

// Сканирование паспорта / визы / карты ВНЖ камерой. Основной путь — машиночитаемая зона (MRZ):
// разбирается на телефоне с проверкой контрольных цифр, фото никуда не уходит и не сохраняется.
// Запасной путь для документов без MRZ — распознанный текст (не фото) отправляется помощнику.
// Результат в любом случае открывается в редакторе документа на подтверждение.
struct ScanDocumentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let onResult: (DocumentInput) -> Void

    @StateObject private var state = ScanState()
    @State private var parsing = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            if DataScannerViewController.isSupported {
                ScannerView(state: state)
                    .ignoresSafeArea(edges: .top)
            } else {
                ContentUnavailableView("Scanning isn’t available on this device", systemImage: "camera.fill", description: Text("A real iPhone with a camera is needed — the simulator can’t scan."))
            }
            VStack(spacing: 10) {
                Text(status).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                if let error { Text(error).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center) }
                if model.aiEnabled {
                    Button {
                        Task { await parseWithAssistant() }
                    } label: {
                        if parsing { ProgressView() } else { Label("No machine-readable zone? Use the recognized text", systemImage: "text.viewfinder") }
                    }
                    .buttonStyle(.bordered)
                    .disabled(parsing || state.lines.isEmpty)
                }
            }
            .padding()
        }
        .navigationTitle("Scan a document")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        .onChange(of: state.mrz) { _, mrz in
            guard let mrz else { return }
            onResult(Self.input(from: mrz, lines: state.lines))
            dismiss()
        }
    }

    private var status: String {
        if state.lines.isEmpty { return String(localized: "Point the camera at the document: for a passport, the two lines with «<<<» at the bottom.") }
        return String(localized: "Reading… \(state.lines.count) lines recognized. Hold the machine-readable zone in frame.")
    }

    /// Поля документа из MRZ + подсказки из видимой части (число въездов и дата начала у виз)
    static func input(from mrz: MRZ.Result, lines: [String]) -> DocumentInput {
        let text = lines.joined(separator: "\n").uppercased()
        switch mrz.type {
        case .passport:
            let country = mrz.nationality ?? mrz.issuer ?? ""
            return DocumentInput(kind: .passport, name: "", countryCode: country, validTo: mrz.expiry)
        case .visa:
            let hints = visaHints(text: text, expiry: mrz.expiry)
            return DocumentInput(kind: .visa, name: "", countryCode: mrz.issuer ?? "", validFrom: hints.from, validTo: mrz.expiry, entries: hints.entries)
        case .card:
            return DocumentInput(kind: .residence, name: "", countryCode: mrz.issuer ?? "", validTo: mrz.expiry)
        }
    }

    /// Виза: «MULT» / «ENTRIES 01» и даты вида DD-MM-YY, DD.MM.YYYY в видимой зоне
    static func visaHints(text: String, expiry: String) -> (entries: VisaEntries?, from: String?) {
        var entries: VisaEntries?
        if text.range(of: #"\bMULT"#, options: .regularExpression) != nil { entries = .multiple }
        else if text.range(of: #"(ENTRIES|ENTRY|ВЪЕЗД)[^\n]{0,20}\b(01|1|SINGLE|ОДНОКР)"#, options: .regularExpression) != nil { entries = .single }
        var dates: [String] = []
        if let re = try? NSRegularExpression(pattern: #"\b(\d{2})[-./](\d{2})[-./](\d{2}|\d{4})\b"#) {
            for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let d = Range(m.range(at: 1), in: text), let mo = Range(m.range(at: 2), in: text), let y = Range(m.range(at: 3), in: text) else { continue }
                var year = String(text[y])
                if year.count == 2 { year = "20" + year }
                dates.append("\(year)-\(text[mo])-\(text[d])")
            }
        }
        // дата начала — самая ранняя из напечатанных, но не раньше чем за 5 лет до окончания
        let from = dates.filter { $0 < expiry && $0 >= String(format: "%04d", (Int(expiry.prefix(4)) ?? 2000) - 5) }.min()
        return (entries, from)
    }

    private func parseWithAssistant() async {
        parsing = true
        error = nil
        defer { parsing = false }
        do {
            let draft = try await APIClient.fromSettings().parseDocument(text: state.lines.joined(separator: "\n"))
            guard draft.kind != "unknown", let kind = DocumentKind(rawValue: draft.kind) else {
                error = String(localized: "Couldn’t tell what this document is. Try a clearer shot of the page with dates.")
                return
            }
            var input = DocumentInput(kind: kind, name: "", countryCode: draft.countryCode ?? "")
            input.validFrom = draft.validFrom
            input.validTo = draft.validTo
            input.entries = draft.entries.flatMap(VisaEntries.init(rawValue:))
            input.maxStayDays = draft.maxStayDays
            input.note = draft.note
            onResult(input)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Строки, распознанные камерой, и результат разбора MRZ
final class ScanState: ObservableObject {
    @Published var lines: [String] = []
    @Published var mrz: MRZ.Result?
}

private struct ScannerView: UIViewControllerRepresentable {
    @ObservedObject var state: ScanState

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.text()],
            qualityLevel: .accurate,
            recognizesMultipleItems: true,
            isHighFrameRateTrackingEnabled: false,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        if !scanner.isScanning, DataScannerViewController.isAvailable { try? scanner.startScanning() }
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(state: state) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let state: ScanState
        init(state: ScanState) { self.state = state }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) { handle(allItems, dataScanner) }
        func dataScanner(_ dataScanner: DataScannerViewController, didUpdate updatedItems: [RecognizedItem], allItems: [RecognizedItem]) { handle(allItems, dataScanner) }

        private func handle(_ items: [RecognizedItem], _ dataScanner: DataScannerViewController) {
            guard state.mrz == nil else { return }
            let lines = items.compactMap { item -> String? in
                if case .text(let t) = item { return t.transcript }
                return nil
            }
            state.lines = lines
            // MRZ может прийти одной строкой с переносом — режем по строкам
            let split = lines.flatMap { $0.components(separatedBy: .newlines) }
            if let result = MRZ.parse(lines: split) {
                state.mrz = result
                dataScanner.stopScanning()
            }
        }
    }
}
