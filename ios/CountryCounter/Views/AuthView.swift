import AuthenticationServices
import GoogleSignInSwift
import SwiftUI

struct AuthView: View {
    @Environment(AuthManager.self) private var auth
    @Environment(\.colorScheme) private var colorScheme
    @State private var serverStatus: String?
    @State private var checking = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(spacing: 8) {
                Text(verbatim: "🌍").font(.system(size: 72))
                Text(verbatim: "Stamps").font(.largeTitle.bold())
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
                .frame(height: 50)
                .disabled(auth.isBusy)

                GoogleSignInButton(scheme: colorScheme == .dark ? .dark : .light, style: .wide) {
                    Task { await auth.signInWithGoogle(mode: .signIn) }
                }
                .frame(height: 50)
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
        }
        .padding(24)
    }

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
}
