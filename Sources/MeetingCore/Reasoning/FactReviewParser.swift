import Foundation

/// 사고 모드 재검토 응답 파서.
public struct FactReviewParser: Sendable {
    public enum Verdict: String, Sendable {
        case confirm
        case revise
        case discard
    }

    public struct Parsed: Sendable {
        public var verdict: Verdict
        public var fact: MeetingFact
        public var problems: [String]
        public var repaired: Bool
    }

    public var validator: EvidenceValidator

    public init(validator: EvidenceValidator = EvidenceValidator()) {
        self.validator = validator
    }

    public func parse(
        raw: String,
        original: MeetingFact,
        window: TranscriptWindow
    ) throws -> Parsed {
        let extraction = try JSONExtractor.extract(from: raw)
        let root = extraction.value
        var problems: [String] = []

        let verdictText = root["verdict", "decision", "판정"].stringValue?.lowercased() ?? "confirm"
        let verdict: Verdict
        if verdictText.contains("discard") || verdictText.contains("폐기") || verdictText.contains("drop") {
            verdict = .discard
        } else if verdictText.contains("revise") || verdictText.contains("수정") {
            verdict = .revise
        } else {
            verdict = .confirm
        }

        var fact = original
        fact.reviewed = true

        if verdict == .discard {
            fact.discarded = true
            return Parsed(verdict: verdict, fact: fact, problems: problems, repaired: extraction.repaired)
        }

        if let content = root["content", "task", "question", "내용"].stringValue {
            fact.content = content
        }

        if fact.kind == .decision {
            let kindText = root["kind", "type", "상태"].stringValue?.lowercased() ?? ""
            if kindText.contains("decid") || kindText.contains("결정") {
                fact.decisionKind = .decided
            } else if kindText.contains("propos") || kindText.contains("제안") {
                fact.decisionKind = .proposed
            }
        }

        if fact.kind == .actionItem {
            // 근거 없이 확정되지 않도록, 값이 명시적으로 오지 않으면 nil로 유지한다.
            fact.assignee = root["assignee", "owner", "담당자"].stringValue
            fact.dueDate = root["dueDate", "due_date", "deadline", "마감일"].stringValue
            fact.dueDateNote = root["dueDateNote", "due_date_note", "일정표현"].stringValue
        }

        if fact.kind == .risk {
            let severityText = root["severity", "심각도"].stringValue?.lowercased() ?? ""
            if severityText.contains("high") || severityText.contains("높") { fact.severity = .high }
            else if severityText.contains("medium") || severityText.contains("중") { fact.severity = .medium }
            else if severityText.contains("low") || severityText.contains("낮") { fact.severity = .low }
        }

        if let confidence = root["confidence", "신뢰도"].confidenceValue {
            fact.confidence = confidence
        }

        // 근거 재확정. 새 근거를 못 주면 기존 근거를 유지한다.
        var refreshed: [Evidence] = []
        for entry in root["evidence", "근거"].arrayValue {
            let shortId = entry["segment", "segmentId", "id"].stringValue
            let quote = entry["quote", "text", "인용"].stringValue
            let (resolved, reason) = validator.resolve(shortId: shortId, quote: quote, in: window)
            if let resolved { refreshed.append(resolved) } else if let reason { problems.append(reason) }
        }
        if !refreshed.isEmpty {
            fact.evidence = validator.dedupe(refreshed)
        }

        // 근거가 전혀 없는 결정은 제안으로 낮춘다.
        if fact.kind == .decision, fact.evidence.isEmpty, fact.decisionKind == .decided {
            fact.decisionKind = .proposed
            problems.append("근거가 없어 결정을 제안으로 낮춤")
        }

        return Parsed(verdict: verdict, fact: fact, problems: problems, repaired: extraction.repaired)
    }
}
