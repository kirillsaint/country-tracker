import AuthenticationServices
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(AuthManager.self) private var auth
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var tracker = LocationTracker.shared

    @AppStorage(AppSettings.serverOverrideKey) private var serverOverride = ""
    @AppStorage(AppSettings.hourlyEnabledKey) private var hourlyEnabled = true
    @AppStorage(AppSettings.notificationsEnabledKey) private var notificationsEnabled = false
    @AppStorage(AppSettings.showCountriesSectionKey) private var showCountries = true

    @State private var actionResult: String?
    @State private var busy = false
    @State private var confirmSignOut = false
    @State private var notificationsDenied = false

    var body: some View {
        Form {
            accountSection

            Section {
                NavigationLink {
                    RulesView()
                } label: {
                    LabeledContent("Counting rules", value: String(localized: "\(model.rules.filter(\.enabled).count) of \(model.rules.count)"))
                }
                NavigationLink {
                    ManualEntriesView()
                } label: {
                    LabeledContent("Manual entries", value: "\(model.manualRanges.count)")
                }
                Toggle("Rule notifications", isOn: $notificationsEnabled)
                    .onChange(of: notificationsEnabled) { _, on in
                        guard on else { return }
                        Task {
                            let granted = await RuleNotifier.requestPermission()
                            notificationsDenied = !granted
                            if !granted { notificationsEnabled = false }
                            await RuleNotifier.evaluate(model.ruleResults)
                        }
                    }
                if notificationsDenied {
                    Button("Notifications are blocked — open iOS Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                    .font(.footnote)
                }
                Toggle("Countries this year on the main screen", isOn: $showCountries)
            } header: {
                Text("Counting")
            } footer: {
                Text("You get a notification when a rule has few days left (the threshold is set in the rule), the limit is used up, or the goal is reached.")
            }

            Section {
                Toggle("Hourly background point", isOn: $hourlyEnabled)
            } header: {
                Text("Tracking")
            } footer: {
                Text("A safety net in case iOS doesn’t report movement for a long time. The interval is not guaranteed.")
            }

            Section("Location") {
                LabeledContent("Permission", value: tracker.authorization.label)
                if !tracker.hasAlwaysPermission {
                    Button(tracker.authorization == .notDetermined ? "Request permission" : "Open iOS Settings") {
                        if tracker.authorization == .notDetermined {
                            tracker.requestPermission()
                        } else if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                }
                Button("Record a point now") {
                    Task {
                        busy = true
                        let ok = await tracker.requestOneShot(source: .manual)
                        actionResult = ok ? String(localized: "Point recorded and uploaded.") : String(localized: "Couldn’t get a location.")
                        await model.refresh()
                        busy = false
                    }
                }
                .disabled(busy || !tracker.hasAnyPermission)
                Button("Upload queue (\(model.pendingCount))") {
                    Task {
                        busy = true
                        let sent = await Uploader.flush()
                        actionResult = String(localized: "Uploaded: \(sent)")
                        await model.refresh()
                        busy = false
                    }
                }
                .disabled(busy || model.pendingCount == 0)
                if let actionResult {
                    Text(actionResult).font(.footnote).foregroundStyle(.secondary)
                }
            }

            Section {
                Button("App language") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            } footer: {
                Text("The app follows the iPhone language (English or Russian). You can pick a different one for this app in iOS Settings → Country Counter → Language.")
            }

            Section {
                LabeledContent("Server", value: AppSettings.serverURL?.absoluteString ?? "—")
                    .lineLimit(1)
                    .truncationMode(.middle)
                #if DEBUG
                TextField("Override address (debug)", text: $serverOverride)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                #endif
            } footer: {
                #if DEBUG
                Text("The simulator talks to localhost:3000, a real phone — to production. The field above overrides the address in Debug builds only; sign out and back in after changing it.")
                #else
                Text("The server address is set in the build.")
                #endif
            }

            Section("Recent events") {
                if let p = tracker.lastPoint {
                    VStack(alignment: .leading) {
                        Text("Last point: \(p.city ?? "—") · \(p.source.rawValue)")
                        Text(verbatim: String(format: "%.4f, %.4f · %@", p.lat, p.lon, p.recordedAt.formatted(date: .abbreviated, time: .shortened)))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                ForEach(tracker.recentEvents.prefix(15)) { e in
                    HStack {
                        Text(e.text)
                        Spacer()
                        Text(e.date.formatted(date: .omitted, time: .standard))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .font(.footnote)
                }
            }
        }
        .navigationTitle("Settings")
        .confirmationDialog("Sign out?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) { Task { await auth.signOut() } }
        } message: {
            Text("Your data stays on the server. Points recorded before the next sign-in are kept locally.")
        }
    }

    // MARK: - Аккаунт

    @ViewBuilder
    private var accountSection: some View {
        Section {
            if let user = auth.user {
                VStack(alignment: .leading, spacing: 2) {
                    Text(user.name ?? user.email ?? String(localized: "Account")).font(.headline)
                    if let email = user.email, user.name != nil {
                        Text(email).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                ForEach(AuthProvider.allCases, id: \.self) { provider in
                    providerRow(provider, linked: user.providers.has(provider), canUnlink: user.providers.apple && user.providers.google)
                }
            } else {
                HStack {
                    Text("Loading profile…").foregroundStyle(.secondary)
                    Spacer()
                    ProgressView()
                }
            }
            if let info = auth.infoMessage {
                Text(info).font(.footnote).foregroundStyle(.secondary)
            }
            if let error = auth.errorMessage {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
            Button("Sign out", role: .destructive) { confirmSignOut = true }
        } header: {
            Text("Account")
        } footer: {
            Text("You can link both sign-in methods to land in the same account.")
        }
    }

    @ViewBuilder
    private func providerRow(_ provider: AuthProvider, linked: Bool, canUnlink: Bool) -> some View {
        HStack {
            Label(provider.title, systemImage: provider == .apple ? "apple.logo" : "g.circle")
            Spacer()
            if linked {
                if canUnlink {
                    Button("Unlink") { Task { await auth.unlink(provider) } }
                        .buttonStyle(.borderless)
                        .disabled(auth.isBusy)
                } else {
                    Text("Linked").foregroundStyle(.secondary)
                }
            } else if provider == .apple {
                SignInWithAppleButton(.continue) { request in
                    request.requestedScopes = [.email]
                } onCompletion: { result in
                    Task { await auth.handleApple(result, mode: .link) }
                }
                .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                .frame(width: 130, height: 32)
                .disabled(auth.isBusy)
            } else {
                Button("Link") { Task { await auth.signInWithGoogle(mode: .link) } }
                    .buttonStyle(.borderless)
                    .disabled(auth.isBusy || !AuthManager.isGoogleConfigured)
            }
        }
    }
}
