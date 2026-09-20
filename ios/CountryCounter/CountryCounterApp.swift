import GoogleSignIn
import SwiftUI

@main
struct CountryCounterApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
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
                // Основание въезда выбрано кнопкой в уведомлении
                .onReceive(NotificationCenter.default.publisher(for: .entryBasisChanged)) { _ in
                    Task { await model.refresh() }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            BackgroundScheduler.schedule()
            Task {
                // сначала показываем то, что уже есть, затем свежая точка — и данные перечитываются с ней
                await model.refresh()
                if await LocationTracker.shared.recordForegroundIfNeeded() {
                    await model.refresh()
                } else {
                    await Uploader.flush()
                }
            }
        }
    }
}
