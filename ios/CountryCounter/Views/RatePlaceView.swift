import SwiftUI

// Оценка места: звёзды обязательны, остальное по желанию — параметры зависят от типа места
struct RatePlaceView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let place: Recommendation
    let existing: PlaceRating?

    @State private var stars: Int
    @State private var facets: [String: Int]
    @State private var tags: Set<String>
    @State private var wouldReturn: Int // 0 не знаю, 1 да, 2 нет
    @State private var note: String
    @State private var visited: Date
    @State private var saving = false
    @State private var error: String?

    init(place: Recommendation, existing: PlaceRating?) {
        self.place = place
        self.existing = existing
        _stars = State(initialValue: existing?.stars ?? 0)
        _facets = State(initialValue: existing?.facets ?? [:])
        _tags = State(initialValue: Set(existing?.tags ?? []))
        _wouldReturn = State(initialValue: existing?.wouldReturn == true ? 1 : existing?.wouldReturn == false ? 2 : 0)
        _note = State(initialValue: existing?.note ?? "")
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        _visited = State(initialValue: existing?.visitedAt.flatMap { f.date(from: $0) } ?? Date())
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 6) {
                    Text(place.name).font(.headline)
                    Spacer()
                }
                HStack(spacing: 12) {
                    ForEach(1...5, id: \.self) { i in
                        Button {
                            stars = i
                        } label: {
                            Image(systemName: i <= stars ? "star.fill" : "star").font(.title).foregroundStyle(.orange)
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }
            } header: {
                Text("Overall")
            }

            Section {
                ForEach(place.facets) { f in
                    VStack(alignment: .leading, spacing: 6) {
                        // сегментный пикер в форме прячет свою подпись — рисуем её сами
                        Text(f.title).font(.subheadline)
                        Picker(f.title, selection: Binding(get: { facets[f.rawValue] ?? 0 }, set: { v in if v == 0 { facets[f.rawValue] = nil } else { facets[f.rawValue] = v } })) {
                            Text("—").tag(0)
                            ForEach(1...5, id: \.self) { Text(String($0)).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("Details (optional)")
            } footer: {
                Text("1 is poor, 5 is great. These tune the recommendations — skip anything you don’t care about.")
            }

            Section("Tags") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 8)], spacing: 8) {
                    ForEach(ratingTags, id: \.self) { t in
                        Button {
                            if tags.contains(t) { tags.remove(t) } else { tags.insert(t) }
                        } label: {
                            Text(ratingTagTitle(t))
                                .font(.caption)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .frame(maxWidth: .infinity)
                                .background(Capsule().fill(tags.contains(t) ? Color.accentColor : Color.secondary.opacity(0.12)))
                                .foregroundStyle(tags.contains(t) ? .white : .primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            }

            Section {
                Picker("Would you go again?", selection: $wouldReturn) {
                    Text("Not sure").tag(0)
                    Text("Yes").tag(1)
                    Text("No").tag(2)
                }
                DatePicker("Visited", selection: $visited, in: ...Date(), displayedComponents: .date)
                TextField("Note (optional)", text: $note, axis: .vertical)
            }

            if let error { Section { Text(error).foregroundStyle(.red).font(.footnote) } }

            if existing != nil {
                Section {
                    Button("Delete rating", role: .destructive) {
                        Task {
                            try? await model.deleteRating(placeId: place.id)
                            dismiss()
                        }
                    }
                }
            }
        }
        .navigationTitle("Rate the place")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(action: save) { if saving { ProgressView() } else { Text("Save") } }
                    .disabled(saving || stars == 0)
            }
        }
    }

    private func save() {
        saving = true
        error = nil
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let trimmed = note.trimmingCharacters(in: .whitespaces)
        let rating = PlaceRating(
            placeId: place.id, name: place.name, countryCode: model.current?.countryCode, city: model.current?.city,
            category: place.primaryType, stars: stars, facets: facets, tags: Array(tags), note: trimmed.isEmpty ? nil : trimmed,
            wouldReturn: wouldReturn == 0 ? nil : wouldReturn == 1, visitedAt: f.string(from: visited), createdAt: nil, updatedAt: nil
        )
        Task {
            do {
                try await model.rate(rating)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            saving = false
        }
    }
}

// MARK: - Сохранённые и оценённые

struct PlacesListView: View {
    @Environment(AppModel.self) private var model
    @State private var segment = 0

    var body: some View {
        List {
            // переключатель — отдельной секцией без фона, иначе он оказывается первой строкой карточки
            // и верхние углы списка не скругляются
            Section {
                Picker("", selection: $segment) {
                    Text("Saved").tag(0)
                    Text("Rated").tag(1)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }

            Section {
            if segment == 0 {
                if model.savedPlaces.isEmpty {
                    ContentUnavailableView("Nothing saved yet", systemImage: "bookmark", description: Text("Swipe a pick to the right or tap “Save for later” on a place."))
                }
                ForEach(model.savedPlaces) { s in
                    NavigationLink { PlaceLoaderView(placeId: s.placeId) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.name).font(.headline)
                            Text(verbatim: [s.city, s.countryCode?.countryDisplayName(fallback: nil)].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { offsets in
                    let ids = offsets.map { model.savedPlaces[$0].placeId }
                    Task { for id in ids { try? await APIClient.fromSettings().unsavePlace(id: id); model.savedPlaces.removeAll { $0.placeId == id } } }
                }
            } else {
                if model.ratedPlaces.isEmpty {
                    ContentUnavailableView("No ratings yet", systemImage: "star", description: Text("After a visit the app asks how it was — or rate a place from its card."))
                }
                ForEach(model.ratedPlaces) { r in
                    NavigationLink { PlaceLoaderView(placeId: r.placeId) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.name).font(.headline)
                                Text(verbatim: [r.visitedAt.map(prettyDate), r.city].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(String(repeating: "★", count: r.stars)).foregroundStyle(.orange)
                        }
                    }
                }
            }
            }
        }
        .navigationTitle("Saved and rated")
        .navigationBarTitleDisplayMode(.inline)
    }
}
