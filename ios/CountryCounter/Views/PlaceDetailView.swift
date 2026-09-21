import SwiftUI

// Карточка места: фото с атрибуцией, факты, объяснение подборки, действия
struct PlaceDetailView: View {
    @Environment(AppModel.self) private var model
    let place: Recommendation
    @State private var showRate = false
    @State private var busy = false

    private var live: Recommendation { model.recommendations.first { $0.id == place.id } ?? place }
    private var rating: PlaceRating? { model.rating(for: place.id) }

    var body: some View {
        List {
            if !live.photoUrls.isEmpty {
                Section {
                    TabView {
                        ForEach(live.photoUrls, id: \.url) { ph in
                            ZStack(alignment: .bottomTrailing) {
                                AsyncImage(url: URL(string: ph.url)) { phase in
                                    if let image = phase.image { image.resizable().scaledToFill() } else { Color.secondary.opacity(0.1) }
                                }
                                if let a = ph.author {
                                    // условие Google: автор фото показывается рядом с ним
                                    Text(String(localized: "Photo: \(a)")).font(.caption2).padding(6).background(.ultraThinMaterial, in: Capsule()).padding(8)
                                }
                            }
                            .frame(height: 220)
                            .clipped()
                        }
                    }
                    .tabViewStyle(.page)
                    .frame(height: 220)
                    .listRowInsets(EdgeInsets())
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(live.name).font(.title2.bold())
                    HStack(spacing: 8) {
                        if let r = live.rating {
                            HStack(spacing: 3) {
                                Image(systemName: "star.fill")
                                Text(String(format: "%.1f", r))
                            }
                            .foregroundStyle(.orange)
                            if let n = live.ratingCount { Text(String(localized: "\(n) reviews")).foregroundStyle(.secondary) }
                        }
                        if let p = live.priceText { Text(p).foregroundStyle(.secondary) }
                        if let d = live.distanceText { Text(d).foregroundStyle(.secondary) }
                    }
                    .font(.subheadline)
                    if let a = live.address { Text(a).font(.footnote).foregroundStyle(.secondary) }
                }
                if let reason = live.reason {
                    Label(reason, systemImage: "sparkles").font(.subheadline)
                }
                if let tags = live.tags, !tags.isEmpty {
                    Text(tags.map { "#\($0)" }.joined(separator: "  ")).font(.caption).foregroundStyle(.tint)
                }
                if let s = live.summary { Text(s).font(.footnote).foregroundStyle(.secondary) }
            }

            Section {
                if let r = rating {
                    Button {
                        showRate = true
                    } label: {
                        HStack {
                            Label("Your rating", systemImage: "star.circle")
                            Spacer()
                            Text(String(repeating: "★", count: r.stars)).foregroundStyle(.orange)
                        }
                    }
                } else {
                    Button { showRate = true } label: { Label("Been there — rate it", systemImage: "star") }
                }
                Button {
                    busy = true
                    Task { try? await model.toggleSave(live); busy = false }
                } label: {
                    Label(live.user.saved || model.isSaved(live.id) ? "Saved" : "Save for later", systemImage: model.isSaved(live.id) ? "bookmark.fill" : "bookmark")
                }
                .disabled(busy)
                Button {
                    UIApplication.shared.open(URL(string: "maps://?daddr=\(live.lat),\(live.lon)&q=\(live.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")")!)
                } label: {
                    Label("Directions in Apple Maps", systemImage: "map")
                }
                if let g = live.mapsUrl, let u = URL(string: g) {
                    Link(destination: u) { Label("Open in Google Maps", systemImage: "globe") }
                }
                if let w = live.website, let u = URL(string: w) {
                    Link(destination: u) { Label("Website", systemImage: "safari") }
                }
                if let phone = live.phone, let u = URL(string: "tel:\(phone.filter { !$0.isWhitespace })") {
                    Link(destination: u) { Label(phone, systemImage: "phone") }
                }
            }

            if !live.hours.isEmpty {
                Section {
                    ForEach(live.hours, id: \.self) { Text($0).font(.footnote) }
                } header: {
                    HStack {
                        Text("Hours")
                        Spacer()
                        if live.openNow == true { Text("Open now").foregroundStyle(.green).textCase(nil) } else if live.openNow == false { Text("Closed now").foregroundStyle(.red).textCase(nil) }
                    }
                }
            }

            Section {
                Button(role: .destructive) {
                    Task { try? await model.dismiss(live) }
                } label: {
                    Label("Not interested", systemImage: "hand.thumbsdown")
                }
            } footer: {
                Text("Hidden from future picks. Data: Google Maps.")
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showRate) {
            NavigationStack { RatePlaceView(place: live, existing: rating) }
        }
    }
}

/// Открыть карточку по id (сохранённые, оценённые, уведомление)
struct PlaceLoaderView: View {
    let placeId: String
    @State private var place: Recommendation?
    @State private var error: String?

    var body: some View {
        Group {
            if let place {
                PlaceDetailView(place: place)
            } else if let error {
                ContentUnavailableView("Couldn’t load the place", systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                ProgressView()
            }
        }
        .task {
            do { place = try await APIClient.fromSettings().place(id: placeId) } catch { self.error = error.localizedDescription }
        }
    }
}

/// Из уведомления «как вам?»: загрузить место и сразу открыть оценку
struct RatePlaceLoader: View {
    @Environment(AppModel.self) private var model
    let placeId: String
    let name: String
    @State private var place: Recommendation?

    var body: some View {
        Group {
            if let place {
                RatePlaceView(place: place, existing: model.rating(for: placeId))
            } else {
                ProgressView()
            }
        }
        .task {
            // сначала оценки (форма открывается из уведомления раньше общего обновления), потом место
            if model.ratedPlaces.isEmpty, let list = try? await APIClient.fromSettings().ratedPlaces() { model.ratedPlaces = list }
            place = (try? await APIClient.fromSettings().place(id: placeId))
                ?? Recommendation(id: placeId, name: name, address: nil, lat: 0, lon: 0, rating: nil, ratingCount: nil, priceLevel: nil, primaryType: nil, types: [], openNow: nil, hours: [], website: nil, mapsUrl: nil, phone: nil, summary: nil, distanceM: nil, reason: nil, tags: nil, photoUrls: [], user: PlaceUserState(stars: nil, saved: false))
        }
    }
}
