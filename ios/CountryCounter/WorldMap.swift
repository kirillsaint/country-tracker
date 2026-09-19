import Foundation
import Observation
import SwiftUI

// Границы стран из Natural Earth 1:50m (Resources/world.json), спроецированные в единичный
// квадрат: x = долгота 0…1, y = широта сверху вниз 0…1. Проекция равнопромежуточная,
// широта обрезана до [-58°, 84°] — без Антарктиды и полярной пустоты.
struct WorldCountry: Identifiable {
    let code: String
    let name: String
    /// bbox всей страны в единичных координатах (со всеми островами и территориями)
    let bounds: CGRect
    /// bbox основного массива суши — для автоподгонки и маркеров. У США полный bbox
    /// растянут Алеутами через 180-й меридиан, у Франции — заморскими территориями.
    let mainBounds: CGRect
    let path: Path

    var id: String { code }
    var center: CGPoint { CGPoint(x: mainBounds.midX, y: mainBounds.midY) }
}

enum WorldProjection {
    static let latMax = 84.0
    static let latMin = -58.0
    /// ширина / высота карты
    static let aspect: CGFloat = 360 / CGFloat(latMax - latMin)

    static func unitPoint(lon: Double, lat: Double) -> CGPoint {
        let clamped = min(max(lat, latMin), latMax)
        return CGPoint(x: (lon + 180) / 360, y: (latMax - clamped) / (latMax - latMin))
    }
}

// Грузится один раз в фоне при первом открытии карты (~1.3 МБ JSON, ~95 тысяч точек).
@MainActor
@Observable
final class WorldMapStore {
    static let shared = WorldMapStore()

    private(set) var countries: [WorldCountry] = []
    private(set) var isLoading = false
    private(set) var error: String?

    func loadIfNeeded() {
        guard countries.isEmpty, !isLoading else { return }
        isLoading = true
        Task.detached(priority: .userInitiated) {
            do {
                let loaded = try Self.load()
                await MainActor.run {
                    self.countries = loaded
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    self.error = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }

    private struct RawFile: Decodable {
        struct Country: Decodable {
            let c: String
            let n: String
            let b: [Double]
            let r: [[[Double]]]
        }
        let countries: [Country]
    }

    nonisolated private static func load() throws -> [WorldCountry] {
        guard let url = Bundle.main.url(forResource: "world", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let raw = try JSONDecoder().decode(RawFile.self, from: Data(contentsOf: url))
        return raw.countries.map { c in
            var path = Path()
            var mainRing: (area: Double, rect: CGRect)? = nil
            for ring in c.r {
                guard let first = ring.first else { continue }
                path.move(to: WorldProjection.unitPoint(lon: first[0], lat: first[1]))
                var minX = first[0], maxX = first[0], minY = first[1], maxY = first[1]
                for p in ring.dropFirst() {
                    path.addLine(to: WorldProjection.unitPoint(lon: p[0], lat: p[1]))
                    minX = min(minX, p[0]); maxX = max(maxX, p[0])
                    minY = min(minY, p[1]); maxY = max(maxY, p[1])
                }
                path.closeSubpath()
                // кольца, пересекающие антимеридиан, в кандидаты не берём
                let area = (maxX - minX) * (maxY - minY)
                let crossesAntimeridian = (maxX - minX) >= 180
                if !crossesAntimeridian && area > (mainRing?.area ?? -1) {
                    let tl = WorldProjection.unitPoint(lon: minX, lat: maxY)
                    let br = WorldProjection.unitPoint(lon: maxX, lat: minY)
                    mainRing = (area, CGRect(x: tl.x, y: tl.y, width: br.x - tl.x, height: br.y - tl.y))
                }
            }
            let tl = WorldProjection.unitPoint(lon: c.b[0], lat: c.b[3])
            let br = WorldProjection.unitPoint(lon: c.b[2], lat: c.b[1])
            let bounds = CGRect(x: tl.x, y: tl.y, width: br.x - tl.x, height: br.y - tl.y)
            return WorldCountry(code: c.c, name: c.n, bounds: bounds, mainBounds: mainRing?.rect ?? bounds, path: path)
        }
    }
}
