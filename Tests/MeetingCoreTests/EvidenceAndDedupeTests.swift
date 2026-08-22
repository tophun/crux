import Foundation
import Testing
@testable import MeetingCore

@Suite("근거 검증")
struct EvidenceValidatorTests {
    let validator = EvidenceValidator()

    @Test("원문에 있는 인용은 세그먼트와 타임스탬프가 연결된다")
    func linksQuoteToSegment() {
        let segments = Fixtures.meetingSegments
        let window = Fixtures.window(segments)
        let (evidence, reason) = validator.resolve(
            shortId: "S2",
            quote: "3월 12일 수요일로 확정합니다",
            in: window
        )
        #expect(reason == nil)
        #expect(evidence?.segmentId == segments[2].id.uuidString)
        #expect(evidence?.startTime == segments[2].startTime)
    }

    @Test("구간 번호가 틀려도 인용으로 올바른 구간을 찾아 교정한다")
    func retargetsWrongSegment() {
        let segments = Fixtures.meetingSegments
        let window = Fixtures.window(segments)
        let (evidence, reason) = validator.resolve(
            shortId: "S0",
            quote: "서버 시피유 사용률이 피크에 85퍼센트까지",
            in: window
        )
        #expect(evidence?.segmentId == segments[5].id.uuidString)
        #expect(reason?.contains("교정") == true)
    }

    @Test("원문에 없는 인용은 근거로 채택되지 않는다")
    func rejectsFabricatedQuote() {
        let window = Fixtures.window(Fixtures.meetingSegments)
        let (evidence, reason) = validator.resolve(
            shortId: "S2",
            quote: "김대리가 예산 5천만 원을 승인했습니다",
            in: window
        )
        #expect(evidence == nil)
        #expect(reason?.contains("확인되지 않은") == true)
    }

    @Test("인용이 비어 있으면 지목된 구간 원문을 근거로 쓴다")
    func usesSegmentTextWhenQuoteMissing() {
        let segments = Fixtures.meetingSegments
        let window = Fixtures.window(segments)
        let (evidence, _) = validator.resolve(shortId: "S3", quote: nil, in: window)
        #expect(evidence?.quote == segments[3].text)
    }

    @Test("저장 전 재검증에서 위조 근거가 제거된다")
    func validateFiltersFabricated() {
        let segments = Fixtures.meetingSegments
        let good = Fixtures.evidence(for: segments[2], quote: "3월 12일 수요일로 확정합니다")
        let bad = Evidence(
            segmentId: UUID().uuidString,
            startTime: 0,
            endTime: 1,
            quote: "존재하지 않는 발언입니다 예산 승인 완료"
        )
        let outcome = validator.validate(evidence: [good, bad], segments: segments)
        #expect(outcome.evidence.count == 1)
        #expect(outcome.rejected.count == 1)
    }
}

@Suite("반복 발언 통합")
struct FactDeduplicatorTests {
    let deduplicator = FactDeduplicator()
    let segments = Fixtures.meetingSegments

    @Test("같은 내용이 반복되면 한 번만 기록한다")
    func mergesRepeatedFacts() {
        let first = Fixtures.fact(
            kind: .decision,
            content: "결제 모듈 배포를 3월 12일 수요일로 확정",
            decisionKind: .decided,
            evidence: [Fixtures.evidence(for: segments[2])]
        )
        let repeated = Fixtures.fact(
            kind: .decision,
            content: "배포일은 3월 12일 수요일로 확정한다",
            decisionKind: .decided,
            evidence: [Fixtures.evidence(for: segments[6])],
            windowIndex: 1
        )
        let result = deduplicator.merge([first, repeated])
        #expect(result.facts.count == 1)
        #expect(result.mergedCount == 1)
        // 근거는 두 발언 모두 유지된다.
        #expect(result.facts[0].evidence.count == 2)
    }

    @Test("마감일이 바뀌면 최종 값을 남기고 변경을 기록한다")
    func recordsDueDateChange() {
        let first = Fixtures.fact(
            kind: .actionItem,
            content: "배포 체크리스트 공유",
            assignee: "박지훈",
            dueDate: "3월 10일",
            evidence: [Fixtures.evidence(for: segments[3])]
        )
        let updated = Fixtures.fact(
            kind: .actionItem,
            content: "배포 체크리스트 공유하기",
            assignee: "박지훈",
            dueDate: "3월 11일",
            evidence: [Fixtures.evidence(for: segments[6])],
            windowIndex: 1
        )
        let result = deduplicator.merge([first, updated])
        #expect(result.facts.count == 1)
        #expect(result.facts[0].dueDate == "3월 11일")
        #expect(result.changeLog.contains { $0.contains("마감일 변경") })
        #expect(result.facts[0].ambiguityNotes.contains { $0.contains("마감일") })
    }

    @Test("담당자가 바뀌면 마지막 담당자를 남기고 변경을 기록한다")
    func recordsAssigneeChange() {
        let first = Fixtures.fact(
            kind: .actionItem,
            content: "회귀 테스트 진행",
            assignee: "김민수",
            evidence: [Fixtures.evidence(for: segments[3])]
        )
        let updated = Fixtures.fact(
            kind: .actionItem,
            content: "회귀 테스트 진행하기",
            assignee: "이서연",
            evidence: [Fixtures.evidence(for: segments[5])],
            windowIndex: 1
        )
        let result = deduplicator.merge([first, updated])
        #expect(result.facts[0].assignee == "이서연")
        #expect(result.changeLog.contains { $0.contains("담당자 변경") })
    }

    @Test("서로 다른 내용은 합치지 않는다")
    func keepsDistinctFacts() {
        let decision = Fixtures.fact(kind: .decision, content: "배포일 확정", decisionKind: .decided)
        let risk = Fixtures.fact(kind: .risk, content: "서버 용량 부족 위험")
        let other = Fixtures.fact(kind: .decision, content: "가격 정책은 사업팀 확인 필요")
        let result = deduplicator.merge([decision, risk, other])
        #expect(result.facts.count == 3)
        #expect(result.mergedCount == 0)
    }
}

@Suite("마감일 근거 검증")
struct DueDateGroundingTests {
    @Test("원문에 있는 날짜는 그대로 확정한다")
    func keepsGroundedDate() {
        let result = DueDateGrounding.check(
            dueDate: "3월 12일",
            dueDateNote: nil,
            evidenceTexts: ["결제 모듈 배포는 3월 12일 수요일로 확정합니다."]
        )
        #expect(result.dueDate == "3월 12일")
        #expect(!result.demoted)
    }

    @Test("모델이 계산해 넣은 절대 날짜는 확정하지 않는다")
    func demotesFabricatedAbsoluteDate() {
        let result = DueDateGrounding.check(
            dueDate: "2023-03-07",
            dueDateNote: nil,
            evidenceTexts: ["박지훈님이 배포 체크리스트를 작성해서 다음주 월요일까지 공유해주세요."]
        )
        #expect(result.dueDate == nil)
        #expect(result.demoted)
        #expect(result.dueDateNote == "2023-03-07")
        #expect(result.reason?.contains("확인되지 않는 날짜") == true)
    }

    @Test("원문에 있는 상대 표현은 유지한다")
    func keepsRelativeExpressionFromTranscript() {
        let result = DueDateGrounding.check(
            dueDate: "다음주 월요일",
            dueDateNote: nil,
            evidenceTexts: ["배포 체크리스트를 작성해서 다음주 월요일까지 공유해주세요."]
        )
        #expect(result.dueDate == "다음주 월요일")
        #expect(!result.demoted)
    }

    @Test("근거가 없으면 마감일을 확정하지 않는다")
    func demotesWithoutEvidence() {
        let result = DueDateGrounding.check(dueDate: "3월 12일", dueDateNote: nil, evidenceTexts: [])
        #expect(result.dueDate == nil)
        #expect(result.demoted)
    }

    @Test("후보에 적용하면 근거 없는 마감일이 표현으로 내려간다")
    func appliesToFact() {
        let segments = Fixtures.meetingSegments
        let fact = Fixtures.fact(
            kind: .actionItem,
            content: "체크리스트 공유",
            dueDate: "2026-03-09",
            evidence: [Fixtures.evidence(for: segments[3])]
        )
        let (updated, reason) = DueDateGrounding.apply(to: fact, segments: segments)
        #expect(updated.dueDate == nil)
        #expect(updated.dueDateNote == "2026-03-09")
        #expect(reason != nil)
    }
}
