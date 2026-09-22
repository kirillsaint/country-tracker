import SwiftUI

// Дизайн-система Stamps. Навигация и контролы — системные; фирменное живёт в трёх вещах:
//  1. акцент — «чернильный» синий (AccentColor: #1F4E9C днём, #7FA8FF ночью), только для главного действия и статуса;
//  2. штамп — основание въезда как оттиск в паспорте: пунктирная рамка, капитель, цвет основания;
//  3. цифры дней — округлый начертанием SF Rounded с моноширинными цифрами, как счётчик.
// Все цвета с вариантами для светлой и тёмной темы, контраст текста ≥ 4.5:1 на своей подложке.

extension Color {
    /// Цвет с вариантами для светлой и тёмной темы
    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(UIColor { trait in
            let hex = trait.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}

extension EntryBasis {
    /// Цвет основания: один цвет — одно значение во всём приложении. Подобраны под контраст текста
    /// на белом и на тёмной карточке (все ≥ 4.8:1), чтобы подписи в этом цвете читались
    var tint: Color {
        switch self {
        case .citizen: return .dynamic(light: 0x6B4FBB, dark: 0xB39DFF)
        case .visa_free: return .dynamic(light: 0x1B7F3B, dark: 0x5CD37A)
        case .visa: return .dynamic(light: 0x0B6E85, dark: 0x4CC3DD)
        case .residence: return .dynamic(light: 0x4338CA, dark: 0xA5B4FC)
        case .transit: return .dynamic(light: 0xB4500B, dark: 0xFFA94D)
        case .other: return .dynamic(light: 0x6B7280, dark: 0xA1A1AA)
        }
    }

    /// Залитый вариант значка для цветного отображения
    var homeSystemImage: String {
        switch self {
        case .citizen: return "person.crop.circle.fill"
        case .visa_free: return "checkmark.seal.fill"
        case .visa: return "doc.text.fill"
        case .residence: return "house.fill"
        case .transit: return "airplane"
        case .other: return "questionmark.circle.fill"
        }
    }
}

/// Штамп в паспорте: основание въезда (и любой другой статус) как оттиск — пунктирная рамка,
/// капитель с разрядкой, цвет основания. В карточке на главной чуть повёрнут, в списках — ровно,
/// чтобы строки выравнивались. Читается и без цвета: есть значок и текст.
struct StampBadge: View {
    let text: String
    let systemImage: String
    let tint: Color
    var trailing: String? = nil
    var rotated = false
    var prominent = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
            Text(text.uppercased()).tracking(0.6)
            if let trailing { Text(trailing) }
        }
        .font(prominent ? .caption.weight(.bold) : .caption2.weight(.semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, prominent ? 8 : 6)
        .padding(.vertical, prominent ? 4 : 2)
        .background(
            RoundedRectangle(cornerRadius: prominent ? 6 : 4, style: .continuous)
                .fill(tint.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: prominent ? 6 : 4, style: .continuous)
                .strokeBorder(tint, style: StrokeStyle(lineWidth: prominent ? 1.5 : 1, dash: [3, 2]))
        )
        .rotationEffect(.degrees(rotated ? -3 : 0))
        .accessibilityElement(children: .combine)
    }
}

/// Счётчик дней: крупная округлая цифра и подпись под ней
struct StatTile: View {
    let value: Int
    let unit: String
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(verbatim: String(value))
                    .font(.system(.title, design: .rounded, weight: .bold))
                    .monospacedDigit()
                Text(unit).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            }
            Text(caption).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
