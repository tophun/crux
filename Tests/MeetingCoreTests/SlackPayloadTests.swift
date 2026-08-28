import Foundation
@testable import MeetingCore
import Testing

@Suite("Slack 액션 페이로드")
struct SlackActionPayloadTests {
    func bundle(includeSecond: Bool = true) -> PublishBundle {
        var result = PublishBundleBuilder().build(
            note: Fixtures.publishableNote(),
            meeting: Fixtures.meeting(),
            event: nil,
            options: PublishBundleBuilder.Options(spaceKey: "TEAM", projectKey: "PROJ")
        )
        if !includeSecond, result.issues.indices.contains(1) {
            result.issues[1].include = false
        }
        return result
    }

    @Test("포함하기로 고른 액션만 들어가고 회의 요약·근거는 빠진다")
    func includesApprovedActionsOnly() {
        let source = bundle()
        let payload = SlackActionPayload.make(from: source, destination: "#eng")
        #expect(payload.actions.count == 2)
        #expect(payload.actions[0].task == "배포 체크리스트 작성 및 공유")
        #expect(payload.actions[0].assignee == "홍길동")
        #expect(payload.normalizedDestination == "eng")

        let text = payload.messageText()
        #expect(text.contains("배포 체크리스트 작성 및 공유"))
        #expect(text.contains("회귀 테스트 완료"))
        #expect(text.contains("홍길동"))

        // Jira 상세에 들어가는 회의 요약·미배정 안내는 Slack 본문에 없어야 한다.
        #expect(!text.contains("배포일을 3월 12일로 확정했고"))
        #expect(!text.contains("회의 요약"))
        #expect(!text.contains("담당자가 회의에서 확인되지 않았습니다"))

        let evidence = EvidenceBundle.make(from: Fixtures.publishableNote())
        #expect(PublishRedaction.audit(text: text, evidence: evidence).isEmpty)

        // 근거 타임스탬프와 원문 인용은 본문에 없다.
        #expect(!text.contains("00:"))
        #expect(!text.contains("확정합니다."))
        #expect(!text.contains("공유해 주세요."))
    }

    @Test("생성 체크를 끈 액션은 Slack 페이로드에서 빠진다")
    func honorsIncludeToggle() {
        let payload = SlackActionPayload.make(from: bundle(includeSecond: false), destination: "C123")
        #expect(payload.actions.map(\.task) == ["배포 체크리스트 작성 및 공유"])
        #expect(!payload.messageText().contains("회귀 테스트"))
    }

    @Test("인코딩 필드가 액션 초안에 필요한 키뿐인지 고정한다")
    func encodedKeysAreActionsOnly() throws {
        let payload = SlackActionPayload.make(from: bundle(), destination: "C1")
        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any]
        )
        #expect(Set(object.keys) == ["destination", "meetingTitle", "actions"])
        let action = try #require((object["actions"] as? [[String: Any]])?.first)
        #expect(Set(action.keys) == ["task", "assignee", "dueDate"])
        for forbidden in ["transcript", "evidence", "startTime", "endTime", "segmentId", "contentId", "quote"] {
            #expect(!object.keys.contains(forbidden))
            #expect(!action.keys.contains(forbidden))
        }
    }
}

@Suite("Slack 보내기 확인 게이트")
struct SlackSendGateTests {
    @Test("채널이 없거나 액션이 없으면 확인 대기에도 들어가지 않는다")
    func beginRejectsIncompleteRequest() {
        var gate = SlackSendGate()
        #expect(gate.begin(destination: "  ", actionCount: 1) == "Slack 채널 또는 DM을 입력하세요.")
        #expect(!gate.awaitingConfirmation)
        #expect(gate.begin(destination: "#eng", actionCount: 0) == "보낼 액션이 없습니다. Preview에서 생성할 항목을 선택하세요.")
        #expect(!gate.awaitingConfirmation)
    }

    @Test("확인하지 않으면 전송을 허용하지 않는다")
    func confirmRequiredBeforeSend() {
        // mutating 호출은 #expect 밖에서 한다. 매크로가 값을 불변 인자로 캡처한다.
        var gate = SlackSendGate()
        let confirmedBeforeBegin = gate.confirm()
        #expect(!confirmedBeforeBegin)

        let beginError = gate.begin(destination: "#eng", actionCount: 2)
        #expect(beginError == nil)
        #expect(gate.awaitingConfirmation)
        let confirmedAfterBegin = gate.confirm()
        #expect(confirmedAfterBegin)
        #expect(!gate.awaitingConfirmation)

        var cancelled = SlackSendGate()
        let cancelledBeginError = cancelled.begin(destination: "U1", actionCount: 1)
        #expect(cancelledBeginError == nil)
        cancelled.cancel()
        let confirmedAfterCancel = cancelled.confirm()
        #expect(!confirmedAfterCancel)
    }
}
