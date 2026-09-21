import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(AuthManager.self) private var auth
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
                #endif
                await auth.restore()
                await model.refresh()
                // Точки, накопленные до входа, уезжают сразу после входа
                await Uploader.flush()
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
