import SwiftUI

// Скелетоны на время первой загрузки: серые плашки формы будущего контента с бегущим бликом.
// Показываются, пока сервер ещё ни разу не ответил (model.showSkeleton); пустые состояния — только после ответа.

/// Бегущий блик поверх серых плашек
private struct Shimmer: ViewModifier {
    @State private var phase: CGFloat = -0.6

    func body(content: Content) -> some View {
        content
            .overlay {
                GeometryReader { geo in
                    LinearGradient(
                        colors: [.clear, Color.primary.opacity(0.10), .clear],
                        startPoint: .leading, endPoint: .trailing
                    )
                    .frame(width: geo.size.width * 0.6)
                    .offset(x: phase * geo.size.width)
                }
                .mask(content)
            }
            .onAppear {
                withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) { phase = 1.2 }
            }
    }
}

extension View {
    /// Скелетон: серые плашки, блик, недоступно для VoiceOver
    func skeleton() -> some View {
        modifier(Shimmer()).accessibilityHidden(true).allowsHitTesting(false)
    }
}

/// Одна плашка: строка текста, число, флаг
struct SkeletonBar: View {
    var width: CGFloat? = nil
    var height: CGFloat = 12
    var radius: CGFloat? = nil

    var body: some View {
        RoundedRectangle(cornerRadius: radius ?? height / 2, style: .continuous)
            .fill(Color.primary.opacity(0.08))
            .frame(width: width, height: height)
    }
}

/// Плашка под флаг (FlagView с тем же соотношением 4:3)
struct SkeletonFlag: View {
    var width: CGFloat = 40
    var body: some View { SkeletonBar(width: width, height: width * 3 / 4, radius: 6) }
}

/// Строка списка: флаг, две строки текста, число справа — страны, документы, ручные записи
struct SkeletonRow: View {
    var flag: CGFloat = 40
    var lines: Int = 2
    var trailing: Bool = true

    var body: some View {
        HStack(spacing: 12) {
            SkeletonFlag(width: flag)
            VStack(alignment: .leading, spacing: 7) {
                SkeletonBar(width: 140, height: 14)
                if lines > 1 { SkeletonBar(width: 90, height: 10) }
                if lines > 2 { SkeletonBar(width: 110, height: 10) }
            }
            Spacer()
            if trailing { SkeletonBar(width: 48, height: 12) }
        }
        .padding(.vertical, 4)
        .skeleton()
    }
}

/// Карточка текущей страны на главной
struct SkeletonCurrentCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                SkeletonFlag(width: 84)
                VStack(alignment: .leading, spacing: 8) {
                    SkeletonBar(width: 160, height: 26)
                    SkeletonBar(width: 90, height: 16)
                }
            }
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    SkeletonBar(width: 56, height: 16)
                    SkeletonBar(width: 110, height: 10)
                }
                VStack(alignment: .leading, spacing: 6) {
                    SkeletonBar(width: 56, height: 16)
                    SkeletonBar(width: 70, height: 10)
                }
            }
            HStack(spacing: 12) {
                SkeletonBar(width: 80, height: 12)
                Spacer()
                SkeletonBar(width: 100, height: 12)
            }
        }
        .padding(.vertical, 6)
        .skeleton()
    }
}

/// Карточка правила: название, число, флаг, прогресс, пояснение
struct SkeletonRuleCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SkeletonBar(width: 170, height: 16)
                Spacer()
                SkeletonBar(width: 52, height: 16)
            }
            SkeletonFlag(width: 24)
            SkeletonBar(height: 6)
            SkeletonBar(width: 220, height: 10)
        }
        .padding(.vertical, 4)
        .skeleton()
    }
}

/// Плитки итогов в статистике
struct SkeletonTiles: View {
    var count: Int = 3

    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { _ in
                VStack(spacing: 8) {
                    SkeletonBar(width: 44, height: 22)
                    SkeletonBar(width: 56, height: 10)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 6)
        .skeleton()
    }
}
