import Foundation

/// 규칙 기반 탐지와 결정적 치환.
///
/// LLM 없이 동작하며, 여기서 처리하지 못한 구간만 LLM 윤문으로 넘긴다.
public struct KoreanTextPolisher: Sendable {
    public struct Result: Sendable {
        public var text: String
        /// 결정적 치환으로 해결한 규칙
        public var appliedRuleIds: [String]
        /// 남아 있는 탐지 구간 (LLM 윤문 대상)
        public var remaining: [KoreanTellSpan]
        public var changeRate: Double
    }

    private let rules: [KoreanStyleRule]

    public init(rules: [KoreanStyleRule] = KoreanStyleRules.all) {
        self.rules = rules
    }

    /// 탐지만 수행한다.
    public func detect(in text: String) -> [KoreanTellSpan] {
        var spans: [KoreanTellSpan] = []
        for rule in rules {
            let matches = Self.matches(of: rule, in: text)
            guard matches.count >= rule.threshold else { continue }
            // 임계를 넘은 만큼만 문제로 본다 (예: 3회 허용 규칙에서 5회면 2건).
            let reportable = rule.threshold > 1
                ? Array(matches.suffix(matches.count - rule.threshold + 1))
                : matches
            for match in reportable {
                guard let matched = match.substring(at: 0, in: text) else { continue }
                if Self.isProtected(matched) { continue }
                spans.append(
                    KoreanTellSpan(
                        ruleId: rule.id,
                        category: rule.category,
                        severity: rule.severity,
                        text: matched,
                        prescription: rule.prescription
                    )
                )
            }
        }
        return spans
    }

    /// 결정적 치환을 적용하고 남은 구간을 돌려준다.
    public func polish(_ text: String) -> Result {
        var current = text
        var applied: [String] = []

        for rule in rules {
            guard let replacement = rule.replacement else { continue }
            let matches = Self.matches(of: rule, in: current)
            guard matches.count >= rule.threshold else { continue }

            // 뒤에서부터 바꿔 인덱스가 밀리지 않게 한다.
            var updated = current
            var changed = false
            for match in matches.reversed() {
                guard let matched = match.substring(at: 0, in: current), !Self.isProtected(matched) else { continue }
                guard let value = replacement(match, current),
                      let range = Range(match.range, in: updated) else { continue }
                updated.replaceSubrange(range, with: value)
                changed = true
            }
            if changed {
                current = updated
                applied.append(rule.id)
            }
        }

        // 치환으로 생긴 이중 공백·문장 앞 공백 정리
        current = Self.tidy(current)

        return Result(
            text: current,
            appliedRuleIds: applied,
            remaining: detect(in: current),
            changeRate: ChangeRate.between(text, current)
        )
    }

    // MARK: - 내부

    static func matches(of rule: KoreanStyleRule, in text: String) -> [NSTextCheckingResult] {
        guard let regex = try? NSRegularExpression(pattern: rule.pattern, options: []) else { return [] }
        return regex.matches(in: text, options: [], range: NSRange(text.startIndex..., in: text))
    }

    /// 보호 대상(고유명사·표준 기술 용어)을 포함하면 건드리지 않는다.
    static func isProtected(_ text: String) -> Bool {
        KoreanStyleRules.protectedTerms.contains { text.localizedCaseInsensitiveContains($0) }
    }

    static func tidy(_ text: String) -> String {
        var result = text
        while result.contains("  ") {
            result = result.replacingOccurrences(of: "  ", with: " ")
        }
        result = result.replacingOccurrences(of: " ,", with: ",")
        result = result.replacingOccurrences(of: " .", with: ".")
        result = result.replacingOccurrences(of: ",,", with: ",")
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// 변경률 계산. 과윤문 방지 가드의 기준값이다.
public enum ChangeRate {
    /// 0…1. 문자 단위 편집 거리를 길이로 정규화한다.
    public static func between(_ original: String, _ revised: String) -> Double {
        let left = Array(original)
        let right = Array(revised)
        guard !left.isEmpty || !right.isEmpty else { return 0 }
        let distance = levenshtein(left, right)
        return Double(distance) / Double(max(left.count, right.count))
    }

    static func levenshtein(_ lhs: [Character], _ rhs: [Character]) -> Int {
        if lhs.isEmpty { return rhs.count }
        if rhs.isEmpty { return lhs.count }
        var previous = Array(0 ... rhs.count)
        var current = [Int](repeating: 0, count: rhs.count + 1)
        for i in 1 ... lhs.count {
            current[0] = i
            for j in 1 ... rhs.count {
                let cost = lhs[i - 1] == rhs[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return previous[rhs.count]
    }
}

/// 내용 앵커 보존 검사. 수치·날짜·고유명사·인용이 사라지면 롤백한다.
public enum ContentAnchor {
    public struct Report: Sendable {
        public var missing: [String]
        public var isPreserved: Bool { missing.isEmpty }
    }

    /// 원문에서 반드시 살아남아야 하는 토큰을 뽑는다.
    public static func anchors(in text: String) -> [String] {
        var result: Set<String> = []

        // 숫자 + 단위 (85%, 3월 12일, 300만 원, 20%)
        if let regex = try? NSRegularExpression(pattern: "\\d+(?:[.,]\\d+)?", options: []) {
            for match in regex.matches(in: text, options: [], range: NSRange(text.startIndex..., in: text)) {
                if let value = match.substring(at: 0, in: text) { result.insert(value) }
            }
        }
        // 영문 토큰 (제품명·약어)
        if let regex = try? NSRegularExpression(pattern: "[A-Za-z][A-Za-z0-9_.+-]{1,}", options: []) {
            for match in regex.matches(in: text, options: [], range: NSRange(text.startIndex..., in: text)) {
                if let value = match.substring(at: 0, in: text) { result.insert(value) }
            }
        }
        // 큰따옴표 안 직접 인용
        if let regex = try? NSRegularExpression(pattern: "[\"\u{201C}]([^\"\u{201D}]{2,})[\"\u{201D}]", options: []) {
            for match in regex.matches(in: text, options: [], range: NSRange(text.startIndex..., in: text)) {
                if let value = match.substring(at: 1, in: text) { result.insert(value) }
            }
        }
        return result.sorted()
    }

    /// 원문 앵커가 결과에 모두 남아 있는지 확인한다.
    public static func check(original: String, revised: String) -> Report {
        let missing = anchors(in: original).filter { !revised.contains($0) }
        return Report(missing: missing)
    }
}
