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
                    .tabItem { Label("Сейчас", systemImage: "location.fill") }
                    .tag(0)
                TimelineView()
                    .tabItem { Label("История", systemImage: "calendar") }
                    .tag(1)
                NavigationStack { SettingsView() }
                    .tabItem { Label("Настройки", systemImage: "gearshape") }
                    .tag(2)
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
