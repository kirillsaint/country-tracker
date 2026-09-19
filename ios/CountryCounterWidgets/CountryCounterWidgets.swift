import SwiftUI
import WidgetKit

@main
struct CountryCounterWidgetsBundle: WidgetBundle {
    var body: some Widget {
        NowWidget()
        RuleWidget()
    }
}

// Общее для обоих виджетов: чтение снимка и пересчёт дней на текущую дату.
enum WidgetData {
    /// Снимок с поправкой на прошедшие с момента записи сутки
    static func snapshot(asOf date: Date) -> WidgetSnapshot? {
        guard let s = WidgetSnapshot.load() else { return nil }
        let elapsed = s.daysElapsed(asOf: date)
        guard elapsed > 0 else { return s }
        let current = s.current.map {
            WidgetSnapshot.Current(countryCode: $0.countryCode, countryName: $0.countryName, city: $0.city,
                                   since: $0.since, daysInRow: $0.daysInRow + elapsed, daysThisYear: $0.daysThisYear + elapsed)
        }
        // Правила не экстраполируем: неизвестно, в стране ли ещё человек. Приложение перепишет снимок.
        return WidgetSnapshot(today: s.today, generatedAt: s.generatedAt, current: current, rules: s.rules,
                              countriesThisYear: s.countriesThisYear, countriesAllTime: s.countriesAllTime)
    }

    /// Следующая полночь — момент, когда счётчики дней должны вырасти
    static func nextMidnight(after date: Date) -> Date {
        let cal = Calendar.current
        return cal.nextDate(after: date, matching: DateComponents(hour: 0, minute: 0, second: 5), matchingPolicy: .nextTime) ?? date.addingTimeInterval(3600)
    }

    static func color(for status: RuleStatus) -> Color {
        switch status {
        case .ok: return .accentColor
        case .warning: return .orange
        case .exceeded: return .red
        case .reached: return .green
        }
    }
}

struct NoDataView: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "globe").font(.title2).foregroundStyle(.secondary)
            Text("Open the app to load data").font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
    }
}
