import SwiftUI

struct TimelineView: View {
    @Environment(AppModel.self) private var model
    @State private var segment = 0
    /// nil — все годы
    @State private var year: Int? = nil
    @State private var basisFor: Segment?

    // Хронология по годам: отрезки, пересекающие Новый год, режем на части
    private var sectionsByYear: [(year: Int, segments: [Segment], days: Int)] {
        let pieces = model.timeline.flatMap { $0.splitByYear() }
        let grouped = Dictionary(grouping: pieces, by: \.year)
        return grouped.keys.sorted(by: >)
            .filter { year == nil || $0 == year }
            .map { y in
                let segs = grouped[y]!.sorted { $0.from > $1.from }
                return (y, segs, segs.reduce(0) { $0 + $1.days })
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
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())

                if segment == 0 {
                    timelineSections
                } else {
                    citySection
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
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink {
                        ManualEntriesView()
                    } label: {
                        Label("Manual entries", systemImage: "square.and.pencil")
                    }
                }
            }
            .task(id: year) {
                if let year { await model.loadYearStats(for: year) }
                else { await model.loadAllTimeIfNeeded() }
            }
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
            ContentUnavailableView("History is empty", systemImage: "calendar.badge.clock")
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
                        Text(city).foregroundStyle(.secondary)
                    }
                    Text(verbatim: s.from == s.to ? prettyDate(s.from) : "\(prettyDate(s.from)) – \(prettyDate(s.to))")
                        .font(.caption).foregroundStyle(.secondary)
                    if let entry {
                        EntryBadge(entry: entry, document: model.document(id: entry.documentId))
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
            if year != nil && model.yearStats(for: year) == nil {
                HStack { Spacer(); ProgressView(); Spacer() }
            } else {
                ContentUnavailableView("No cities yet", systemImage: "building.2")
            }
        } else {
            Section {
                ForEach(cities) { c in
                    HStack(spacing: 12) {
                        FlagView(code: c.countryCode, width: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.city).font(.headline)
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
