import SwiftUI

struct TimelineView: View {
    @Environment(AppModel.self) private var model
    @State private var segment = 0

    var body: some View {
        NavigationStack {
            List {
                Picker("", selection: $segment) {
                    Text("Хронология").tag(0)
                    Text("Города").tag(1)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())

                if segment == 0 {
                    timelineRows
                } else {
                    cityRows
                }
            }
            .navigationTitle("История")
            .refreshable { await model.refresh() }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink {
                        ManualEntriesView()
                    } label: {
                        Label("Ручные записи", systemImage: "square.and.pencil")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var timelineRows: some View {
        if model.timeline.isEmpty {
            ContentUnavailableView("История пуста", systemImage: "calendar.badge.clock")
        } else {
            ForEach(model.timeline) { s in
                HStack(alignment: .center, spacing: 12) {
                    FlagView(code: s.countryCode, width: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.countryCode.countryDisplayName(fallback: s.countryName))
                            .font(.headline)
                        if let city = s.city {
                            Text(city).foregroundStyle(.secondary)
                        }
                        Text(s.from == s.to ? prettyDate(s.from) : "\(prettyDate(s.from)) – \(prettyDate(s.to))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(pluralDays(s.days)).monospacedDigit().foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
        }
    }

    @ViewBuilder
    private var cityRows: some View {
        if model.cities.isEmpty {
            ContentUnavailableView("Городов пока нет", systemImage: "building.2")
        } else {
            Section {
                ForEach(model.cities) { c in
                    HStack(spacing: 12) {
                        FlagView(code: c.countryCode, width: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.city).font(.headline)
                            Text("\(c.countryCode.countryDisplayName(fallback: c.countryName)) · \(prettyDate(c.firstDay)) – \(prettyDate(c.lastDay))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(pluralDays(c.days)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("Город берётся с устройства в момент записи точки; дни без города показаны как «—».")
            }
        }
    }
}
