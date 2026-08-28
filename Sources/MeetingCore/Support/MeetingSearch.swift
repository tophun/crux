import Foundation

/// 회의 제목·회의록·전사문·결정·액션을 이 기기에서만 찾는다.
///
/// 네트워크와 모델을 부르지 않는다. 맞춘 문장은 상세 화면에 그대로 보여 준다.
public enum MeetingSearch {
    /// 검색이 맞춘 필드.
    public enum Field: String, Sendable, Hashable {
        case title
        case notes
        case transcript
        case decision
        case action

        public var displayName: String {
            switch self {
            case .title: "제목"
            case .notes: "회의록"
            case .transcript: "전사문"
            case .decision: "결정사항"
            case .action: "액션"
            }
        }
    }

    /// 목록에서 고른 결과가 상세에서 보여줄 한 문장.
    public struct Hit: Sendable, Hashable {
        public var field: Field
        public var sentence: String

        public init(field: Field, sentence: String) {
            self.field = field
            self.sentence = sentence
        }
    }

    /// 한 회의에서 검색할 로컬 텍스트. 저장소가 이미 읽어 둔 값만 넣는다.
    public struct Document: Sendable, Hashable {
        public var title: String
        public var notes: [String]
        public var transcript: [String]
        public var decisions: [String]
        public var actions: [String]

        public init(
            title: String,
            notes: [String] = [],
            transcript: [String] = [],
            decisions: [String] = [],
            actions: [String] = []
        ) {
            self.title = title
            self.notes = notes
            self.transcript = transcript
            self.decisions = decisions
            self.actions = actions
        }
    }

    /// 빈 질의는 검색하지 않는다. 앞뒤 공백만 있는 입력도 비운 것으로 본다.
    public static func normalizedQuery(_ query: String?) -> String? {
        guard let query else { return nil }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 제목만으로는 지난 결정·액션을 못 찾으므로 내용 필드를 먼저 본다.
    public static func firstHit(query: String, in document: Document) -> Hit? {
        guard let needle = normalizedQuery(query) else { return nil }

        if let sentence = firstSentence(in: document.transcript, matching: needle) {
            return Hit(field: .transcript, sentence: sentence)
        }
        if let sentence = firstSentence(in: document.decisions, matching: needle) {
            return Hit(field: .decision, sentence: sentence)
        }
        if let sentence = firstSentence(in: document.actions, matching: needle) {
            return Hit(field: .action, sentence: sentence)
        }
        if let sentence = firstSentence(in: document.notes, matching: needle) {
            return Hit(field: .notes, sentence: sentence)
        }
        if let sentence = sentence(in: document.title, matching: needle) {
            return Hit(field: .title, sentence: sentence)
        }
        return nil
    }

    /// 질의어가 들어 있는 문장. 문장 구분이 없으면 해당 텍스트 전체를 돌려준다.
    public static func sentence(in text: String, matching query: String) -> String? {
        guard let needle = normalizedQuery(query) else { return nil }
        let parts = sentences(in: text)
        if let match = parts.first(where: { contains($0, needle) }) {
            return match
        }
        return contains(text, needle) ? collapseWhitespace(text) : nil
    }

    public static func contains(_ text: String, _ query: String) -> Bool {
        guard let needle = normalizedQuery(query) else { return false }
        return text.localizedCaseInsensitiveContains(needle)
    }

    private static func firstSentence(in texts: [String], matching needle: String) -> String? {
        for text in texts {
            if let sentence = sentence(in: text, matching: needle) {
                return sentence
            }
        }
        return nil
    }

    private static func sentences(in text: String) -> [String] {
        var result: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if Self.sentenceTerminators.contains(character) {
                let piece = collapseWhitespace(current)
                if !piece.isEmpty {
                    result.append(piece)
                }
                current = ""
            }
        }
        let tail = collapseWhitespace(current)
        if !tail.isEmpty {
            result.append(tail)
        }
        return result
    }

    private static let sentenceTerminators: Set<Character> = [".", "。", "!", "?", "！", "？", "\n"]

    private static func collapseWhitespace(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
