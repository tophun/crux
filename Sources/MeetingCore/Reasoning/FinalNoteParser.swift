import Foundation

/// 최종 회의록 응답 파서. 근거는 모델 출력이 아니라 카탈로그의 후보에서 가져온다.
public struct FinalNoteParser: Sendable {
    public struct Parsed: Sendable {
        public var note: MeetingNote
        public var problems: [String]
        public var repaired: Bool
    }

    public init() {}

    public func parse(
        raw: String,
        meetingId: UUID,
        catalog: FactCatalog,
        fallbackTitle: String
    ) throws -> Parsed {
        let extraction = try JSONExtractor.extract(from: raw)
        let root = extraction.value
        var problems: [String] = []

        var note = MeetingNote(meetingId: meetingId)
        note.title = root["title", "제목"].stringValue ?? fallbackTitle
        note.summary = root["summary", "요약"].stringValue ?? ""

        // MARK: 결정사항
        for item in root["decisions", "결정사항"].arrayValue {
            guard let content = item["content", "decision", "내용"].stringValue else { continue }
            guard let source = resolve(item, kind: .decision, content: content, catalog: catalog, problems: &problems)
            else { continue }
            let kindText = item["kind", "status", "상태"].stringValue?.lowercased() ?? ""
            var decisionKind = source.decisionKind ?? .proposed
            if kindText.contains("decid") || kindText.contains("결정") { decisionKind = .decided }
            if kindText.contains("propos") || kindText.contains("제안") { decisionKind = .proposed }
            // 근거가 없으면 결정으로 확정하지 않는다.
            let evidence = source.evidence
            if evidence.isEmpty, decisionKind == .decided {
                decisionKind = .proposed
                problems.append("근거 없는 결정을 제안으로 낮춤: \(String(content.prefix(20)))")
            }
            note.decisions.append(
                Decision(
                    content: content,
                    kind: decisionKind,
                    evidence: evidence,
                    confidence: source.confidence,
                    reviewed: source.reviewed
                )
            )
        }

        // MARK: 액션아이템
        for item in root["actionItems", "action_items", "액션아이템"].arrayValue {
            guard let task = item["task", "content", "내용"].stringValue else { continue }
            guard let source = resolve(item, kind: .actionItem, content: task, catalog: catalog, problems: &problems)
            else { continue }
            // 담당자·마감일은 검증된 후보 값을 우선한다. 모델이 새로 채운 값은 후보에 없으면 버린다.
            let assignee = source.assignee
            let modelAssignee = item["assignee", "담당자"].stringValue
            if source.assignee == nil, modelAssignee != nil {
                problems.append("검증된 후보에 없는 담당자 값 무시: \(modelAssignee!)")
            }
            let dueDate = source.dueDate
            let modelDueDate = item["dueDate", "마감일"].stringValue
            if source.dueDate == nil, modelDueDate != nil {
                problems.append("검증된 후보에 없는 마감일 값 무시(후보의 일정 표현을 사용): \(modelDueDate!)")
            }
            let statusText = item["status", "상태"].stringValue?.lowercased() ?? ""
            var status: ActionItemStatus = .proposed
            if statusText.contains("confirm") || statusText.contains("확정") { status = .confirmed }
            if statusText.contains("progress") || statusText.contains("진행") { status = .inProgress }
            if statusText.contains("done") || statusText.contains("완료") { status = .done }
            let evidence = source.evidence
            if evidence.isEmpty { status = .proposed }

            note.actionItems.append(
                ActionItem(
                    task: task,
                    assignee: assignee,
                    dueDate: dueDate,
                    dueDateNote: source.dueDateNote,
                    status: status,
                    evidence: evidence,
                    confidence: source.confidence,
                    reviewed: source.reviewed
                )
            )
        }

        // MARK: 미해결 질문
        for item in root["openQuestions", "open_questions", "미해결질문"].arrayValue {
            guard let question = item["question", "content", "내용"].stringValue else { continue }
            guard let source = resolve(item, kind: .openQuestion, content: question, catalog: catalog, problems: &problems)
            else { continue }
            note.openQuestions.append(
                OpenQuestion(
                    question: question,
                    evidence: source.evidence,
                    confidence: source.confidence
                )
            )
        }

        // MARK: 리스크
        for item in root["risks", "리스크"].arrayValue {
            guard let content = item["content", "risk", "내용"].stringValue else { continue }
            guard let source = resolve(item, kind: .risk, content: content, catalog: catalog, problems: &problems)
            else { continue }
            var severity = source.severity ?? .unknown
            if let text = item["severity", "심각도"].stringValue?.lowercased() {
                if text.contains("high") || text.contains("높") { severity = .high }
                else if text.contains("medium") || text.contains("중") { severity = .medium }
                else if text.contains("low") || text.contains("낮") { severity = .low }
            }
            note.risks.append(
                RiskItem(
                    content: content,
                    severity: severity,
                    evidence: source.evidence,
                    confidence: source.confidence
                )
            )
        }

        // MARK: 주제
        for item in root["topics", "주제"].arrayValue {
            guard let title = item["title", "topic", "제목"].stringValue ?? item.stringValue else { continue }
            note.topics.append(
                Topic(title: title, summary: item["summary", "요약"].stringValue ?? "")
            )
        }

        // 최종 단계에서 같은 문장이 여러 번 나오는 경우가 있다. 섹션마다 중복을 걷어낸다.
        let beforeCount = note.decisions.count + note.actionItems.count
            + note.openQuestions.count + note.risks.count + note.topics.count
        note.decisions = Self.deduplicated(note.decisions, key: \.content)
        note.actionItems = Self.deduplicated(note.actionItems, key: \.task)
        note.openQuestions = Self.deduplicated(note.openQuestions, key: \.question)
        note.risks = Self.deduplicated(note.risks, key: \.content)
        note.topics = Self.deduplicated(note.topics, key: \.title)
        let afterCount = note.decisions.count + note.actionItems.count
            + note.openQuestions.count + note.risks.count + note.topics.count
        if afterCount < beforeCount {
            problems.append("중복 항목 \(beforeCount - afterCount)건 제거")
        }

        if note.summary.isEmpty {
            problems.append("요약이 비어 있음")
        }

        return Parsed(note: note, problems: problems, repaired: extraction.repaired)
    }

    /// 같은 내용을 한 번만 남긴다. 공백·문장부호 차이는 무시한다.
    static func deduplicated<T>(_ items: [T], key: (T) -> String) -> [T] {
        var seen: Set<String> = []
        return items.filter { item in
            let normalized = key(item).lowercased().filter { $0.isLetter || $0.isNumber }
            guard !normalized.isEmpty else { return false }
            return seen.insert(normalized).inserted
        }
    }

    /// evidenceIndex → 후보. 번호가 틀리면 내용 유사도로 찾는다.
    /// 후보에 전혀 없으면 nil을 돌려주고, 호출자는 그 항목을 회의록에 넣지 않는다.
    private func resolve(
        _ item: JSONValue,
        kind: MeetingFact.Kind,
        content: String,
        catalog: FactCatalog,
        problems: inout [String]
    ) -> MeetingFact? {
        if let number = item["evidenceIndex", "evidence_index", "index", "번호"].doubleValue.map({ Int($0) }),
           let fact = catalog.fact(kind, number: number) {
            // 번호가 가리키는 후보와 내용이 전혀 다르면 잘못된 참조로 본다.
            if TextSimilarity.overlap(fact.content, content) >= 0.3 {
                return fact
            }
            problems.append("evidenceIndex \(number)가 내용과 불일치해 유사도로 재연결")
        }
        if let fact = catalog.bestMatch(kind, content: content) {
            return fact
        }
        problems.append("후보에 없는 항목이라 회의록에서 제외: \(String(content.prefix(20)))")
        return nil
    }
}
