import MeetingPublishing

/// Preview 게시 버튼이 Settings의 연결 상태와 같은 Keychain 경로를 보게 한다.
public extension MeetingSessionCoordinator {
    func hasStoredAtlassianCredentials() -> Bool {
        (try? credentialStore.load()) != nil
    }

    func refreshAtlassianCredentials() {
        previewModel?.hasAtlassianCredentials = hasStoredAtlassianCredentials()
    }
}
