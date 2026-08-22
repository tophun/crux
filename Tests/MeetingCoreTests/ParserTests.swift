import Foundation
@testable import MeetingCore
import Testing

@Suite("1차 추출 응답 파싱")
struct WindowExtractionParserTests {
    let parser = WindowExtractionParser()
    let segments = Fixtures.meetingSegments

    var window: TranscriptWindow { Fixtures.window(segments) }

    @Test("결정·액션·리스크·질문과 구간 분류를 추출한다")
    func parsesAllSections() throws {
        let raw = """
        {
          "topics": [{"title": "배포 일정", "summary": "3월 배포"}],
          "decisions": [{"content": "배포일을 3월 12일로 확정", "kind": "decided", "confidence": 0.9,
            "evidence": [{"segment": "S2", "quote": "3월 12일 수요일로 확정합니다"}]}],
          "actionItems": [{"task": "배포 체크리스트 공유", "assignee": "홍길동", "dueDate": null,
            "dueDateNote": "다음 주 월요일", "confidence": 0.8,
            "evidence": [{"segment": "S3", "quote": "다음 주 월요일까지 공유해 주세요"}]}],
          "risks": [{"content": "서버 용량 한계", "severity": "high", "confidence": 0.7,
            "evidence": [{"segment": "S5", "quote": "85퍼센트까지 올라가서 위험합니다"}]}],
          "openQuestions": [{"question": "가격 정책 미정", "confidence": 0.6,
            "evidence": [{"segment": "S7", "quote": "아직 정해지지 않았습니다"}]}],
          "segmentRelevance": [
            {"segment": "S0", "label": "EXCLUDE"},
            {"segment": "S2", "label": "KEEP"},
            {"segment": "S8", "label": "EXCLUDE"}
          ]
        }
        """
        let parsed = try parser.parse(raw: raw, window: window, meetingId: Fixtures.meetingId)

        #expect(parsed.facts.count(where: { $0.kind == .decision }) == 1)
        #expect(parsed.facts.count(where: { $0.kind == .actionItem }) == 1)
        #expect(parsed.facts.count(where: { $0.kind == .risk }) == 1)
        #expect(parsed.facts.count(where: { $0.kind == .openQuestion }) == 1)
        #expect(parsed.facts.count(where: { $0.kind == .topic }) == 1)

        let action = parsed.facts.first { $0.kind == .actionItem }!
        #expect(action.assignee == "홍길동")
        // 마감일이 모호하면 dueDate는 비우고 표현만 남긴다.
        #expect(action.dueDate == nil)
        #expect(action.dueDateNote == "다음 주 월요일")
        #expect(action.evidence.first?.startTime == segments[3].startTime)

        let excluded = parsed.relevance.filter { $0.label == .exclude }
        #expect(excluded.count >= 2)
    }

    @Test("위조된 인용은 근거에서 제거된다")
    func dropsFabricatedEvidence() throws {
        let raw = """
        {"decisions": [{"content": "예산 5천만 원 승인", "kind": "decided", "confidence": 0.9,
          "evidence": [{"segment": "S2", "quote": "예산 5천만 원을 승인했습니다"}]}],
         "segmentRelevance": []}
        """
        let parsed = try parser.parse(raw: raw, window: window, meetingId: Fixtures.meetingId)
        #expect(parsed.facts.count == 1)
        #expect(parsed.facts[0].evidence.isEmpty)
        #expect(parsed.problems.contains { $0.contains("확인되지 않은") })
    }

    @Test("구간 분류가 없으면 규칙 판정으로 모든 구간을 채운다")
    func fallsBackToHeuristicLabels() throws {
        let raw = "{\"decisions\": [], \"actionItems\": []}"
        let parsed = try parser.parse(raw: raw, window: window, meetingId: Fixtures.meetingId)
        #expect(parsed.relevance.count == segments.count)
        #expect(parsed.problems.contains { $0.contains("규칙 판정") })
    }
}

@Suite("사고 모드 재검토 응답 파싱")
struct FactReviewParserTests {
    let parser = FactReviewParser()
    let segments = Fixtures.meetingSegments

    @Test("폐기 판정은 후보를 버린다")
    func discardsFact() throws {
        let fact = Fixtures.fact(kind: .decision, content: "근거 없는 결정", decisionKind: .decided)
        let parsed = try parser.parse(
            raw: "{\"verdict\": \"discard\"}",
            original: fact,
            window: Fixtures.window(segments)
        )
        #expect(parsed.verdict == .discard)
        #expect(parsed.fact.discarded)
        #expect(parsed.fact.reviewed)
    }

    @Test("근거가 부족하면 결정을 제안으로 낮춘다")
    func downgradesDecisionWithoutEvidence() throws {
        let fact = Fixtures.fact(kind: .decision, content: "가격 인상 결정", decisionKind: .decided)
        let parsed = try parser.parse(
            raw: "{\"verdict\": \"revise\", \"content\": \"가격 인상은 검토 중\", \"kind\": \"decided\", \"confidence\": 0.5}",
            original: fact,
            window: Fixtures.window(segments)
        )
        #expect(parsed.fact.decisionKind == .proposed)
        #expect(parsed.problems.contains { $0.contains("제안으로 낮춤") })
    }

    @Test("담당자와 마감일이 명시되지 않으면 null로 유지한다")
    func keepsAssigneeNullWhenUnspecified() throws {
        let fact = Fixtures.fact(
            kind: .actionItem,
            content: "회귀 테스트",
            assignee: "추정된담당자",
            evidence: [Fixtures.evidence(for: segments[3])]
        )
        let parsed = try parser.parse(
            raw: "{\"verdict\": \"revise\", \"content\": \"회귀 테스트 진행\", \"assignee\": null, \"dueDate\": null, \"confidence\": 0.7}",
            original: fact,
            window: Fixtures.window(segments)
        )
        #expect(parsed.fact.assignee == nil)
        #expect(parsed.fact.dueDate == nil)
    }

    @Test("사고 블록이 붙어 있어도 판정을 읽어낸다")
    func parsesWithThinkingBlock() throws {
        let fact = Fixtures.fact(
            kind: .decision,
            content: "배포일 확정",
            decisionKind: .decided,
            evidence: [Fixtures.evidence(for: segments[2])]
        )
        let raw = """
        <think>이건 명확한 결정이다. 근거도 있다.</think>
        {"verdict": "confirm", "kind": "decided", "confidence": 0.95,
         "evidence": [{"segment": "S2", "quote": "3월 12일 수요일로 확정합니다"}]}
        """
        let parsed = try parser.parse(raw: raw, original: fact, window: Fixtures.window(segments))
        #expect(parsed.verdict == .confirm)
        #expect(parsed.fact.decisionKind == .decided)
        #expect(parsed.fact.confidence == 0.95)
    }
}

@Suite("최종 회의록 응답 파싱")
struct FinalNoteParserTests {
    let parser = FinalNoteParser()
    let segments = Fixtures.meetingSegments

    func catalog() -> FactCatalog {
        FactCatalog(facts: [
            Fixtures.fact(
                kind: .decision,
                content: "결제 모듈 배포를 3월 12일로 확정",
                decisionKind: .decided,
                evidence: [Fixtures.evidence(for: segments[2])],
                confidence: 0.9
            ),
            Fixtures.fact(
                kind: .actionItem,
                content: "배포 체크리스트 공유",
                assignee: "홍길동",
                dueDateNote: "다음 주 월요일",
                evidence: [Fixtures.evidence(for: segments[3])],
                confidence: 0.8
            )
        ])
    }

    @Test("evidenceIndex로 후보의 근거가 연결된다")
    func linksEvidenceByIndex() throws {
        let raw = """
        {"title": "결제 모듈 배포 회의", "summary": "배포일을 확정했다.",
         "decisions": [{"content": "결제 모듈 배포를 3월 12일로 확정", "kind": "decided", "evidenceIndex": 1}],
         "actionItems": [{"task": "배포 체크리스트 공유", "assignee": "홍길동", "dueDate": null, "status": "confirmed", "evidenceIndex": 1}]}
        """
        let parsed = try parser.parse(
            raw: raw,
            meetingId: Fixtures.meetingId,
            catalog: catalog(),
            fallbackTitle: "회의"
        )
        #expect(parsed.note.decisions.count == 1)
        #expect(parsed.note.decisions[0].kind == .decided)
        #expect(parsed.note.decisions[0].evidence.first?.startTime == segments[2].startTime)
        #expect(parsed.note.actionItems[0].assignee == "홍길동")
        #expect(parsed.note.actionItems[0].dueDate == nil)
        #expect(parsed.note.actionItems[0].dueDateNote == "다음 주 월요일")
    }

    @Test("후보에 없는 담당자·마감일은 무시한다")
    func ignoresUngroundedFields() throws {
        let raw = """
        {"title": "회의", "summary": "요약",
         "actionItems": [{"task": "배포 체크리스트 공유", "assignee": "김철수", "dueDate": "3월 9일", "status": "confirmed", "evidenceIndex": 1}]}
        """
        let parsed = try parser.parse(
            raw: raw,
            meetingId: Fixtures.meetingId,
            catalog: catalog(),
            fallbackTitle: "회의"
        )
        // 후보의 담당자는 홍길동이고 마감일은 없다. 모델이 새로 만든 값은 버린다.
        #expect(parsed.note.actionItems[0].assignee == "홍길동")
        #expect(parsed.note.actionItems[0].dueDate == nil)
        #expect(parsed.problems.contains { $0.contains("마감일 값 무시") })
    }

    @Test("후보에 없는 항목은 회의록에 넣지 않는다")
    func dropsItemsWithoutCandidate() throws {
        // 실제 실행에서 관찰된 실패: 최종 단계가 후보에 없던 문장을 만들어 넣었다.
        let raw = """
        {"title": "회의", "summary": "요약",
         "decisions": [{"content": "인력 2명 추가 채용 확정", "kind": "decided"}],
         "actionItems": [{"task": "녹음 여부 확인", "status": "proposed"},
                         {"task": "녹음 여부 확인", "status": "proposed"}],
         "risks": [{"content": "녹음 여부 확인"}]}
        """
        let parsed = try parser.parse(
            raw: raw,
            meetingId: Fixtures.meetingId,
            catalog: catalog(),
            fallbackTitle: "회의"
        )
        #expect(parsed.note.decisions.isEmpty)
        #expect(parsed.note.actionItems.isEmpty)
        #expect(parsed.note.risks.isEmpty)
        #expect(parsed.problems.contains { $0.contains("후보에 없는 항목이라 회의록에서 제외") })
    }

    @Test("후보에 있으나 근거가 없는 결정은 제안으로 기록한다")
    func downgradesUngroundedCandidate() throws {
        let ungrounded = FactCatalog(facts: [
            Fixtures.fact(
                kind: .decision,
                content: "인력 2명 추가 채용",
                decisionKind: .decided,
                evidence: [],
                confidence: 0.4
            )
        ])
        let raw = """
        {"title": "회의", "summary": "요약",
         "decisions": [{"content": "인력 2명 추가 채용", "kind": "decided", "evidenceIndex": 1}]}
        """
        let parsed = try parser.parse(
            raw: raw,
            meetingId: Fixtures.meetingId,
            catalog: ungrounded,
            fallbackTitle: "회의"
        )
        #expect(parsed.note.decisions.count == 1)
        #expect(parsed.note.decisions[0].kind == .proposed)
        #expect(parsed.note.decisions[0].evidence.isEmpty)
    }

    @Test("같은 내용이 여러 번 오면 한 번만 남긴다")
    func removesDuplicateItems() throws {
        let raw = """
        {"title": "회의", "summary": "요약",
         "actionItems": [
           {"task": "배포 체크리스트 공유", "evidenceIndex": 1},
           {"task": "배포 체크리스트 공유", "evidenceIndex": 1},
           {"task": "배포 체크리스트  공유.", "evidenceIndex": 1}
         ]}
        """
        let parsed = try parser.parse(
            raw: raw,
            meetingId: Fixtures.meetingId,
            catalog: catalog(),
            fallbackTitle: "회의"
        )
        #expect(parsed.note.actionItems.count == 1)
        #expect(parsed.problems.contains { $0.contains("중복 항목") })
    }
}
