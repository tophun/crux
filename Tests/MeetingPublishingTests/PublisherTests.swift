import Foundation
@testable import MeetingCore
@testable import MeetingPublishing
import Testing

@Suite("Atlassian 인증 정보")
struct AtlassianCredentialsTests {
    @Test("요약 문자열에 토큰이 들어가지 않는다")
    func redactsToken() {
        let credentials = AtlassianCredentials(
            site: "https://team.atlassian.net",
            email: "user@example.com",
            apiToken: "super-secret-token-value"
        )
        #expect(credentials.site == "team.atlassian.net")
        #expect(!credentials.redactedDescription.contains("super-secret"))
        #expect(credentials.redactedDescription.contains("토큰 저장됨"))
    }

    @Test("Basic 인증 헤더를 만든다")
    func buildsBasicHeader() throws {
        let credentials = AtlassianCredentials(site: "team.atlassian.net", email: "a@b.c", apiToken: "t")
        #expect(credentials.authorizationHeader.hasPrefix("Basic "))
        let encoded = credentials.authorizationHeader.replacingOccurrences(of: "Basic ", with: "")
        let decoded = try String(decoding: #require(Data(base64Encoded: encoded)), as: UTF8.self)
        #expect(decoded == "a@b.c:t")
    }

    @Test("환경 변수가 없으면 인증 정보를 만들지 않는다")
    func environmentStoreWithoutVariables() throws {
        // 테스트 환경에는 ATLASSIAN_* 변수가 없다고 가정한다.
        if ProcessInfo.processInfo.environment["ATLASSIAN_API_TOKEN"] == nil {
            #expect(try EnvironmentCredentialStore().load() == nil)
        }
    }
}

@Suite("게시 게이트")
struct MeetingPublisherGateTests {
    func makeBundle(note: MeetingNote) -> PublishBundle {
        PublishBundleBuilder().build(
            note: note,
            meeting: Meeting(
                id: note.meetingId,
                title: "회의",
                startedAt: Date(timeIntervalSince1970: 1_772_000_000),
                storageDirectory: URL(fileURLWithPath: NSTemporaryDirectory())
            ),
            event: nil,
            options: PublishBundleBuilder.Options(spaceKey: "TEAM", projectKey: "PROJ")
        )
    }

    func makeNote() -> MeetingNote {
        var note = MeetingNote(
            meetingId: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            title: "결제 모듈 배포 회의",
            summary: "배포일을 3월 12일로 확정했다."
        )
        note.decisions = [
            Decision(
                content: "배포일을 3월 12일로 확정",
                kind: .decided,
                evidence: [
                    Evidence(
                        segmentId: UUID().uuidString,
                        startTime: 32,
                        endTime: 40,
                        quote: "결제 모듈 배포는 3월 12일 수요일로 확정합니다."
                    )
                ],
                confidence: 0.9
            )
        ]
        note.actionItems = [
            ActionItem(
                task: "배포 체크리스트 공유",
                assignee: "홍길동",
                dueDate: "3월 10일",
                status: .confirmed,
                evidence: [
                    Evidence(
                        segmentId: UUID().uuidString,
                        startTime: 42,
                        endTime: 47,
                        quote: "홍길동 님이 배포 체크리스트를 다음 주 월요일까지 공유해 주세요."
                    )
                ],
                confidence: 0.85
            )
        ]
        return note
    }

    func publisher() -> MeetingPublisher {
        MeetingPublisher(
            client: AtlassianClient(
                credentials: AtlassianCredentials(site: "example.atlassian.net", email: "a@b.c", apiToken: "x")
            )
        )
    }

    @Test("승인하지 않으면 아무것도 전송하지 않는다")
    func requiresApproval() async {
        let note = makeNote()
        let bundle = makeBundle(note: note)
        await #expect(throws: PublishError.self) {
            _ = try await publisher().publish(
                bundle: bundle,
                evidence: EvidenceBundle.make(from: note),
                approved: false
            )
        }
    }

    @Test("정상 묶음은 검열 게이트를 통과한다")
    func auditPasses() throws {
        let note = makeNote()
        let bundle = makeBundle(note: note)
        try publisher().audit(
            page: bundle.page,
            issues: bundle.includedIssues,
            evidence: EvidenceBundle.make(from: note)
        )
    }

    @Test("근거 인용이 섞이면 게시를 거부한다")
    func auditRejectsEvidence() throws {
        let note = makeNote()
        var bundle = makeBundle(note: note)
        // 사용자가 근거 문장을 그대로 붙여 넣은 상황
        bundle.page.summary = note.decisions[0].evidence[0].quote
        #expect(throws: PublishError.self) {
            try publisher().audit(
                page: bundle.page,
                issues: bundle.includedIssues,
                evidence: EvidenceBundle.make(from: note)
            )
        }
    }

    @Test("타임스탬프가 섞이면 게시를 거부한다")
    func auditRejectsTimestamp() throws {
        let note = makeNote()
        var bundle = makeBundle(note: note)
        bundle.page.decisions.append("근거 00:32 참고")
        #expect(throws: PublishError.self) {
            try publisher().audit(
                page: bundle.page,
                issues: bundle.includedIssues,
                evidence: EvidenceBundle.make(from: note)
            )
        }
    }

    @Test("dry run은 전송 없이 보낼 내용을 보여준다")
    func dryRunShowsPayload() throws {
        let note = makeNote()
        let bundle = makeBundle(note: note)
        let output = try publisher().dryRun(bundle: bundle, evidence: EvidenceBundle.make(from: note))
        #expect(output.contains("[Confluence] space=TEAM"))
        #expect(output.contains("[Jira] project=PROJ"))
        #expect(output.contains("배포 체크리스트 공유"))
        // 근거 타임스탬프와 인용은 나오지 않는다.
        #expect(!output.contains("00:32"))
        #expect(!output.contains("확정합니다."))
    }
}
