import GoogleSignIn
import SwiftUI

@main
struct CountryCounterApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = AppModel()
    @State private var auth = AuthManager()

    init() {
        // Оба вызова должны случиться до конца запуска приложения: iOS может поднять
        // нас в фоне ради события геолокации или BGTask, и делегаты должны уже стоять.
        BackgroundScheduler.register()
        LocationTracker.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(auth)
                // Возврат из браузера после входа через Google
                .onOpenURL { url in GIDSignIn.sharedInstance.handle(url) }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            BackgroundScheduler.schedule()
            Task {
                await LocationTracker.shared.recordForegroundIfNeeded()
                await Uploader.flush()
                await model.refresh()
            }
        }
    }
}
