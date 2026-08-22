import Foundation

/// 마감일이 원문에 실제로 있는지 검사한다.
///
/// 모델은 "다음 주 월요일"을 임의의 절대 날짜(예: `2023-03-07`)로 바꾸는 경향이 있다.
/// 근거 인용에 그 날짜가 없으면 확정하지 않고 원문 표현만 남긴다(§2, §8).
public enum DueDateGrounding {
    public struct Result: Hashable, Sendable {
        public var dueDate: String?
        public var dueDateNote: String?
        /// 근거 없는 값을 내렸는지 (로그용)
        public var demoted: Bool
        public var reason: String?
    }

    /// - Parameters:
    ///   - dueDate: 모델이 제시한 마감일
    ///   - dueDateNote: 모델이 남긴 원문 일정 표현
    ///   - evidenceTexts: 근거 인용문과 근거 구간 원문
    public static func check(
        dueDate: String?,
        dueDateNote: String?,
        evidenceTexts: [String]
    ) -> Result {
        guard let dueDate, !dueDate.trimmingCharacters(in: .whitespaces).isEmpty else {
            return Result(dueDate: nil, dueDateNote: dueDateNote, demoted: false, reason: nil)
        }

        let haystack = evidenceTexts.joined(separator: " ")
        guard !haystack.isEmpty else {
            return Result(
                dueDate: nil,
                dueDateNote: dueDateNote ?? dueDate,
                demoted: true,
                reason: "근거가 없어 마감일을 확정하지 않음: \(dueDate)"
            )
        }

        let normalizedHaystack = normalize(haystack)
        let numbers = numericGroups(in: dueDate)

        if numbers.isEmpty {
            // 숫자가 없는 상대 표현("다음 주 월요일", "추후"). 표현 자체가 원문에 있어야 인정한다.
            if normalizedHaystack.contains(normalize(dueDate)) {
                return Result(dueDate: dueDate, dueDateNote: dueDateNote, demoted: false, reason: nil)
            }
            return Result(
                dueDate: nil,
                dueDateNote: dueDateNote ?? dueDate,
                demoted: true,
                reason: "원문에 없는 마감일 표현이라 확정하지 않음: \(dueDate)"
            )
        }

        // 숫자가 있는 날짜는 모든 숫자 조각이 원문에 있어야 한다.
        // 연도처럼 원문에 없는 값을 붙인 경우를 걸러낸다.
        let haystackNumbers = Set(numericGroups(in: haystack))
        let missing = numbers.filter { !haystackNumbers.contains($0) && !stripLeadingZero(in: haystackNumbers, matches: $0) }
        if missing.isEmpty {
            return Result(dueDate: dueDate, dueDateNote: dueDateNote, demoted: false, reason: nil)
        }

        return Result(
            dueDate: nil,
            dueDateNote: dueDateNote ?? dueDate,
            demoted: true,
            reason: "원문에서 확인되지 않는 날짜라 확정하지 않음: \(dueDate) (근거에 없는 값: \(missing.joined(separator: ",")))"
        )
    }

    /// 후보 하나에 규칙을 적용한다.
    public static func apply(to fact: MeetingFact, segments: [TranscriptSegment]) -> (MeetingFact, String?) {
        guard fact.kind == .actionItem else { return (fact, nil) }
        let byId = Dictionary(segments.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { first, _ in first })
        let texts = fact.evidence.flatMap { evidence -> [String] in
            [evidence.quote, byId[evidence.segmentId]?.text].compactMap(\.self)
        }
        let result = check(dueDate: fact.dueDate, dueDateNote: fact.dueDateNote, evidenceTexts: texts)
        var updated = fact
        updated.dueDate = result.dueDate
        updated.dueDateNote = result.dueDateNote
        return (updated, result.reason)
    }

    static func numericGroups(in text: String) -> [String] {
        var groups: [String] = []
        var current = ""
        for character in text {
            if character.isNumber {
                current.append(character)
            } else if !current.isEmpty {
                groups.append(current)
                current = ""
            }
        }
        if !current.isEmpty { groups.append(current) }
        return groups
    }

    /// "03"과 "3"을 같은 값으로 본다.
    static func stripLeadingZero(in haystack: Set<String>, matches number: String) -> Bool {
        let trimmed = String(number.drop(while: { $0 == "0" }))
        guard !trimmed.isEmpty else { return false }
        return haystack.contains(trimmed) || haystack.contains { String($0.drop(while: { $0 == "0" })) == trimmed }
    }

    static func normalize(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
