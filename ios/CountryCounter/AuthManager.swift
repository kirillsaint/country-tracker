import AuthenticationServices
import Foundation
import GoogleSignIn
import Observation
import UIKit

// Вход через Apple / Google, привязка второго провайдера, выход. Токен сессии живёт в Keychain,
// сюда зеркалится, чтобы SwiftUI перерисовался при входе/выходе.
@MainActor
@Observable
final class AuthManager {
    enum Mode { case signIn, link }

    private(set) var token: String? = AppSettings.sessionToken {
        didSet { AppSettings.sessionToken = token }
    }
    private(set) var user: User?
    var isBusy = false
    var errorMessage: String?
    var infoMessage: String?

    var isSignedIn: Bool { token != nil && AppSettings.serverURL != nil }

    /// Google работает только если в Config.xcconfig задан настоящий client id.
    static var isGoogleConfigured: Bool {
        guard let id = Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String else { return false }
        return id.hasSuffix(".apps.googleusercontent.com") && !id.hasPrefix("000000000000-")
    }

    init() {
        NotificationCenter.default.addObserver(forName: .sessionInvalid, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.token = nil
                self?.user = nil
                self?.errorMessage = String(localized: "Session expired, please sign in again.")
            }
        }
    }

    /// При запуске: подтянуть профиль, если сессия есть. Сетевая ошибка не разлогинивает —
    /// разлогинивает только 401 (через .sessionInvalid).
    func restore() async {
        guard isSignedIn, user == nil else { return }
        user = try? await APIClient.fromSettings().me()
    }

    // MARK: - Apple

    func handleApple(_ result: Result<ASAuthorization, Error>, mode: Mode) async {
        switch result {
        case .failure(let error):
            // Отмена пользователем — не ошибка
            if (error as? ASAuthorizationError)?.code == .canceled { return }
            errorMessage = error.localizedDescription
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let identityToken = String(data: tokenData, encoding: .utf8)
            else {
                errorMessage = String(localized: "Apple didn’t return an identity token.")
                return
            }
            let fullName = credential.fullName.map { PersonNameComponentsFormatter().string(from: $0) }
            await complete(provider: .apple, identityToken: identityToken, fullName: fullName?.isEmpty == false ? fullName : nil, mode: mode)
        }
    }

    // MARK: - Google

    func signInWithGoogle(mode: Mode) async {
        guard Self.isGoogleConfigured else {
            errorMessage = String(localized: "Google Sign-In is not configured: set GOOGLE_CLIENT_ID in Config.xcconfig.")
            return
        }
        guard let root = Self.rootViewController else {
            errorMessage = String(localized: "No window to present Google sign-in.")
            return
        }
        do {
            let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: root)
            guard let idToken = result.user.idToken?.tokenString else {
                errorMessage = String(localized: "Google didn’t return an ID token.")
                return
            }
            await complete(provider: .google, identityToken: idToken, fullName: result.user.profile?.name, mode: mode)
        } catch let error as GIDSignInError where error.code == .canceled {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private static var rootViewController: UIViewController? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .rootViewController
    }

    // MARK: - Общее

    private func complete(provider: AuthProvider, identityToken: String, fullName: String?, mode: Mode) async {
        isBusy = true
        defer { isBusy = false }
        errorMessage = nil
        infoMessage = nil
        do {
            switch mode {
            case .signIn:
                let r = try await APIClient.anonymous().signIn(provider: provider, identityToken: identityToken, fullName: fullName)
                user = r.user
                token = r.token
                if r.autoLinked { infoMessage = String(localized: "\(provider.title) has been linked to your existing account.") }
            case .link:
                user = try await APIClient.fromSettings().link(provider: provider, identityToken: identityToken, fullName: fullName)
                infoMessage = String(localized: "\(provider.title) linked.")
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func unlink(_ provider: AuthProvider) async {
        isBusy = true
        defer { isBusy = false }
        do {
            user = try await APIClient.fromSettings().unlink(provider: provider)
            infoMessage = String(localized: "\(provider.title) unlinked.")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func signOut() async {
        if let client = try? APIClient.fromSettings() {
            try? await client.logout()
        }
        GIDSignIn.sharedInstance.signOut()
        token = nil
        user = nil
        infoMessage = nil
        errorMessage = nil
    }
}
