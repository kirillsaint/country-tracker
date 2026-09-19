import SwiftUI

// Плоский флаг с flagcdn.com (кэшируется URLSession'ом); пока грузится или без сети — эмодзи.
struct FlagView: View {
    let code: String
    var width: CGFloat = 32

    private var height: CGFloat { width * 3 / 4 }

    var body: some View {
        AsyncImage(url: URL(string: "https://flagcdn.com/w160/\(code.lowercased()).png")) { phase in
            if case .success(let image) = phase {
                image.resizable().scaledToFill()
            } else {
                Text(code.flagEmoji)
                    .font(.system(size: width * 0.7))
                    .minimumScaleFactor(0.5)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: width * 0.12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: width * 0.12, style: .continuous)
                .strokeBorder(.primary.opacity(0.12), lineWidth: 0.5)
        )
        .accessibilityLabel(code.countryDisplayName(fallback: nil))
    }
}

// Ряд флагов для правила: первые несколько + "+N"
struct FlagRow: View {
    let codes: [String]
    var max = 6
    var width: CGFloat = 22

    var body: some View {
        HStack(spacing: 4) {
            if codes.isEmpty {
                Label("Any country", systemImage: "globe").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(codes.prefix(max), id: \.self) { FlagView(code: $0, width: width) }
                if codes.count > max {
                    Text("+\(codes.count - max)").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
