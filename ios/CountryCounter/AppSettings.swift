import Foundation

// Настройки лежат в UserDefaults (токен сессии — в Keychain). Ключи вынесены сюда,
// чтобы @AppStorage во вьюхах и фоновый код читали одно и то же.
enum AppSettings {
    static let serverOverrideKey = "serverOverride"
    static let hourlyEnabledKey = "hourlyEnabled"
    static let notificationsEnabledKey = "notificationsEnabled"
    static let showCountriesSectionKey = "showCountriesSection"
    static let lastForegroundPointKey = "lastForegroundPointAt"
    static let sessionTokenKey = "sessionToken"

    private static var defaults: UserDefaults { .standard }

    // Симулятор ходит в локальный dev-сервер, телефон — в прод.
    static let defaultServerURL: URL = {
        #if targetEnvironment(simulator)
        return URL(string: "http://localhost:3000")!
        #else
        return URL(string: "https://country-tracker.kirillsaint.ge")!
        #endif
    }()

    /// Адрес сервера: переопределение из настроек (только Debug), иначе дефолт по типу сборки.
    static var serverURL: URL? {
        #if DEBUG
        if let raw = defaults.string(forKey: serverOverrideKey)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty,
           let url = URL(string: raw.hasSuffix("/") ? String(raw.dropLast()) : raw),
           url.scheme != nil {
            return url
        }
        #endif
        return defaultServerURL
    }

    static var sessionToken: String? {
        get {
            #if DEBUG
            // Для симулятора, где нет Apple ID: xcrun simctl launch с SIMCTL_CHILD_CC_SESSION_TOKEN=...
            if let debugToken = ProcessInfo.processInfo.environment["CC_SESSION_TOKEN"], !debugToken.isEmpty {
                return debugToken
            }
            #endif
            return Keychain.get(sessionTokenKey)
        }
        set { Keychain.set(newValue, for: sessionTokenKey) }
    }

    static var isSignedIn: Bool { sessionToken != nil }

    static var hourlyEnabled: Bool {
        defaults.object(forKey: hourlyEnabledKey) as? Bool ?? true
    }

    static var notificationsEnabled: Bool {
        defaults.object(forKey: notificationsEnabledKey) as? Bool ?? false
    }

    static var lastForegroundPointAt: Date? {
        get { defaults.object(forKey: lastForegroundPointKey) as? Date }
        set { defaults.set(newValue, forKey: lastForegroundPointKey) }
    }
}
