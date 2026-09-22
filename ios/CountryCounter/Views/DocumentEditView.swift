import SwiftUI

// Редактор документа. document == nil — создание документа вида kind.
struct DocumentEditView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let document: TravelDocument?
    @State private var draft: DocumentInput
    @State private var countrySelection: [String]
    @State private var zone: [String]
    @State private var hasValidFrom: Bool
    @State private var hasValidTo: Bool
    @State private var validFrom: Date
    @State private var validTo: Date
    @State private var maxStay: Int
    @State private var hasMaxStay: Bool
    @State private var hasWindow: Bool
    @State private var windowLimit: Int
    @State private var window: Int
    @State private var hasMinDays: Bool
    @State private var minDays: Int
    @State private var hasMaxAbsence: Bool
    @State private var maxAbsence: Int
    @State private var saving = false
    @State private var error: String?
    @State private var confirmDelete = false
    @State private var showRenew = false
    @State private var switchOffer: SwitchOffer?

    /// Предложение перевести текущее пребывание на только что сохранённый ВНЖ
    struct SwitchOffer: Identifiable {
        let document: TravelDocument
        let country: String
        let date: String
        /// ВНЖ действовал уже на день въезда — меняем основание въезда, а не отмечаем смену
        let asArrival: Bool
        var id: String { document.id }
    }

    /// Создание из листа «Как въехали?»: страна и паспорт уже подставлены, а после сохранения
    /// документ уходит вызывающему (он сам отметит основание), предложение «перейти на ВНЖ» не нужно
    private let onSaved: ((TravelDocument) -> Void)?

    init(document: TravelDocument?, kind: DocumentKind = .passport, presetCountry: String? = nil, presetPassportId: String? = nil, onSaved: ((TravelDocument) -> Void)? = nil) {
        self.document = document
        self.onSaved = onSaved
        var input = document?.input ?? DocumentInput(kind: kind, name: "", countryCode: "")
        if document == nil, let presetCountry {
            input.countryCode = presetCountry
            input.name = Self.defaultName(kind: kind, code: presetCountry)
            if kind != .passport { input.passportId = presetPassportId }
        }
        _draft = State(initialValue: input)
        _countrySelection = State(initialValue: input.countryCode.isEmpty ? [] : [input.countryCode])
        _zone = State(initialValue: input.countries.count > 1 ? input.countries : [])
        _hasValidFrom = State(initialValue: input.validFrom != nil)
        _hasValidTo = State(initialValue: input.validTo != nil)
        _validFrom = State(initialValue: Self.parse(input.validFrom) ?? Date())
        _validTo = State(initialValue: Self.parse(input.validTo) ?? Calendar.current.date(byAdding: .year, value: 1, to: Date())!)
        _hasMaxStay = State(initialValue: input.maxStayDays != nil)
        _maxStay = State(initialValue: input.maxStayDays ?? 30)
        _hasWindow = State(initialValue: input.windowLimitDays != nil)
        _windowLimit = State(initialValue: input.windowLimitDays ?? 90)
        _window = State(initialValue: input.windowDays ?? 180)
        _hasMinDays = State(initialValue: input.minDaysPerYear != nil)
        _minDays = State(initialValue: input.minDaysPerYear ?? 183)
        _hasMaxAbsence = State(initialValue: input.maxAbsenceDays != nil)
        _maxAbsence = State(initialValue: input.maxAbsenceDays ?? 180)
    }

    private var kind: DocumentKind { draft.kind }
    private var country: String? { countrySelection.first }

    var body: some View {
        Form {
            Section {
                NavigationLink {
                    CountryPickerView(selection: $countrySelection, single: true)
                } label: {
                    HStack {
                        Text(kind == .passport ? "Citizenship" : "Country")
                        Spacer()
                        if let country {
                            FlagView(code: country, width: 24)
                            Text(country.countryDisplayName(fallback: nil)).foregroundStyle(.secondary)
                        } else {
                            Text("Choose").foregroundStyle(.secondary)
                        }
                    }
                }
                TextField(namePlaceholder, text: $draft.name)
                if kind != .passport {
                    Picker("Issued on passport", selection: $draft.passportId) {
                        Text("Not specified").tag(String?.none)
                        ForEach(model.passports) { p in
                            Text(verbatim: "\(p.countryCode.flagEmoji) \(p.name)").tag(String?.some(p.id))
                        }
                    }
                    NavigationLink {
                        CountryPickerView(selection: $zone)
                    } label: {
                        HStack {
                            Text("Also valid in")
                            Spacer()
                            if zone.isEmpty {
                                Text("Only this country").foregroundStyle(.secondary)
                            } else {
                                FlagRow(codes: zone, max: 5, width: 20)
                            }
                        }
                    }
                }
            } header: {
                Text(kind.title)
            } footer: {
                if kind != .passport {
                    Text("For a zone-wide document (a Schengen visa, an EU residence permit) pick all the countries it covers.")
                }
            }

            Section("Validity") {
                Toggle("Valid from", isOn: $hasValidFrom)
                if hasValidFrom {
                    DatePicker("From", selection: $validFrom, displayedComponents: .date)
                }
                Toggle("Valid until", isOn: $hasValidTo)
                if hasValidTo {
                    DatePicker("Until", selection: $validTo, displayedComponents: .date)
                }
            }

            if kind == .visa {
                Section {
                    Picker("Entries", selection: $draft.entries) {
                        Text("Not specified").tag(VisaEntries?.none)
                        ForEach(VisaEntries.allCases) { Text($0.title).tag(VisaEntries?.some($0)) }
                    }
                    if draft.entries == .single {
                        Toggle("Already used", isOn: $draft.used)
                        if let detected = detectedUsage {
                            Text(detected.label).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    Toggle("Max stay per entry", isOn: $hasMaxStay)
                    if hasMaxStay {
                        DaysField(title: "Per entry", value: $maxStay)
                    }
                    Toggle("Limit within a window", isOn: $hasWindow)
                    if hasWindow {
                        DaysField(title: "No more than", value: $windowLimit)
                        DaysField(title: "In any", value: $window, range: 2...3660)
                    }
                } header: {
                    Text("Stay limits")
                } footer: {
                    if draft.entries == .single {
                        Text("Each limit becomes a counting rule: “per entry” restarts every time you enter, the window rule counts days in any N consecutive days (Schengen 90/180). The visa expiry closes both. A single-entry visa is spent after one trip: the app notices a stay entered with this visa or a manual trip inside its validity; switch “Already used” on if it doesn’t. A used visa sends no expiry reminders and its rules close.")
                    } else {
                        Text("Each limit becomes a counting rule: “per entry” restarts every time you enter, the window rule counts days in any N consecutive days (Schengen 90/180). The visa expiry closes both.")
                    }
                }
            }

            if kind == .residence {
                Section {
                    Picker("Type", selection: $draft.residenceType) {
                        Text("Not specified").tag(ResidenceType?.none)
                        ForEach(ResidenceType.allCases) { Text($0.title).tag(ResidenceType?.some($0)) }
                    }
                    Toggle("Minimum days per year", isOn: $hasMinDays)
                    if hasMinDays {
                        DaysField(title: "At least", value: $minDays, range: 1...366)
                    }
                    Toggle("Maximum days away in a row", isOn: $hasMaxAbsence)
                    if hasMaxAbsence {
                        DaysField(title: "No more than", value: $maxAbsence)
                    }
                } header: {
                    Text("Obligations")
                } footer: {
                    Text("Obligations to keep the permit: a goal rule for presence days and an “away” rule that counts consecutive days outside the country.")
                }
            }

            Section {
                TextField("Note (optional)", text: Binding(get: { draft.note ?? "" }, set: { draft.note = $0.isEmpty ? nil : $0 }), axis: .vertical)
            }

            if let document, kind != .passport {
                Section {
                    Button {
                        showRenew = true
                    } label: {
                        Label("Renew…", systemImage: "arrow.clockwise")
                    }
                    ForEach(document.history ?? []) { p in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: "\(p.validFrom.map(prettyFullDate) ?? "…") – \(p.validTo.map(prettyFullDate) ?? "…")")
                            Text("Previous period").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Renewal")
                } footer: {
                    Text("Extends this same document: its rules, entry bases and history stay linked. Previous dates are kept below.")
                }
            }

            if let document {
                let generated = model.rules.filter { $0.documentId == document.id }
                if !generated.isEmpty {
                    Section("Rules from this document") {
                        ForEach(generated) { r in
                            NavigationLink {
                                RuleEditView(rule: r)
                            } label: {
                                HStack {
                                    Text(r.name).lineLimit(2)
                                    Spacer()
                                    if r.isCustomized { Image(systemName: "pencil.circle").foregroundStyle(.secondary) }
                                }
                            }
                        }
                    }
                }
            }

            if let error {
                Section { Text(error).foregroundStyle(.red).font(.footnote) }
            }

            if document != nil {
                Section {
                    Button("Delete document", role: .destructive) { confirmDelete = true }
                } footer: {
                    Text("Its rules are deleted too. Visas issued on a deleted passport stay, but lose the link.")
                }
            }
        }
        .navigationTitle(document == nil ? kind.title : document!.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if document == nil {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(action: save) {
                    if saving { ProgressView() } else { Text("Save") }
                }
                .disabled(saving || country == nil)
            }
        }
        .sheet(isPresented: $showRenew) {
            if let document { NavigationStack { RenewDocumentView(document: document) } }
        }
        .alert(
            Text("Use this permit for your current stay in \(switchOffer.map { $0.country.countryDisplayName(fallback: nil) } ?? "")?"),
            isPresented: Binding(get: { switchOffer != nil }, set: { if !$0 { switchOffer = nil } }),
            presenting: switchOffer
        ) { offer in
            Button(String(localized: "Switch from \(prettyDate(offer.date))")) {
                Task {
                    try? await model.setEntry(countryCode: offer.country, date: offer.date, basis: .residence, documentId: offer.document.id,
                                              note: nil, kind: offer.asArrival ? .arrival : .statusChange)
                    await model.refresh()
                    dismiss()
                }
            }
            Button("Not now", role: .cancel) { dismiss() }
        } message: { offer in
            Text("From \(prettyFullDate(offer.date)) days count under the residence permit and no longer toward visa-free or visa limits.")
        }
        .confirmationDialog("Delete this document?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                guard let document else { return }
                Task {
                    await model.deleteDocument(document)
                    dismiss()
                }
            }
        }
        .onChange(of: countrySelection) { _, sel in
            if draft.name.isEmpty, let c = sel.first { draft.name = defaultName(for: c) }
        }
    }

    private var namePlaceholder: LocalizedStringKey {
        switch kind {
        case .passport: return "Name, e.g. Russian passport"
        case .visa: return "Name, e.g. Schengen visa C"
        case .residence: return "Name, e.g. Georgia residence permit"
        }
    }

    private func defaultName(for code: String) -> String { Self.defaultName(kind: kind, code: code) }

    static func defaultName(kind: DocumentKind, code: String) -> String {
        let country = code.countryDisplayName(fallback: code)
        switch kind {
        case .passport: return String(localized: "Passport \(country)")
        case .visa: return String(localized: "Visa \(country)")
        case .residence: return String(localized: "Residence permit \(country)")
        }
    }

    /// ВНЖ на страну, где человек сейчас находится не по ВНЖ, — предложить перейти без "выезда"
    private func switchOffer(for doc: TravelDocument) -> SwitchOffer? {
        guard doc.kind == .residence, let cur = model.current, doc.covers(cur.countryCode) else { return nil }
        if let now = cur.basisNow, now.basis == .residence, now.documentId == doc.id { return nil }
        let today = DocumentInput.todayString()
        var date = doc.validFrom ?? today
        // ВНЖ ещё не вступил в силу — предлагать нечего
        if date > today { return nil }
        let asArrival = date <= cur.since
        if asArrival { date = cur.since }
        return SwitchOffer(document: doc, country: cur.countryCode, date: date, asArrival: asArrival)
    }

    /// Использование, найденное по данным (без учёта ручного флага) — подсказка рядом с переключателем
    private var detectedUsage: VisaUsage? {
        guard let document else { return nil }
        var probe = document
        probe.used = false
        return probe.usage(entries: model.entries, ranges: model.manualRanges, current: model.current)
    }

    private func save() {
        guard let country else { return }
        var input = draft
        input.countryCode = country
        input.name = input.name.trimmingCharacters(in: .whitespaces)
        if input.name.isEmpty { input.name = defaultName(for: country) }
        input.countries = kind == .passport ? [country] : Array(Set(zone + [country])).sorted()
        input.validFrom = hasValidFrom ? Self.format(validFrom) : nil
        input.validTo = hasValidTo ? Self.format(validTo) : nil
        input.maxStayDays = kind == .visa && hasMaxStay ? maxStay : nil
        input.windowLimitDays = kind == .visa && hasWindow ? windowLimit : nil
        input.windowDays = kind == .visa && hasWindow ? window : nil
        input.minDaysPerYear = kind == .residence && hasMinDays ? minDays : nil
        input.maxAbsenceDays = kind == .residence && hasMaxAbsence ? maxAbsence : nil
        if kind != .visa { input.entries = nil }
        input.used = kind == .visa && input.entries == .single && draft.used
        // если поездка уже видна в данных — закрываем правила визы её последним днём, а не сегодняшним
        input.usedAt = input.used ? (detectedUsage?.to ?? detectedUsage?.from) : nil
        if kind != .residence { input.residenceType = nil }
        if kind == .passport { input.passportId = nil }
        input.lang = DocumentInput.currentLang
        saving = true
        error = nil
        Task {
            do {
                let saved = try await model.saveDocument(input, id: document?.id)
                if let onSaved {
                    onSaved(saved)
                    dismiss()
                } else if let offer = switchOffer(for: saved) {
                    switchOffer = offer
                } else {
                    dismiss()
                }
            } catch {
                self.error = error.localizedDescription
            }
            saving = false
        }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f
    }()

    private static func parse(_ s: String?) -> Date? { s.flatMap { dateFormatter.date(from: $0) } }
    private static func format(_ d: Date) -> String { dateFormatter.string(from: d) }
}
