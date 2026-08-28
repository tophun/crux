import Foundation

/// 회의록 내보내기. 로컬 파일로만 저장하며 업로드 경로는 존재하지 않는다(§11).
public enum MeetingNoteExporter {
    // MARK: - JSON (§10 구조)

    /// §10의 회의록 JSON 구조. `kind`, `dueDateNote`, `generation`은 결정/제안 구분과 품질 측정을 위한 추가 필드다.
    public static func json(_ note: MeetingNote, prettyPrinted: Bool = true) throws -> Data {
        let payload = Payload(note: note)
        let encoder = JSONEncoder()
        encoder.outputFormatting = prettyPrinted
            ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            : [.withoutEscapingSlashes]
        return try encoder.encode(payload)
    }

    public static func jsonString(_ note: MeetingNote) throws -> String {
        try String(decoding: json(note), as: UTF8.self)
    }

    struct Payload: Encodable {
        var title: String
        var summary: String
        var decisions: [DecisionPayload]
        var actionItems: [ActionItemPayload]
        var openQuestions: [QuestionPayload]
        var risks: [RiskPayload]
        var topics: [TopicPayload]
        var generatedAt: Date
        var generation: GenerationSummary

        init(note: MeetingNote) {
            title = note.title
            summary = note.summary
            decisions = note.decisions.map(DecisionPayload.init)
            actionItems = note.actionItems.map(ActionItemPayload.init)
            openQuestions = note.openQuestions.map(QuestionPayload.init)
            risks = note.risks.map(RiskPayload.init)
            topics = note.topics.map(TopicPayload.init)
            generatedAt = note.generatedAt
            generation = note.generation
        }
    }

    struct DecisionPayload: Encodable {
        var content: String
        var kind: String
        var evidence: [Evidence]
        var confidence: Double

        init(_ decision: Decision) {
            content = decision.content
            kind = decision.kind.rawValue
            evidence = decision.evidence
            confidence = decision.confidence
        }
    }

    struct ActionItemPayload: Encodable {
        var task: String
        var assignee: String?
        var dueDate: String?
        var dueDateNote: String?
        var status: String
        var evidence: [Evidence]
        var confidence: Double

        init(_ item: ActionItem) {
            task = item.task
            assignee = item.assignee
            dueDate = item.dueDate
            dueDateNote = item.dueDateNote
            status = item.status.rawValue
            evidence = item.evidence
            confidence = item.confidence
        }
    }

    struct QuestionPayload: Encodable {
        var question: String
        var evidence: [Evidence]
        var confidence: Double

        init(_ question: OpenQuestion) {
            self.question = question.question
            evidence = question.evidence
            confidence = question.confidence
        }
    }

    struct RiskPayload: Encodable {
        var content: String
        var severity: String
        var evidence: [Evidence]
        var confidence: Double

        init(_ risk: RiskItem) {
            content = risk.content
            severity = risk.severity.rawValue
            evidence = risk.evidence
            confidence = risk.confidence
        }
    }

    struct TopicPayload: Encodable {
        var title: String
        var summary: String

        init(_ topic: Topic) {
            title = topic.title
            summary = topic.summary
        }
    }

    // MARK: - Markdown

    /// 화면·파일에 쓸 최종 문서. 사용자 프롬프트로 구성한 문서가 있으면 그것을 쓴다.
    public static func document(_ note: MeetingNote, meeting: Meeting? = nil, attendees: [String] = []) -> String {
        if let custom = note.customDocument, !custom.isEmpty {
            return custom
        }
        return markdown(note, meeting: meeting, attendees: attendees)
    }

    /// 회의록 문서.
    ///
    /// 일반(기본):
    ///     ## 날짜 / ## 참여자
    ///     ## 내용 → ### 요약 · ### 결정 · ### 논의(표) · ### 리스크 · ### 미해결
    ///     ## Action Item (체크리스트)
    ///
    /// 유형을 고르면 강조 섹션만 달라진다. 스크럼은 한 일/이슈, 1:1은 약속, 리뷰는 결정/리스크.
    /// 일반은 지금과 같다. 리스크·미해결·결정은 일반에서 **내용이 있을 때만** 만든다.
    /// 전사문과 근거 타임스탬프는 넣지 않는다. 근거는 `{meetingId}.evidence.json`에만 둔다.
    ///
    /// - Parameter attendees: 캘린더 참석자. 없으면 비워 두고 임의로 만들지 않는다.
    public static func markdown(_ note: MeetingNote, meeting: Meeting? = nil, attendees: [String] = []) -> String {
        // 제목은 화면 카드와 파일명이 이미 담으므로 문서 본문에는 넣지 않는다.
        var lines: [String] = []
        appendHeader(to: &lines, note: note, meeting: meeting, attendees: attendees)
        switch meeting?.meetingType ?? .general {
        case .general:
            appendGeneralBody(to: &lines, note: note)
        case .scrum:
            appendScrumBody(to: &lines, note: note)
        case .oneOnOne:
            appendOneOnOneBody(to: &lines, note: note)
        case .review:
            appendReviewBody(to: &lines, note: note)
        }
        return lines.joined(separator: "\n")
    }

    private static func appendHeader(
        to lines: inout [String],
        note: MeetingNote,
        meeting: Meeting?,
        attendees: [String]
    ) {
        lines.append("## 날짜")
        lines.append(dateText(meeting?.startedAt ?? note.generatedAt))
        lines.append("")

        lines.append("## 참여자")
        if attendees.isEmpty {
            lines.append("- \(UnresolvedMarker.undetermined)")
        } else {
            for attendee in attendees {
                lines.append("- \(attendee)")
            }
        }
        lines.append("")
    }

    /// 지금과 같은 일반 구성. 빈 결정·리스크·미해결 제목은 만들지 않는다.
    private static func appendGeneralBody(to lines: inout [String], note: MeetingNote) {
        appendContentPreamble(to: &lines, note: note)
        appendDecided(to: &lines, note: note, always: false)
        appendDiscussion(to: &lines, note: note, includeTopics: true)
        appendRisks(to: &lines, note: note, always: false)
        appendOpenQuestions(to: &lines, note: note)
        appendActionItems(to: &lines, items: note.actionItems, heading: "## Action Item")
    }

    /// 스크럼: 한 일(주제·완료 액션)과 이슈(리스크)를 요약 바로 뒤에 둔다.
    private static func appendScrumBody(to lines: inout [String], note: MeetingNote) {
        appendContentPreamble(to: &lines, note: note)
        appendBullets("### 한 일", items: doneWorkItems(note), to: &lines, always: true)
        appendRisks(to: &lines, note: note, always: true, heading: "### 이슈")
        appendDiscussion(to: &lines, note: note, includeTopics: false)
        appendDecided(to: &lines, note: note, always: false)
        appendOpenQuestions(to: &lines, note: note)
        appendActionItems(
            to: &lines,
            items: note.actionItems.filter { $0.status != .done },
            heading: "## Action Item"
        )
    }

    /// 1:1: 약속을 요약 바로 뒤에 두고 Action Item 자리를 대신한다.
    private static func appendOneOnOneBody(to lines: inout [String], note: MeetingNote) {
        appendContentPreamble(to: &lines, note: note)
        appendActionItems(to: &lines, items: note.actionItems, heading: "### 약속")
        appendDiscussion(to: &lines, note: note, includeTopics: true)
        appendDecided(to: &lines, note: note, always: false)
        appendRisks(to: &lines, note: note, always: false)
        appendOpenQuestions(to: &lines, note: note)
    }

    /// 리뷰: 결정과 리스크를 요약 바로 뒤에 항상 둔다.
    private static func appendReviewBody(to lines: inout [String], note: MeetingNote) {
        appendContentPreamble(to: &lines, note: note)
        appendDecided(to: &lines, note: note, always: true)
        appendRisks(to: &lines, note: note, always: true)
        appendDiscussion(to: &lines, note: note, includeTopics: true)
        appendOpenQuestions(to: &lines, note: note)
        appendActionItems(to: &lines, items: note.actionItems, heading: "## Action Item")
    }

    private static func appendContentPreamble(to lines: inout [String], note: MeetingNote) {
        lines.append("## 내용")
        lines.append("")
        lines.append("### 요약")
        lines.append(note.summary.isEmpty ? "(요약 없음)" : note.summary)
        lines.append("")
    }

    private static func appendDecided(to lines: inout [String], note: MeetingNote, always: Bool) {
        let decided = note.decisions.filter { $0.kind == .decided }.map(\.content)
        appendBullets("### 결정", items: decided, to: &lines, always: always)
    }

    private static func appendRisks(
        to lines: inout [String],
        note: MeetingNote,
        always: Bool,
        heading: String = "### 리스크"
    ) {
        appendBullets(heading, items: note.risks.map(\.content), to: &lines, always: always)
    }

    private static func appendOpenQuestions(to lines: inout [String], note: MeetingNote) {
        appendBullets("### 미해결", items: note.openQuestions.map(\.question), to: &lines, always: false)
    }

    private static func appendBullets(
        _ heading: String,
        items: [String],
        to lines: inout [String],
        always: Bool
    ) {
        guard always || !items.isEmpty else { return }
        lines.append(heading)
        if items.isEmpty {
            lines.append("- 없음")
        } else {
            for item in items {
                lines.append("- \(item)")
            }
        }
        lines.append("")
    }

    private static func appendDiscussion(
        to lines: inout [String],
        note: MeetingNote,
        includeTopics: Bool
    ) {
        lines.append("### 논의")
        lines.append("| 주제 | 내용 |")
        lines.append("| --- | --- |")
        let rows = includeTopics
            ? discussionRows(note)
            : note.decisions.filter { $0.kind == .proposed }.map { (topic: "검토 중", detail: $0.content) }
        if rows.isEmpty {
            lines.append("| \(UnresolvedMarker.undetermined) | - |")
        } else {
            for row in rows {
                lines.append("| \(escapeCell(row.topic)) | \(escapeCell(row.detail)) |")
            }
        }
        lines.append("")
    }

    private static func appendActionItems(
        to lines: inout [String],
        items: [ActionItem],
        heading: String
    ) {
        lines.append(heading)
        if items.isEmpty {
            lines.append("- 없음")
        } else {
            for item in items {
                let mark = item.status == .done ? "x" : " "
                lines.append("- [\(mark)] \(item.task) — \(item.assigneeDisplay) · \(item.dueDateDisplay)")
            }
        }
        lines.append("")
    }

    private static func doneWorkItems(_ note: MeetingNote) -> [String] {
        var items = note.topics.compactMap { topic -> String? in
            if topic.title.isEmpty, topic.summary.isEmpty { return nil }
            if topic.summary.isEmpty { return topic.title }
            if topic.title.isEmpty { return topic.summary }
            return "\(topic.title) — \(topic.summary)"
        }
        items += note.actionItems.filter { $0.status == .done }.map(\.task)
        return items
    }

    /// 논의 표의 행. 주제 요약이 먼저 오고, 확정되지 않은 제안을 뒤에 붙인다.
    private static func discussionRows(_ note: MeetingNote) -> [(topic: String, detail: String)] {
        var rows = note.topics
            .filter { !$0.title.isEmpty || !$0.summary.isEmpty }
            .map { (topic: $0.title, detail: $0.summary.isEmpty ? "-" : $0.summary) }
        rows += note.decisions
            .filter { $0.kind == .proposed }
            .map { (topic: "검토 중", detail: $0.content) }
        return rows
    }

    /// 표 안의 줄바꿈과 세로줄은 칸을 깨뜨리므로 바꿔 준다.
    private static func escapeCell(_ text: String) -> String {
        text
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    private static func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
