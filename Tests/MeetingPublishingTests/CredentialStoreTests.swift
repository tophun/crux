@testable import MeetingCore
@testable import MeetingPublishing
import Testing

/// 테스트용 메모리 저장소. Keychain 없이 저장·삭제·미설정을 검증한다.
final class InMemoryCredentialStore: AtlassianCredentialStore, @unchecked Sendable {
    private var credentials: AtlassianCredentials?

    init(credentials: AtlassianCredentials? = nil) {
        self.credentials = credentials
    }

    func load() throws -> AtlassianCredentials? {
        credentials
    }

    func save(_ credentials: AtlassianCredentials) throws {
        self.credentials = credentials
    }

    func delete() throws {
        credentials = nil
    }
}

@Suite("Atlassian 자격증명 저장소")
struct CredentialStoreTests {
    @Test("저장 전에는 미설정이다")
    func unsetBeforeSave() throws {
        let store = InMemoryCredentialStore()
        #expect(try store.load() == nil)
    }

    @Test("저장한 자격증명을 다시 읽는다")
    func savesAndLoads() throws {
        let store = InMemoryCredentialStore()
        let credentials = AtlassianCredentials(
            site: "https://team.atlassian.net",
            email: " user@example.com ",
            apiToken: "secret-token\n"
        )
        try store.save(credentials)
        #expect(try store.load() == credentials)
        #expect(try store.load()?.site == "team.atlassian.net")
        #expect(try store.load()?.email == "user@example.com")
        #expect(try store.load()?.apiToken == "secret-token")
    }

    @Test("삭제하면 미설정이 된다")
    func deleteReturnsUnset() throws {
        let store = InMemoryCredentialStore(
            credentials: AtlassianCredentials(site: "team.atlassian.net", email: "a@b.c", apiToken: "t")
        )
        #expect(try store.load() != nil)
        try store.delete()
        #expect(try store.load() == nil)
    }

    @Test("ChainedCredentialStore는 첫 저장소에 쓰고 삭제하면 비운다")
    func chainedSaveAndDelete() throws {
        let memory = InMemoryCredentialStore()
        let store = ChainedCredentialStore(stores: [memory])
        #expect(try store.load() == nil)

        let credentials = AtlassianCredentials(site: "team.atlassian.net", email: "a@b.c", apiToken: "secret")
        try store.save(credentials)
        #expect(try store.load() == credentials)
        #expect(try memory.load() == credentials)

        try store.delete()
        #expect(try store.load() == nil)
        #expect(try memory.load() == nil)
    }

    @Test("앞 저장소가 비면 다음 저장소를 본다")
    func chainedFallsBack() throws {
        let first = InMemoryCredentialStore()
        let second = InMemoryCredentialStore(
            credentials: AtlassianCredentials(site: "team.atlassian.net", email: "a@b.c", apiToken: "env-token")
        )
        let store = ChainedCredentialStore(stores: [first, second])
        #expect(try store.load()?.email == "a@b.c")
    }
}

@Suite("Atlassian 계정 연결")
struct AtlassianAccountServiceTests {
    @Test("빈 필드는 저장하지 않고 미설정으로 남긴다")
    func rejectsIncompleteAndStaysUnset() throws {
        let store = InMemoryCredentialStore()
        let service = AtlassianAccountService(store: store)
        #expect(throws: PublishError.self) {
            try service.connect(site: "team.atlassian.net", email: "", apiToken: "token")
        }
        #expect(try service.currentCredentials() == nil)
        #expect(!AtlassianCredentials(site: "", email: "a@b.c", apiToken: "t").isComplete)
    }

    @Test("연결 후 읽고 해제하면 미설정이 된다")
    func connectThenDisconnectUnsets() throws {
        let service = AtlassianAccountService(store: InMemoryCredentialStore())
        #expect(try service.currentCredentials() == nil)

        let saved = try service.connect(
            site: "https://team.atlassian.net",
            email: "user@example.com",
            apiToken: "super-secret-token-value"
        )
        #expect(saved.isComplete)
        #expect(!saved.redactedDescription.contains("super-secret"))
        #expect(try service.currentCredentials() == saved)

        try service.disconnect()
        #expect(try service.currentCredentials() == nil)
    }
}
