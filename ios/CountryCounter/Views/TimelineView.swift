import SwiftUI

struct TimelineView: View {
    @Environment(AppModel.self) private var model
    @State private var segment = 0
    /// nil — все годы
    @State private var year: Int? = nil
    @State private var basisFor: Segment?
    @State private var showMap = false

    // Хронология по годам: отрезки, пересекающие Новый год, режем на части
    private var sectionsByYear: [(year: Int, segments: [Segment], days: Int)] {
        let pieces = model.timeline.flatMap { $0.splitByYear() }
        let grouped = Dictionary(grouping: pieces, by: \.year)
        return grouped.keys.sorted(by: >)
            .filter { year == nil || $0 == year }
            .map { y in
                let segs = grouped[y]!.sorted { $0.from > $1.from }
                // день перелёта входит в оба отрезка — в сумме года считаем его один раз
                var total = segs.reduce(0) { $0 + $1.days }
                let byStart = segs.sorted { $0.from < $1.from }
                for (a, b) in zip(byStart, byStart.dropFirst()) where a.to >= b.from {
                    total -= (daysBetween(b.from, a.to) ?? 0) + 1
                }
                return (y, segs, total)
            }
    }

    private var cities: [CityStat] {
        if let year { return model.yearStats(for: year)?.cities ?? [] }
        return model.allTimeCities
    }

    var body: some View {
        NavigationStack {
            List {
                Picker("", selection: $segment) {
                    Text("Timeline").tag(0)
                    Text("Cities").tag(1)
                    Text("Statistics").tag(2)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())

                switch segment {
                case 0: timelineSections
                case 1: citySection
                default: StatsSections(year: year)
                }
            }
            .navigationTitle("History")
            .refreshable { await model.refresh() }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Picker("Year", selection: $year) {
                            Text("All years").tag(Int?.none)
                            ForEach(model.availableYears, id: \.self) { y in
                                Text(verbatim: String(y)).tag(Int?.some(y))
                            }
                        }
                    } label: {
                        Label(year.map { String($0) } ?? String(localized: "All years"), systemImage: "calendar")
                    }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button("Map", systemImage: "map") { showMap = true }
                    NavigationLink {
                        ManualEntriesView()
                    } label: {
                        Label("Manual entries", systemImage: "square.and.pencil")
                    }
                }
            }
            .sheet(isPresented: $showMap) { MapScreen() }
            .task(id: year) {
                await model.loadYearStats(for: year)
                if year == nil { await model.loadAllTimeIfNeeded() }
            }
            .onChange(of: model.lastRefresh) { _, _ in Task { await model.loadYearStats(for: year) } }
            .sheet(item: $basisFor) { seg in
                NavigationStack { EntryBasisSheet(segment: seg, existing: model.entry(for: seg)) }
            }
        }
    }

    /// Кусок отрезка, разрезанного по годам, ведёт к исходному отрезку — основание привязано к его дате въезда
    private func originalSegment(for piece: Segment) -> Segment {
        model.timeline.first { $0.countryCode == piece.countryCode && $0.from <= piece.from && piece.from <= $0.to } ?? piece
    }

    @ViewBuilder
    private var timelineSections: some View {
        if sectionsByYear.isEmpty {
            if model.showSkeleton {
                Section {
                    ForEach(0..<4, id: \.self) { _ in SkeletonRow(lines: 3) }
                } header: {
                    SkeletonBar(width: 48, height: 14).skeleton()
                }
            } else {
                ContentUnavailableView("History is empty", systemImage: "calendar.badge.clock")
            }
        } else {
            ForEach(sectionsByYear, id: \.year) { section in
                Section {
                    ForEach(section.segments) { s in
                        segmentRow(s)
                    }
                } header: {
                    HStack {
                        Text(verbatim: String(section.year))
                        Spacer()
                        Text(pluralDays(section.days)).textCase(nil)
                    }
                }
            }
        }
    }

    private func segmentRow(_ s: Segment) -> some View {
        let original = originalSegment(for: s)
        let entry = model.entry(for: original)
        return Button {
            basisFor = original
        } label: {
            HStack(alignment: .center, spacing: 12) {
                FlagView(code: s.countryCode, width: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text(s.countryCode.countryDisplayName(fallback: s.countryName))
                        .font(.headline)
                    if let city = s.city {
                        Text(city.cityDisplayName(country: s.countryCode)).foregroundStyle(.secondary)
                    }
                    Text(verbatim: s.from == s.to ? prettyDate(s.from) : "\(prettyDate(s.from)) – \(prettyDate(s.to))")
                        .font(.caption).foregroundStyle(.secondary)
                    if let entry {
                        EntryBadge(entry: entry, document: model.document(id: entry.documentId))
                        if entry.basis == .visa_free, let pid = entry.documentId,
                           let version = model.regime(passportId: pid, country: s.countryCode)?.version(on: original.from),
                           !version.constraints.isEmpty {
                            Text(String(localized: "Rules then: \(version.constraints.map(\.summary).joined(separator: ", "))"))
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    // смены статуса внутри пребывания (получил ВНЖ, не выезжая)
                    ForEach(model.switches(for: original)) { sw in
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.turn.down.right").font(.caption2).foregroundStyle(.tertiary)
                            EntryBadge(entry: sw, document: model.document(id: sw.documentId))
                            Text(String(localized: "from \(prettyDate(sw.date))")).font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
                Spacer()
                Text(pluralDays(s.days)).monospacedDigit().foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var citySection: some View {
        if cities.isEmpty {
            if model.showSkeleton || (year != nil && model.yearStats(for: year) == nil) {
                Section {
                    ForEach(0..<5, id: \.self) { _ in SkeletonRow(flag: 32) }
                }
            } else {
                ContentUnavailableView("No cities yet", systemImage: "building.2")
            }
        } else {
            Section {
                ForEach(cities) { c in
                    HStack(spacing: 12) {
                        FlagView(code: c.countryCode, width: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.city.cityDisplayName(country: c.countryCode)).font(.headline)
                            Text(verbatim: "\(c.countryCode.countryDisplayName(fallback: c.countryName)) · \(prettyDate(c.firstDay)) – \(prettyDate(c.lastDay))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(pluralDays(c.days)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text(year.map { String($0) } ?? String(localized: "All years"))
            } footer: {
                Text("The city comes from the device when a point is recorded; days without a city are shown as “—”.")
            }
        }
    }
}
