import SwiftUI

// Паспорта, визы, ВНЖ/ПМЖ. Из виз и ВНЖ сервер собирает правила подсчёта автоматически.
struct DocumentsView: View {
    @Environment(AppModel.self) private var model
    @State private var newKind: DocumentKind?
    @State private var cacheStatus: [VisaCacheStatus] = []
    @State private var referenceEnabled = true
    @State private var showLookup = false

    var body: some View {
        NavigationStack {
            List {
                if model.documents.isEmpty {
                    ContentUnavailableView(
                        "No documents yet",
                        systemImage: "person.text.rectangle",
                        description: Text("Add your passport, then visas and residence permits. Counting rules for them are created automatically.")
                    )
                }
                ForEach(DocumentKind.allCases) { kind in
                    let docs = model.documents.filter { $0.kind == kind }
                    if !docs.isEmpty {
                        Section {
                            ForEach(docs) { doc in
                                NavigationLink {
                                    DocumentEditView(document: doc)
                                } label: {
                                    DocumentRow(document: doc, passport: model.document(id: doc.passportId), rules: model.rules.filter { $0.documentId == doc.id })
                                }
                            }
                            .onDelete { offsets in
                                let toDelete = offsets.map { docs[$0] }
                                Task { for d in toDelete { await model.deleteDocument(d) } }
                            }
                        } header: {
                            Text(kind.pluralTitle)
                        } footer: {
                            if kind == .passport { referenceFooter }
                        }
                    }
                }
            }
            .navigationTitle("Documents")
            .refreshable {
                await model.refresh()
                await loadStatus()
            }
            .task(id: model.passports.count) { await loadStatus() }
            .onAppear {
                #if DEBUG
                // xcrun simctl launch … -debugCountryInfo GE — сразу открыть условия въезда
                if UserDefaults.standard.string(forKey: "debugCountryInfo") != nil { showLookup = true }
                #endif
            }
            .sheet(isPresented: $showLookup) {
                NavigationStack {
                    CountryLookupView(initial: UserDefaults.standard.string(forKey: "debugCountryInfo"))
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { showLookup = false } } }
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Check a country", systemImage: "magnifyingglass") { showLookup = true }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        ForEach(DocumentKind.allCases) { kind in
                            Button(kind.title, systemImage: kind.systemImage) { newKind = kind }
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(item: $newKind) { kind in
                NavigationStack { DocumentEditView(document: nil, kind: kind) }
            }
        }
    }
}

extension DocumentsView {
    @ViewBuilder
    var referenceFooter: some View {
        if !referenceEnabled {
            Text("Visa reference is off on the server — entry conditions are set by hand.")
        } else if cacheStatus.isEmpty {
            Text("The visa reference downloads entry conditions for each passport and refreshes them weekly.")
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(cacheStatus) { st in
                    HStack(spacing: 6) {
                        Text(verbatim: st.passport.flagEmoji)
                        if st.inProgress {
                            ProgressView().controlSize(.mini)
                            Text("Downloading reference: \(st.cached) of \(st.total)")
                        } else if let last = st.lastFetchedAt {
                            Text("Reference: \(st.fresh) of \(st.total) destinations, updated \(prettyDate(String(last.prefix(10))))")
                        } else {
                            Text("Reference not downloaded yet")
                        }
                        Button("Refresh") {
                            Task {
                                try? await APIClient.fromSettings().refreshVisaCache(passport: st.passport)
                                await loadStatus()
                            }
                        }
                        .font(.footnote)
                    }
                }
            }
        }
    }

    func loadStatus() async {
        guard let client = try? APIClient.fromSettings(), let st = try? await client.visaCacheStatus() else { return }
        referenceEnabled = st.enabled
        cacheStatus = st.passports
    }
}

struct DocumentRow: View {
    let document: TravelDocument
    let passport: TravelDocument?
    let rules: [Rule]

    var body: some View {
        HStack(spacing: 12) {
            FlagView(code: document.countryCode, width: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(document.name).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                if let expiry = expiryText {
                    Text(expiry.text).font(.caption).foregroundStyle(expiry.color)
                }
            }
            Spacer()
            if !rules.isEmpty {
                Text(verbatim: "\(rules.count)")
                    .font(.caption2.bold())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                    .accessibilityLabel(Text("\(rules.count) rules"))
            }
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        switch document.kind {
        case .passport:
            parts.append(document.countryCode.countryDisplayName(fallback: nil))
        case .visa:
            if document.countries.count > 1 { parts.append(String(localized: "\(document.countries.count) countries")) }
            if let n = document.maxStayDays { parts.append(String(localized: "\(pluralDays(n)) per entry")) }
            if let l = document.windowLimitDays, let w = document.windowDays { parts.append("\(l)/\(w)") }
            if let e = document.entries { parts.append(e.title) }
        case .residence:
            if let t = document.residenceType { parts.append(t.title) }
            if let n = document.minDaysPerYear { parts.append(String(localized: "≥ \(pluralDays(n)) a year")) }
            if let n = document.maxAbsenceDays { parts.append(String(localized: "≤ \(pluralDays(n)) away")) }
        }
        if let passport, document.kind != .passport {
            parts.append(String(localized: "by \(passport.countryCode.flagEmoji) passport"))
        }
        return parts.joined(separator: " · ")
    }

    private var expiryText: (text: String, color: Color)? {
        guard let left = document.daysUntilExpiry, let to = document.validTo else { return nil }
        if left < 0 { return (String(localized: "Expired \(prettyFullDate(to))"), .red) }
        if left <= 30 { return (String(localized: "Expires in \(pluralDays(left))"), .orange) }
        return (String(localized: "Valid until \(prettyFullDate(to))"), .secondary)
    }
}
