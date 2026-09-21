import SwiftUI

// Маршрут на полдня: 3–4 остановки по порядку со временем и объяснениями
struct ItineraryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var tracker = LocationTracker.shared
    let lat: Double?
    let lon: Double?
    let radiusKm: Double

    @State private var hours = 4
    @State private var note = ""
    @State private var customStart = false
    @State private var start = Date().addingTimeInterval(30 * 60)
    @State private var loading = false
    @State private var error: String?
    @FocusState private var noteFocused: Bool

    var body: some View {
        List {
            Section {
                Picker("Duration", selection: $hours) {
                    Text(String(localized: "\(3) h")).tag(3)
                    Text(String(localized: "\(4) h")).tag(4)
                    Text(String(localized: "\(6) h")).tag(6)
                }
                .pickerStyle(.segmented)
                Picker("Start", selection: $customStart) {
                    Text("Now").tag(false)
                    Text("Pick date and time").tag(true)
                }
                .pickerStyle(.segmented)
                if customStart {
                    DatePicker("Start", selection: $start, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                }
                TextField("Wishes: e.g. must visit Roasters, dinner by the water", text: $note, axis: .vertical)
                    .focused($noteFocused)
                    .lineLimit(1...3)
                Button {
                    Task { await build() }
                } label: {
                    HStack(spacing: 8) {
                        if loading { ProgressView().tint(.white) } else { Image(systemName: "sparkles"); Text(model.itinerary == nil ? "Build a route" : "Build another one") }
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .disabled(loading)
                .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            } footer: {
                Text(customStart
                     ? "For another day the plan relies on the weekly opening hours; the weather is not taken into account."
                     : "Starts in about 15 minutes from where you are. Name a place you definitely want to visit and the route is built around it; saved places are considered too.")
            }

            if loading {
                Section { ForEach(0..<3, id: \.self) { _ in SkeletonRow(flag: 72, lines: 3) } }
            } else if let it = model.itinerary {
                Section {
                    ForEach(it.stops) { stop in
                        NavigationLink {
                            PlaceDetailView(place: stop.place)
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                VStack(spacing: 2) {
                                    Text(stop.start).font(.subheadline.monospacedDigit().weight(.semibold))
                                    Text(stop.end).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                }
                                .frame(width: 48)
                                PlaceThumb(url: stop.place.photoUrls.first?.url, size: 56)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(stop.place.name).font(.headline).lineLimit(2)
                                    if let r = stop.place.reason { Text(r).font(.footnote).foregroundStyle(.secondary) }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                } header: {
                    Text(customStart ? "\(it.title) · \(prettyFullDate(isoDay(start)))" : it.title)
                } footer: {
                    Text(it.summary)
                }
                Section {
                    if let url = it.googleRouteURL {
                        Link(destination: url) { Label("Whole route in Google Maps", systemImage: "map") }
                    }
                    if let first = it.stops.first {
                        Button {
                            UIApplication.shared.open(URL(string: "maps://?daddr=\(first.place.lat),\(first.place.lon)")!)
                        } label: {
                            Label("First stop in Apple Maps", systemImage: "location")
                        }
                    }
                } footer: {
                    Text("Apple Maps takes one destination at a time; Google Maps shows all stops.")
                }
            }
        }
        .navigationTitle("Half-day route")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        .task {
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "debugItinerary"), model.itinerary == nil {
                try? await Task.sleep(for: .seconds(3))
                await build()
            }
            #endif
        }
    }

    private func isoDay(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    private func build() async {
        noteFocused = false
        loading = true
        error = nil
        defer { loading = false }
        var lat = lat, lon = lon
        if lat == nil {
            if tracker.lastPoint == nil { _ = await tracker.requestOneShot(source: .manual) }
            lat = tracker.lastPoint?.lat
            lon = tracker.lastPoint?.lon
        }
        guard let lat, let lon else {
            error = String(localized: "Couldn’t get your location — allow location access or pick a city.")
            return
        }
        do {
            let trimmed = note.trimmingCharacters(in: .whitespaces)
            try await model.buildItinerary(lat: lat, lon: lon, hours: hours, radiusKm: radiusKm, note: trimmed.isEmpty ? nil : trimmed, start: customStart ? start : nil)
        } catch {
            if !error.isCancellation { self.error = error.localizedDescription }
        }
    }
}
