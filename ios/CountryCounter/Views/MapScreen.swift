import SwiftUI
import UniformTypeIdentifiers

// Карта в духе Been: посещённые страны закрашены (насыщеннее — где больше дней),
// в режиме "Города" — точки городов. Экспорт в PNG через системный share.
struct MapScreen: View {
    enum Mode: Hashable { case countries, cities }
    enum Period: Hashable { case thisYear, allTime }

    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @State private var store = WorldMapStore.shared
    @State private var mode: Mode = .countries
    @State private var period: Period = .allTime

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var canvasSize: CGSize = .zero
    // Готовый PNG для шаринга: рендерится заранее, чтобы панель «Поделиться» получала обычный файл
    @State private var exportURL: URL?
    @State private var exportTask: Task<Void, Never>?

    private var fitKey: String { "\(period)|\(mode)|\(countries.count)|\(cities.count)" }

    private var countries: [CountryStat] { period == .allTime ? model.allTimeCountries : model.countries }
    private var cities: [CityStat] { period == .allTime ? model.allTimeCities : model.cities }

    private var data: MapData {
        MapData(
            visited: Dictionary(countries.map { ($0.countryCode, $0.days) }, uniquingKeysWith: +),
            cities: cities.compactMap { c in
                guard let lat = c.lat, let lon = c.lon else { return nil }
                return MapData.City(name: c.city.cityDisplayName(country: c.countryCode), lat: lat, lon: lon, days: c.days)
            }
        )
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Picker("", selection: $mode) {
                    Text("Countries").tag(Mode.countries)
                    Text("Cities").tag(Mode.cities)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                GeometryReader { geo in
                    ZStack {
                        if store.countries.isEmpty {
                            ProgressView("Loading map…")
                        } else {
                            MapCanvas(
                                countries: store.countries,
                                data: data,
                                mode: mode,
                                palette: .system(colorScheme),
                                scale: scale,
                                offset: offset
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .gesture(mapGestures(in: geo.size))
                            .onTapGesture(count: 2) { fitToVisited(in: geo.size) }
                        }
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                    .onAppear { canvasSize = geo.size }
                    .onChange(of: geo.size) { _, s in canvasSize = s }
                }
                .aspectRatio(1.15, contentMode: .fit)
                .padding(.horizontal)
                // при первом показе данных и при смене периода/режима — подогнать под посещённое
                .onChange(of: fitKey, initial: true) { _, _ in fitToVisited(in: canvasSize); scheduleExport() }
                .onChange(of: store.countries.isEmpty) { _, _ in fitToVisited(in: canvasSize); scheduleExport() }

                summary
                    .padding(.horizontal)

                Picker("", selection: $period) {
                    Text("This year").tag(Period.thisYear)
                    Text("All time").tag(Period.allTime)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.bottom, 8)

                Spacer(minLength: 0)
            }
            .navigationTitle("Map")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    if let exportURL {
                        ShareLink(item: exportURL, preview: SharePreview("Stamps map", image: Image(systemName: "map"))) {
                            Label("Export PNG", systemImage: "square.and.arrow.up")
                        }
                    } else if !store.countries.isEmpty {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .task {
                store.loadIfNeeded()
                await model.loadAllTimeIfNeeded()
                #if DEBUG
                await debugExportIfRequested()
                #endif
            }
        }
    }

    #if DEBUG
    // xcrun simctl launch … -debugExportPNG /tmp/map.png — сохранить экспорт без нажатия кнопки
    private func debugExportIfRequested() async {
        guard let path = UserDefaults.standard.string(forKey: "debugExportPNG") else { return }
        while store.countries.isEmpty { try? await Task.sleep(for: .milliseconds(200)) }
        let png = MapPNG(countries: store.countries, data: data, mode: mode, caption: summaryText)
        if let bytes = try? await png.debugRender() {
            try? bytes.write(to: URL(fileURLWithPath: path))
        }
    }
    #endif

    private var summaryText: String {
        let n = data.visited.count
        let percent = Int((Double(n) / 195 * 100).rounded())
        let countriesPart = String(localized: "\(n) countries")
        let citiesPart = String(localized: "\(data.cities.count) cities")
        let periodPart = period == .allTime ? String(localized: "all time") : String(localized: "this year")
        return "\(countriesPart) · \(percent)% · \(citiesPart) · \(periodPart)"
    }

    private var summary: some View {
        HStack {
            Text(summaryText).font(.footnote).foregroundStyle(.secondary)
            Spacer()
            Button("Reset zoom") { fitToVisited(in: canvasSize) }.font(.footnote)
        }
    }

    private func mapGestures(in size: CGSize) -> some Gesture {
        let magnify = MagnifyGesture()
            .onChanged { value in
                scale = min(max(lastScale * value.magnification, 1), 10)
            }
            .onEnded { _ in
                lastScale = scale
                if scale <= 1.01 { resetZoom() }
            }
        let drag = DragGesture(minimumDistance: 2)
            .onChanged { value in
                guard scale > 1.01 else { return }
                offset = CGSize(width: lastOffset.width + value.translation.width, height: lastOffset.height + value.translation.height)
            }
            .onEnded { _ in lastOffset = offset }
        return magnify.simultaneously(with: drag)
    }

    private func resetZoom() {
        withAnimation(.easeOut(duration: 0.2)) {
            scale = 1
            offset = .zero
        }
        lastScale = 1
        lastOffset = .zero
    }

    /// Отрендерить PNG во временный файл (с задержкой, чтобы не рендерить на каждое переключение)
    private func scheduleExport() {
        exportTask?.cancel()
        exportURL = nil
        guard !store.countries.isEmpty else { return }
        let png = MapPNG(countries: store.countries, data: data, mode: mode, caption: summaryText)
        exportTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            guard let bytes = try? png.renderData() else { return }
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("map-export", isDirectory: true)
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("country-counter-map.png")
            guard (try? bytes.write(to: url, options: .atomic)) != nil, !Task.isCancelled else { return }
            exportURL = url
        }
    }

    /// Приблизить так, чтобы все посещённые страны и города поместились с отступом.
    private func fitToVisited(in size: CGSize) {
        guard size.width > 0, size.height > 0, !store.countries.isEmpty else { return }
        var box: CGRect? = nil
        func include(_ r: CGRect) { box = box.map { $0.union(r) } ?? r }
        if mode == .countries {
            for c in store.countries where data.visited[c.code] != nil { include(c.mainBounds) }
        } else {
            for city in data.cities {
                let p = WorldProjection.unitPoint(lon: city.lon, lat: city.lat)
                include(CGRect(x: p.x - 0.01, y: p.y - 0.01, width: 0.02, height: 0.02))
            }
        }
        guard let unitBox = box else { resetZoom(); return }

        let (origin, mapSize) = MapCanvas.baseGeometry(for: size)
        let px = CGRect(
            x: origin.x + unitBox.minX * mapSize.width,
            y: origin.y + unitBox.minY * mapSize.height,
            width: max(unitBox.width * mapSize.width, 1),
            height: max(unitBox.height * mapSize.height, 1)
        )
        let s = min(max(min(size.width * 0.8 / px.width, size.height * 0.8 / px.height), 1), 8)
        let center = CGPoint(x: px.midX, y: px.midY)
        let newOffset = CGSize(width: -(center.x - size.width / 2) * s, height: -(center.y - size.height / 2) * s)
        withAnimation(.easeOut(duration: 0.25)) {
            scale = s
            offset = newOffset
        }
        lastScale = s
        lastOffset = newOffset
    }
}

// MARK: - Данные и палитра

struct MapData {
    struct City: Identifiable {
        var id: String { "\(name)|\(lat)|\(lon)" }
        let name: String
        let lat: Double
        let lon: Double
        let days: Int
    }

    let visited: [String: Int]
    let cities: [City]

    var maxDays: Int { max(visited.values.max() ?? 1, 1) }
}

struct MapPalette {
    let ocean: Color
    let land: Color
    let border: Color
    let visited: Color
    let city: Color
    let cityStroke: Color

    static func system(_ scheme: ColorScheme) -> MapPalette {
        MapPalette(
            ocean: Color(uiColor: .secondarySystemBackground),
            land: Color(uiColor: scheme == .dark ? .systemGray4 : .systemGray5),
            border: Color(uiColor: .secondarySystemBackground),
            visited: .accentColor,
            city: .accentColor,
            cityStroke: Color(uiColor: .systemBackground)
        )
    }

    // Экспорт всегда светлый, чтобы PNG одинаково смотрелся везде
    static let export = MapPalette(
        ocean: Color(red: 0.93, green: 0.95, blue: 0.97),
        land: Color(red: 0.84, green: 0.86, blue: 0.88),
        border: .white,
        visited: Color(red: 0.0, green: 0.478, blue: 0.902),
        city: Color(red: 0.0, green: 0.478, blue: 0.902),
        cityStroke: .white
    )
}

// MARK: - Отрисовка

struct MapCanvas: View {
    let countries: [WorldCountry]
    let data: MapData
    let mode: MapScreen.Mode
    let palette: MapPalette
    var scale: CGFloat = 1
    var offset: CGSize = .zero

    /// Карта вписывается в доступный прямоугольник с сохранением пропорций
    static func baseGeometry(for size: CGSize) -> (origin: CGPoint, mapSize: CGSize) {
        let aspect = WorldProjection.aspect
        var mapSize = CGSize(width: size.width, height: size.width / aspect)
        if mapSize.height > size.height {
            mapSize = CGSize(width: size.height * aspect, height: size.height)
        }
        return (CGPoint(x: (size.width - mapSize.width) / 2, y: (size.height - mapSize.height) / 2), mapSize)
    }

    var body: some View {
        Canvas(rendersAsynchronously: true) { context, size in
            let (origin, mapSize) = Self.baseGeometry(for: size)

            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(palette.ocean))

            // Зум вокруг центра + сдвиг
            context.translateBy(x: size.width / 2 + offset.width, y: size.height / 2 + offset.height)
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -size.width / 2, y: -size.height / 2)

            let transform = CGAffineTransform(translationX: origin.x, y: origin.y)
                .scaledBy(x: mapSize.width, y: mapSize.height)
            let borderWidth = max(0.4, 0.6 / scale)

            for country in countries {
                let path = country.path.applying(transform)
                let days = mode == .countries ? data.visited[country.code] : nil
                let fill: Color
                if let days {
                    let t = 0.45 + 0.55 * min(1, Double(days) / Double(data.maxDays))
                    fill = palette.visited.opacity(t)
                } else {
                    fill = palette.land
                }
                context.fill(path, with: .color(fill), style: FillStyle(eoFill: true))
                context.stroke(path, with: .color(palette.border), lineWidth: borderWidth)
            }

            // Мелкие посещённые страны (Мальта, Сингапур) не видны как полигон — ставим маркер
            if mode == .countries {
                for country in countries where data.visited[country.code] != nil {
                    let w = country.mainBounds.width * mapSize.width * scale
                    if w < 6 {
                        let c = country.center.applying(transform)
                        let r = 3.0 / scale
                        let dot = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
                        context.fill(dot, with: .color(palette.visited))
                        context.stroke(dot, with: .color(palette.cityStroke), lineWidth: 1 / scale)
                    }
                }
            }

            if mode == .cities {
                let maxDays = Double(max(data.cities.map(\.days).max() ?? 1, 1))
                for city in data.cities {
                    let p = WorldProjection.unitPoint(lon: city.lon, lat: city.lat).applying(transform)
                    let r = (2.5 + 4 * sqrt(Double(city.days) / maxDays)) / scale
                    let dot = Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
                    context.fill(dot, with: .color(palette.city.opacity(0.85)))
                    context.stroke(dot, with: .color(palette.cityStroke), lineWidth: 1.2 / scale)
                }
            }
        }
    }
}

// MARK: - Экспорт

// Файл PNG, который рендерится в момент шаринга: заголовок, карта, подпись.
struct MapPNG: Transferable {
    let countries: [WorldCountry]
    let data: MapData
    let mode: MapScreen.Mode
    let caption: String

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { item in
            try await item.render()
        }
        .suggestedFileName("country-counter-map.png")
    }

    #if DEBUG
    @MainActor
    func debugRender() throws -> Data { try render() }
    #endif

    @MainActor
    func renderData() throws -> Data { try render() }

    @MainActor
    private func render() throws -> Data {
        let width: CGFloat = 2400
        let view = MapExportView(countries: countries, data: data, mode: mode, caption: caption)
            .frame(width: width)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        renderer.proposedSize = ProposedViewSize(width: width, height: nil)
        guard let image = renderer.uiImage, let png = image.pngData() else {
            throw CocoaError(.fileWriteUnknown)
        }
        return png
    }
}

struct MapExportView: View {
    let countries: [WorldCountry]
    let data: MapData
    let mode: MapScreen.Mode
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: "Stamps")
                    .font(.system(size: 64, weight: .bold))
                Spacer()
                Text(caption)
                    .font(.system(size: 30))
                    .foregroundStyle(.secondary)
            }
            MapCanvas(countries: countries, data: data, mode: mode, palette: .export)
                .aspectRatio(WorldProjection.aspect, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            Text(Date().formatted(date: .long, time: .omitted))
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
        }
        .padding(72)
        .background(Color.white)
        .environment(\.colorScheme, .light)
    }
}
