import AppIntents
import SwiftUI
import WidgetKit

// "Правило": кольцо прогресса по одному выбранному правилу. Какое — выбирается при настройке виджета.

struct RuleEntity: AppEntity {
    let id: String
    let name: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Rule"
    static var defaultQuery = RuleQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct RuleQuery: EntityQuery {
    private var all: [RuleEntity] {
        (WidgetSnapshot.load()?.rules ?? []).map { RuleEntity(id: $0.id, name: $0.name) }
    }

    func entities(for identifiers: [String]) async throws -> [RuleEntity] {
        all.filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [RuleEntity] { all }

    func defaultResult() async -> RuleEntity? { all.first }
}

struct SelectRuleIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Rule"
    static var description = IntentDescription("Choose which counting rule to show.")

    @Parameter(title: "Rule")
    var rule: RuleEntity?
}

struct RuleEntry: TimelineEntry {
    let date: Date
    let rule: WidgetSnapshot.Rule?
    let hasSnapshot: Bool
}

struct RuleProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> RuleEntry {
        RuleEntry(date: Date(), rule: WidgetSnapshot.preview.rules.first, hasSnapshot: true)
    }

    func snapshot(for configuration: SelectRuleIntent, in context: Context) async -> RuleEntry {
        if context.isPreview { return placeholder(in: context) }
        return entry(for: configuration)
    }

    func timeline(for configuration: SelectRuleIntent, in context: Context) async -> Timeline<RuleEntry> {
        let now = Date()
        return Timeline(entries: [entry(for: configuration)], policy: .after(WidgetData.nextMidnight(after: now)))
    }

    private func entry(for configuration: SelectRuleIntent) -> RuleEntry {
        guard let s = WidgetSnapshot.load() else { return RuleEntry(date: Date(), rule: nil, hasSnapshot: false) }
        let rule = s.rules.first { $0.id == configuration.rule?.id } ?? s.rules.first
        return RuleEntry(date: Date(), rule: rule, hasSnapshot: true)
    }
}

struct RuleWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "ge.kirillsaint.countrycounter.rule", intent: SelectRuleIntent.self, provider: RuleProvider()) { entry in
            RuleWidgetView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Rule")
        .description("Progress of one counting rule: days used, days left.")
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct RuleWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: RuleEntry

    var body: some View {
        if let r = entry.rule {
            switch family {
            case .accessoryCircular: circular(r)
            case .accessoryRectangular: rectangular(r)
            case .accessoryInline: inline(r)
            default: small(r)
            }
        } else if entry.hasSnapshot {
            VStack(spacing: 6) {
                Image(systemName: "list.bullet.clipboard").font(.title2).foregroundStyle(.secondary)
                Text("No rules yet").font(.caption2).foregroundStyle(.secondary)
            }
        } else {
            NoDataView()
        }
    }

    private func fraction(_ r: WidgetSnapshot.Rule) -> Double {
        min(1, Double(r.used) / Double(max(r.limit, 1)))
    }

    private func caption(_ r: WidgetSnapshot.Rule) -> String {
        if r.inCountry == false { return String(localized: "Not in the country") }
        switch (r.mode, r.status) {
        case (.limit, .exceeded): return String(localized: "Limit exceeded")
        case (.limit, _):
            if let stay = r.canStayDays, stay != r.remaining { return String(localized: "\(pluralDays(stay)) more in a row") }
            return String(localized: "\(pluralDays(r.remaining)) left")
        case (.goal, .reached): return String(localized: "Goal reached")
        case (.goal, _): return String(localized: "\(pluralDays(r.remaining)) to go")
        }
    }

    private func small(_ r: WidgetSnapshot.Rule) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(r.name).font(.caption.bold()).lineLimit(1)
            Gauge(value: fraction(r)) {
                EmptyView()
            } currentValueLabel: {
                VStack(spacing: -2) {
                    Text(verbatim: "\(r.used)").font(.title3.bold().monospacedDigit())
                    Text(verbatim: "/\(r.limit)").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .tint(WidgetData.color(for: r.status))
            .frame(maxWidth: .infinity)
            .scaleEffect(1.25)
            .padding(.vertical, 6)
            Text(caption(r)).font(.caption2).foregroundStyle(.secondary).lineLimit(2).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func circular(_ r: WidgetSnapshot.Rule) -> some View {
        Gauge(value: fraction(r)) {
            Text(r.countries.first ?? "").font(.caption2)
        } currentValueLabel: {
            Text(verbatim: "\(r.remaining)").font(.headline.monospacedDigit())
        }
        .gaugeStyle(.accessoryCircular)
    }

    private func rectangular(_ r: WidgetSnapshot.Rule) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(r.name).font(.headline).lineLimit(1)
                Spacer()
                Text(verbatim: "\(r.used)/\(r.limit)").font(.caption.monospacedDigit())
            }
            Gauge(value: fraction(r)) { EmptyView() }
                .gaugeStyle(.accessoryLinearCapacity)
            Text(caption(r)).font(.caption2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func inline(_ r: WidgetSnapshot.Rule) -> some View {
        Text(verbatim: "\(r.countries.first?.flagEmoji ?? "") \(r.name) · \(r.used)/\(r.limit)")
    }
}
