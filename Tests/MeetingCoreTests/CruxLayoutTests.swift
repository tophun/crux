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

    @Test("접힌 노치에는 짧은 문구만 두고 제목·긴 문장은 넣지 않는다")
    func compactStatusAvoidsTruncation() {
        let imminent = CruxState.imminent(title: "주간 유저성장 회의", minutesUntilStart: 5)
        #expect(imminent.compactStatusText == "곧 시작")
        #expect(!imminent.compactStatusText.contains("주간"))

        #expect(CruxState.detected(title: nil, message: "확인").compactStatusText == "회의 시작")
        #expect(CruxState.detected(title: nil, message: "확인").statusText == "회의가 시작된 것 같습니다")
        #expect(CruxState.generating(fraction: 0.4, message: "음성 인식").compactStatusText == "작성 중")
        #expect(CruxState.previewReady(meetingId: UUID(), actionItemCount: 3).compactStatusText == "준비 완료")
        #expect(CruxState.recording(elapsed: 12, paused: false).compactStatusText == "녹음 중")
        #expect(CruxState.failed(message: "오류").compactStatusText == "처리 실패")
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

@Suite("캡슐 셸프 표시 모델")
struct CruxPresentationTests {
    @Test("표시 모드는 호버·고정 조합을 세 가지 값으로 정규화한다")
    func expansionModeTransitions() {
        #expect(CruxExpansionMode.resolve(isHovering: false, isPinned: false) == .collapsed)
        #expect(CruxExpansionMode.resolve(isHovering: true, isPinned: false) == .preview)
        #expect(CruxExpansionMode.resolve(isHovering: false, isPinned: true) == .pinned)
        #expect(CruxExpansionMode.preview.handlingHover(false) == .collapsed)
        #expect(CruxExpansionMode.pinned.handlingHover(false) == .pinned)
        #expect(CruxExpansionMode.preview.togglingPin() == .pinned)
        #expect(CruxExpansionMode.pinned.togglingPin() == .collapsed)
    }

    @Test("첫 표시에서는 데모 미리보기 모드를 접지 않는다")
    func keepsInitialDemoPreview() {
        #expect(
            !CapsuleHoverGate.shouldResetExpansionMode(
                previousKindId: nil,
                nextKindId: "recording"
            )
        )
        #expect(
            CapsuleHoverGate.shouldResetExpansionMode(
                previousKindId: "detected",
                nextKindId: "recording"
            )
        )
        #expect(
            !CapsuleHoverGate.shouldResetExpansionMode(
                previousKindId: "recording",
                nextKindId: "recording"
            )
        )
    }

    @Test("녹음 상태는 경과 시간과 일시정지·종료 동작을 함께 제공한다")
    func recordingPresentation() {
        let presentation = CruxPresentationModel(
            state: .recording(elapsed: 754, paused: false)
        )
        #expect(presentation.title == "녹음 중")
        #expect(presentation.elapsed == 754)
        #expect(presentation.primaryAction == .stopRecording)
        #expect(presentation.secondaryActions == [.pauseRecording, .stopRecording])
        #expect(presentation.accessibilityLabel.contains("경과 시간 12:34"))
    }

    @Test("생성 상태는 진행률과 취소 동작을 제공한다")
    func generatingPresentation() {
        let presentation = CruxPresentationModel(
            state: .generating(fraction: 0.42, message: "음성 인식")
        )
        #expect(presentation.title == "회의록 작성 중")
        #expect(presentation.progressFraction == 0.42)
        #expect(presentation.primaryAction == nil)
        #expect(presentation.secondaryActions == [.cancelProcessing])
        #expect(presentation.accessibilityLabel.contains("진행률 42%"))
    }

    @Test("실패 상태는 오류 문구와 재시도·닫기 동작을 제공한다")
    func failedPresentation() {
        let presentation = CruxPresentationModel(state: .failed(message: "네트워크 오류"))
        #expect(presentation.title == "처리 실패")
        #expect(presentation.detailText == "네트워크 오류")
        #expect(presentation.primaryAction == .retry)
        #expect(presentation.secondaryActions == [.dismiss])
    }

    @Test("임박·감지·검토·게시 상태의 주 동작이 상태별로 매핑된다")
    func promptAndCompletionActions() {
        #expect(
            CruxPresentationModel(
                state: .imminent(title: "주간 회의", minutesUntilStart: 5)
            ).primaryAction == .prepareMeeting
        )
        #expect(
            CruxPresentationModel(
                state: .detected(title: "주간 회의", message: "녹음하시겠습니까?")
            ).primaryAction == .startMeeting
        )
        #expect(
            CruxPresentationModel(
                state: .previewReady(meetingId: UUID(), actionItemCount: 2)
            ).primaryAction == .review
        )
        #expect(
            CruxPresentationModel(
                state: .published(confluencePageTitle: "게시 문서", jiraIssueCount: 1)
            ).primaryAction == .open
        )
    }

    @Test("생성 단계의 외부 안내 문구는 상태 메시지를 덮어쓸 수 있다")
    func generatingDetailOverride() {
        let presentation = CruxPresentationModel(
            state: .generating(fraction: 0.2, message: "음성 인식"),
            detailMessage: "화자 분리 중"
        )
        #expect(presentation.detailText == "화자 분리 중")
    }
}
