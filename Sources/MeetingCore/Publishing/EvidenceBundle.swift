import Foundation

/// 근거 파일(`{meetingId}.evidence.json`).
///
/// 타임스탬프와 원문 인용은 이 로컬 파일에만 둔다. Confluence·Jira에는 나가지 않는다(요구사항 7).
/// 게시 결과물과는 내부 `contentId`로 연결한다.
public struct EvidenceBundle: Hashable, Sendable, Codable {
    public struct Item: Hashable, Sendable, Codable {
        /// 회의록 항목의 내부 식별자 (예: `D1`, `A2`). 외부로 게시되지 않는다.
        public var contentId: String
        public var kind: String
        /// 항목 본문. Preview Viewer의 근거 확인 화면에서 대조용으로 쓴다.
        public var content: String
        public var evidence: [Evidence]

        public init(contentId: String, kind: String, content: String, evidence: [Evidence]) {
            self.contentId = contentId
            self.kind = kind
            self.content = content
            self.evidence = evidence
        }
    }

    public var meetingId: UUID
    public var generatedAt: Date
    public var items: [Item]

    public init(meetingId: UUID, generatedAt: Date = Date(), items: [Item] = []) {
        self.meetingId = meetingId
        self.generatedAt = generatedAt
        self.items = items
    }

    public static func fileName(meetingId: UUID) -> String {
        "\(meetingId.uuidString).evidence.json"
    }

    public func item(contentId: String) -> Item? {
        items.first { $0.contentId == contentId }
    }

    /// 회의록에서 근거 파일을 만든다. contentId는 종류별 순번으로 안정적으로 붙인다.
    public static func make(from note: MeetingNote) -> EvidenceBundle {
        var items: [Item] = []
        for (index, decision) in note.decisions.enumerated() {
            items.append(
                Item(
                    contentId: ContentId.decision(index),
                    kind: decision.kind == .decided ? "decision" : "proposal",
                    content: decision.content,
                    evidence: decision.evidence
                )
            )
        }
        for (index, item) in note.actionItems.enumerated() {
            items.append(
                Item(contentId: ContentId.actionItem(index), kind: "actionItem", content: item.task, evidence: item.evidence)
            )
        }
        for (index, risk) in note.risks.enumerated() {
            items.append(
                Item(contentId: ContentId.risk(index), kind: "risk", content: risk.content, evidence: risk.evidence)
            )
        }
        for (index, question) in note.openQuestions.enumerated() {
            items.append(
                Item(
                    contentId: ContentId.openQuestion(index),
                    kind: "openQuestion",
                    content: question.question,
                    evidence: question.evidence
                )
            )
        }
        return EvidenceBundle(meetingId: note.meetingId, generatedAt: note.generatedAt, items: items)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func decoded(from data: Data) throws -> EvidenceBundle {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(EvidenceBundle.self, from: data)
    }
}

/// 내부 contentId 생성 규칙. 게시물에는 포함되지 않는다.
public enum ContentId {
    public static func decision(_ index: Int) -> String {
        "D\(index + 1)"
    }

    public static func actionItem(_ index: Int) -> String {
        "A\(index + 1)"
    }

    public static func risk(_ index: Int) -> String {
        "R\(index + 1)"
    }

    public static func openQuestion(_ index: Int) -> String {
        "Q\(index + 1)"
    }
}
