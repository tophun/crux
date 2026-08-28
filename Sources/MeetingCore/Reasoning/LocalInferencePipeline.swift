import Foundation

/// 전사문 → 회의록 생성의 전체 추론 흐름(§8).
///
///   전사문
///     → 구간별 빠른 사실 추출 (비사고 모드)
///     → 복잡도·불확실성 평가 (규칙)
///     → 필요한 항목만 사고 모드 재검토
///     → 반복 발언 통합 + 근거 검증
///     → 최종 회의록 생성 (필요할 때만 사고 모드)
///
/// 사용자에게 사고 모드를 노출하지 않으며 내부 사고 내용은 어디에도 저장하지 않는다.
public struct LocalInferencePipeline: Sendable {
    public struct Configuration: Sendable {
        public var chunker: TranscriptChunker
        public var router: ReasoningRouter
        public var policy: RelevancePolicy
        public var validator: EvidenceValidator
        public var deduplicator: FactDeduplicator
        public var digestBuilder: TranscriptDigestBuilder
        /// 1차 추출 응답 토큰 한계
        public var extractionMaxTokens: Int
        /// 사고 모드 재검토 응답 토큰 한계 (사고 과정 포함)
        public var reviewMaxTokens: Int
        /// 최종 종합 응답 토큰 한계
        public var finalMaxTokens: Int
        /// JSON 파싱 실패 시 복구 재시도 횟수
        public var repairAttempts: Int
        /// 사고 모드 재검토를 적용할 최대 항목 수 (처리 시간 상한)
        public var maxThinkingReviews: Int
        /// 사고 모드에서 토큰 한계를 늘리는 배수. 사고 과정이 답변 자리를 잡아먹는 것을 막는다.
        public var thinkingTokenMultiplier: Double

        public init(
            chunker: TranscriptChunker = TranscriptChunker(),
            router: ReasoningRouter = ReasoningRouter(),
            policy: RelevancePolicy = RelevancePolicy(),
            validator: EvidenceValidator = EvidenceValidator(),
            deduplicator: FactDeduplicator = FactDeduplicator(),
            digestBuilder: TranscriptDigestBuilder = TranscriptDigestBuilder(),
            extractionMaxTokens: Int = 2048,
            reviewMaxTokens: Int = 3072,
            finalMaxTokens: Int = 3072,
            repairAttempts: Int = 1,
            maxThinkingReviews: Int = 24,
            thinkingTokenMultiplier: Double = 1.8
        ) {
            self.chunker = chunker
            self.router = router
            self.policy = policy
            self.validator = validator
            self.deduplicator = deduplicator
            self.digestBuilder = digestBuilder
            self.extractionMaxTokens = extractionMaxTokens
            self.reviewMaxTokens = reviewMaxTokens
            self.finalMaxTokens = finalMaxTokens
            self.repairAttempts = repairAttempts
            self.maxThinkingReviews = maxThinkingReviews
            self.thinkingTokenMultiplier = thinkingTokenMultiplier
        }
    }

    public struct Output: Sendable {
        public var note: MeetingNote
        public var facts: [MeetingFact]
        public var relevance: [RelevanceDecision]
        /// 처리 중 발견된 문제. 사용자에게는 요약해서 보여주고 로그로 남긴다.
        public var problems: [String]
    }

    public enum Progress: Sendable {
        case extracting(window: Int, total: Int)
        case reviewing(item: Int, total: Int)
        case assembling
    }

    public var configuration: Configuration
    private let model: any LocalLanguageModel

    public init(model: any LocalLanguageModel, configuration: Configuration = Configuration()) {
        self.model = model
        self.configuration = configuration
    }

    public func generateNote(
        meetingId: UUID,
        titleHint: String,
        segments: [TranscriptSegment],
        meetingType: MeetingType = .general,
        calendarContext: MeetingCalendarContext? = nil,
        progress: (@Sendable (Progress) -> Void)? = nil
    ) async throws -> Output {
        guard !segments.isEmpty else { throw InferenceError.emptyTranscript }

        let windows = configuration.chunker.windows(for: segments)
        var facts: [MeetingFact] = []
        var relevance: [RelevanceDecision] = []
        var problems: [String] = []
        var repairCount = 0
        var chatterDroppedCount = 0

        let extractionParser = WindowExtractionParser(
            validator: configuration.validator,
            policy: configuration.policy
        )

        // MARK: 1차 추출 — 구간별 비사고 모드

        for window in windows {
            progress?(.extracting(window: window.index + 1, total: windows.count))
            do {
                let (parsed, repairs) = try await generate(
                    prompt: PromptLibrary.windowExtraction(window: window, meetingType: meetingType),
                    mode: .nonThinking,
                    maxTokens: configuration.extractionMaxTokens,
                    expectedShape: Self.windowShape
                ) { raw in
                    try extractionParser.parse(raw: raw, window: window, meetingId: meetingId)
                }
                repairCount += repairs
                facts += parsed.facts
                relevance += parsed.relevance
                problems += parsed.problems.map { "[구간 \(window.index)] \($0)" }
            } catch {
                // 한 구간이 실패해도 회의 전체를 버리지 않는다. 규칙 판정만으로 사담 분류를 채운다.
                problems.append("[구간 \(window.index)] 사실 추출 실패: \(error.localizedDescription)")
                relevance += window.segments.map { segment in
                    configuration.policy.merge(
                        modelLabel: nil,
                        heuristic: configuration.policy.heuristic(for: segment),
                        segment: segment
                    )
                }
            }
        }

        let candidateCount = facts.count

        // MARK: 복잡도 평가 → 사고 모드 재검토 대상 선정

        var routing: [(fact: MeetingFact, decision: RoutingDecision)] = facts.map { fact in
            (fact, configuration.router.decide(for: fact, segments: segments, peers: facts))
        }
        routing.sort { $0.decision.score > $1.decision.score }

        let reviewTargets = routing
            .filter { $0.decision.needsThinking && $0.fact.kind != .topic }
            .prefix(configuration.maxThinkingReviews)
        if routing.count(where: { $0.decision.needsThinking }) > configuration.maxThinkingReviews {
            problems.append("재검토 대상이 상한(\(configuration.maxThinkingReviews))을 넘어 점수가 높은 항목만 처리")
        }

        let windowsByIndex = Dictionary(uniqueKeysWithValues: windows.map { ($0.index, $0) })
        let reviewParser = FactReviewParser(validator: configuration.validator)
        var reviewedFacts: [UUID: MeetingFact] = [:]
        var thinkingReviewCount = 0

        for (offset, target) in reviewTargets.enumerated() {
            progress?(.reviewing(item: offset + 1, total: reviewTargets.count))
            guard let window = windowsByIndex[target.fact.windowIndex] else { continue }
            let related = facts.filter {
                $0.id != target.fact.id && ReasoningRouter.isSimilar($0, target.fact)
            }
            do {
                let (parsed, repairs) = try await generate(
                    prompt: PromptLibrary.factReview(
                        fact: target.fact,
                        window: window,
                        signals: target.decision.signals,
                        relatedFacts: related
                    ),
                    mode: .thinking,
                    maxTokens: configuration.reviewMaxTokens,
                    expectedShape: Self.reviewShape
                ) { raw in
                    try reviewParser.parse(raw: raw, original: target.fact, window: window)
                }
                repairCount += repairs
                thinkingReviewCount += 1
                reviewedFacts[target.fact.id] = parsed.fact
                problems += parsed.problems.map { "[재검토] \($0)" }
            } catch {
                problems.append("[재검토] 실패해 1차 결과 유지: \(error.localizedDescription)")
            }
        }

        facts = facts.map { reviewedFacts[$0.id] ?? $0 }
        let discardedCount = facts.filter(\.discarded).count
        facts = facts.filter { !$0.discarded }

        // MARK: 반복 발언 통합

        let dedupeResult = configuration.deduplicator.merge(facts)
        facts = dedupeResult.facts
        problems += dedupeResult.changeLog.map { "[통합] \($0)" }

        // MARK: 근거 재검증 — 원문에 없는 인용은 여기서 사라진다.

        var evidenceRejected = 0
        facts = facts.map { fact in
            var updated = fact
            let outcome = configuration.validator.validate(evidence: fact.evidence, segments: segments)
            updated.evidence = outcome.evidence
            evidenceRejected += outcome.rejected.count
            if !outcome.rejected.isEmpty {
                problems += outcome.rejected.map { "[근거] \($0)" }
            }
            if updated.kind == .decision, updated.evidence.isEmpty, updated.decisionKind == .decided {
                updated.decisionKind = .proposed
            }
            return updated
        }

        // MARK: 마감일 근거 검증 — 원문에 없는 날짜는 확정하지 않는다.

        facts = facts.map { fact in
            let (updated, reason) = DueDateGrounding.apply(to: fact, segments: segments)
            if let reason {
                problems.append("[마감일] \(reason)")
            }
            return updated
        }

        // MARK: 사담 구간에서만 나온 후보 제거 — 회식·인사 같은 내용이 회의록에 새지 않게 한다(§9).

        let excludedSegmentIds = Set(
            relevance.filter { $0.label == .exclude }.map(\.segmentId.uuidString)
        )
        if !excludedSegmentIds.isEmpty {
            let before = facts.count
            facts = facts.filter { fact in
                guard !fact.evidence.isEmpty else { return true }
                let allExcluded = fact.evidence.allSatisfy { excludedSegmentIds.contains($0.segmentId) }
                if allExcluded {
                    problems.append("[사담] 제외 구간에서만 근거가 나온 후보 제거: \(String(fact.content.prefix(30)))")
                }
                return !allExcluded
            }
            if facts.count != before {
                // 통계에 반영한다.
                chatterDroppedCount = before - facts.count
            }
        }

        // MARK: 최종 종합

        progress?(.assembling)
        let conflictCount = facts.count(where: { !$0.ambiguityNotes.isEmpty })
        let unresolvedCount = facts.count(where: {
            $0.kind == .actionItem && ($0.assignee == nil || $0.dueDate == nil)
        })
        let finalDecision = configuration.router.decideFinalPass(
            totalCandidates: max(candidateCount, 1),
            reviewedCandidates: thinkingReviewCount,
            conflictCount: conflictCount,
            unresolvedCount: unresolvedCount
        )

        let catalog = FactCatalog(facts: facts)
        let digest = configuration.digestBuilder.build(segments: segments, decisions: relevance)
        let finalParser = FinalNoteParser()

        var note: MeetingNote
        do {
            let (parsed, repairs) = try await generate(
                prompt: PromptLibrary.finalNote(
                    meetingTitleHint: titleHint,
                    catalog: catalog,
                    transcriptDigest: digest,
                    meetingType: meetingType,
                    calendarContext: calendarContext
                ),
                mode: finalDecision.mode,
                maxTokens: configuration.finalMaxTokens,
                expectedShape: Self.finalShape
            ) { raw in
                try finalParser.parse(
                    raw: raw,
                    meetingId: meetingId,
                    catalog: catalog,
                    fallbackTitle: titleHint
                )
            }
            repairCount += repairs
            note = parsed.note
            problems += parsed.problems.map { "[최종] \($0)" }
        } catch {
            // 최종 종합이 실패해도 검증된 후보로 회의록을 만든다. 데이터 유실보다 재처리 가능성을 우선한다.
            problems.append("[최종] 생성 실패 — 후보 기반으로 회의록 구성: \(error.localizedDescription)")
            note = Self.fallbackNote(meetingId: meetingId, titleHint: titleHint, catalog: catalog)
        }

        // MARK: 관측값 채우기

        let labelCounts = Dictionary(grouping: relevance, by: \.label).mapValues(\.count)
        note.generation = GenerationSummary(
            windowCount: windows.count,
            thinkingReviewCount: thinkingReviewCount,
            candidateCount: candidateCount,
            droppedCandidateCount: discardedCount + chatterDroppedCount,
            mergedDuplicateCount: dedupeResult.mergedCount,
            evidenceRejectedCount: evidenceRejected,
            keptSegmentCount: labelCounts[.keep] ?? 0,
            condensedSegmentCount: labelCounts[.condense] ?? 0,
            excludedSegmentCount: labelCounts[.exclude] ?? 0,
            uncertainSegmentCount: labelCounts[.uncertain] ?? 0,
            finalPassUsedThinking: finalDecision.mode == .thinking,
            jsonRepairCount: repairCount
        )
        if note.title.isEmpty {
            note.title = titleHint
        }

        return Output(note: note, facts: facts, relevance: relevance, problems: problems)
    }

    // MARK: - 생성 + JSON 복구

    private func generate<T>(
        prompt: String,
        mode: ReasoningMode,
        maxTokens: Int,
        expectedShape: String,
        parse: (String) throws -> T
    ) async throws -> (T, Int) {
        // 사고 모드는 사고 과정이 토큰을 먹으므로 여유를 더 준다.
        let budget = mode == .thinking
            ? Int(Double(maxTokens) * configuration.thinkingTokenMultiplier)
            : maxTokens

        let raw = try await model.generate(
            systemPrompt: PromptLibrary.systemPrompt,
            prompt: prompt,
            mode: mode,
            maxTokens: budget
        )
        do {
            return try (parse(raw), 0)
        } catch {
            var lastError = error
            var repairs = 0

            // 사고가 토큰을 다 써서 본문이 남지 않은 경우가 있다.
            // 이때는 형식 복구가 아니라 같은 작업을 비사고 모드로 다시 시키는 것이 맞다.
            if mode == .thinking, raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                repairs += 1
                let retried = try await model.generate(
                    systemPrompt: PromptLibrary.systemPrompt,
                    prompt: prompt,
                    mode: .nonThinking,
                    maxTokens: maxTokens
                )
                do {
                    return try (parse(retried), repairs)
                } catch {
                    lastError = error
                }
            }

            for _ in 0 ..< configuration.repairAttempts {
                repairs += 1
                let strippedRaw = ThinkingStripper.strip(raw).visibleText
                let repairedRaw: String = if strippedRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // 고칠 본문이 없으면 원래 작업을 비사고 모드로 다시 시킨다.
                    try await model.generate(
                        systemPrompt: PromptLibrary.systemPrompt,
                        prompt: prompt,
                        mode: .nonThinking,
                        maxTokens: maxTokens
                    )
                } else {
                    try await model.generate(
                        systemPrompt: nil,
                        prompt: PromptLibrary.repairJSON(raw: strippedRaw, expectedShape: expectedShape),
                        mode: .nonThinking,
                        maxTokens: maxTokens
                    )
                }
                do {
                    return try (parse(repairedRaw), repairs)
                } catch {
                    lastError = error
                }
            }
            throw lastError
        }
    }

    /// 최종 종합이 실패했을 때 검증된 후보만으로 만드는 회의록.
    static func fallbackNote(meetingId: UUID, titleHint: String, catalog: FactCatalog) -> MeetingNote {
        var note = MeetingNote(meetingId: meetingId, title: titleHint)
        note.decisions = catalog.facts(.decision).map {
            Decision(
                content: $0.content,
                kind: $0.evidence.isEmpty ? .proposed : ($0.decisionKind ?? .proposed),
                evidence: $0.evidence,
                confidence: $0.confidence,
                reviewed: $0.reviewed
            )
        }
        note.actionItems = catalog.facts(.actionItem).map {
            ActionItem(
                task: $0.content,
                assignee: $0.assignee,
                dueDate: $0.dueDate,
                dueDateNote: $0.dueDateNote,
                status: .proposed,
                evidence: $0.evidence,
                confidence: $0.confidence,
                reviewed: $0.reviewed
            )
        }
        note.risks = catalog.facts(.risk).map {
            RiskItem(
                content: $0.content,
                severity: $0.severity ?? .unknown,
                evidence: $0.evidence,
                confidence: $0.confidence
            )
        }
        note.openQuestions = catalog.facts(.openQuestion).map {
            OpenQuestion(question: $0.content, evidence: $0.evidence, confidence: $0.confidence)
        }
        note.topics = catalog.facts(.topic).map { Topic(title: $0.content) }
        let decided = note.decisions.count(where: { $0.kind == .decided })
        note.summary = "자동 종합에 실패해 검증된 항목만 정리했습니다. 결정 \(decided)건, 액션아이템 \(note.actionItems.count)건, 리스크 \(note.risks.count)건이 확인됐습니다."
        return note
    }

    static let windowShape = """
    {"topics": [], "decisions": [], "actionItems": [], "risks": [], "openQuestions": [], "segmentRelevance": []}
    """
    static let reviewShape = """
    {"verdict": "confirm", "content": "", "kind": "decided", "assignee": null, "dueDate": null, "confidence": 0.0, "evidence": []}
    """
    static let finalShape = """
    {"title": "", "summary": "", "decisions": [], "actionItems": [], "openQuestions": [], "risks": [], "topics": []}
    """
}

public enum InferenceError: Error, LocalizedError, Sendable {
    case emptyTranscript
    case modelUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .emptyTranscript: "전사문이 비어 있어 회의록을 생성할 수 없습니다."
        case let .modelUnavailable(message): "로컬 LLM을 사용할 수 없습니다: \(message)"
        }
    }
}
