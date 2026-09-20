import SwiftUI

// Паспорта, визы, ВНЖ/ПМЖ. Из виз и ВНЖ сервер собирает правила подсчёта автоматически.
struct DocumentsView: View {
    @Environment(AppModel.self) private var model
    @State private var newKind: DocumentKind?
    @State private var showLookup = false

    var body: some View {
        NavigationStack {
            List {
                if model.showSkeleton {
                    Section { SkeletonRow(lines: 2, trailing: false) } header: { SkeletonBar(width: 90, height: 12).skeleton() }
                    Section { SkeletonRow(lines: 3, trailing: false) } header: { SkeletonBar(width: 60, height: 12).skeleton() }
                } else if model.documents.isEmpty {
                    ContentUnavailableView(
                        "No documents yet",
                        systemImage: "person.text.rectangle",
                        description: Text("Add your passport, then visas and residence permits. Counting rules for them are created automatically.")
                    )
                }
                regimesSection

                ForEach(DocumentKind.allCases) { kind in
                    let docs = model.documents.filter { $0.kind == kind }
                    if !docs.isEmpty {
                        Section {
                            ForEach(docs) { doc in
                                NavigationLink {
                                    DocumentEditView(document: doc)
                                } label: {
                                    DocumentRow(document: doc, passport: model.document(id: doc.passportId), rules: model.rules.filter { $0.documentId == doc.id }, usage: model.visaUsage(doc))
                                }
                            }
                            .onDelete { offsets in
                                let toDelete = offsets.map { docs[$0] }
                                Task { for d in toDelete { await model.deleteDocument(d) } }
                            }
                        } header: {
                            Text(kind.pluralTitle)
                        } footer: {
                            if kind == .passport { Text("Entry rules per country are kept under “Check a country” and appear automatically when you arrive somewhere new.") }
                        }
                    }
                }
            }
            .navigationTitle("Documents")
            .refreshable { await model.refresh() }
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
    var regimesSection: some View {
        if !model.passports.isEmpty {
            Section {
                if model.regimes.isEmpty {
                    Text("No entry rules recorded yet. Check a country to see what your passport allows — or wait: the app asks when you arrive somewhere new.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(model.regimes.sorted { $0.updatedAt > $1.updatedAt }) { r in
                    NavigationLink {
                        RegimeView(countryCode: r.countryCode, initialPassportId: r.passportId)
                    } label: {
                        RegimeRow(regime: r, freshDays: model.regimeFreshDays)
                    }
                }
                Button("Check a country", systemImage: "magnifyingglass") { showLookup = true }
            } header: {
                Text("Entry rules")
            }
        }
    }
}

struct RegimeRow: View {
    let regime: Regime
    let freshDays: Int

    var body: some View {
        HStack(spacing: 12) {
            FlagView(code: regime.countryCode, width: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(regime.countryCode.countryDisplayName(fallback: nil)).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Text(status.text).font(.caption).foregroundStyle(status.color)
            }
        }
    }

    private var subtitle: String {
        guard let a = regime.active else { return String(localized: "No active version") }
        let parts = a.constraints.map(\.summary)
        let head = a.requirement == .visa_free && !parts.isEmpty ? parts.joined(separator: " · ") : a.requirement.title
        return "\(regime.passportCode.flagEmoji) \(head)"
    }

    private var status: (text: String, color: Color) {
        guard let last = regime.lastCheckedAt else { return (String(localized: "Never checked"), .orange) }
        let days = daysBetween(String(last.prefix(10)), DocumentInput.todayString()) ?? 0
        if days >= freshDays { return (String(localized: "Checked \(pluralDays(days)) ago — re-check"), .orange) }
        if days == 0 { return (String(localized: "Checked today"), .secondary) }
        return (String(localized: "Checked \(pluralDays(days)) ago"), .secondary)
    }
}

struct DocumentRow: View {
    let document: TravelDocument
    let passport: TravelDocument?
    let rules: [Rule]
    /// однократная виза уже потрачена — вместо срока показываем это
    var usage: VisaUsage? = nil

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
        if let usage { return (usage.label, .secondary) }
        guard let left = document.daysUntilExpiry, let to = document.validTo else { return nil }
        if left < 0 { return (String(localized: "Expired \(prettyFullDate(to))"), .red) }
        if left <= 30 { return (String(localized: "Expires in \(pluralDays(left))"), .orange) }
        return (String(localized: "Valid until \(prettyFullDate(to))"), .secondary)
    }
}
