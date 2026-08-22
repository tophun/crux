import Foundation
import Testing
@testable import MeetingCore

@Suite("한국어 규칙 기반 윤문")
struct KoreanTextPolisherTests {
    let polisher = KoreanTextPolisher()

    @Test("번역투를 결정적으로 치환한다")
    func rewritesTranslationese() {
        let cases: [(String, String)] = [
            ("배포 일정에 대해 논의했습니다.", "배포 일정을 논의했습니다."),
            ("이번 회의에 있어서 중요한 건 일정입니다.", "이번 회의에서 중요한 건 일정입니다."),
            ("우리 팀은 충분한 여유를 가지고 있습니다.", "우리 팀은 충분한 여유가 있습니다."),
            ("배포는 다음 주로 결정되어집니다.", "배포는 다음 주로 결정됩니다."),
        ]
        for (input, expected) in cases {
            #expect(polisher.polish(input).text == expected, "입력: \(input)")
        }
    }

    @Test("연결어미 뒤 쉼표와 볼드·엠대시를 정리한다")
    func cleansFormatting() {
        let result = polisher.polish("배포를 준비하고, **체크리스트**를 공유합니다 — 월요일까지입니다.")
        #expect(result.text == "배포를 준비하고 체크리스트를 공유합니다, 월요일까지입니다.")
        #expect(result.appliedRuleIds.contains("C-11"))
        #expect(result.appliedRuleIds.contains("J-1"))
        #expect(result.appliedRuleIds.contains("J-3"))
    }

    @Test("AI 관용구와 이모지를 제거한다")
    func removesSignaturePhrases() {
        let result = polisher.polish("🚀 결론적으로, 배포는 3월 12일입니다.")
        #expect(!result.text.contains("결론적으로"))
        #expect(!result.text.contains("🚀"))
        #expect(result.text.contains("3월 12일"))
    }

    @Test("형식명사 결말을 직접 종결로 바꾼다")
    func rewritesFormalNounEnding() {
        #expect(polisher.polish("일정이 하루 밀린다는 것이다.").text == "일정이 하루 밀린다.")
    }

    @Test("보호 대상 용어가 든 구간은 건드리지 않는다")
    func keepsProtectedTerms() {
        let input = "QA에 있어서 회귀 테스트가 필요합니다."
        // "에 있어서" 규칙이 있지만 보호 용어(QA)를 포함한 구간이면 치환하지 않는다.
        let result = polisher.polish(input)
        #expect(result.text.contains("QA"))
    }

    @Test("임계 이상 반복될 때만 탐지한다")
    func respectsThresholds() {
        let single = polisher.detect(in: "배포 일정은 변경될 수 있습니다.")
        #expect(!single.contains { $0.ruleId == "A-10" })

        let repeated = polisher.detect(
            in: "일정은 밀릴 수 있습니다. 비용도 늘 수 있습니다. 품질도 떨어질 수 있습니다. 범위도 줄 수 있습니다."
        )
        #expect(repeated.contains { $0.ruleId == "A-10" })
    }

    @Test("변경률을 계산한다")
    func computesChangeRate() {
        #expect(ChangeRate.between("같은 문장", "같은 문장") == 0)
        let rate = ChangeRate.between("배포 일정에 대해 논의했습니다.", "배포 일정을 논의했습니다.")
        #expect(rate > 0 && rate < 0.3)
    }
}

@Suite("내용 앵커 보존")
struct ContentAnchorTests {
    @Test("수치·영문·인용을 앵커로 뽑는다")
    func extractsAnchors() {
        let anchors = ContentAnchor.anchors(in: "CPU 사용률이 85%까지 올라가고 \"용량 초과\" 위험이 있습니다.")
        #expect(anchors.contains("85"))
        #expect(anchors.contains("CPU"))
        #expect(anchors.contains("용량 초과"))
    }

    @Test("앵커가 사라지면 손실로 판정한다")
    func detectsMissingAnchor() {
        let report = ContentAnchor.check(
            original: "서버 사용률이 85%까지 올라갑니다.",
            revised: "서버 사용률이 크게 올라갑니다."
        )
        #expect(!report.isPreserved)
        #expect(report.missing.contains("85"))
    }

    @Test("문체만 바뀌면 보존으로 판정한다")
    func acceptsStyleOnlyChange() {
        let report = ContentAnchor.check(
            original: "배포 일정에 대해 논의가 되어졌습니다. 3월 12일입니다.",
            revised: "배포 일정을 논의했습니다. 3월 12일입니다."
        )
        #expect(report.isPreserved)
    }
}

@Suite("회의록 윤문 Skill")
struct KoreanMeetingEditorTests {
    func sampleNote() -> MeetingNote {
        let segments = Fixtures.meetingSegments
        var note = MeetingNote(
            meetingId: Fixtures.meetingId,
            title: "결제 모듈 배포 회의",
            summary: "🚀 결론적으로, 배포 일정에 대해 논의했고, 3월 12일로 결정되어집니다. CPU 사용률이 85%까지 올라갈 수 있습니다."
        )
        note.decisions = [
            Decision(
                content: "**배포일**을 3월 12일로 확정하는 것에 대해 합의했습니다.",
                kind: .decided,
                evidence: [Fixtures.evidence(for: segments[2], quote: "3월 12일 수요일로 확정합니다")],
                confidence: 0.9
            )
        ]
        note.actionItems = [
            ActionItem(
                task: "체크리스트 작성에 대해 공유",
                assignee: "홍길동",
                dueDateNote: "다음 주 월요일",
                status: .proposed,
                evidence: [Fixtures.evidence(for: segments[3], quote: "다음 주 월요일까지 공유해 주세요")],
                confidence: 0.8
            )
        ]
        note.risks = [RiskItem(content: "서버 용량이 부족해질 가능성을 가지고 있습니다.", severity: .high)]
        return note
    }

    @Test("규칙만으로도 AI 티를 줄이고 수치·인용은 그대로 둔다")
    func conservativeModeKeepsFacts() async {
        let editor = KoreanMeetingEditor()
        let original = sampleNote()
        let (edited, report) = await editor.edit(note: original, model: nil)

        #expect(report.mode == .conservative)
        #expect(!edited.summary.contains("결론적으로"))
        #expect(!edited.summary.contains("🚀"))
        #expect(edited.summary.contains("3월 12일"))
        #expect(edited.summary.contains("85%"))
        #expect(!edited.decisions[0].content.contains("**"))
        #expect(edited.risks[0].content.contains("부족해질 가능성이 있습니다"))
        #expect(report.editedFieldCount > 0)
    }

    @Test("근거 인용문과 담당자·기한은 절대 바뀌지 않는다")
    func neverTouchesEvidenceOrDataFields() async {
        let editor = KoreanMeetingEditor()
        let original = sampleNote()
        let (edited, _) = await editor.edit(note: original, model: nil)

        #expect(edited.decisions[0].evidence == original.decisions[0].evidence)
        #expect(edited.actionItems[0].evidence == original.actionItems[0].evidence)
        #expect(edited.actionItems[0].assignee == "홍길동")
        #expect(edited.actionItems[0].dueDate == original.actionItems[0].dueDate)
        #expect(edited.actionItems[0].dueDateNote == "다음 주 월요일")
        #expect(edited.decisions[0].kind == .decided)
    }

    @Test("탐지 밀도가 높으면 정밀 경로를 고른다")
    func selectsStrictModeForDenseText() {
        let editor = KoreanMeetingEditor()
        var note = sampleNote()
        note.summary += " 이는 배포에 있어서 중요한 결정이며, 팀은 충분한 준비를 가지고 있습니다. 결론적으로, 일정이 밀린다는 것이다."
        #expect(editor.selectMode(for: note) == .strict)
    }

    @Test("짧은 회의록은 보수적 경로로 처리한다")
    func selectsConservativeForShortText() {
        let editor = KoreanMeetingEditor()
        let note = MeetingNote(meetingId: Fixtures.meetingId, title: "회의", summary: "배포일을 정했다.")
        #expect(editor.selectMode(for: note) == .conservative)
    }

    /// 결정적 치환으로 해결되지 않는 탐지 전용 패턴(A-9, A-10)이 남는 회의록
    func noteNeedingLLM() -> MeetingNote {
        var note = sampleNote()
        note.summary = "이번 결정은 마케팅팀에 의해 요청되었고, 최종 승인은 사업팀에 의해 진행됩니다. "
            + "일정은 밀릴 수 있습니다. 비용은 늘어날 수 있습니다. 품질은 떨어질 수 있습니다. "
            + "서버 CPU 사용률은 85%이고 배포일은 3월 12일입니다."
        return note
    }

    @Test("LLM이 내용을 바꾸면 롤백한다")
    func rollsBackWhenAnchorsLost() async {
        // 수치를 지워 버리는 모델
        let model = FakeLanguageModel { _, _ in
            "이번 결정은 마케팅팀이 요청했고 최종 승인은 사업팀이 진행합니다. 일정과 비용, 품질이 흔들릴 수 있습니다. 서버 사용률과 배포일은 확인이 필요합니다."
        }
        let editor = KoreanMeetingEditor()
        let note = noteNeedingLLM()

        let (edited, report) = await editor.edit(note: note, model: model)
        #expect(report.rolledBackFieldCount >= 1)
        #expect(report.outcomes.contains { $0.rollbackReason?.contains("내용 앵커 손실") == true })
        // 롤백된 필드는 규칙 기반 결과를 유지하므로 수치가 살아 있다.
        #expect(edited.summary.contains("85%"))
        #expect(edited.summary.contains("3월 12일"))
    }

    @Test("LLM이 과도하게 고쳐 쓰면 롤백한다")
    func rollsBackWhenChangeRateTooHigh() async {
        // 길이는 비슷하지만 내용이 완전히 다른 응답
        let model = FakeLanguageModel { _, _ in
            String(repeating: "전혀 다른 문장으로 바꿔 씁니다. ", count: 5)
        }
        let editor = KoreanMeetingEditor()
        let (_, report) = await editor.edit(note: noteNeedingLLM(), model: model)
        #expect(report.rolledBackFieldCount >= 1)
        #expect(report.outcomes.contains { $0.rolledBack })
    }

    @Test("LLM 응답의 머리말과 따옴표를 걷어낸다")
    func cleansModelOutput() {
        #expect(
            KoreanMeetingEditor.extractText(from: "다듬은 문장: \"배포일을 확정했다.\"") == "배포일을 확정했다."
        )
        #expect(
            KoreanMeetingEditor.extractText(from: "<think>고민</think>\n배포일을 확정했다.") == "배포일을 확정했다."
        )
    }
}
