import AppKit
import CryptoKit
import Foundation
import MeetingCore
import Network
import Security

/// Google Calendar OAuth access/refresh token 쌍.
public struct GoogleOAuthTokens: Codable, Hashable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var expirationDate: Date
    public var grantedScopes: [String]

    public init(
        accessToken: String,
        refreshToken: String? = nil,
        expirationDate: Date,
        grantedScopes: [String] = []
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expirationDate = expirationDate
        self.grantedScopes = grantedScopes
    }
}

/// Google Desktop OAuth 클라이언트 설정.
public struct GoogleCalendarOAuthConfiguration: Sendable {
    public static let calendarEventsScope = "https://www.googleapis.com/auth/calendar.events"

    public var clientID: String
    /// Desktop client의 secret은 public client에서 필수가 아니므로 기본값은 nil이다.
    public var clientSecret: String?
    public var authorizationEndpoint: URL
    public var tokenEndpoint: URL
    public var revokeEndpoint: URL

    public init(
        clientID: String,
        clientSecret: String? = nil,
        authorizationEndpoint: URL = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
        tokenEndpoint: URL = URL(string: "https://oauth2.googleapis.com/token")!,
        revokeEndpoint: URL = URL(string: "https://oauth2.googleapis.com/revoke")!
    ) {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.revokeEndpoint = revokeEndpoint
    }

    /// 앱 번들 Info.plist의 `GoogleCalendarClientID`에서 설정을 읽는다.
    public static func fromBundle(_ bundle: Bundle = .main) -> GoogleCalendarOAuthConfiguration? {
        GoogleCalendarOAuthConfiguration(
            rawClientID: bundle.object(forInfoDictionaryKey: "GoogleCalendarClientID") as? String,
            rawClientSecret: bundle.object(forInfoDictionaryKey: "GoogleCalendarClientSecret") as? String
        )
    }

    public static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> GoogleCalendarOAuthConfiguration? {
        GoogleCalendarOAuthConfiguration(
            rawClientID: environment["GOOGLE_CALENDAR_CLIENT_ID"],
            rawClientSecret: environment["GOOGLE_CALENDAR_CLIENT_SECRET"]
        )
    }

    /// 공백을 정리하고, Client ID가 비어 있으면 설정 없음(nil)으로 본다. 빈 Secret은 nil로 정규화한다.
    private init?(rawClientID: String?, rawClientSecret: String?) {
        let clientID = rawClientID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !clientID.isEmpty else { return nil }
        let clientSecret = rawClientSecret?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(clientID: clientID, clientSecret: clientSecret.flatMap { $0.isEmpty ? nil : $0 })
    }
}

/// Google OAuth 토큰 저장소.
public protocol GoogleCalendarTokenStore: Sendable {
    func load() throws -> GoogleOAuthTokens?
    func save(_ tokens: GoogleOAuthTokens) throws
    func delete() throws
}

/// Google OAuth 토큰을 macOS Keychain에 저장한다.
public struct GoogleCalendarKeychainTokenStore: GoogleCalendarTokenStore {
    private let service: String
    private let account: String

    public init(service: String = "Crux.GoogleCalendar", account: String = "primary") {
        self.service = service
        self.account = account
    }

    public func load() throws -> GoogleOAuthTokens? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw GoogleCalendarError.keychain(status)
        }
        do {
            return try JSONDecoder().decode(GoogleOAuthTokens.self, from: data)
        } catch {
            throw GoogleCalendarError.invalidStoredTokens
        }
    }

    public func save(_ tokens: GoogleOAuthTokens) throws {
        let data = try JSONEncoder().encode(tokens)
        try delete()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw GoogleCalendarError.keychain(status)
        }
    }

    public func delete() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw GoogleCalendarError.keychain(status)
        }
    }
}

public enum GoogleCalendarError: Error, LocalizedError, Sendable, Equatable {
    case missingClientID
    case notAuthorized
    case oauthCancelled
    case callbackStateMismatch
    case oauthDenied(String)
    case tokenExchange(String)
    case api(status: Int, message: String)
    case invalidResponse(String)
    case invalidStoredTokens
    case keychain(OSStatus)
    case conflict

    public var errorDescription: String? {
        switch self {
        case .missingClientID:
            "Google Calendar Client ID가 설정되지 않았습니다."
        case .notAuthorized:
            "Google Calendar 연결이 필요합니다."
        case .oauthCancelled:
            "Google Calendar 연결을 취소했습니다."
        case .callbackStateMismatch:
            "Google OAuth 응답을 확인하지 못했습니다. 다시 연결해 주세요."
        case let .oauthDenied(message):
            "Google OAuth 권한 승인이 거부되었습니다: " + message
        case let .tokenExchange(message):
            "Google OAuth 토큰을 교환하지 못했습니다: " + message
        case let .api(status, message):
            "Google Calendar API 오류(" + String(status) + "): " + message
        case let .invalidResponse(message):
            "Google Calendar 응답 형식이 올바르지 않습니다: " + message
        case .invalidStoredTokens:
            "저장된 Google Calendar 인증 정보가 손상되었습니다. 다시 연결해 주세요."
        case let .keychain(status):
            "Google Calendar Keychain 오류(" + String(status) + ")"
        case .conflict:
            "다른 곳에서 일정이 변경되었습니다. 최신 일정을 확인한 뒤 다시 시도해 주세요."
        }
    }
}

/// Google OAuth authorization callback.
struct GoogleOAuthCallback: Sendable {
    var code: String?
    var state: String?
    var error: String?
}

/// Google OAuth Desktop 앱 인증과 token refresh를 담당한다.
public actor GoogleCalendarOAuthClient {
    private let configuration: GoogleCalendarOAuthConfiguration
    private let tokenStore: any GoogleCalendarTokenStore
    private let session: URLSession
    private let openURL: @Sendable (URL) async -> Bool

    public init(
        configuration: GoogleCalendarOAuthConfiguration,
        tokenStore: any GoogleCalendarTokenStore = GoogleCalendarKeychainTokenStore(),
        session: URLSession = .shared,
        openURL: @escaping @Sendable (URL) async -> Bool = { url in
            await MainActor.run { NSWorkspace.shared.open(url) }
        }
    ) {
        self.configuration = configuration
        self.tokenStore = tokenStore
        self.session = session
        self.openURL = openURL
    }

    /// 토큰이 있으면 연결됨으로 간주한다. 만료된 access token도 refresh token으로 복구할 수 있다.
    public nonisolated var authorizationStatus: CalendarAuthorizationStatus {
        guard let tokens = try? tokenStore.load(), tokens.refreshToken != nil else {
            return .notDetermined
        }
        return .authorized
    }

    /// OAuth callback을 기다리는 최대 시간(초).
    static let callbackTimeout: TimeInterval = 300

    public func requestAccess() async throws -> Bool {
        if authorizationStatus == .authorized { return true }
        guard !configuration.clientID.isEmpty else { throw GoogleCalendarError.missingClientID }

        let server = LoopbackOAuthCallbackServer()
        let redirectURI = try await server.start()
        defer { Task { await server.stop() } }

        let verifier = Self.randomVerifier()
        let state = Self.randomVerifier()
        let authorizationURL = try Self.authorizationURL(
            configuration: configuration,
            redirectURI: redirectURI,
            verifier: verifier,
            state: state
        )
        guard await openURL(authorizationURL) else {
            throw GoogleCalendarError.oauthCancelled
        }

        // 브라우저를 닫거나 무시하면 callback이 오지 않는다. 일정 시간 뒤 대기를 끊어
        // 연결 진행 상태가 앱 재시작까지 남지 않게 한다.
        let timeoutTask = Task {
            try await Task.sleep(for: .seconds(Self.callbackTimeout))
            await server.stop()
        }
        defer { timeoutTask.cancel() }
        let callback = try await server.waitForCallback()
        guard callback.state == state else {
            throw GoogleCalendarError.callbackStateMismatch
        }
        if let error = callback.error {
            throw GoogleCalendarError.oauthDenied(error)
        }
        guard let code = callback.code else {
            throw GoogleCalendarError.tokenExchange("authorization code가 없습니다.")
        }
        let tokens = try await exchange(code: code, verifier: verifier, redirectURI: redirectURI)
        try tokenStore.save(tokens)
        return true
    }

    public func accessToken(forceRefresh: Bool = false) async throws -> String {
        guard let tokens = try tokenStore.load() else {
            throw GoogleCalendarError.notAuthorized
        }
        if !forceRefresh, tokens.expirationDate.timeIntervalSinceNow > 60 {
            return tokens.accessToken
        }
        guard let refreshToken = tokens.refreshToken else {
            throw GoogleCalendarError.notAuthorized
        }
        let refreshed = try await refresh(
            refreshToken: refreshToken,
            existingScopes: tokens.grantedScopes
        )
        try tokenStore.save(refreshed)
        return refreshed.accessToken
    }

    public func disconnect() async throws {
        defer { try? tokenStore.delete() }
        guard let tokens = try tokenStore.load() else { return }
        let token = tokens.refreshToken ?? tokens.accessToken
        var components = URLComponents(url: configuration.revokeEndpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "token", value: token)]
        guard let url = components?.url else { throw GoogleCalendarError.invalidResponse("revoke URL") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            throw GoogleCalendarError.invalidResponse("revoke 응답")
        }
    }

    static func authorizationURL(
        configuration: GoogleCalendarOAuthConfiguration,
        redirectURI: String,
        verifier: String,
        state: String
    ) throws -> URL {
        var components = URLComponents(
            url: configuration.authorizationEndpoint,
            resolvingAgainstBaseURL: false
        )
        let challenge = Self.codeChallenge(for: verifier)
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: GoogleCalendarOAuthConfiguration.calendarEventsScope),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state)
        ]
        guard let url = components?.url else {
            throw GoogleCalendarError.invalidResponse("authorization URL")
        }
        return url
    }

    private func exchange(code: String, verifier: String, redirectURI: String) async throws -> GoogleOAuthTokens {
        var fields = [
            "client_id": configuration.clientID,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirectURI
        ]
        if let clientSecret = configuration.clientSecret {
            fields["client_secret"] = clientSecret
        }
        return try await tokenRequest(fields: fields)
    }

    private func refresh(refreshToken: String, existingScopes: [String]) async throws -> GoogleOAuthTokens {
        var fields = [
            "client_id": configuration.clientID,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token"
        ]
        if let clientSecret = configuration.clientSecret {
            fields["client_secret"] = clientSecret
        }
        var refreshed = try await tokenRequest(fields: fields)
        refreshed.refreshToken = refreshToken
        refreshed.grantedScopes = existingScopes
        return refreshed
    }

    private func tokenRequest(fields: [String: String]) async throws -> GoogleOAuthTokens {
        var request = URLRequest(url: configuration.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formData(fields)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GoogleCalendarError.tokenExchange("HTTP 응답이 아닙니다.")
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            let message = String(decoding: data.prefix(500), as: UTF8.self)
            throw GoogleCalendarError.tokenExchange(message)
        }
        struct Response: Decodable {
            let access_token: String
            let refresh_token: String?
            let expires_in: Double?
            let scope: String?
        }
        do {
            let result = try JSONDecoder().decode(Response.self, from: data)
            return GoogleOAuthTokens(
                accessToken: result.access_token,
                refreshToken: result.refresh_token,
                expirationDate: Date().addingTimeInterval(result.expires_in ?? 3600),
                grantedScopes: result.scope?.split(separator: " ").map(String.init) ?? []
            )
        } catch {
            throw GoogleCalendarError.tokenExchange("토큰 응답 JSON을 해석하지 못했습니다.")
        }
    }

    private static func formData(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let body = fields
            .sorted { $0.key < $1.key }
            .map { key, value in
                let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return encodedKey + "=" + encodedValue
            }
            .joined(separator: "&")
        return Data(body.utf8)
    }

    private static func randomVerifier() -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        var generator = SystemRandomNumberGenerator()
        return String((0 ..< 64).map { _ in alphabet[Int.random(in: 0 ..< alphabet.count, using: &generator)] })
    }

    private static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }
}

/// 로컬 loopback HTTP listener로 OAuth callback을 받는다.
private actor LoopbackOAuthCallbackServer {
    private var listener: NWListener?
    private var startContinuation: CheckedContinuation<String, Error>?
    private var callbackContinuation: CheckedContinuation<GoogleOAuthCallback, Error>?

    func start() async throws -> String {
        // redirect URI가 127.0.0.1이므로 loopback에만 바인딩한다.
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        return try await withCheckedThrowingContinuation { continuation in
            startContinuation = continuation
            let server = self
            listener.stateUpdateHandler = { [weak server] state in
                Task { await server?.handle(state) }
            }
            listener.newConnectionHandler = { [weak server] connection in
                connection.start(queue: .global(qos: .userInitiated))
                connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak server] data, _, _, _ in
                    let callback = data.flatMap(Self.parseCallback)
                    // 이 응답은 OAuth callback을 받은 시점에 전송된다. 아직 token endpoint
                    // 교환과 Keychain 저장이 끝나지 않았으므로 여기서 연결 완료라고 단정하지 않는다.
                    let body = "<html><body>Crux가 Google 인증 응답을 받았습니다. "
                        + "앱으로 돌아가 처리 결과를 확인하세요.</body></html>"
                    let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n"
                        + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                    connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                        connection.cancel()
                    })
                    Task { await server?.finish(callback) }
                }
            }
            listener.start(queue: .global(qos: .userInitiated))
        }
    }

    func waitForCallback() async throws -> GoogleOAuthCallback {
        try await withCheckedThrowingContinuation { continuation in
            callbackContinuation = continuation
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        startContinuation?.resume(throwing: GoogleCalendarError.oauthCancelled)
        startContinuation = nil
        callbackContinuation?.resume(throwing: GoogleCalendarError.oauthCancelled)
        callbackContinuation = nil
    }

    private func handle(_ state: NWListener.State) {
        switch state {
        case .ready:
            guard let port = listener?.port else {
                startContinuation?.resume(throwing: GoogleCalendarError.invalidResponse("loopback port"))
                startContinuation = nil
                return
            }
            startContinuation?.resume(returning: "http://127.0.0.1:\(port.rawValue)/oauth2callback")
            startContinuation = nil
        case let .failed(error):
            startContinuation?.resume(throwing: error)
            startContinuation = nil
        default:
            break
        }
    }

    private func finish(_ callback: GoogleOAuthCallback?) {
        guard let callback else {
            callbackContinuation?.resume(throwing: GoogleCalendarError.invalidResponse("OAuth callback"))
            callbackContinuation = nil
            return
        }
        callbackContinuation?.resume(returning: callback)
        callbackContinuation = nil
    }

    private static func parseCallback(data: Data) -> GoogleOAuthCallback? {
        guard let text = String(data: data, encoding: .utf8),
              let requestLine = text.components(separatedBy: "\r\n").first
        else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let target = String(parts[1])
        guard let components = URLComponents(string: "http://127.0.0.1\(target)") else { return nil }
        let items = components.queryItems ?? []
        return GoogleOAuthCallback(
            code: items.first(where: { $0.name == "code" })?.value,
            state: items.first(where: { $0.name == "state" })?.value,
            error: items.first(where: { $0.name == "error" })?.value
        )
    }
}
