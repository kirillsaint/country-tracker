import SwiftUI

// Статистика за год (или за всё время): итоги, рейтинг стран и городов, рекорды.
struct StatsSections: View {
    @Environment(AppModel.self) private var model
    /// nil — за всё время (тот же фильтр, что у хронологии)
    let year: Int?

    private var stats: YearStats? { model.yearStats(for: year) }

    var body: some View {
        if let stats {
            if stats.totalDays == 0 {
                ContentUnavailableView("No data for this period", systemImage: "chart.bar")
            } else {
                summary(stats)
                countriesSection(stats)
                citiesSection(stats)
                highlights(stats)
            }
        } else {
            HStack { Spacer(); ProgressView(); Spacer() }
                .listRowBackground(Color.clear)
        }
    }

    private func summary(_ s: YearStats) -> some View {
        Section {
            HStack(spacing: 0) {
                tile(value: "\(s.totalDays)", caption: String(localized: "days"))
                Divider()
                tile(value: "\(s.countries.count)", caption: String(localized: "countries"))
                Divider()
                tile(value: "\(s.cities.count)", caption: String(localized: "cities"))
                Divider()
                tile(value: "\(s.trips)", caption: String(localized: "trips"))
            }
            .padding(.vertical, 6)
        } footer: {
            if let year, year == Calendar.current.component(.year, from: Date()) {
                Text("\(pluralDays(s.totalDays)) tracked so far this year.")
            }
        }
    }

    private func tile(value: String, caption: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title2.bold().monospacedDigit())
            Text(caption).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func countriesSection(_ s: YearStats) -> some View {
        Section("Countries") {
            ForEach(s.countries) { c in
                rankedRow(
                    flag: c.countryCode,
                    title: c.countryCode.countryDisplayName(fallback: c.countryName),
                    subtitle: "\(prettyDate(c.firstDay)) – \(prettyDate(c.lastDay))",
                    days: c.days,
                    total: s.totalDays
                )
            }
        }
    }

    private func citiesSection(_ s: YearStats) -> some View {
        Section("Cities") {
            ForEach(s.cities.prefix(10)) { c in
                rankedRow(
                    flag: c.countryCode,
                    title: c.city,
                    subtitle: c.countryCode.countryDisplayName(fallback: c.countryName),
                    days: c.days,
                    total: s.totalDays
                )
            }
            if s.cities.count > 10 {
                Text("And \(s.cities.count - 10) more").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func rankedRow(flag: String, title: String, subtitle: String, days: Int, total: Int) -> some View {
        let share = total > 0 ? Double(days) / Double(total) : 0
        return HStack(spacing: 12) {
            FlagView(code: flag, width: 34)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.body).lineLimit(1)
                    Spacer()
                    Text(pluralDays(days)).font(.subheadline.monospacedDigit())
                    Text(verbatim: "\(Int((share * 100).rounded()))%")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: 38, alignment: .trailing)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color(uiColor: .systemGray5))
                        Capsule().fill(Color.accentColor).frame(width: max(4, geo.size.width * share))
                    }
                }
                .frame(height: 6)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    private func highlights(_ s: YearStats) -> some View {
        Section("Highlights") {
            if let longest = s.longestStay {
                HStack(spacing: 12) {
                    FlagView(code: longest.countryCode, width: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Longest stay").font(.caption).foregroundStyle(.secondary)
                        Text(verbatim: [longest.countryCode.countryDisplayName(fallback: longest.countryName), longest.city].compactMap { $0 }.joined(separator: " · "))
                        Text(verbatim: "\(prettyDate(longest.from)) – \(prettyDate(longest.to))").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(pluralDays(longest.days)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            if let top = s.countries.first {
                LabeledContent("Most time in") {
                    Text(verbatim: "\(top.countryCode.flagEmoji) \(top.countryCode.countryDisplayName(fallback: top.countryName))")
                }
            }
            if let topCity = s.cities.first, topCity.city != "—" {
                LabeledContent("Most visited city", value: topCity.city)
            }
            if s.segments.count > 1, let first = s.segments.last, let last = s.segments.first {
                LabeledContent("Started in") {
                    Text(verbatim: "\(first.countryCode.flagEmoji) \(first.countryCode.countryDisplayName(fallback: first.countryName))")
                }
                LabeledContent("Ended in") {
                    Text(verbatim: "\(last.countryCode.flagEmoji) \(last.countryCode.countryDisplayName(fallback: last.countryName))")
                }
            }
        }
    }
}
