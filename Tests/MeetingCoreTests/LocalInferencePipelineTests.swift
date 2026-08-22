import Foundation
import Testing
@testable import MeetingCore

@Suite("추론 파이프라인")
struct LocalInferencePipelineTests {
    func makeModel(
        extraction: @escaping @Sendable (Int) -> String = { _ in FakeResponses.extraction },
        review: (@Sendable (String) -> String)? = nil,
        finalNote: @escaping @Sendable (Int) -> String = { _ in FakeResponses.finalNote },
        repair: @escaping @Sendable (Int) -> String = { _ in FakeResponses.extraction }
    ) -> FakeLanguageModel {
        FakeLanguageModel { call, index in
            switch call.kind {
            case .extraction: extraction(index)
            case .review: review?(call.prompt) ?? FakeResponses.review(for: call.prompt)
            case .finalNote: finalNote(index)
            case .repair: repair(index)
            case .unknown: "{}"
            }
        }
    }

    @Test("전사문에서 근거가 연결된 회의록을 만든다")
    func producesGroundedNote() async throws {
        let model = makeModel()
        let pipeline = LocalInferencePipeline(model: model)
        let segments = Fixtures.meetingSegments

        let output = try await pipeline.generateNote(
            meetingId: Fixtures.meetingId,
            titleHint: "결제 모듈 배포 회의",
            segments: segments
        )

        #expect(output.note.title == "결제 모듈 배포 회의")
        #expect(!output.note.summary.isEmpty)

        // 결정사항: 확정 1건, 제안 1건
        #expect(output.note.decisions.count == 2)
        let decided = output.note.decisions.filter { $0.kind == .decided }
        #expect(decided.count == 1)
        #expect(decided[0].content.contains("3월 12일"))
        // 모든 결정에 원문 근거 타임스탬프가 붙는다.
        #expect(decided[0].evidence.first?.startTime == segments[2].startTime)

        // 액션아이템: 담당자는 원문에서 확인된 값, 마감일은 모호하므로 미확정
        #expect(output.note.actionItems.count == 1)
        let action = output.note.actionItems[0]
        #expect(action.assignee == "박지훈")
        #expect(action.dueDate == nil)
        #expect(action.dueDateDisplay.contains(UnresolvedMarker.needsConfirmation))
        #expect(action.evidence.first?.startTime == segments[3].startTime)

        #expect(output.note.risks.count == 1)
        #expect(output.note.openQuestions.count == 1)
    }

    @Test("사담은 회의록 입력에서 제외되고 전사문은 그대로 남는다")
    func excludesSmallTalk() async throws {
        let model = makeModel()
        let pipeline = LocalInferencePipeline(model: model)
        let segments = Fixtures.meetingSegments
        let output = try await pipeline.generateNote(
            meetingId: Fixtures.meetingId,
            titleHint: "회의",
            segments: segments
        )

        let excluded = output.relevance.filter { $0.label == .exclude }
        #expect(excluded.count >= 4)
        #expect(output.note.generation.excludedSegmentCount >= 4)

        // 회의록 본문에 사담이 남지 않는다.
        let body = output.note.summary
            + output.note.decisions.map(\.content).joined()
            + output.note.actionItems.map(\.task).joined()
        #expect(!body.contains("순대국"))
        #expect(!body.contains("회식"))
        #expect(!body.contains("날씨"))
        // "사담 제외" 같은 표현도 넣지 않는다.
        #expect(!body.contains("사담"))

        // 전사문 자체는 보존된다 (파이프라인은 전사문을 변경하지 않는다).
        #expect(segments.count == 9)
        #expect(segments.contains { $0.text.contains("순대국") })
    }

    @Test("모호한 항목만 사고 모드로 재검토한다")
    func routesOnlyAmbiguousItemsToThinking() async throws {
        let model = makeModel()
        let pipeline = LocalInferencePipeline(model: model)
        let output = try await pipeline.generateNote(
            meetingId: Fixtures.meetingId,
            titleHint: "회의",
            segments: Fixtures.meetingSegments
        )

        let calls = await model.callLog()
        let extractions = calls.filter { $0.kind == .extraction }
        let reviews = calls.filter { $0.kind == .review }

        // 1차 추출은 항상 비사고 모드
        #expect(extractions.allSatisfy { $0.mode == .nonThinking })
        // 재검토는 사고 모드, 그리고 전체 후보보다 적게 일어난다
        #expect(!reviews.isEmpty)
        #expect(reviews.allSatisfy { $0.mode == .thinking })
        #expect(reviews.count < output.note.generation.candidateCount)
        #expect(output.note.generation.thinkingReviewCount == reviews.count)

        // 재검토 결과가 반영돼 보류 항목은 제안으로 남는다.
        #expect(output.note.decisions.contains { $0.kind == .proposed && $0.content.contains("보류") })
    }

    @Test("내부 사고 내용은 결과에 저장되지 않는다")
    func neverPersistsThinking() async throws {
        let model = makeModel()
        let pipeline = LocalInferencePipeline(model: model)
        let output = try await pipeline.generateNote(
            meetingId: Fixtures.meetingId,
            titleHint: "회의",
            segments: Fixtures.meetingSegments
        )
        let serialized = try MeetingNoteExporter.jsonString(output.note)
        #expect(!serialized.contains("<think>"))
        #expect(!serialized.contains("보류라고 했으니"))
    }

    @Test("JSON 파싱이 실패하면 복구 요청 후 계속 진행한다")
    func repairsInvalidJSON() async throws {
        let model = makeModel(extraction: { index in
            index == 0 ? "죄송하지만 JSON을 만들 수 없습니다." : FakeResponses.extraction
        })
        let pipeline = LocalInferencePipeline(model: model)
        let output = try await pipeline.generateNote(
            meetingId: Fixtures.meetingId,
            titleHint: "회의",
            segments: Fixtures.meetingSegments
        )
        #expect(output.note.generation.jsonRepairCount >= 1)
        #expect(!output.note.decisions.isEmpty)
        let calls = await model.callLog()
        #expect(calls.contains { $0.kind == .repair })
    }

    @Test("1차 추출이 완전히 실패해도 규칙 판정으로 사담 분류를 채운다")
    func survivesExtractionFailure() async throws {
        let model = makeModel(
            extraction: { _ in "완전히 잘못된 응답" },
            finalNote: { _ in FakeResponses.finalNote },
            repair: { _ in "여전히 JSON이 아님" }
        )
        let pipeline = LocalInferencePipeline(model: model)
        let output = try await pipeline.generateNote(
            meetingId: Fixtures.meetingId,
            titleHint: "회의",
            segments: Fixtures.meetingSegments
        )
        #expect(output.relevance.count == Fixtures.meetingSegments.count)
        #expect(output.problems.contains { $0.contains("사실 추출 실패") })
        // 후보가 없으므로 근거 없는 항목은 회의록에서 제안으로만 남는다.
        #expect(output.note.decisions.allSatisfy { $0.kind == .proposed || !$0.evidence.isEmpty })
    }

    @Test("최종 종합이 실패해도 검증된 후보로 회의록을 만든다")
    func fallsBackWhenFinalPassFails() async throws {
        let model = makeModel(finalNote: { _ in "JSON 없음" }, repair: { _ in "여전히 없음" })
        let pipeline = LocalInferencePipeline(model: model)
        let output = try await pipeline.generateNote(
            meetingId: Fixtures.meetingId,
            titleHint: "결제 모듈 배포 회의",
            segments: Fixtures.meetingSegments
        )
        #expect(output.problems.contains { $0.contains("생성 실패") })
        #expect(!output.note.decisions.isEmpty)
        #expect(!output.note.actionItems.isEmpty)
        #expect(output.note.actionItems[0].evidence.isEmpty == false)
    }

    @Test("빈 전사문은 오류로 처리한다")
    func rejectsEmptyTranscript() async {
        let pipeline = LocalInferencePipeline(model: makeModel())
        await #expect(throws: InferenceError.self) {
            _ = try await pipeline.generateNote(
                meetingId: Fixtures.meetingId,
                titleHint: "회의",
                segments: []
            )
        }
    }
}

@Suite("사담이 회의록으로 새지 않는다")
struct ChatterLeakTests {
    /// 사담 구간에서 후보를 만들어내는 응답. 실제 실행에서 관찰된 실패 양상이다.
    static let extractionWithChatterFact = """
    {
      "decisions": [],
      "actionItems": [],
      "risks": [],
      "openQuestions": [
        {"question": "회식 일정에 대한 확정 여부", "confidence": 0.6,
         "evidence": [{"segment": "S8", "quote": "다음 주 금요일에 회식하려고 하는데 다들 가능하신가요"}]},
        {"question": "가격 정책이 정해지지 않아 사업팀 확인이 필요", "confidence": 0.7,
         "evidence": [{"segment": "S7", "quote": "아직 정해지지 않았습니다"}]}
      ],
      "topics": [],
      "segmentRelevance": [{"segment": "S8", "label": "CONDENSE"}, {"segment": "S7", "label": "KEEP"}]
    }
    """

    static let finalNote = """
    {"title": "회의", "summary": "가격 정책이 미정이다.",
     "decisions": [], "actionItems": [], "risks": [], "topics": [],
     "openQuestions": [{"question": "가격 정책이 정해지지 않아 사업팀 확인이 필요", "evidenceIndex": 1}]}
    """

    @Test("제외 구간에서만 근거가 나온 후보는 회의록에 들어가지 않는다")
    func dropsChatterOnlyFacts() async throws {
        let model = FakeLanguageModel { call, _ in
            switch call.kind {
            case .extraction: Self.extractionWithChatterFact
            case .finalNote: Self.finalNote
            case .review: FakeResponses.review(for: call.prompt)
            default: "{}"
            }
        }
        let pipeline = LocalInferencePipeline(model: model)
        let output = try await pipeline.generateNote(
            meetingId: Fixtures.meetingId,
            titleHint: "회의",
            segments: Fixtures.meetingSegments
        )

        #expect(output.problems.contains { $0.contains("제외 구간에서만 근거가 나온 후보 제거") })
        #expect(!output.note.openQuestions.contains { $0.question.contains("회식") })
        // 업무 관련 미해결 질문은 남는다.
        #expect(output.note.openQuestions.contains { $0.question.contains("가격 정책") })
    }
}

@Suite("사고 모드 토큰 소진 복구")
struct ThinkingBudgetRecoveryTests {
    @Test("사고가 토큰을 다 써서 본문이 비면 같은 작업을 비사고 모드로 다시 시킨다")
    func retriesInNonThinkingWhenOutputEmpty() async throws {
        // 최종 종합을 사고 모드로 돌릴 상황을 만들고, 사고 모드 응답만 비워 둔다.
        let model = FakeLanguageModel { call, _ in
            switch call.kind {
            case .extraction: FakeResponses.extraction
            case .review: FakeResponses.review(for: call.prompt)
            case .finalNote: call.mode == .thinking ? "" : FakeResponses.finalNote
            case .repair, .unknown: "{}"
            }
        }
        let pipeline = LocalInferencePipeline(model: model)
        let output = try await pipeline.generateNote(
            meetingId: Fixtures.meetingId,
            titleHint: "결제 모듈 배포 회의",
            segments: Fixtures.meetingSegments
        )

        // 회의록이 비지 않는다.
        #expect(!output.note.summary.isEmpty)
        #expect(!output.note.decisions.isEmpty)
        #expect(output.note.generation.finalPassUsedThinking)
        #expect(output.note.generation.jsonRepairCount >= 1)

        // 비사고 모드로 같은 최종 종합 프롬프트를 다시 시켰다 (형식 복구 프롬프트가 아니다).
        let calls = await model.callLog()
        let finalCalls = calls.filter { $0.kind == .finalNote }
        #expect(finalCalls.count == 2)
        #expect(finalCalls[0].mode == .thinking)
        #expect(finalCalls[1].mode == .nonThinking)
    }
}
