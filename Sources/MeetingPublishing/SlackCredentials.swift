import Foundation
import MeetingCore
import Security

/// Slack 봇 토큰. 토큰은 로그·인자·화면에 남기지 않는다.
public struct SlackCredentials: Sendable {
    /// Bot User OAuth Token (`xoxb-…`). `description`에 절대 포함하지 않는다.
    public let botToken: String

    public init(botToken: String) {
        self.botToken = botToken.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Bearer 헤더 값. 이 값을 로그에 남기지 않는다.
    var authorizationHeader: String {
        "Bearer \(botToken)"
    }

    /// 토큰이 노출되지 않는 요약. 로그·UI에는 이것만 쓴다.
    public var redactedDescription: String {
        "Slack (토큰 \(botToken.isEmpty ? "없음" : "저장됨"))"
    }
}

/// Slack 인증 정보 저장소.
public protocol SlackCredentialStore: Sendable {
    func load() throws -> SlackCredentials?
    func save(_ credentials: SlackCredentials) throws
    func delete() throws
}

/// Keychain 저장소. 토큰은 Keychain에만 두고 파일이나 설정에 쓰지 않는다.
public struct SlackKeychainCredentialStore: SlackCredentialStore {
    private let service: String
    private let account: String

    public init(service: String = "Crux.Slack", account: String = "bot") {
        self.service = service
        self.account = account
    }

    public func save(_ credentials: SlackCredentials) throws {
        try delete()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(credentials.botToken.utf8)
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw SlackCredentialError.keychain(status)
        }
    }

    public func load() throws -> SlackCredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = item as? Data else {
            throw SlackCredentialError.keychain(status)
        }
        let token = String(decoding: data, as: UTF8.self)
        guard !token.isEmpty else { return nil }
        return SlackCredentials(botToken: token)
    }

    public func delete() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SlackCredentialError.keychain(status)
        }
    }
}

public enum SlackCredentialError: Error, LocalizedError {
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case let .keychain(status): "Keychain 오류(\(status))"
        }
    }
}

/// 환경 변수 저장소. CI·CLI 검증용이며 토큰을 명령 인자로 받지 않는다.
public struct SlackEnvironmentCredentialStore: SlackCredentialStore {
    public init() {}

    public func load() throws -> SlackCredentials? {
        let token = ProcessInfo.processInfo.environment["SLACK_BOT_TOKEN"] ?? ""
        guard !token.isEmpty else { return nil }
        return SlackCredentials(botToken: token)
    }

    public func save(_: SlackCredentials) throws {
        throw PublishError.missingSlackCredentials("환경 변수 저장소는 쓰기를 지원하지 않습니다.")
    }

    public func delete() throws {}
}

/// Keychain을 먼저 보고 없으면 환경 변수를 본다.
public struct SlackChainedCredentialStore: SlackCredentialStore {
    private let stores: [any SlackCredentialStore]

    public init(
        stores: [any SlackCredentialStore] = [SlackKeychainCredentialStore(), SlackEnvironmentCredentialStore()]
    ) {
        self.stores = stores
    }

    public func load() throws -> SlackCredentials? {
        for store in stores {
            if let credentials = try? store.load(), credentials != nil {
                return credentials
            }
        }
        return nil
    }

    public func save(_ credentials: SlackCredentials) throws {
        guard let first = stores.first else {
            throw PublishError.missingSlackCredentials("저장소가 없습니다.")
        }
        try first.save(credentials)
    }

    public func delete() throws {
        for store in stores {
            try? store.delete()
        }
    }
}
