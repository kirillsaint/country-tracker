import Foundation

enum APIError: LocalizedError {
    case noServer
    case notSignedIn
    case unauthorized
    case http(Int, String)
    case transport(Error)

    var errorDescription: String? {
        switch self {
        case .noServer: return "Не задан адрес сервера."
        case .notSignedIn: return "Нужно войти в аккаунт."
        case .unauthorized: return "Сессия недействительна, войдите заново."
        case .http(let code, let body): return "Сервер ответил \(code): \(Self.message(from: body))"
        case .transport(let e): return e.localizedDescription
        }
    }

    // Бэкенд отвечает {"error": "..."} — показываем текст, а не сырой JSON
    private static func message(from body: String) -> String {
        if let data = body.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let msg = obj["error"] as? String {
            return msg
        }
        return String(body.prefix(200))
    }
}

extension Notification.Name {
    // Сервер ответил 401 на запрос с токеном сессии — токен отозван или сервер переустановлен
    static let sessionInvalid = Notification.Name("sessionInvalid")
}

struct APIClient {
    let baseURL: URL
    let token: String?

    /// Клиент с сессией — для всего, что под /api и /auth/me, /auth/link...
    static func fromSettings() throws -> APIClient {
        guard let url = AppSettings.serverURL else { throw APIError.noServer }
        guard let token = AppSettings.sessionToken else { throw APIError.notSignedIn }
        return APIClient(baseURL: url, token: token)
    }

    /// Клиент без сессии — для входа
    static func anonymous() throws -> APIClient {
        guard let url = AppSettings.serverURL else { throw APIError.noServer }
        return APIClient(baseURL: url, token: nil)
    }

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg)
    }()

    // MARK: - Аккаунт

    func signIn(provider: AuthProvider, identityToken: String, fullName: String?) async throws -> SignInResponse {
        struct Body: Encodable { let identityToken: String; let fullName: String?; let device: String? }
        return try await send("POST", "/auth/signin/\(provider.rawValue)", body: Body(identityToken: identityToken, fullName: fullName, device: Self.deviceName))
    }

    func link(provider: AuthProvider, identityToken: String, fullName: String?) async throws -> User {
        struct Body: Encodable { let identityToken: String; let fullName: String? }
        struct R: Decodable { let user: User }
        let r: R = try await send("POST", "/auth/link/\(provider.rawValue)", body: Body(identityToken: identityToken, fullName: fullName))
        return r.user
    }

    func unlink(provider: AuthProvider) async throws -> User {
        struct R: Decodable { let user: User }
        let r: R = try await send("POST", "/auth/unlink/\(provider.rawValue)", body: Optional<Empty>.none)
        return r.user
    }

    func me() async throws -> User {
        struct R: Decodable { let user: User }
        let r: R = try await send("GET", "/auth/me")
        return r.user
    }

    func logout() async throws {
        struct R: Decodable { let ok: Bool }
        let _: R = try await send("POST", "/auth/logout", body: Optional<Empty>.none)
    }

    func health() async throws {
        var req = URLRequest(url: baseURL.appendingPathComponent("health"))
        req.httpMethod = "GET"
        let (_, resp) = try await Self.session.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw APIError.http((resp as? HTTPURLResponse)?.statusCode ?? 0, "")
        }
    }

    // MARK: - Данные

    func upload(_ points: [PendingPoint]) async throws -> UploadResult {
        struct Body: Encodable { let points: [PendingPoint] }
        return try await send("POST", "/api/points", body: Body(points: points))
    }

    // Сервер считает "сегодня" по часам пользователя, поэтому шлём свой сдвиг таймзоны
    private static var tz: String { String(TimeZone.current.secondsFromGMT() / 60) }

    func countries(from: String? = nil, to: String? = nil) async throws -> [CountryStat] {
        struct R: Decodable { let countries: [CountryStat] }
        let r: R = try await send("GET", "/api/stats/countries", query: ["from": from, "to": to, "tz": Self.tz])
        return r.countries
    }

    func current() async throws -> CurrentStatus? {
        struct R: Decodable { let current: CurrentStatus? }
        let r: R = try await send("GET", "/api/stats/current", query: ["tz": Self.tz])
        return r.current
    }

    func timeline(from: String? = nil, to: String? = nil) async throws -> [Segment] {
        struct R: Decodable { let segments: [Segment] }
        let r: R = try await send("GET", "/api/timeline", query: ["from": from, "to": to, "tz": Self.tz])
        return r.segments
    }

    func cities(from: String? = nil, to: String? = nil) async throws -> [CityStat] {
        struct R: Decodable { let cities: [CityStat] }
        let r: R = try await send("GET", "/api/stats/cities", query: ["from": from, "to": to, "tz": Self.tz])
        return r.cities
    }

    // MARK: - Ручные записи

    func overrides() async throws -> [DayOverride] {
        struct R: Decodable { let overrides: [DayOverride] }
        let r: R = try await send("GET", "/api/overrides")
        return r.overrides
    }

    func setRange(from: String, to: String, countryCode: String, city: String?, note: String?) async throws {
        struct Body: Encodable { let from: String; let to: String; let countryCode: String; let city: String?; let note: String? }
        struct R: Decodable { let days: Int }
        let _: R = try await send("PUT", "/api/overrides/range", body: Body(from: from, to: to, countryCode: countryCode, city: city, note: note))
    }

    func deleteRange(from: String, to: String) async throws {
        struct R: Decodable { let deleted: Int }
        let _: R = try await send("DELETE", "/api/overrides/range", query: ["from": from, "to": to])
    }

    // MARK: - Правила

    func rules() async throws -> [Rule] {
        struct R: Decodable { let rules: [Rule] }
        let r: R = try await send("GET", "/api/rules")
        return r.rules
    }

    func createRule(_ input: RuleInput) async throws -> Rule {
        struct R: Decodable { let rule: Rule }
        let r: R = try await send("POST", "/api/rules", body: input)
        return r.rule
    }

    func updateRule(id: String, _ input: RuleInput) async throws -> Rule {
        struct R: Decodable { let rule: Rule }
        let r: R = try await send("PUT", "/api/rules/\(id)", body: input)
        return r.rule
    }

    func deleteRule(id: String) async throws {
        struct R: Decodable { let deleted: Bool }
        let _: R = try await send("DELETE", "/api/rules/\(id)")
    }

    func ruleResults() async throws -> [RuleResult] {
        struct R: Decodable { let results: [RuleResult] }
        let r: R = try await send("GET", "/api/stats/rules", query: ["tz": Self.tz])
        return r.results
    }

    // MARK: - Общее

    private struct Empty: Encodable {}

    private static var deviceName: String {
        #if targetEnvironment(simulator)
        return "Simulator"
        #else
        return ProcessInfo.processInfo.hostName
        #endif
    }

    private func send<T: Decodable>(_ method: String, _ path: String, query: [String: String?] = [:]) async throws -> T {
        try await send(method, path, query: query, body: Optional<Empty>.none)
    }

    private func send<T: Decodable, B: Encodable>(_ method: String, _ path: String, query: [String: String?] = [:], body: B?) async throws -> T {
        var comps = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        let items = query.compactMap { k, v in v.map { URLQueryItem(name: k, value: $0) } }
        if !items.isEmpty { comps.queryItems = items }

        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try PendingQueue.encoder.encode(body)
        }

        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await Self.session.data(for: req)
        } catch {
            throw APIError.transport(error)
        }
        guard let http = resp as? HTTPURLResponse else { throw APIError.http(0, "") }
        if http.statusCode == 401, token != nil {
            NotificationCenter.default.post(name: .sessionInvalid, object: nil)
            throw APIError.unauthorized
        }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return try PendingQueue.decoder.decode(T.self, from: data)
    }
}
