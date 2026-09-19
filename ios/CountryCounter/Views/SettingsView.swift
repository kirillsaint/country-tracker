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
                    LabeledContent("Правила подсчёта", value: "\(model.rules.filter(\.enabled).count) из \(model.rules.count)")
                }
                NavigationLink {
                    ManualEntriesView()
                } label: {
                    LabeledContent("Ручные записи", value: "\(model.manualRanges.count)")
                }
                Toggle("Уведомления по правилам", isOn: $notificationsEnabled)
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
                    Button("Уведомления запрещены — открыть настройки iOS") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                    .font(.footnote)
                }
                Toggle("Список стран за год на главном", isOn: $showCountries)
            } header: {
                Text("Подсчёт")
            } footer: {
                Text("Уведомление приходит, когда по правилу остаётся мало дней (порог задаётся в правиле), лимит исчерпан или цель достигнута.")
            }

            Section {
                Toggle("Ежечасная точка в фоне", isOn: $hourlyEnabled)
            } header: {
                Text("Трекинг")
            } footer: {
                Text("Страховка на случай, если iOS долго не присылает события перемещения. Интервал не гарантирован.")
            }

            Section("Геолокация") {
                LabeledContent("Разрешение", value: tracker.authorization.label)
                if !tracker.hasAlwaysPermission {
                    Button(tracker.authorization == .notDetermined ? "Запросить разрешение" : "Открыть настройки iOS") {
                        if tracker.authorization == .notDetermined {
                            tracker.requestPermission()
                        } else if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                }
                Button("Записать точку сейчас") {
                    Task {
                        busy = true
                        let ok = await tracker.requestOneShot(source: .manual)
                        actionResult = ok ? "Точка записана и отправлена." : "Не удалось получить локацию."
                        await model.refresh()
                        busy = false
                    }
                }
                .disabled(busy || !tracker.hasAnyPermission)
                Button("Отправить очередь (\(model.pendingCount))") {
                    Task {
                        busy = true
                        let sent = await Uploader.flush()
                        actionResult = "Отправлено: \(sent)"
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
                LabeledContent("Сервер", value: AppSettings.serverURL?.absoluteString ?? "—")
                    .lineLimit(1)
                    .truncationMode(.middle)
                #if DEBUG
                TextField("Переопределить адрес (debug)", text: $serverOverride)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                #endif
            } footer: {
                #if DEBUG
                Text("Симулятор ходит в localhost:3000, телефон — в прод. Поле выше переопределяет адрес только в Debug-сборке; после смены выйдите и войдите заново.")
                #else
                Text("Адрес сервера задан в сборке.")
                #endif
            }

            Section("Последние события") {
                if let p = tracker.lastPoint {
                    VStack(alignment: .leading) {
                        Text("Последняя точка: \(p.city ?? "—") · \(p.source.rawValue)")
                        Text(String(format: "%.4f, %.4f · %@", p.lat, p.lon, p.recordedAt.formatted(date: .abbreviated, time: .shortened)))
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
        .navigationTitle("Настройки")
        .confirmationDialog("Выйти из аккаунта?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Выйти", role: .destructive) { Task { await auth.signOut() } }
        } message: {
            Text("Данные останутся на сервере. Точки, записанные до следующего входа, накопятся локально.")
        }
    }

    // MARK: - Аккаунт

    @ViewBuilder
    private var accountSection: some View {
        Section {
            if let user = auth.user {
                VStack(alignment: .leading, spacing: 2) {
                    Text(user.name ?? user.email ?? "Аккаунт").font(.headline)
                    if let email = user.email, user.name != nil {
                        Text(email).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                ForEach(AuthProvider.allCases, id: \.self) { provider in
                    providerRow(provider, linked: user.providers.has(provider), canUnlink: user.providers.apple && user.providers.google)
                }
            } else {
                HStack {
                    Text("Загрузка профиля…").foregroundStyle(.secondary)
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
            Button("Выйти", role: .destructive) { confirmSignOut = true }
        } header: {
            Text("Аккаунт")
        } footer: {
            Text("Можно привязать оба способа входа, чтобы попадать в один и тот же аккаунт.")
        }
    }

    @ViewBuilder
    private func providerRow(_ provider: AuthProvider, linked: Bool, canUnlink: Bool) -> some View {
        HStack {
            Label(provider.title, systemImage: provider == .apple ? "apple.logo" : "g.circle")
            Spacer()
            if linked {
                if canUnlink {
                    Button("Отвязать") { Task { await auth.unlink(provider) } }
                        .buttonStyle(.borderless)
                        .disabled(auth.isBusy)
                } else {
                    Text("Привязан").foregroundStyle(.secondary)
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
                Button("Привязать") { Task { await auth.signInWithGoogle(mode: .link) } }
                    .buttonStyle(.borderless)
                    .disabled(auth.isBusy || !AuthManager.isGoogleConfigured)
            }
        }
    }
}
