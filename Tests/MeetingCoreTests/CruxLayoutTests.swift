import Foundation
@testable import MeetingCore
import Testing

@Suite("캡슐 좌우 배치")
struct CruxLayoutTests {
    @Test("녹음 중에는 좌측에 상태, 우측에 경과 시간이 나뉜다")
    func splitsRecording() {
        let state = CruxState.recording(elapsed: 754, paused: false)
        #expect(state.statusText == "녹음 중")
        #expect(state.trailingText == "12:34")
        // 좌측 문구에는 시간이 들어가지 않는다. 우측과 중복되면 안 된다.
        #expect(!state.statusText.contains(":"))
    }

    @Test("일시정지도 좌측 상태만 바뀌고 시간은 우측에 남는다")
    func pausedKeepsClock() {
        let state = CruxState.recording(elapsed: 61, paused: true)
        #expect(state.statusText == "일시정지")
        #expect(state.trailingText == "1:01")
    }

    @Test("회의록 작성 중에는 우측에 진행률이 붙는다")
    func showsProgressPercent() {
        #expect(CruxState.generating(fraction: 0.42, message: "음성 인식").statusText == "회의록 작성 중")
        #expect(CruxState.generating(fraction: 0.42, message: "음성 인식").trailingText == "42%")
        #expect(CruxState.generating(fraction: 1, message: "완료").trailingText == "100%")
    }

    @Test("준비 완료·게시 완료는 개수를, 없으면 아무것도 보이지 않는다")
    func countsOnRight() {
        #expect(CruxState.previewReady(meetingId: UUID(), actionItemCount: 3).trailingText == "액션 3개")
        #expect(CruxState.previewReady(meetingId: UUID(), actionItemCount: 0).trailingText == nil)
        #expect(CruxState.published(confluencePageTitle: "주간 회의", jiraIssueCount: 2).trailingText == "이슈 2개")
        #expect(CruxState.published(confluencePageTitle: nil, jiraIssueCount: 0).trailingText == nil)
    }

    @Test("확인·실패 상태는 우측을 비워 문구에 집중시킨다")
    func emptyTrailingForPrompts() {
        #expect(CruxState.detected(title: nil, message: "확인").trailingText == nil)
        #expect(CruxState.failed(message: "오류").trailingText == nil)
        #expect(CruxState.failed(message: "오류").statusText == "처리 실패")
    }

    @Test("임박 상태는 제목과 남은 시간을 좌우로 나눈다")
    func splitsImminent() {
        let state = CruxState.imminent(title: "주간 유저성장 회의", minutesUntilStart: 5)
        #expect(state.statusText == "주간 유저성장 회의")
        #expect(state.trailingText == "5분 전")
    }

    @Test("녹음 중에는 아이콘 대신 점을 그리므로 심볼이 없다")
    func recordingHasNoSymbol() {
        #expect(CruxState.recording(elapsed: 0, paused: false).symbolName == nil)
        #expect(CruxState.generating(fraction: 0, message: "").symbolName == "waveform")
    }
}

@Suite("캡슐 단계 식별")
struct CruxKindTests {
    @Test("녹음 시간이 흘러도 같은 단계로 본다 — 펼친 패널이 매초 닫히면 안 된다")
    func tickKeepsSameKind() {
        let first = CruxState.recording(elapsed: 10, paused: false)
        let later = CruxState.recording(elapsed: 11, paused: false)
        #expect(first != later)
        #expect(first.kindId == later.kindId)
    }

    @Test("일시정지와 진행률 변화는 구분한다")
    func distinguishesRealTransitions() {
        #expect(
            CruxState.recording(elapsed: 10, paused: false).kindId
                != CruxState.recording(elapsed: 10, paused: true).kindId
        )
        #expect(
            CruxState.generating(fraction: 0.1, message: "a").kindId
                == CruxState.generating(fraction: 0.9, message: "b").kindId
        )
        #expect(
            CruxState.generating(fraction: 1, message: "").kindId
                != CruxState.previewReady(meetingId: UUID(), actionItemCount: 1).kindId
        )
    }
}
