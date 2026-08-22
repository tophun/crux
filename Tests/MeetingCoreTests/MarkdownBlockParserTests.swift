import Foundation
import Testing

@testable import MeetingCore

@Suite("회의록 마크다운 미리보기")
struct MarkdownBlockParserTests {
    /// 내보내기와 같은 회의록을 만든다.
    private func makeNote() -> (MeetingNote, Meeting) {
        let meeting = Meeting(
            title: "주간 회의",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_003_600),
            storageDirectory: URL(fileURLWithPath: "/tmp")
        )
        let evidence = [Evidence(segmentId: UUID().uuidString, startTime: 65, endTime: 70, quote: "배포는 목요일에 합니다")]
        let note = MeetingNote(
            meetingId: meeting.id,
            title: "주간 회의 정리",
            summary: "배포 일정과 담당자를 정했다.",
            decisions: [
                Decision(content: "목요일 배포", kind: .decided, evidence: evidence),
                Decision(content: "성능 개선 검토", kind: .proposed, evidence: evidence)
            ],
            actionItems: [
                ActionItem(task: "체크리스트 작성", assignee: "홍길동", dueDate: "2026-03-12", evidence: evidence)
            ],
            openQuestions: [OpenQuestion(question: "서버 증설 범위", evidence: evidence)],
            risks: [RiskItem(content: "회귀 테스트 시간 부족", evidence: evidence)],
            topics: [Topic(title: "배포", summary: "일정 확정")]
        )
        return (note, meeting)
    }

    @Test("내보내기 결과의 모든 내용 줄이 블록으로 남는다 — 미리보기가 내용을 삼키면 안 된다")
    func keepsEveryContentLine() {
        let (note, meeting) = makeNote()
        let markdown = MeetingNoteExporter.markdown(note, meeting: meeting)
        let blocks = MarkdownBlockParser.parse(markdown)

        let contentLines = markdown
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        // 표 구분선은 화면에 그리지 않으므로 셈에서 뺀다.
        let separatorCount = contentLines.count(where: { $0.hasPrefix("| ---") })
        let tableRowCount = blocks.reduce(0) { total, block in
            if case let .table(headers, rows) = block {
                return total + (headers.isEmpty ? 0 : 1) + rows.count
            }
            return total
        }
        let nonTableBlocks = blocks.filter { if case .table = $0 { false } else { true } }
        #expect(nonTableBlocks.count + tableRowCount == contentLines.count - separatorCount)
    }

    @Test("제목 단계를 구분한다")
    func parsesHeadings() {
        let blocks = MarkdownBlockParser.parse("# 회의록\n\n## 요약\n내용")
        #expect(blocks == [
            .heading(level: 1, text: "회의록"),
            .heading(level: 2, text: "요약"),
            .paragraph(text: "내용")
        ])
    }

    @Test("Action Item 체크리스트를 상태와 함께 읽는다")
    func parsesChecklist() {
        #expect(MarkdownBlockParser.parse("- [ ] 예시 1") == [.checklist(text: "예시 1", done: false)])
        #expect(MarkdownBlockParser.parse("- [x] 끝난 일") == [.checklist(text: "끝난 일", done: true)])
        // 대괄호가 없는 줄은 그대로 목록이다.
        #expect(MarkdownBlockParser.parse("- 그냥 목록") == [.bullet(text: "그냥 목록")])
    }

    @Test("목록의 앞 기호는 떼고 본문만 남긴다")
    func parsesBullets() {
        #expect(MarkdownBlockParser.parse("- 목요일 배포") == [.bullet(text: "목요일 배포")])
    }

    @Test("액션아이템 표는 머리글과 행으로 나뉘고 구분선은 버린다")
    func parsesTable() {
        let markdown = """
        | 작업 | 담당자 |
        | --- | --- |
        | 체크리스트 작성 | 홍길동 |
        | 배포 준비 | 미확정 |
        """
        #expect(MarkdownBlockParser.parse(markdown) == [
            .table(
                headers: ["작업", "담당자"],
                rows: [["체크리스트 작성", "홍길동"], ["배포 준비", "미확정"]]
            )
        ])
    }

    @Test("회의록 마크다운에는 전사문이 들어가지 않는다")
    func excludesTranscript() {
        let (note, meeting) = makeNote()
        let markdown = MeetingNoteExporter.markdown(note, meeting: meeting)
        #expect(!markdown.contains("## 전사문"))
        #expect(!markdown.contains("전사"))
        // 근거 인용문 자체도 본문에 풀어 놓지 않는다.
        #expect(!markdown.contains("배포는 목요일에 합니다"))
    }
}
