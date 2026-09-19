import SwiftUI

// "Что мне доступно в стране X": по каждому паспорту — режим въезда из справочника,
// подсказка правила подсчёта с возможностью подтвердить/поправить, плюс ваши документы на страну.
struct CountryInfoView: View {
    @Environment(AppModel.self) private var model
    let countryCode: String

    @State private var response: VisaInfoResponse?
    @State private var error: String?
    @State private var loading = false

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    FlagView(code: countryCode, width: 44)
                    Text(countryCode.countryDisplayName(fallback: nil)).font(.title2.bold())
                }
            }

            if let response {
                if !response.enabled {
                    Section {
                        Label("The visa reference is off on the server (no ORIZN_API_KEY). Set the conditions by hand below.", systemImage: "info.circle")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if response.passports.isEmpty {
                    Section {
                        Text("Add a passport in Documents to see entry conditions.").foregroundStyle(.secondary)
                    }
                }
                ForEach(response.passports) { p in
                    PassportInfoSection(country: countryCode, item: p, onChange: reload)
                }
                if !response.documents.isEmpty {
                    Section("Your documents for this country") {
                        ForEach(response.documents) { d in
                            NavigationLink {
                                DocumentEditView(document: d)
                            } label: {
                                Label(d.name, systemImage: d.kind.systemImage)
                            }
                        }
                    }
                }
            } else if loading {
                HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear)
            }

            if let error {
                Section { Text(error).foregroundStyle(.red).font(.footnote) }
            }
        }
        .navigationTitle("Entry conditions")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    private func reload() { Task { await load() } }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            response = try await APIClient.fromSettings().visaInfo(country: countryCode)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct PassportInfoSection: View {
    @Environment(AppModel.self) private var model
    let country: String
    let item: VisaInfoByPassport
    let onChange: () -> Void

    @State private var type: RuleType = .fromDate
    @State private var limit: Int = 30
    @State private var window: Int = 180
    @State private var saving = false
    @State private var message: String?
    @State private var showDetails = false

    var body: some View {
        Section {
            if item.isCitizen {
                Label("Your citizenship — no stay limit.", systemImage: "person.crop.circle.badge.checkmark")
            } else if let info = item.info, let req = info.requirement {
                requirementRow(req, info)
                if let d = info.description, !d.isEmpty {
                    Text(d).font(.footnote).foregroundStyle(.secondary)
                }
                DisclosureGroup("Details", isExpanded: $showDetails) {
                    if let s = info.maxStay { LabeledContent("Max stay", value: s) }
                    if let n = info.passportValidityMonths { LabeledContent("Passport validity", value: String(localized: "\(n) months")) }
                    if let e = info.extensionNotes, !e.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Extension").font(.caption).foregroundStyle(.secondary)
                            Text(e).font(.footnote)
                        }
                    }
                    if let o = info.overstayNotes, !o.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Overstay").font(.caption).foregroundStyle(.secondary)
                            Text(o).font(.footnote)
                        }
                    }
                    if let note = info.requirementStatusNote {
                        Label(note, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
                    }
                }
                sourceLine(info)
            } else {
                Label("No reference data for this pair yet.", systemImage: "questionmark.circle").foregroundStyle(.secondary)
            }

            if !item.isCitizen {
                ruleBlock
            }
        } header: {
            Text(verbatim: "\(item.passportCode.flagEmoji) \(item.passportName)")
        }
        .onAppear(perform: seed)
        .onChange(of: item) { _, _ in seed() }
    }

    private func seed() {
        if let r = item.rule {
            type = r.type
            limit = r.limitDays
            window = r.windowDays ?? 180
        } else if let s = item.suggestion {
            type = s.type
            limit = s.limitDays
            window = s.windowDays ?? 180
        } else if let d = item.info?.visaFreeDays {
            type = .fromDate
            limit = d
        }
    }

    @ViewBuilder
    private func requirementRow(_ req: VisaRequirement, _ info: VisaInfoRecord) -> some View {
        HStack {
            Label(req.title, systemImage: req.allowsEntry ? "checkmark.seal.fill" : (req == .unknown ? "questionmark.circle" : "xmark.seal.fill"))
                .foregroundStyle(req.allowsEntry ? .green : (req == .unknown ? .secondary : .red))
                .font(.headline)
            Spacer()
            if let d = info.visaFreeDays, d > 0 {
                Text(String(localized: "up to \(pluralDays(d))")).font(.subheadline.monospacedDigit())
            }
        }
    }

    private func sourceLine(_ info: VisaInfoRecord) -> some View {
        let verified = info.lastVerifiedAt.map { String(localized: "officially verified \(prettyFullDate(String($0.prefix(10))))") }
            ?? String(localized: "not verified against an official source")
        return Text(String(localized: "Source: Orizn · \(verified). Treat as a hint, not legal advice."))
            .font(.caption2).foregroundStyle(.tertiary)
    }

    @ViewBuilder
    private var ruleBlock: some View {
        if let rule = item.rule {
            NavigationLink {
                RuleEditView(rule: rule)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Counting rule").font(.caption).foregroundStyle(.secondary)
                    Text(rule.name)
                }
            }
        } else if item.info?.requirement?.allowsEntry == true || item.info == nil {
            VStack(alignment: .leading, spacing: 8) {
                Text("Counting rule").font(.caption).foregroundStyle(.secondary)
                if let s = item.suggestion {
                    Text(String(localized: "Suggested from the reference: \(s.reason). Check the type — the reference gives the number of days but not how they are counted."))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Picker("Type", selection: $type) {
                    Text("Per entry").tag(RuleType.fromDate)
                    Text("Rolling").tag(RuleType.rolling)
                    Text("Per year").tag(RuleType.calendarYear)
                }
                .pickerStyle(.segmented)
            }
            DaysField(title: "No more than", value: $limit)
            if type == .rolling {
                DaysField(title: "In any", value: $window, range: 2...3660)
            }
            Button {
                Task { await createRule() }
            } label: {
                HStack {
                    Text("Create rule")
                    Spacer()
                    if saving { ProgressView() }
                }
            }
            .disabled(saving)
            if let message {
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func createRule() async {
        saving = true
        defer { saving = false }
        do {
            let rule = try await APIClient.fromSettings().ensureVisaFreeRule(
                country: country, passportId: item.passportId, type: type, limitDays: limit, windowDays: type == .rolling ? window : (type == .fromDate ? nil : nil)
            )
            message = rule.map { String(localized: "Rule created: \($0.name)") } ?? String(localized: "Couldn’t create the rule.")
            await model.refresh()
            onChange()
        } catch {
            message = error.localizedDescription
        }
    }
}

// Выбор страны → условия въезда (из вкладки «Документы»)
struct CountryLookupView: View {
    @State private var selection: [String]

    init(initial: String? = nil) {
        _selection = State(initialValue: initial.map { [$0] } ?? [])
    }

    var body: some View {
        if let code = selection.first {
            CountryInfoView(countryCode: code)
        } else {
            CountryPickerView(selection: $selection, single: true)
        }
    }
}
