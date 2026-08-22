import Foundation

/// 1차 추출 응답 파서. 근거는 모델이 준 타임스탬프를 믿지 않고 실제 세그먼트에서 채운다.
public struct WindowExtractionParser: Sendable {
    public struct Parsed: Sendable {
        public var facts: [MeetingFact]
        public var relevance: [RelevanceDecision]
        public var problems: [String]
        public var repaired: Bool
    }

    public var validator: EvidenceValidator
    public var policy: RelevancePolicy

    public init(validator: EvidenceValidator = EvidenceValidator(), policy: RelevancePolicy = RelevancePolicy()) {
        self.validator = validator
        self.policy = policy
    }

    public func parse(
        raw: String,
        window: TranscriptWindow,
        meetingId: UUID
    ) throws -> Parsed {
        let extraction = try JSONExtractor.extract(from: raw)
        let root = extraction.value
        var problems: [String] = []
        var facts: [MeetingFact] = []

        // MARK: 결정/제안

        for item in root["decisions", "decision", "결정사항"].arrayValue {
            guard let content = item["content", "decision", "내용"].stringValue else { continue }
            let kindText = item["kind", "type", "status"].stringValue?.lowercased() ?? ""
            let decisionKind: DecisionKind = kindText.contains("propos") || kindText.contains("제안")
                ? .proposed
                : (kindText.contains("decid") || kindText.contains("결정") ? .decided : .proposed)
            let (evidence, evidenceProblems) = resolveEvidence(item, window: window)
            problems += evidenceProblems
            facts.append(
                MeetingFact(
                    meetingId: meetingId,
                    windowIndex: window.index,
                    kind: .decision,
                    content: content,
                    decisionKind: decisionKind,
                    evidence: evidence,
                    confidence: item["confidence", "신뢰도"].confidenceValue ?? 0.5,
                    ambiguityNotes: stringList(item["ambiguity", "ambiguityNotes", "notes"])
                )
            )
        }

        // MARK: 액션아이템

        for item in root["actionItems", "action_items", "actions", "액션아이템"].arrayValue {
            guard let task = item["task", "content", "action", "내용"].stringValue else { continue }
            let (evidence, evidenceProblems) = resolveEvidence(item, window: window)
            problems += evidenceProblems
            facts.append(
                MeetingFact(
                    meetingId: meetingId,
                    windowIndex: window.index,
                    kind: .actionItem,
                    content: task,
                    assignee: item["assignee", "owner", "담당자"].stringValue,
                    dueDate: item["dueDate", "due_date", "deadline", "마감일"].stringValue,
                    dueDateNote: item["dueDateNote", "due_date_note", "일정표현"].stringValue,
                    evidence: evidence,
                    confidence: item["confidence", "신뢰도"].confidenceValue ?? 0.5,
                    ambiguityNotes: stringList(item["ambiguity", "ambiguityNotes", "notes"])
                )
            )
        }

        // MARK: 리스크

        for item in root["risks", "risk", "리스크"].arrayValue {
            guard let content = item["content", "risk", "내용"].stringValue else { continue }
            let (evidence, evidenceProblems) = resolveEvidence(item, window: window)
            problems += evidenceProblems
            facts.append(
                MeetingFact(
                    meetingId: meetingId,
                    windowIndex: window.index,
                    kind: .risk,
                    content: content,
                    severity: severity(from: item["severity", "level", "심각도"].stringValue),
                    evidence: evidence,
                    confidence: item["confidence", "신뢰도"].confidenceValue ?? 0.5
                )
            )
        }

        // MARK: 미해결 질문

        for item in root["openQuestions", "open_questions", "questions", "미해결질문"].arrayValue {
            guard let content = item["question", "content", "내용"].stringValue else { continue }
            let (evidence, evidenceProblems) = resolveEvidence(item, window: window)
            problems += evidenceProblems
            facts.append(
                MeetingFact(
                    meetingId: meetingId,
                    windowIndex: window.index,
                    kind: .openQuestion,
                    content: content,
                    evidence: evidence,
                    confidence: item["confidence", "신뢰도"].confidenceValue ?? 0.5
                )
            )
        }

        // MARK: 주제

        for item in root["topics", "topic", "주제"].arrayValue {
            let title = item["title", "topic", "제목"].stringValue ?? item.stringValue
            guard let title else { continue }
            facts.append(
                MeetingFact(
                    meetingId: meetingId,
                    windowIndex: window.index,
                    kind: .topic,
                    content: title,
                    confidence: 0.5,
                    ambiguityNotes: [item["summary", "요약"].stringValue].compactMap(\.self)
                )
            )
        }

        // MARK: 사담 분류 — 모델 판정과 규칙 판정을 합친다.

        var modelLabels: [UUID: RelevanceLabel] = [:]
        for item in root["segmentRelevance", "segment_relevance", "relevance", "구간분류"].arrayValue {
            guard let shortId = item["segment", "segmentId", "id"].stringValue,
                  let segment = window.segment(forShortId: shortId) else { continue }
            guard let labelText = item["label", "relevance", "분류"].stringValue,
                  let label = RelevanceLabel(rawValue: labelText.uppercased()) else { continue }
            modelLabels[segment.id] = label
        }

        let relevance = window.segments.map { segment in
            policy.merge(
                modelLabel: modelLabels[segment.id],
                heuristic: policy.heuristic(for: segment),
                segment: segment
            )
        }

        if modelLabels.isEmpty, !window.segments.isEmpty {
            problems.append("구간 분류가 비어 있어 규칙 판정만 사용")
        }

        return Parsed(
            facts: facts,
            relevance: relevance,
            problems: problems,
            repaired: extraction.repaired
        )
    }

    // MARK: - 보조

    func resolveEvidence(_ item: JSONValue, window: TranscriptWindow) -> ([Evidence], [String]) {
        var evidence: [Evidence] = []
        var problems: [String] = []
        let entries = item["evidence", "근거", "citations"].arrayValue
        for entry in entries {
            let shortId = entry["segment", "segmentId", "id", "구간"].stringValue
            let quote = entry["quote", "text", "인용"].stringValue
            let (resolved, reason) = validator.resolve(shortId: shortId, quote: quote, in: window)
            if let resolved {
                evidence.append(resolved)
                if let reason {
                    problems.append(reason)
                }
            } else if let reason {
                problems.append(reason)
            }
        }
        return (validator.dedupe(evidence), problems)
    }

    func stringList(_ value: JSONValue) -> [String] {
        value.arrayValue.compactMap(\.stringValue)
    }

    func severity(from text: String?) -> RiskSeverity {
        guard let text = text?.lowercased() else { return .unknown }
        if text.contains("high") || text.contains("높") || text.contains("심각") {
            return .high
        }
        if text.contains("medium") || text.contains("중") {
            return .medium
        }
        if text.contains("low") || text.contains("낮") {
            return .low
        }
        return .unknown
    }
}
