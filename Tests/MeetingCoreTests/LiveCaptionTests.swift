import Foundation
@testable import MeetingCore
import Testing

@Suite("실시간 초안 요약")
struct LiveCaptionTests {
    @Test("빈 자막은 요약을 만들지 않는다")
    func emptyTexts() {
        #expect(LiveDraftSummaryBuilder.make(from: [String]()) == "")
        #expect(LiveDraftSummaryBuilder.make(from: ["  ", ""]) == "")
    }

    @Test("짧은 자막은 그대로 이어 붙인다")
    func joinsShortCaptions() {
        let summary = LiveDraftSummaryBuilder.make(from: [
            "배포는 3월 12일입니다.",
            "체크리스트를 공유합니다."
        ])
        #expect(summary == "배포는 3월 12일입니다. 체크리스트를 공유합니다.")
    }

    @Test("긴 자막은 잘라 초안처럼 보이게 한다")
    func truncatesLongSummary() {
        let long = String(repeating: "가", count: 200)
        let summary = LiveDraftSummaryBuilder.make(from: [long], maxCharacters: 20)
        #expect(summary.hasSuffix("…"))
        #expect(summary.count == 21)
    }

    @Test("회의가 끝나기 전 상태는 항상 초안이다")
    func staysDraftUntilFinalized() {
        let state = LiveCaptionState(
            lines: [LiveCaptionLine(startTime: 0, endTime: 4, text: "안녕하세요")],
            draftSummary: "안녕하세요",
            isDraft: true,
            isActive: true
        )
        #expect(state.isDraft)
        #expect(state.recentLines.count == 1)
        #expect(state.fingerprint.contains("안녕하세요"))
    }

    @Test("화자 식별자는 초안에 넣지 않는다")
    func omitsSpeaker() {
        let segment = TranscriptSegment(
            meetingId: UUID(),
            index: 0,
            startTime: 0,
            endTime: 3,
            speakerId: "speaker-1",
            text: "결정했습니다."
        )
        let summary = LiveDraftSummaryBuilder.make(from: [segment])
        #expect(summary == "결정했습니다.")
        #expect(!summary.contains("speaker"))
    }
}
