import Foundation
@testable import MeetingCore
@testable import MeetingPublishing
import Testing

final class RecordingSlackClient: SlackMessaging, @unchecked Sendable {
    private let lock = NSLock()
    private var _posts: [(channel: String, text: String)] = []

    var posts: [(channel: String, text: String)] {
        lock.lock()
        defer { lock.unlock() }
        return _posts
    }

    func postMessage(channel: String, text: String) async throws -> SlackPostedMessage {
        lock.lock()
        _posts.append((channel, text))
        lock.unlock()
        return SlackPostedMessage(channel: channel, timestamp: "1.0")
    }
}

@Suite("Slack 전송 게이트")
struct SlackPublisherTests {
    func makeNote() -> MeetingNote {
        var note = MeetingNote(
            meetingId: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            title: "결제 모듈 배포 회의",
            summary: "배포일을 3월 12일로 확정했고 체크리스트는 다음 주 월요일까지 공유한다."
        )
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

    @Test("확인하지 않으면 클라이언트를 호출하지 않는다")
    func doesNotSendWithoutConfirmation() async {
        let note = makeNote()
        let client = RecordingSlackClient()
        let publisher = SlackPublisher(client: client)
        let payload = SlackActionPayload.make(from: makeBundle(note: note), destination: "#eng")

        await #expect(throws: PublishError.self) {
            _ = try await publisher.send(
                payload: payload,
                evidence: EvidenceBundle.make(from: note),
                confirmed: false
            )
        }
        #expect(client.posts.isEmpty)
    }

    @Test("채널이 없으면 전송하지 않는다")
    func doesNotSendWithoutDestination() async {
        let note = makeNote()
        let client = RecordingSlackClient()
        let payload = SlackActionPayload.make(from: makeBundle(note: note), destination: "  ")
        await #expect(throws: PublishError.self) {
            _ = try await SlackPublisher(client: client).send(
                payload: payload,
                evidence: EvidenceBundle.make(from: note),
                confirmed: true
            )
        }
        #expect(client.posts.isEmpty)
    }

    @Test("검열 게이트가 막으면 전송하지 않는다")
    func gateBlocksBeforeSend() async throws {
        let note = makeNote()
        let evidence = EvidenceBundle.make(from: note)
        var payload = SlackActionPayload.make(from: makeBundle(note: note), destination: "C123")
        payload.actions[0].task = note.actionItems[0].evidence[0].quote

        let client = RecordingSlackClient()
        #expect(throws: PublishError.self) {
            try SlackPublisher(client: client).audit(payload, evidence: evidence)
        }
        await #expect(throws: PublishError.self) {
            _ = try await SlackPublisher(client: client).send(
                payload: payload,
                evidence: evidence,
                confirmed: true
            )
        }
        #expect(client.posts.isEmpty)
    }

    @Test("타임스탬프가 섞이면 전송하지 않는다")
    func gateRejectsTimestamp() async {
        let note = makeNote()
        let evidence = EvidenceBundle.make(from: note)
        var payload = SlackActionPayload.make(from: makeBundle(note: note), destination: "C123")
        payload.actions[0].task += " 00:42"

        let client = RecordingSlackClient()
        await #expect(throws: PublishError.self) {
            _ = try await SlackPublisher(client: client).send(
                payload: payload,
                evidence: evidence,
                confirmed: true
            )
        }
        #expect(client.posts.isEmpty)
    }

    @Test("확인한 액션 본문만 전송하고 요약·타임스탬프는 빠진다")
    func sendsActionsOnlyAfterConfirm() async throws {
        let note = makeNote()
        let client = RecordingSlackClient()
        let payload = SlackActionPayload.make(from: makeBundle(note: note), destination: "#eng")
        let posted = try await SlackPublisher(client: client).send(
            payload: payload,
            evidence: EvidenceBundle.make(from: note),
            confirmed: true
        )

        #expect(posted.channel == "eng")
        #expect(client.posts.count == 1)
        let text = try #require(client.posts.first?.text)
        #expect(text.contains("배포 체크리스트 공유"))
        #expect(!text.contains("배포일을 3월 12일로 확정했고"))
        #expect(!text.contains("00:"))
        #expect(!text.contains("공유해 주세요."))
    }

    @Test("dry run은 전송 없이 액션 본문만 보여 준다")
    func dryRunDoesNotSend() throws {
        let note = makeNote()
        let client = RecordingSlackClient()
        let output = try SlackPublisher(client: client).dryRun(
            payload: SlackActionPayload.make(from: makeBundle(note: note), destination: "C1"),
            evidence: EvidenceBundle.make(from: note)
        )
        #expect(output.contains("[Slack]"))
        #expect(output.contains("배포 체크리스트 공유"))
        #expect(!output.contains("00:"))
        #expect(client.posts.isEmpty)
    }
}

@Suite("Slack 인증 정보")
struct SlackCredentialsTests {
    @Test("요약 문자열에 토큰이 들어가지 않는다")
    func redactsToken() {
        let credentials = SlackCredentials(botToken: "xoxb-super-secret-token")
        #expect(!credentials.redactedDescription.contains("super-secret"))
        #expect(!credentials.redactedDescription.contains("xoxb-"))
        #expect(credentials.redactedDescription.contains("토큰 저장됨"))
        #expect(credentials.authorizationHeader.hasPrefix("Bearer "))
    }

    @Test("환경 변수가 없으면 인증 정보를 만들지 않는다")
    func environmentStoreWithoutVariables() throws {
        if ProcessInfo.processInfo.environment["SLACK_BOT_TOKEN"] == nil {
            #expect(try SlackEnvironmentCredentialStore().load() == nil)
        }
    }
}
