import MeetingPublishing
import Observation

/// 설정 화면의 Atlassian 연결 상태를 움직인다.
///
/// 토큰은 Keychain 경로(`ChainedCredentialStore` → `KeychainCredentialStore`)에만 저장하고,
/// 상태 문구에는 `redactedDescription`만 쓴다.
@MainActor
@Observable
public final class AtlassianSettingsModel {
    public var site: String
    public var email: String
    /// 입력 중인 토큰. 저장 후 비우고, 로그·상태 문구에 넣지 않는다.
    public var apiToken: String
    public private(set) var connectedSummary: String?
    public private(set) var statusMessage: String?
    public private(set) var errorMessage: String?
    public private(set) var isVerifying = false

    private let service: AtlassianAccountService

    public init(store: any AtlassianCredentialStore = ChainedCredentialStore()) {
        service = AtlassianAccountService(store: store)
        site = ""
        email = ""
        apiToken = ""
        reload()
    }

    public var isConnected: Bool {
        connectedSummary != nil
    }

    public var canSave: Bool {
        AtlassianCredentials(site: site, email: email, apiToken: apiToken).isComplete
    }

    public func reload() {
        errorMessage = nil
        do {
            if let credentials = try service.currentCredentials() {
                site = credentials.site
                email = credentials.email
                apiToken = ""
                connectedSummary = credentials.redactedDescription
            } else {
                connectedSummary = nil
            }
        } catch {
            errorMessage = error.localizedDescription
            connectedSummary = nil
        }
    }

    public func save() {
        errorMessage = nil
        statusMessage = nil
        do {
            let credentials = try service.connect(site: site, email: email, apiToken: apiToken)
            apiToken = ""
            connectedSummary = credentials.redactedDescription
            statusMessage = "저장했습니다. 토큰은 Keychain에만 있습니다."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func disconnect() {
        errorMessage = nil
        statusMessage = nil
        do {
            try service.disconnect()
            site = ""
            email = ""
            apiToken = ""
            connectedSummary = nil
            statusMessage = "연결을 해제했습니다."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func verify() async {
        errorMessage = nil
        statusMessage = nil
        guard let credentials = try? service.currentCredentials() else {
            errorMessage = "설정에서 Atlassian 계정을 연결해 주세요."
            return
        }
        isVerifying = true
        defer { isVerifying = false }
        do {
            let name = try await AtlassianClient(credentials: credentials).verifyConnection()
            statusMessage = "연결 확인 완료: \(name)"
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
