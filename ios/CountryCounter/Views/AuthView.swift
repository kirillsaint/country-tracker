import AuthenticationServices
import GoogleSignInSwift
import SwiftUI

struct AuthView: View {
    @Environment(AuthManager.self) private var auth
    @Environment(\.colorScheme) private var colorScheme
    #if DEBUG
    @State private var serverStatus: String?
    @State private var checking = false
    #endif

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(spacing: 12) {
                // знак приложения — штамп с глобусом, тот же язык, что у оснований въезда
                Image(systemName: "globe.europe.africa.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.tint)
                    .frame(width: 92, height: 92)
                    .overlay(Circle().strokeBorder(.tint, style: StrokeStyle(lineWidth: 2, dash: [5, 3])))
                    .rotationEffect(.degrees(-6))
                    .accessibilityHidden(true)
                Text(verbatim: "Stamps").font(.system(.largeTitle, design: .rounded, weight: .bold))
                Text("Counts which countries and cities you spend your time in.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 12) {
                SignInWithAppleButton(.signIn) { request in
                    request.requestedScopes = [.fullName, .email]
                } onCompletion: { result in
                    Task { await auth.handleApple(result, mode: .signIn) }
                }
                .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                // системная кнопка не меняет цвет при смене темы на лету — пересоздаём её
                .id(colorScheme)
                .frame(height: 50)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .disabled(auth.isBusy)

                GoogleButton { Task { await auth.signInWithGoogle(mode: .signIn) } }
                    .disabled(auth.isBusy || !AuthManager.isGoogleConfigured)
                    .opacity(AuthManager.isGoogleConfigured ? 1 : 0.5)

                if !AuthManager.isGoogleConfigured {
                    Text("Google appears once GOOGLE_CLIENT_ID is set in Config.xcconfig.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }

            if auth.isBusy { ProgressView() }
            if let error = auth.errorMessage {
                Text(error).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
            }

            Spacer()

            #if DEBUG
            // адрес сервера и проверка связи — только для отладки
            Button {
                Task { await checkServer() }
            } label: {
                HStack(spacing: 6) {
                    if checking { ProgressView().controlSize(.small) }
                    Text(serverStatus ?? String(localized: "Server: \(AppSettings.serverURL?.host() ?? "—")"))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .disabled(checking)
            #endif
        }
        .padding(24)
    }

    #if DEBUG
    private func checkServer() async {
        checking = true
        defer { checking = false }
        do {
            try await APIClient.anonymous().health()
            serverStatus = String(localized: "Server \(AppSettings.serverURL?.host() ?? "") is reachable.")
        } catch {
            serverStatus = error.localizedDescription
        }
    }
    #endif
}

/// Кнопка Google той же формы, что и «Вход с Apple»: во всю ширину, 50 pt, те же скругления и шрифт.
/// Цвета — по рекомендациям Google: светлая с тонкой рамкой днём, тёмно-серая ночью. Логотип «G» берётся
/// из бандла GoogleSignIn, чтобы не хранить свою копию.
struct GoogleButton: View {
    @Environment(\.colorScheme) private var colorScheme
    let action: () -> Void

    private static let logo: UIImage? = {
        guard let url = Bundle.main.url(forResource: "GoogleSignIn_GoogleSignIn", withExtension: "bundle"),
              let bundle = Bundle(url: url) else { return nil }
        return UIImage(named: "google", in: bundle, with: nil)
    }()

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let logo = Self.logo {
                    Image(uiImage: logo).resizable().scaledToFit().frame(width: 20, height: 20)
                }
                Text("Sign in with Google")
                    .font(.system(size: 19, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .foregroundStyle(colorScheme == .dark ? Color(white: 0.9) : Color(white: 0.12))
            .background(colorScheme == .dark ? Color(red: 0.075, green: 0.075, blue: 0.078) : .white)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(colorScheme == .dark ? Color(white: 0.45) : Color(white: 0.75), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

