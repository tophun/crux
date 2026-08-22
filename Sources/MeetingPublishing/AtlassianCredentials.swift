import Foundation
import MeetingCore
import Security

/// Atlassian 인증 정보. 토큰은 로그·인자·화면에 남기지 않는다.
public struct AtlassianCredentials: Sendable {
    /// 예: `your-team.atlassian.net`
    public let site: String
    public let email: String
    /// API 토큰. `description`에 절대 포함하지 않는다.
    public let apiToken: String

    public init(site: String, email: String, apiToken: String) {
        self.site = site.replacingOccurrences(of: "https://", with: "").trimmingCharacters(in: .whitespaces)
        self.email = email.trimmingCharacters(in: .whitespaces)
        self.apiToken = apiToken.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var baseURL: URL? { URL(string: "https://\(site)") }

    /// Basic 인증 헤더 값. 이 값을 로그에 남기지 않는다.
    var authorizationHeader: String {
        let raw = "\(email):\(apiToken)"
        let encoded = Data(raw.utf8).base64EncodedString()
        return "Basic \(encoded)"
    }

    /// 토큰이 노출되지 않는 요약. 로그·UI에는 이것만 쓴다.
    public var redactedDescription: String {
        "\(email)@\(site) (토큰 \(apiToken.isEmpty ? "없음" : "저장됨"))"
    }
}

/// 인증 정보 저장소.
public protocol AtlassianCredentialStore: Sendable {
    func load() throws -> AtlassianCredentials?
    func save(_ credentials: AtlassianCredentials) throws
    func delete() throws
}

/// Keychain 저장소. 토큰은 Keychain에만 두고 파일이나 설정에 쓰지 않는다.
public struct KeychainCredentialStore: AtlassianCredentialStore {
    private let service: String

    public init(service: String = "LiveCapsule.Atlassian") {
        self.service = service
    }

    public func save(_ credentials: AtlassianCredentials) throws {
        let account = "\(credentials.site)|\(credentials.email)"
        try delete()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(credentials.apiToken.utf8)
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw CredentialError.keychain(status)
        }
    }

    public func load() throws -> AtlassianCredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let dictionary = item as? [String: Any],
              let data = dictionary[kSecValueData as String] as? Data,
              let account = dictionary[kSecAttrAccount as String] as? String
        else {
            throw CredentialError.keychain(status)
        }
        let parts = account.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { throw CredentialError.malformedAccount }
        return AtlassianCredentials(
            site: parts[0],
            email: parts[1],
            apiToken: String(decoding: data, as: UTF8.self)
        )
    }

    public func delete() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialError.keychain(status)
        }
    }

    public enum CredentialError: Error, LocalizedError {
        case keychain(OSStatus)
        case malformedAccount

        public var errorDescription: String? {
            switch self {
            case let .keychain(status): "Keychain 오류(\(status))"
            case .malformedAccount: "저장된 Atlassian 계정 형식이 올바르지 않습니다."
            }
        }
    }
}

/// 환경 변수 저장소. CI·CLI 검증용이며 토큰을 명령 인자로 받지 않는다.
public struct EnvironmentCredentialStore: AtlassianCredentialStore {
    public init() {}

    public func load() throws -> AtlassianCredentials? {
        let environment = ProcessInfo.processInfo.environment
        guard let site = environment["ATLASSIAN_SITE"],
              let email = environment["ATLASSIAN_EMAIL"],
              let token = environment["ATLASSIAN_API_TOKEN"],
              !site.isEmpty, !email.isEmpty, !token.isEmpty
        else { return nil }
        return AtlassianCredentials(site: site, email: email, apiToken: token)
    }

    public func save(_: AtlassianCredentials) throws {
        throw PublishError.missingCredentials("환경 변수 저장소는 쓰기를 지원하지 않습니다.")
    }

    public func delete() throws {}
}

/// Keychain을 먼저 보고 없으면 환경 변수를 본다.
public struct ChainedCredentialStore: AtlassianCredentialStore {
    private let stores: [any AtlassianCredentialStore]

    public init(stores: [any AtlassianCredentialStore] = [KeychainCredentialStore(), EnvironmentCredentialStore()]) {
        self.stores = stores
    }

    public func load() throws -> AtlassianCredentials? {
        for store in stores {
            if let credentials = try? store.load(), credentials != nil { return credentials }
        }
        return nil
    }

    public func save(_ credentials: AtlassianCredentials) throws {
        guard let first = stores.first else { throw PublishError.missingCredentials("저장소가 없습니다.") }
        try first.save(credentials)
    }

    public func delete() throws {
        for store in stores {
            try? store.delete()
        }
    }
}
