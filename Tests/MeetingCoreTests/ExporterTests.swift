import Foundation
import Testing
@testable import MeetingCore

@Suite("회의록 내보내기")
struct MeetingNoteExporterTests {
    func sampleNote() -> MeetingNote {
        let segments = Fixtures.meetingSegments
        var note = MeetingNote(meetingId: Fixtures.meetingId, title: "결제 모듈 배포 회의", summary: "배포일 확정")
        note.decisions = [
            Decision(
                content: "배포를 3월 12일로 확정",
                kind: .decided,
                evidence: [Fixtures.evidence(for: segments[2])],
                confidence: 0.9
            )
        ]
        note.actionItems = [
            ActionItem(
                task: "체크리스트 공유",
                assignee: "박지훈",
                dueDate: nil,
                dueDateNote: "다음 주 월요일",
                status: .confirmed,
                evidence: [Fixtures.evidence(for: segments[3])],
                confidence: 0.8
            ),
            ActionItem(task: "회귀 테스트", assignee: nil, dueDate: nil, status: .proposed)
        ]
        note.risks = [RiskItem(content: "서버 용량 한계", severity: .high)]
        note.openQuestions = [OpenQuestion(question: "가격 정책 미정")]
        return note
    }

    @Test("JSON은 명세의 최상위 구조를 따른다")
    func jsonMatchesSpecShape() throws {
        let data = try MeetingNoteExporter.json(sampleNote())
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        for key in ["title", "summary", "decisions", "actionItems", "openQuestions", "risks", "topics"] {
            #expect(object[key] != nil, "누락된 키: \(key)")
        }
        let decisions = object["decisions"] as! [[String: Any]]
        #expect(decisions[0]["content"] as? String == "배포를 3월 12일로 확정")
        let evidence = decisions[0]["evidence"] as! [[String: Any]]
        #expect(evidence[0]["segmentId"] != nil)
        #expect(evidence[0]["startTime"] != nil)
        #expect(evidence[0]["quote"] != nil)

        let actions = object["actionItems"] as! [[String: Any]]
        // 근거 없는 담당자·마감일은 null로 남는다.
        #expect(actions[1]["assignee"] is NSNull || actions[1]["assignee"] == nil)
        #expect(actions[1]["status"] as? String == "proposed")
    }

    @Test("회의록 문서는 날짜·참여자·내용·Action Item 순서로 만들어진다")
    func markdownStructure() {
        let markdown = MeetingNoteExporter.markdown(sampleNote(), attendees: ["정상훈", "박지훈"])
        let order = ["## 날짜", "## 참여자", "## 내용", "### 요약", "### 논의", "## Action Item"]
        var cursor = markdown.startIndex
        for heading in order {
            let found = markdown.range(of: heading, range: cursor..<markdown.endIndex)
            #expect(found != nil, "\(heading)이 순서대로 나와야 한다")
            cursor = found?.upperBound ?? cursor
        }
        #expect(markdown.contains("- 정상훈"))
        #expect(markdown.contains("- 박지훈"))
    }

    @Test("참석자를 모르면 지어내지 않고 미확정으로 남긴다")
    func markdownWithoutAttendees() {
        let markdown = MeetingNoteExporter.markdown(sampleNote())
        #expect(markdown.contains("## 참여자\n- \(UnresolvedMarker.undetermined)"))
    }

    @Test("논의는 표로, Action Item은 체크리스트로 만든다")
    func markdownUsesTableAndChecklist() {
        let markdown = MeetingNoteExporter.markdown(sampleNote())
        #expect(markdown.contains("| 주제 | 내용 |"))
        #expect(markdown.contains("| --- | --- |"))
        #expect(markdown.contains("- [ ] "))
        #expect(markdown.contains("박지훈"))
        #expect(markdown.contains(UnresolvedMarker.undetermined))
    }

    @Test("결정은 있을 때만 만들고 리스크·미해결도 마찬가지다")
    func markdownOmitsEmptySections() {
        let empty = MeetingNote(meetingId: UUID(), title: "빈 회의", summary: "내용 없음")
        let markdown = MeetingNoteExporter.markdown(empty)
        #expect(!markdown.contains("### 결정"))
        #expect(!markdown.contains("### 리스크"))
        #expect(!markdown.contains("### 미해결"))
        // 논의 표와 Action Item 자리는 항상 남는다.
        #expect(markdown.contains("### 논의"))
        #expect(markdown.contains("## Action Item"))
    }

    @Test("문서에는 전사문도 근거 타임스탬프도 넣지 않는다")
    func markdownHasNoEvidence() {
        let markdown = MeetingNoteExporter.markdown(sampleNote())
        #expect(!markdown.contains("근거:"))
        #expect(!markdown.contains("00:20"))
        #expect(!markdown.contains("사담"))
        #expect(markdown.contains("배포를 3월 12일로 확정"))
    }
}

@Suite("문서 구성기")
struct DocumentComposerTests {
    @Test("짧거나 빈 프롬프트는 구성 단계를 건너뛴다")
    func skipsEmptyPrompt() {
        #expect(!DocumentComposer.isUsable(prompt: ""))
        #expect(!DocumentComposer.isUsable(prompt: "  요약 "))
        #expect(DocumentComposer.isUsable(prompt: "한 문단 요약과 할 일 목록만 만들어 줘"))
    }

    @Test("프롬프트에는 검증된 회의록 내용만 들어간다 — 전사문·근거는 없다")
    func promptContainsOnlyVerifiedFacts() {
        let note = MeetingNote(meetingId: UUID(), title: "주간 회의", summary: "배포 확정")
        let built = DocumentComposer.buildPrompt(note: note, meeting: nil, userPrompt: "표로 정리")
        #expect(built.user.contains("배포 확정"))
        #expect(built.user.contains("표로 정리"))
        #expect(!built.user.contains("전사"))
        #expect(built.system.contains("없는 사실"))
    }

    @Test("코드 블록 포장과 빈 출력은 정리한다")
    func cleansOutput() {
        #expect(DocumentComposer.clean("```markdown\n# 회의\n내용이 충분히 긴 문서입니다.\n```") == "# 회의\n내용이 충분히 긴 문서입니다.")
        #expect(DocumentComposer.clean("  \n") == nil)
        #expect(DocumentComposer.clean("짧음") == nil)
    }

    @Test("구성 문서가 있으면 그것을, 없으면 기본 구성을 쓴다")
    func documentPrefersCustom() {
        var note = MeetingNote(meetingId: UUID(), title: "회의", summary: "요약")
        #expect(MeetingNoteExporter.document(note).contains("## 날짜"))
        note.customDocument = "# 내 마음대로 구성한 문서"
        #expect(MeetingNoteExporter.document(note) == "# 내 마음대로 구성한 문서")
    }
}
