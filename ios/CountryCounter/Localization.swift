import Foundation

// Все пользовательские строки — английские ключи в коде, переводы в Localizable.xcstrings.
// Язык приложения = язык iPhone (или переопределение для приложения в Настройках iOS);
// Locale.current учитывает это, поэтому названия стран и даты форматируются тем же языком.

/// "1 day" / "2 days"; по-русски "1 день / 2 дня / 5 дней" — формы задаются в каталоге.
func pluralDays(_ n: Int) -> String {
    String(localized: "\(n) days")
}

func pluralPoints(_ n: Int) -> String {
    String(localized: "\(n) points")
}

private let isoDayParser: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.timeZone = TimeZone(identifier: "UTC")
    return f
}()

/// "2026-09-18" -> "18 сент." / "Sep 18" в зависимости от языка
func prettyDate(_ iso: String) -> String {
    guard let d = isoDayParser.date(from: iso) else { return iso }
    let style = Date.FormatStyle(locale: .current, calendar: .current, timeZone: TimeZone(identifier: "UTC")!)
        .day().month(.abbreviated)
    return d.formatted(style)
}

extension String {
    /// Локализованное имя страны по ISO-коду, с фолбэком на имя с сервера.
    func countryDisplayName(fallback: String?) -> String {
        Locale.current.localizedString(forRegionCode: self) ?? fallback ?? self
    }
}
