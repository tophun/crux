import Foundation
import Testing
@testable import MeetingCore

@Suite("사고 모드 자동 라우팅")
struct ReasoningRouterTests {
    let router = ReasoningRouter()
    let segments = Fixtures.meetingSegments

    @Test("근거가 명확한 결정은 비사고 모드로 처리한다")
    func simpleDecisionUsesNonThinking() {
        let segment = segments[2]
        let fact = Fixtures.fact(
            kind: .decision,
            content: "결제 모듈 배포를 3월 12일로 확정",
            decisionKind: .decided,
            evidence: [Fixtures.evidence(for: segment)],
            confidence: 0.92
        )
        let decision = router.decide(for: fact, segments: segments)
        #expect(decision.mode == .nonThinking)
        #expect(decision.signals.isEmpty)
    }

    @Test("담당자가 없는 액션아이템은 사고 모드로 재검토한다")
    func missingAssigneeTriggersThinking() {
        let fact = Fixtures.fact(
            kind: .actionItem,
            content: "회귀 테스트 완료",
            evidence: [Fixtures.evidence(for: segments[3])],
            confidence: 0.8
        )
        let decision = router.decide(for: fact, segments: segments)
        #expect(decision.needsThinking)
        #expect(decision.signals.contains(.assigneeMissing))
    }

    @Test("모호한 표현이 있으면 사고 모드로 재검토한다")
    func vagueExpressionTriggersThinking() {
        let fact = Fixtures.fact(
            kind: .decision,
            content: "증설 비용은 일단 보류하고 추후 논의",
            decisionKind: .decided,
            evidence: [Fixtures.evidence(for: segments[6])],
            confidence: 0.9
        )
        let decision = router.decide(for: fact, segments: segments)
        #expect(decision.needsThinking)
        #expect(decision.signals.contains(.vagueExpression))
    }

    @Test("전사 신뢰도가 낮으면 사고 모드로 재검토한다")
    func lowTranscriptConfidenceTriggersThinking() {
        let noisy = Fixtures.segment(20, "배포는 다음 달에 하기로 했습니다", confidence: 0.3)
        let fact = Fixtures.fact(
            kind: .decision,
            content: "배포를 다음 달로 결정",
            decisionKind: .decided,
            evidence: [Fixtures.evidence(for: noisy)],
            confidence: 0.9
        )
        let decision = router.decide(for: fact, segments: segments + [noisy])
        #expect(decision.needsThinking)
        #expect(decision.signals.contains(.lowTranscriptConfidence))
    }

    @Test("근거가 없으면 반드시 사고 모드로 재검토한다")
    func missingEvidenceTriggersThinking() {
        let fact = Fixtures.fact(kind: .decision, content: "배포 확정", decisionKind: .decided)
        let decision = router.decide(for: fact, segments: segments)
        #expect(decision.needsThinking)
        #expect(decision.signals.contains(.missingEvidence))
    }

    @Test("결정 상태가 불명확하면 사고 모드로 재검토한다")
    func ambiguousDecisionTriggersThinking() {
        let fact = Fixtures.fact(
            kind: .decision,
            content: "가격 정책 변경",
            decisionKind: nil,
            evidence: [Fixtures.evidence(for: segments[7])],
            confidence: 0.9
        )
        let decision = router.decide(for: fact, segments: segments)
        #expect(decision.needsThinking)
        #expect(decision.signals.contains(.decisionAmbiguous))
    }

    @Test("담당자·마감일이 다른 중복 액션아이템은 충돌로 감지한다")
    func detectsConflictingActions() {
        let first = Fixtures.fact(
            kind: .actionItem,
            content: "배포 체크리스트 작성해서 공유",
            assignee: "박지훈",
            dueDate: "3월 10일",
            evidence: [Fixtures.evidence(for: segments[3])]
        )
        let second = Fixtures.fact(
            kind: .actionItem,
            content: "배포 체크리스트 작성 후 공유하기",
            assignee: "김민수",
            dueDate: "3월 11일",
            evidence: [Fixtures.evidence(for: segments[3])],
            windowIndex: 1
        )
        let decision = router.decide(for: first, segments: segments, peers: [first, second])
        #expect(decision.needsThinking)
        #expect(decision.signals.contains(.duplicateOrConflictingActions))
        #expect(decision.signals.contains(.crossWindowComparison))
    }

    @Test("단순한 회의는 최종 종합도 비사고 모드로 처리한다")
    func simpleMeetingUsesNonThinkingFinalPass() {
        let decision = router.decideFinalPass(
            totalCandidates: 10,
            reviewedCandidates: 0,
            conflictCount: 0,
            unresolvedCount: 0
        )
        #expect(decision.mode == .nonThinking)
    }

    @Test("충돌이나 미확정이 있으면 최종 종합을 사고 모드로 처리한다")
    func complexMeetingUsesThinkingFinalPass() {
        let decision = router.decideFinalPass(
            totalCandidates: 10,
            reviewedCandidates: 4,
            conflictCount: 2,
            unresolvedCount: 3
        )
        #expect(decision.mode == .thinking)
    }
}
