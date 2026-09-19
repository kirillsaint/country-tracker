import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(AuthManager.self) private var auth
    @State private var tab = Self.initialTab

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
                MapScreen()
                    .tabItem { Label("Map", systemImage: "map") }
                    .tag(2)
                NavigationStack { SettingsView() }
                    .tabItem { Label("Settings", systemImage: "gearshape") }
                    .tag(3)
            }
            .task(id: auth.token) {
                await auth.restore()
                await model.refresh()
                // Точки, накопленные до входа, уезжают сразу после входа
                await Uploader.flush()
            }
        } else {
            AuthView()
        }
    }
}
