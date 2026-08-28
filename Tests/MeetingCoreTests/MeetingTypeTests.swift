import Foundation
@testable import MeetingCore
import Testing

@Suite("회의 유형 템플릿")
struct MeetingTypeTests {
    @Test("문자열을 유형으로 읽고, 모르면 nil라서 기본 일반으로 둘 수 있다")
    func parsesKnownValues() {
        #expect(MeetingType.parse("general") == .general)
        #expect(MeetingType.parse("일반") == .general)
        #expect(MeetingType.parse("scrum") == .scrum)
        #expect(MeetingType.parse("one-on-one") == .oneOnOne)
        #expect(MeetingType.parse("1:1") == .oneOnOne)
        #expect(MeetingType.parse("review") == .review)
        #expect(MeetingType.parse("리뷰") == .review)
        #expect(MeetingType.parse("unknown") == nil)
        #expect(MeetingType.parse("") == nil)
    }

    @Test("일반은 강조 문구가 없고 다른 유형만 강조한다", arguments: MeetingType.allCases)
    func emphasisOnlyForPickedTypes(type: MeetingType) {
        if type == .general {
            #expect(type.extractionEmphasis == nil)
            #expect(type.finalNoteEmphasis == nil)
        } else {
            #expect(type.extractionEmphasis != nil)
            #expect(type.finalNoteEmphasis != nil)
        }
    }
}

@Suite("회의 유형 프롬프트")
struct MeetingTypePromptTests {
    func window() -> TranscriptWindow {
        let segment = TranscriptSegment(
            meetingId: Fixtures.meetingId,
            index: 0,
            startTime: 0,
            endTime: 5,
            text: "배포를 수요일로 확정합니다."
        )
        return TranscriptWindow(index: 0, segments: [segment], contextSegments: [])
    }

    func catalog() -> FactCatalog {
        FactCatalog(facts: [])
    }

    @Test("일반 프롬프트는 유형 강조가 없고 사담·근거 규칙은 그대로다")
    func generalPromptMatchesSharedRules() {
        let extraction = PromptLibrary.windowExtraction(window: window())
        let typed = PromptLibrary.windowExtraction(window: window(), meetingType: .general)
        #expect(extraction == typed)
        #expect(!extraction.contains("스크럼"))
        #expect(!extraction.contains("1:1"))
        #expect(!extraction.contains("리뷰다"))
        #expect(extraction.contains("EXCLUDE"))
        #expect(extraction.contains("evidence"))

        let final = PromptLibrary.finalNote(
            meetingTitleHint: "회의",
            catalog: catalog(),
            transcriptDigest: "요약"
        )
        let typedFinal = PromptLibrary.finalNote(
            meetingTitleHint: "회의",
            catalog: catalog(),
            transcriptDigest: "요약",
            meetingType: .general
        )
        #expect(final == typedFinal)
        #expect(!final.contains("이 회의는"))
        #expect(final.contains("사담은 이미 제외됨"))
        #expect(final.contains("evidenceIndex"))
    }

    @Test("유형별 추출·최종 프롬프트는 강조만 다르고 사담·근거 규칙은 공통이다", arguments: MeetingType.allCases)
    func typePromptsKeepSharedRules(type: MeetingType) throws {
        let extraction = PromptLibrary.windowExtraction(window: window(), meetingType: type)
        let final = PromptLibrary.finalNote(
            meetingTitleHint: "회의",
            catalog: catalog(),
            transcriptDigest: "요약",
            meetingType: type
        )
        #expect(extraction.contains("EXCLUDE"))
        #expect(extraction.contains("KEEP"))
        #expect(extraction.contains("evidence"))
        #expect(final.contains("사담은 이미 제외됨"))
        #expect(final.contains("evidenceIndex"))
        #expect(PromptLibrary.systemPrompt.contains("전사문에 없는 사실을 만들지 않는다"))

        if type == .general {
            #expect(extraction.contains("이 구간에서 다음을 추출하라.\n"))
            #expect(!final.contains("8. 이 회의는"))
        } else {
            let emphasis = try #require(type.extractionEmphasis)
            #expect(extraction.contains(emphasis))
            let finalEmphasis = try #require(type.finalNoteEmphasis)
            #expect(final.contains(finalEmphasis))
        }
    }
}

@Suite("회의 유형 섹션 구성")
struct MeetingTypeSectionTests {
    func sampleNote() -> MeetingNote {
        var note = MeetingNote(meetingId: Fixtures.meetingId, title: "결제 모듈 배포 회의", summary: "배포일 확정")
        note.decisions = [
            Decision(content: "배포를 3월 12일로 확정", kind: .decided),
            Decision(content: "증설은 다음 주에 검토", kind: .proposed)
        ]
        note.actionItems = [
            ActionItem(task: "체크리스트 공유", assignee: "홍길동", status: .confirmed),
            ActionItem(task: "회귀 테스트 완료", status: .done)
        ]
        note.risks = [RiskItem(content: "서버 용량 한계")]
        note.openQuestions = [OpenQuestion(question: "가격 정책 미정")]
        note.topics = [Topic(title: "배포 일정", summary: "3월 배포")]
        return note
    }

    func meeting(_ type: MeetingType) -> Meeting {
        var meeting = Meeting(
            title: "회의",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            storageDirectory: URL(fileURLWithPath: "/tmp")
        )
        meeting.meetingType = type
        return meeting
    }

    func headings(in markdown: String) -> [String] {
        markdown.split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { $0.hasPrefix("##") }
    }

    @Test("유형을 고르지 않으면 지금 문서와 같다")
    func omittedTypeMatchesGeneral() {
        let note = sampleNote()
        let withoutMeeting = MeetingNoteExporter.markdown(note)
        let general = MeetingNoteExporter.markdown(note, meeting: meeting(.general))
        #expect(headings(in: withoutMeeting) == headings(in: general))
        #expect(headings(in: withoutMeeting) == [
            "## 날짜", "## 참여자", "## 내용", "### 요약", "### 결정",
            "### 논의", "### 리스크", "### 미해결", "## Action Item"
        ])
        #expect(!withoutMeeting.contains("### 한 일"))
        #expect(!withoutMeeting.contains("### 이슈"))
        #expect(!withoutMeeting.contains("### 약속"))
    }

    @Test("스크럼은 한 일·이슈를 앞에 두고 완료 액션을 한 일로 옮긴다")
    func scrumEmphasizesDoneAndIssues() {
        let markdown = MeetingNoteExporter.markdown(sampleNote(), meeting: meeting(.scrum))
        #expect(headings(in: markdown) == [
            "## 날짜", "## 참여자", "## 내용", "### 요약", "### 한 일",
            "### 이슈", "### 논의", "### 결정", "### 미해결", "## Action Item"
        ])
        #expect(markdown.contains("### 한 일\n- 배포 일정 — 3월 배포\n- 회귀 테스트 완료"))
        #expect(markdown.contains("### 이슈\n- 서버 용량 한계"))
        #expect(markdown.contains("- [ ] 체크리스트 공유"))
        #expect(!markdown.contains("- [x] 회귀 테스트 완료"))
        #expect(!markdown.contains("### 리스크"))
    }

    @Test("1:1은 약속 섹션이 Action Item을 대신한다")
    func oneOnOneEmphasizesCommitments() {
        let markdown = MeetingNoteExporter.markdown(sampleNote(), meeting: meeting(.oneOnOne))
        #expect(headings(in: markdown) == [
            "## 날짜", "## 참여자", "## 내용", "### 요약", "### 약속",
            "### 논의", "### 결정", "### 리스크", "### 미해결"
        ])
        #expect(markdown.contains("### 약속"))
        #expect(markdown.contains("- [ ] 체크리스트 공유"))
        #expect(!markdown.contains("## Action Item"))
    }

    @Test("리뷰는 결정·리스크를 요약 바로 뒤에 항상 둔다")
    func reviewEmphasizesDecisionsAndRisks() {
        let markdown = MeetingNoteExporter.markdown(sampleNote(), meeting: meeting(.review))
        #expect(headings(in: markdown) == [
            "## 날짜", "## 참여자", "## 내용", "### 요약", "### 결정",
            "### 리스크", "### 논의", "### 미해결", "## Action Item"
        ])
        let empty = MeetingNote(meetingId: UUID(), title: "빈 리뷰", summary: "내용 없음")
        let emptyMarkdown = MeetingNoteExporter.markdown(empty, meeting: meeting(.review))
        #expect(emptyMarkdown.contains("### 결정\n- 없음"))
        #expect(emptyMarkdown.contains("### 리스크\n- 없음"))
        let generalEmpty = MeetingNoteExporter.markdown(empty)
        #expect(!generalEmpty.contains("### 결정"))
        #expect(!generalEmpty.contains("### 리스크"))
    }

    @Test("유형이 달라도 문서에 전사문·근거 타임스탬프는 넣지 않는다", arguments: MeetingType.allCases)
    func noEvidenceInTypedDocuments(type: MeetingType) {
        let markdown = MeetingNoteExporter.markdown(sampleNote(), meeting: meeting(type))
        #expect(!markdown.contains("근거:"))
        #expect(!markdown.contains("사담"))
    }
}

@Suite("회의 유형 파이프라인")
struct MeetingTypePipelineTests {
    func makeModel() -> FakeLanguageModel {
        FakeLanguageModel { call, _ in
            switch call.kind {
            case .extraction: FakeResponses.extraction
            case .review: FakeResponses.review(for: call.prompt)
            case .finalNote: FakeResponses.finalNote
            case .repair, .unknown: "{}"
            }
        }
    }

    @Test("유형을 고르면 프롬프트가 바뀌고, 일반은 지금과 같다", arguments: MeetingType.allCases)
    func pipelinePromptsFollowType(type: MeetingType) async throws {
        let model = makeModel()
        let pipeline = LocalInferencePipeline(model: model)
        _ = try await pipeline.generateNote(
            meetingId: Fixtures.meetingId,
            titleHint: "회의",
            segments: Fixtures.meetingSegments,
            meetingType: type
        )
        let calls = await model.callLog()
        let extraction = try #require(calls.first { $0.kind == .extraction }?.prompt)
        let final = try #require(calls.first { $0.kind == .finalNote }?.prompt)

        #expect(extraction.contains("EXCLUDE"))
        #expect(extraction.contains("evidence"))
        #expect(final.contains("사담은 이미 제외됨"))

        if type == .general {
            #expect(!extraction.contains("이 구간은 스크럼"))
            #expect(!extraction.contains("이 구간은 1:1"))
            #expect(!extraction.contains("이 구간은 리뷰"))
            #expect(!final.contains("8. 이 회의는"))
        } else {
            let emphasis = try #require(type.extractionEmphasis)
            #expect(extraction.contains(emphasis))
            let finalEmphasis = try #require(type.finalNoteEmphasis)
            #expect(final.contains(finalEmphasis))
        }
    }

    @Test("유형과 관계없이 사담은 회의록에서 빠진다", arguments: MeetingType.allCases)
    func smallTalkDroppedForEveryType(type: MeetingType) async throws {
        let model = makeModel()
        let pipeline = LocalInferencePipeline(model: model)
        let output = try await pipeline.generateNote(
            meetingId: Fixtures.meetingId,
            titleHint: "회의",
            segments: Fixtures.meetingSegments,
            meetingType: type
        )
        let body = output.note.summary
            + output.note.decisions.map(\.content).joined()
            + output.note.actionItems.map(\.task).joined()
        #expect(!body.contains("순대국"))
        #expect(!body.contains("회식"))
        #expect(!body.contains("날씨"))
        #expect(output.note.generation.excludedSegmentCount >= 4)
    }
}
