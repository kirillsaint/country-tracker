import SwiftUI
import WidgetKit

// "Сейчас": где я и сколько дней. Маленький, средний, и три варианта для экрана блокировки.
struct NowEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}

struct NowProvider: TimelineProvider {
    func placeholder(in context: Context) -> NowEntry {
        NowEntry(date: Date(), snapshot: .preview)
    }

    func getSnapshot(in context: Context, completion: @escaping (NowEntry) -> Void) {
        completion(NowEntry(date: Date(), snapshot: context.isPreview ? .preview : WidgetData.snapshot(asOf: Date())))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NowEntry>) -> Void) {
        let now = Date()
        let midnight = WidgetData.nextMidnight(after: now)
        let entries = [
            NowEntry(date: now, snapshot: WidgetData.snapshot(asOf: now)),
            NowEntry(date: midnight, snapshot: WidgetData.snapshot(asOf: midnight)),
        ]
        completion(Timeline(entries: entries, policy: .after(WidgetData.nextMidnight(after: midnight))))
    }
}

struct NowWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ge.kirillsaint.countrycounter.now", provider: NowProvider()) { entry in
            NowWidgetView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Now")
        .description("Current country and how many days you have been there.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryInline, .accessoryRectangular, .accessoryCircular])
    }
}

struct NowWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: NowEntry

    var body: some View {
        if let s = entry.snapshot, let c = s.current {
            switch family {
            case .systemMedium: medium(s, c)
            case .accessoryInline: inline(c)
            case .accessoryRectangular: rectangular(c)
            case .accessoryCircular: circular(c)
            default: small(c)
            }
        } else {
            NoDataView()
        }
    }

    private func small(_ c: WidgetSnapshot.Current) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(c.countryCode.flagEmoji).font(.system(size: 34))
            Spacer(minLength: 0)
            Text(c.countryCode.countryDisplayName(fallback: c.countryName))
                .font(.headline).lineLimit(2).minimumScaleFactor(0.7)
            if let city = c.city {
                Text(city).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Text(pluralDays(c.daysInRow)).font(.title3.bold().monospacedDigit())
            Text("in a row").font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func medium(_ s: WidgetSnapshot, _ c: WidgetSnapshot.Current) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(c.countryCode.flagEmoji).font(.system(size: 30))
                    VStack(alignment: .leading, spacing: 0) {
                        Text(c.countryCode.countryDisplayName(fallback: c.countryName))
                            .font(.headline).lineLimit(1).minimumScaleFactor(0.7)
                        if let city = c.city {
                            Text(city).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                Spacer(minLength: 0)
                HStack(spacing: 12) {
                    stat(pluralDays(c.daysInRow), String(localized: "in a row"))
                    stat(pluralDays(c.daysThisYear), String(localized: "this year"))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !s.rules.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(s.rules.prefix(3)) { r in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(r.name).font(.caption).lineLimit(1)
                                Spacer()
                                Text(verbatim: "\(r.used)/\(r.limit)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            ProgressView(value: Double(min(r.used, r.limit)), total: Double(max(r.limit, 1)))
                                .tint(WidgetData.color(for: r.status))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func stat(_ value: String, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.subheadline.bold().monospacedDigit())
            Text(caption).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func inline(_ c: WidgetSnapshot.Current) -> some View {
        Text(verbatim: "\(c.countryCode.flagEmoji) \(c.countryCode.countryDisplayName(fallback: c.countryName)) · \(pluralDays(c.daysInRow))")
    }

    private func rectangular(_ c: WidgetSnapshot.Current) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: "\(c.countryCode.flagEmoji) \(c.countryCode.countryDisplayName(fallback: c.countryName))")
                .font(.headline).lineLimit(1)
            Text(String(localized: "\(pluralDays(c.daysInRow)) in a row")).font(.caption)
            Text(String(localized: "\(pluralDays(c.daysThisYear)) this year")).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func circular(_ c: WidgetSnapshot.Current) -> some View {
        VStack(spacing: 0) {
            Text(c.countryCode).font(.caption2.bold())
            Text(verbatim: "\(c.daysInRow)").font(.title3.bold().monospacedDigit())
        }
    }
}

extension WidgetSnapshot {
    // Данные для галереи виджетов
    static let preview = WidgetSnapshot(
        today: "2026-09-20",
        generatedAt: Date(),
        current: Current(countryCode: "GE", countryName: "Georgia", city: "Tbilisi", since: "2026-06-01", daysInRow: 109, daysThisYear: 226),
        rules: [
            Rule(id: "1", name: "Georgia visa-free", mode: .limit, countries: ["GE"], used: 109, limit: 365, remaining: 256, canStayDays: 253, status: .ok, periodEnd: "2027-05-31", inCountry: true),
            Rule(id: "2", name: "Schengen 90/180", mode: .limit, countries: ["FR", "DE"], used: 12, limit: 90, remaining: 78, canStayDays: 78, status: .ok, periodEnd: "2026-09-20", inCountry: nil),
        ],
        countriesThisYear: 4,
        countriesAllTime: 12
    )
}
