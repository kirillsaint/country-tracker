import SwiftUI

// Мини-тест о вкусах: минута вопросов вместо холодного старта. Ответы уходят в промпт рекомендаций
// вместе с оценками; всё необязательно, можно вернуться и поменять.
struct TasteQuizView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var p: TastePreferences
    @State private var saving = false
    @State private var error: String?

    init(existing: TastePreferences?) {
        _p = State(initialValue: existing ?? TastePreferences())
    }

    var body: some View {
        Form {
            Section {
                chips(TastePreferences.cuisineOptions, selection: $p.cuisines)
            } header: {
                Text("What do you like to eat?")
            }

            Section("What matters most on a trip?") {
                chips(TastePreferences.priorityOptions, selection: $p.priorities)
            }

            Section {
                labeled("Atmosphere") {
                    Picker("Atmosphere", selection: $p.vibe) {
                        Text("Quiet").tag("quiet")
                        Text("Doesn’t matter").tag("any")
                        Text("Lively").tag("lively")
                    }
                }
                labeled("Budget") {
                    Picker("Budget", selection: $p.budget) {
                        Text("Cheap").tag("cheap")
                        Text("Mid").tag("mid")
                        Text("Upscale").tag("high")
                        Text("Any").tag("any")
                    }
                }
                Picker("Usually travelling", selection: $p.company) {
                    Text("Solo").tag("solo")
                    Text("As a couple").tag("couple")
                    Text("With friends").tag("friends")
                    Text("With family").tag("family")
                }
                labeled("Famous or hidden?") {
                    Picker("Famous or hidden?", selection: $p.discovery) {
                        Text("Famous").tag("famous")
                        Text("Mix").tag("mix")
                        Text("Hidden").tag("hidden")
                    }
                }
            } header: {
                Text("Style")
            }

            Section("Dietary") {
                chips(TastePreferences.dietaryOptions, selection: $p.dietary)
            }

            Section("What to avoid") {
                chips(TastePreferences.avoidOptions, selection: $p.avoid)
            }

            Section {
                TextField("Anything else? e.g. love terraces with a view, hate malls", text: Binding(get: { p.note ?? "" }, set: { p.note = $0.isEmpty ? nil : $0 }), axis: .vertical)
            } footer: {
                Text("Free-form wishes go straight to the assistant.")
            }

            if let error { Section { Text(error).foregroundStyle(.red).font(.footnote) } }
        }
        .navigationTitle("Your taste")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(action: save) { if saving { ProgressView() } else { Text("Save") } }.disabled(saving)
            }
        }
    }

    /// Сегментный пикер в форме прячет заголовок — подписываем сами
    private func labeled<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline)
            content().pickerStyle(.segmented).labelsHidden()
        }
        .padding(.vertical, 2)
    }

    private func chips(_ options: [(id: String, title: String)], selection: Binding<[String]>) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)], spacing: 8) {
            ForEach(options, id: \.id) { o in
                let on = selection.wrappedValue.contains(o.id)
                Button {
                    if on { selection.wrappedValue.removeAll { $0 == o.id } } else { selection.wrappedValue.append(o.id) }
                } label: {
                    Text(o.title)
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .frame(maxWidth: .infinity)
                        .background(Capsule().fill(on ? Color.accentColor : Color.secondary.opacity(0.12)))
                        .foregroundStyle(on ? .white : .primary)
                }
                .buttonStyle(.plain)
            }
        }
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
    }

    private func save() {
        saving = true
        error = nil
        Task {
            do {
                try await model.saveTaste(p)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            saving = false
        }
    }
}
