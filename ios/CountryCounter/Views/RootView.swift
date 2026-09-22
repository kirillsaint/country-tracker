import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(AuthManager.self) private var auth
    @Environment(\.openURL) private var openURL
    @State private var tab = Self.initialTab
    @State private var router = Router.shared

    // В Debug-сборке вкладку можно выбрать аргументом запуска: -debugInitialTab 1
    private static var initialTab: Int {
        #if DEBUG
        return UserDefaults.standard.integer(forKey: "debugInitialTab")
        #else
        return 0
        #endif
    }

    var body: some View {
        if auth.isSignedIn {
            TabView(selection: $tab) {
                HomeView()
                    .tabItem { Label("Now", systemImage: "location.fill") }
                    .tag(0)
                TimelineView()
                    .tabItem { Label("History", systemImage: "calendar") }
                    .tag(1)
                DocumentsView()
                    .tabItem { Label("Documents", systemImage: "person.text.rectangle") }
                    .tag(2)
                NavigationStack { SettingsView() }
                    .tabItem { Label("Settings", systemImage: "gearshape") }
                    .tag(3)
            }
            .task(id: auth.token) {
                #if DEBUG
                // xcrun simctl launch … -debugPlace <id> | -debugRatePlace <id> | -debugPlaces — открыть экран сразу
                if let id = UserDefaults.standard.string(forKey: "debugPlace") { router.pending = .place(id: id) }
                if let id = UserDefaults.standard.string(forKey: "debugRatePlace") { router.pending = .ratePlace(id: id, name: "") }
                if UserDefaults.standard.bool(forKey: "debugPlaces") { router.pending = .places }
                // -debugEntryBasis YES — открыть лист «как въехали?» для текущего пребывания
                if UserDefaults.standard.bool(forKey: "debugEntryBasis") { router.pending = .entryBasis(country: "") }
                #endif
                await auth.restore()
                await model.refresh()
                // Точки, накопленные до входа, уезжают сразу после входа
                await Uploader.flush()
                await model.checkForUpdate(force: true)
            }
            .alert("Update available", isPresented: Binding(get: { model.availableUpdate != nil }, set: { if !$0 { model.availableUpdate = nil } }), presenting: model.availableUpdate) { update in
                Button("Update") { openURL(update.url) }
                Button("Later", role: .cancel) {}
            } message: { update in
                if let notes = update.notes, !notes.isEmpty {
                    Text("Version \(update.version) (\(update.buildNumber)) is in the store.\n\(notes)")
                } else {
                    Text("Version \(update.version) (\(update.buildNumber)) is in the store.")
                }
            }
            .sheet(item: $router.pending) { link in
                NavigationStack {
                    switch link {
                    case .regime(let country, let passportId):
                        RegimeView(countryCode: country, initialPassportId: passportId)
                            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { router.pending = nil } } }
                    case .ratePlace(let id, let name):
                        RatePlaceLoader(placeId: id, name: name)
                    case .place(let id):
                        PlaceLoaderView(placeId: id)
                            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { router.pending = nil } } }
                    case .places:
                        PlacesListView()
                            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { router.pending = nil } } }
                    case .entryBasis:
                        if let seg = model.currentSegment {
                            EntryBasisSheet(segment: seg, existing: model.entry(for: seg), previous: model.current?.previousEntry, regimeRef: model.current?.regime)
                        } else {
                            ContentUnavailableView("No data yet", systemImage: "globe")
                                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { router.pending = nil } } }
                        }
                    }
                }
            }
        } else {
            AuthView()
        }
    }
}
