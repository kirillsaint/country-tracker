import SwiftUI

// «Чем заняться»: категория или свободный запрос → рекомендации нейросети из справочника Google
struct DiscoverView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var tracker = LocationTracker.shared

    @State private var query = ""
    @State private var category: DiscoverCategory? = .any
    @State private var subtags: Set<String> = []
    @State private var radiusKm = 3.0
    @State private var openNow = false
    @State private var useCity = false
    @State private var city: CityOption?
    @State private var cityCountry: [String] = []
    /// Погода для карточки места: для «рядом» — в текущей точке, для «другого города» — в выбранном городе.
    /// Отдельно от model.weather, который приходит с последним поиском и может быть про другой город.
    @State private var headerWeather: Weather?
    @State private var loading = false
    @State private var error: String?
    @FocusState private var queryFocused: Bool
    @State private var showItinerary = false
    @State private var showTaste = false

    private let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

    var body: some View {
        ScrollViewReader { proxy in
        List {
            if model.tasteLoaded, model.taste == nil {
                Section {
                    Button {
                        showTaste = true
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "slider.horizontal.3").foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Tell the assistant your taste").foregroundStyle(.primary)
                                Text("A one-minute quiz — better picks from the first search.").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }
                    }
                }
            }

            Section {
                Picker("Where", selection: $useCity) {
                    Text("Near me").tag(false)
                    Text("Another city").tag(true)
                }
                .pickerStyle(.segmented)
                if useCity {
                    NavigationLink {
                        CountryPickerView(selection: $cityCountry, single: true)
                    } label: {
                        LabeledContent("Country", value: cityCountry.first?.countryDisplayName(fallback: nil) ?? String(localized: "Choose"))
                    }
                    if let country = cityCountry.first {
                        NavigationLink {
                            CityPickerView(country: country, known: [], selection: .constant(city?.name ?? ""), onPickOption: { city = $0 })
                        } label: {
                            LabeledContent("City", value: city.map { $0.localized ?? $0.name } ?? String(localized: "Choose"))
                        }
                    }
                } else if let p = tracker.lastPoint {
                    LabeledContent("Location", value: p.city ?? String(format: "%.3f, %.3f", p.lat, p.lon))
                }
                if let w = headerWeather {
                    Label {
                        Text(verbatim: "\(w.tempC)°, \(w.localizedSummary)")
                        if w.isRainy || w.isHot || w.isCold {
                            Text("— picks lean indoors").foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: w.systemImage).foregroundStyle(.orange)
                    }
                    .font(.footnote)
                }
            }

            Section {
                Button {
                    showItinerary = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "point.topleft.down.to.point.bottomright.curvepath.fill").foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Plan a half-day route").foregroundStyle(.primary)
                            Text("3–4 places in a sensible order with times, e.g. coffee → walk → dinner.").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                }
                .disabled(useCity && city == nil)
            }

            Section {
                TextField("What do you feel like? e.g. quiet café with outlets", text: $query)
                    .focused($queryFocused)
                    .submitLabel(.search)
                    .onSubmit { Task { await search() } }
                    .onChange(of: query) { _, q in if !q.isEmpty { category = nil } }
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(DiscoverCategory.allCases.filter { $0 != .any }) { c in
                        Button {
                            if category != c { subtags = [] }
                            category = c
                            query = ""
                        } label: {
                            Label(c.title, systemImage: c.systemImage)
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                                .padding(.horizontal, 10).padding(.vertical, 8)
                                .frame(maxWidth: .infinity)
                                .background(RoundedRectangle(cornerRadius: 10).fill(category == c && query.isEmpty ? Color.accentColor : Color.secondary.opacity(0.12)))
                                .foregroundStyle(category == c && query.isEmpty ? .white : .primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                // «удиви меня» — во всю ширину, отдельно от сетки
                Button {
                    category = .any
                    subtags = []
                    query = ""
                } label: {
                    Label(DiscoverCategory.any.title, systemImage: DiscoverCategory.any.systemImage)
                        .font(.caption.weight(.medium))
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity)
                        .background(RoundedRectangle(cornerRadius: 10).fill(category == .any && query.isEmpty ? Color.accentColor : Color.secondary.opacity(0.12)))
                        .foregroundStyle(category == .any && query.isEmpty ? .white : .primary)
                }
                .buttonStyle(.plain)
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 8, trailing: 16))
                .listRowSeparator(.hidden)
                // уточнения выбранной категории: кухни, виды прогулок и т.д.
                if query.isEmpty, let c = category, !c.subtags.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 6)], spacing: 6) {
                        ForEach(c.subtags) { s in
                            Button {
                                if subtags.contains(s.id) { subtags.remove(s.id) } else { subtags.insert(s.id) }
                            } label: {
                                Text(s.title)
                                    .font(.caption)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                                    .padding(.horizontal, 10).padding(.vertical, 6)
                                    .frame(maxWidth: .infinity)
                                    .background(Capsule().fill(subtags.contains(s.id) ? Color.accentColor.opacity(0.9) : Color.secondary.opacity(0.08)))
                                    .foregroundStyle(subtags.contains(s.id) ? .white : .primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 8, trailing: 16))
                }
                Toggle("Open now", isOn: $openNow)
                Picker("Radius", selection: $radiusKm) {
                    Text(String(localized: "\(1) km")).tag(1.0)
                    Text(String(localized: "\(3) km")).tag(3.0)
                    Text(String(localized: "\(10) km")).tag(10.0)
                    Text(String(localized: "\(25) km")).tag(25.0)
                }
                Button {
                    Task { await search() }
                } label: {
                    // Label внутри кнопки в списке резервирует место под иконку, но не рисует её — текст уезжает; собираем сами
                    HStack(spacing: 8) {
                        if loading {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: "sparkles")
                            Text("Find something to do")
                        }
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(loading || (useCity && city == nil))
                .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            } footer: {
                Text("The assistant picks from Google’s directory for your taste and the moment: it can’t invent places. Rate what you visit and the picks get sharper.")
            }

            if loading {
                Section { ForEach(0..<4, id: \.self) { _ in SkeletonRow(flag: 72, lines: 3) } }
            } else if !model.recommendations.isEmpty {
                Section {
                    ForEach(model.recommendations) { r in
                        NavigationLink {
                            PlaceDetailView(place: r)
                        } label: {
                            PlaceRow(place: r)
                        }
                        .swipeActions(edge: .leading) {
                            Button {
                                Task { try? await model.toggleSave(r) }
                            } label: {
                                Label(r.user.saved ? "Unsave" : "Save", systemImage: r.user.saved ? "bookmark.slash" : "bookmark")
                            }
                            .tint(.blue)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                Task { try? await model.dismiss(r) }
                            } label: {
                                Label("Not interested", systemImage: "hand.thumbsdown")
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("Picks for you")
                        if model.discoverRefining {
                            Spacer()
                            ProgressView().controlSize(.mini)
                            Text("Refining for your taste…").textCase(nil)
                        }
                    }
                } footer: {
                    if let s = model.discoverSummary { Text(s) }
                }
                .id("picks")
            }
        }
        .navigationTitle("What to do?")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: weatherKey) { await loadHeaderWeather() }
        .sheet(isPresented: $showItinerary) {
            NavigationStack { ItineraryView(lat: useCity ? city?.lat : tracker.lastPoint?.lat, lon: useCity ? city?.lon : tracker.lastPoint?.lon, radiusKm: min(radiusKm, 10)) }
        }
        .task {
            #if DEBUG
            // -debugItinerary — сразу открыть маршрут и построить его
            if UserDefaults.standard.bool(forKey: "debugItinerary") { showItinerary = true }
            if UserDefaults.standard.bool(forKey: "debugTaste") { showTaste = true }
            if let c = UserDefaults.standard.string(forKey: "debugDiscover"), let cat = DiscoverCategory(rawValue: c) {
                category = cat
                try? await Task.sleep(for: .seconds(2))
                await search()
                // -debugScroll — прокрутить к результатам для скриншота
                if UserDefaults.standard.bool(forKey: "debugScroll") {
                    try? await Task.sleep(for: .milliseconds(300))
                    withAnimation { proxy.scrollTo("picks", anchor: .top) }
                }
            }
            #endif
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    NavigationLink { PlacesListView() } label: { Label("Saved and rated", systemImage: "bookmark") }
                    Button { showTaste = true } label: { Label("Your taste", systemImage: "slider.horizontal.3") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showTaste) { NavigationStack { TasteQuizView(existing: model.taste) } }
        }
    }

    /// Меняется, когда меняется место, для которого нужна погода
    private var weatherKey: String {
        if useCity { return "city|\(city?.id ?? 0)" }
        guard let p = tracker.lastPoint else { return "near|none" }
        return String(format: "near|%.2f|%.2f", p.lat, p.lon)
    }

    private func loadHeaderWeather() async {
        let lat: Double, lon: Double
        if useCity {
            guard let c = city else { headerWeather = nil; return }
            (lat, lon) = (c.lat, c.lon)
            headerWeather = nil
        } else {
            guard let p = tracker.lastPoint else { headerWeather = nil; return }
            (lat, lon) = (p.lat, p.lon)
            // пока грузится свежая — показываем ту, что пришла с последней подборкой рядом
            if headerWeather == nil { headerWeather = model.weather }
        }
        if let w = try? await APIClient.fromSettings().weather(lat: lat, lon: lon), !Task.isCancelled { headerWeather = w }
    }

    private func search() async {
        // клавиатура мешает смотреть результаты — прячем сразу
        queryFocused = false
        loading = true
        error = nil
        defer { loading = false }
        let lat: Double, lon: Double
        if useCity {
            guard let city else { return }
            lat = city.lat
            lon = city.lon
        } else {
            if tracker.lastPoint == nil { _ = await tracker.requestOneShot(source: .manual) }
            // при старте координата может ещё идти (запрос при открытии уже в работе) — подождём немного
            for _ in 0..<12 where tracker.lastPoint == nil { try? await Task.sleep(for: .milliseconds(500)) }
            guard let p = tracker.lastPoint else {
                error = String(localized: "Couldn’t get your location — allow location access or pick a city.")
                return
            }
            lat = p.lat
            lon = p.lon
        }
        var q = query.trimmingCharacters(in: .whitespaces)
        // подтеги превращаются в текстовый запрос: «Italian seafood restaurant»
        if q.isEmpty, let c = category, !subtags.isEmpty {
            q = (c.subtags.filter { subtags.contains($0.id) }.map(\.query) + [c.noun]).joined(separator: " ")
        }
        do {
            try await model.discover(lat: lat, lon: lon, query: q.isEmpty ? nil : q, category: category ?? .any, radiusKm: radiusKm, openNow: openNow)
        } catch {
            if !error.isCancellation { self.error = error.localizedDescription }
        }
    }
}

// MARK: - Строка места

struct PlaceRow: View {
    let place: Recommendation

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            PlaceThumb(url: place.photoUrls.first?.url, size: 72)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(place.name).font(.headline).lineLimit(2)
                    Spacer()
                    if place.user.saved { Image(systemName: "bookmark.fill").foregroundStyle(.tint).font(.caption) }
                }
                HStack(spacing: 6) {
                    if let r = place.rating {
                        HStack(spacing: 2) {
                            Image(systemName: "star.fill")
                            Text(String(format: "%.1f", r))
                        }
                        .foregroundStyle(.orange)
                        if let n = place.ratingCount { Text(verbatim: "(\(n))").foregroundStyle(.secondary) }
                    }
                    if let p = place.priceText { Text(p).foregroundStyle(.secondary) }
                    if let d = place.distanceText { Text(d).foregroundStyle(.secondary) }
                    if place.openNow == true { Text("open").foregroundStyle(.green) } else if place.openNow == false { Text("closed").foregroundStyle(.red) }
                }
                .font(.caption)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                if let reason = place.reason {
                    Text(reason).font(.footnote).foregroundStyle(.secondary).lineLimit(3)
                }
                if let stars = place.user.stars {
                    Text(String(repeating: "★", count: stars)).font(.caption).foregroundStyle(.orange)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct PlaceThumb: View {
    let url: String?
    var size: CGFloat = 72

    var body: some View {
        Group {
            if let url, let u = URL(string: url) {
                AsyncImage(url: u) { phase in
                    if let image = phase.image { image.resizable().scaledToFill() }
                    else if phase.error != nil { placeholder }
                    else { Color.secondary.opacity(0.1) }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var placeholder: some View {
        ZStack {
            Color.secondary.opacity(0.12)
            Image(systemName: "photo").foregroundStyle(.secondary)
        }
    }
}
