import SwiftUI

// «Чем заняться»: категория или свободный запрос → рекомендации нейросети из справочника Google
struct DiscoverView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var tracker = LocationTracker.shared

    @State private var query = ""
    @State private var category: DiscoverCategory? = .any
    @State private var radiusKm = 3.0
    @State private var openNow = false
    @State private var useCity = false
    @State private var city: CityOption?
    @State private var cityCountry: [String] = []
    @State private var loading = false
    @State private var error: String?

    private let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

    var body: some View {
        List {
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
            }

            Section {
                TextField("What do you feel like? e.g. quiet café with outlets", text: $query, axis: .vertical)
                    .onChange(of: query) { _, q in if !q.isEmpty { category = nil } }
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(DiscoverCategory.allCases) { c in
                        Button {
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
                    HStack {
                        Spacer()
                        if loading { ProgressView().tint(.white) } else { Label("Find something to do", systemImage: "sparkles") }
                        Spacer()
                    }
                    .font(.headline)
                }
                .buttonStyle(.borderedProminent)
                .disabled(loading || (useCity && city == nil))
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
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
                    Text("Picks for you")
                } footer: {
                    if let s = model.discoverSummary { Text(s) }
                }
            }
        }
        .navigationTitle("What to do?")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            #if DEBUG
            if let c = UserDefaults.standard.string(forKey: "debugDiscover"), let cat = DiscoverCategory(rawValue: c), model.recommendations.isEmpty {
                category = cat
                try? await Task.sleep(for: .seconds(2))
                await search()
            }
            #endif
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            ToolbarItem(placement: .primaryAction) {
                NavigationLink { PlacesListView() } label: { Label("Saved and rated", systemImage: "bookmark") }
            }
        }
    }

    private func search() async {
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
        let q = query.trimmingCharacters(in: .whitespaces)
        do {
            try await model.discover(lat: lat, lon: lon, query: q.isEmpty ? nil : q, category: q.isEmpty ? (category ?? .any) : nil, radiusKm: radiusKm, openNow: openNow)
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
                        Label(String(format: "%.1f", r), systemImage: "star.fill").foregroundStyle(.orange)
                        if let n = place.ratingCount { Text(verbatim: "(\(n))").foregroundStyle(.secondary) }
                    }
                    if let p = place.priceText { Text(p).foregroundStyle(.secondary) }
                    if let d = place.distanceText { Text(d).foregroundStyle(.secondary) }
                    if place.openNow == true { Text("open").foregroundStyle(.green) } else if place.openNow == false { Text("closed").foregroundStyle(.red) }
                }
                .font(.caption)
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
