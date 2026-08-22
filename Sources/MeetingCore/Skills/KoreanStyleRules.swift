import Foundation

/// AI 티 패턴의 심각도.
public enum KoreanTellSeverity: String, Sendable, Codable, Comparable, CaseIterable {
    /// 결정적 — 1회로 확신
    case s1 = "S1"
    /// 강함 — 반복되면 티
    case s2 = "S2"
    /// 약함 — 중첩 시 강화
    case s3 = "S3"

    public static func < (lhs: Self, rhs: Self) -> Bool {
        let order: [KoreanTellSeverity] = [.s1, .s2, .s3]
        return order.firstIndex(of: lhs)! < order.firstIndex(of: rhs)!
    }
}

/// AI 티 패턴 대분류. `im-not-ai`의 분류 체계를 따른다.
public enum KoreanTellCategory: String, Sendable, Codable, CaseIterable {
    case translationese = "A"
    case englishOveruse = "B"
    case structuralPattern = "C"
    case signaturePhrase = "D"
    case rhythm = "E"
    case redundantModifier = "F"
    case hedging = "G"
    case conjunctionOveruse = "H"
    case formalNoun = "I"
    case visualDecoration = "J"
    /// fluent-korean에서 온 명확성 규칙
    case clarity = "K"

    public var displayName: String {
        switch self {
        case .translationese: "번역투"
        case .englishOveruse: "영어 과다"
        case .structuralPattern: "기계적 구조"
        case .signaturePhrase: "AI 관용구"
        case .rhythm: "리듬 균일"
        case .redundantModifier: "과도한 수식"
        case .hedging: "과도한 완곡"
        case .conjunctionOveruse: "접속사 남발"
        case .formalNoun: "형식명사 과다"
        case .visualDecoration: "시각 장식"
        case .clarity: "의미 불명확"
        }
    }
}

/// 규칙 하나. 탐지는 모든 규칙이 하고, 결정적 치환은 안전한 규칙만 한다.
public struct KoreanStyleRule: Sendable {
    public let id: String
    public let category: KoreanTellCategory
    public let severity: KoreanTellSeverity
    /// 규칙 설명 (처방)
    public let prescription: String
    /// 이 횟수를 넘을 때만 문제로 본다. 1이면 1회로 문제.
    public let threshold: Int
    /// 탐지 패턴 (정규식)
    public let pattern: String
    /// 결정적 치환. nil이면 탐지만 하고 LLM 윤문에 맡긴다.
    public let replacement: (@Sendable (NSTextCheckingResult, String) -> String?)?

    public init(
        id: String,
        category: KoreanTellCategory,
        severity: KoreanTellSeverity,
        prescription: String,
        pattern: String,
        threshold: Int = 1,
        replacement: (@Sendable (NSTextCheckingResult, String) -> String?)? = nil
    ) {
        self.id = id
        self.category = category
        self.severity = severity
        self.prescription = prescription
        self.threshold = threshold
        self.pattern = pattern
        self.replacement = replacement
    }
}

/// 탐지된 구간.
public struct KoreanTellSpan: Hashable, Sendable, Codable {
    public var ruleId: String
    public var category: KoreanTellCategory
    public var severity: KoreanTellSeverity
    public var text: String
    public var prescription: String

    public init(
        ruleId: String,
        category: KoreanTellCategory,
        severity: KoreanTellSeverity,
        text: String,
        prescription: String
    ) {
        self.ruleId = ruleId
        self.category = category
        self.severity = severity
        self.text = text
        self.prescription = prescription
    }
}

/// 규칙 모음.
///
/// 출처
/// - `im-not-ai` (MIT, epoko77-ai) — quick-rules v2.0의 카테고리·ID·처방을 회의록 도메인에 맞게 이식
/// - `fluent-korean` (MIT, snflkd) — 조사·어미 생략 보정, 명사 나열 개선, 엠대시 축소 규칙을 K 카테고리로 이식
///
/// 두 저장소는 Claude Code용 플러그인·output style이므로 지침만 추출해 앱 내부 규칙으로 재구성했다.
public enum KoreanStyleRules {
    /// Do-NOT: 탐지·윤문 모두 제외. 고유명사·수치·날짜·직접 인용·표준 기술 용어는 건드리지 않는다.
    public static let protectedTerms: [String] = [
        "API", "LLM", "GPU", "CPU", "QA", "MCP", "SQL", "URL", "JSON", "SDK", "UI", "UX",
        "prompt", "token", "pipeline", "Confluence", "Jira", "Slack", "Zoom", "Teams",
    ]

    public static let all: [KoreanStyleRule] = [
        // MARK: A. 번역투
        KoreanStyleRule(
            id: "A-1",
            category: .translationese,
            severity: .s1,
            prescription: "\"~에 대해\"를 목적격 조사로 직결한다",
            pattern: "([가-힣A-Za-z0-9]+)에 대해서?\\s+(논의|검토|설명|합의|이야기|공유|결정)",
            replacement: { match, source in
                guard let noun = match.substring(at: 1, in: source),
                      let verb = match.substring(at: 2, in: source) else { return nil }
                return "\(noun)\(KoreanParticle.objective(after: noun)) \(verb)"
            }
        ),
        KoreanStyleRule(
            id: "A-3",
            category: .translationese,
            severity: .s1,
            prescription: "\"~에 있어(서)\"는 \"~에서\"로 바꾼다",
            pattern: "에 있어서?",
            replacement: { _, _ in "에서" }
        ),
        KoreanStyleRule(
            id: "A-7",
            category: .translationese,
            severity: .s1,
            prescription: "\"~를 가지고 있다\"는 \"~가 있다\"로 환원한다",
            pattern: "([가-힣A-Za-z0-9]+)(?:을|를) 가지고 (있습니다|있다|있음)",
            replacement: { match, source in
                guard let noun = match.substring(at: 1, in: source),
                      let tail = match.substring(at: 2, in: source) else { return nil }
                return "\(noun)\(KoreanParticle.subjective(after: noun)) \(tail)"
            }
        ),
        KoreanStyleRule(
            id: "A-8",
            category: .translationese,
            severity: .s1,
            prescription: "이중 피동을 단일 피동으로 되돌린다",
            pattern: "되어(진다|집니다|졌다|졌습니다)",
            replacement: { match, source in
                switch match.substring(at: 1, in: source) {
                case "진다": "된다"
                case "집니다": "됩니다"
                case "졌다": "되었다"
                case "졌습니다": "되었습니다"
                default: nil
                }
            }
        ),
        KoreanStyleRule(
            id: "A-9",
            category: .translationese,
            severity: .s2,
            prescription: "\"~에 의해\" 피동은 행위자를 주어로 바꾼다",
            pattern: "에 의해\\s?",
            threshold: 2
        ),
        KoreanStyleRule(
            id: "A-10",
            category: .translationese,
            severity: .s2,
            prescription: "\"~할 수 있다\" 남발을 단언으로 바꾼다",
            pattern: "[가-힣]\\s?수 있(다|습니다)",
            threshold: 3
        ),
        KoreanStyleRule(
            id: "A-11",
            category: .translationese,
            severity: .s2,
            prescription: "\"~을 위해\" 목적절 남발을 \"~려고/도록\"으로 분산한다",
            pattern: "(?:을|를) 위해",
            threshold: 3
        ),
        KoreanStyleRule(
            id: "A-16",
            category: .translationese,
            severity: .s1,
            prescription: "영어 대명사 직역(그/그것/그들)을 생략하거나 명사구로 바꾼다",
            pattern: "\\b그(것|들|녀)(?:은|는|이|가|을|를)",
            threshold: 3
        ),
        KoreanStyleRule(
            id: "A-19",
            category: .translationese,
            severity: .s2,
            prescription: "이중 조사(~에서의/~으로의)를 절로 풀어쓴다",
            pattern: "(에서의|으로의|에로의|에의|으로부터의|로부터의)",
            threshold: 2
        ),

        // MARK: C. 기계적 구조
        KoreanStyleRule(
            id: "C-5",
            category: .structuralPattern,
            severity: .s1,
            prescription: "회의록에서는 이모지를 쓰지 않는다",
            pattern: "[\\p{So}\\p{Sk}]",
            replacement: { _, _ in "" }
        ),
        KoreanStyleRule(
            id: "C-9",
            category: .structuralPattern,
            severity: .s2,
            prescription: "숫자 괄호 인덱싱을 본문에 녹인다",
            pattern: "\\d\\)\\s",
            threshold: 3
        ),
        KoreanStyleRule(
            id: "C-11",
            category: .structuralPattern,
            severity: .s1,
            prescription: "연결어미 직후 쉼표를 제거한다",
            pattern: "(고|며|지만|면서|아서|어서|는데),\\s",
            replacement: { match, source in
                guard let ending = match.substring(at: 1, in: source) else { return nil }
                return "\(ending) "
            }
        ),

        // MARK: D. AI 관용구
        KoreanStyleRule(
            id: "D-1",
            category: .signaturePhrase,
            severity: .s1,
            prescription: "결산 관용구(결론적으로/요약하면)를 덜어낸다",
            pattern: "(결론적으로|요약하면|정리하자면|이를 통해)[,\\s]",
            threshold: 1,
            replacement: { _, _ in "" }
        ),
        KoreanStyleRule(
            id: "D-2",
            category: .signaturePhrase,
            severity: .s1,
            prescription: "의의 과장(시사하는 바가 크다/주목할 만하다)을 삭제하거나 구체 결론으로 바꾼다",
            pattern: "(시사하는 바가 크|주목할 만하|매우 중요하|의미가 크)",
            threshold: 1
        ),
        KoreanStyleRule(
            id: "D-3",
            category: .signaturePhrase,
            severity: .s1,
            prescription: "열거 도입구를 삭제하고 바로 본론을 쓴다",
            pattern: "(크게 [가-힣]+ 가지로 나눌 수 있|다음과 같습니다|다음과 같은)",
            threshold: 1
        ),
        KoreanStyleRule(
            id: "D-4",
            category: .signaturePhrase,
            severity: .s2,
            prescription: "hype 어휘를 구체 수치·사실로 바꾼다",
            pattern: "(혁신적|획기적|압도적|파격적|폭발적|전례 없는)",
            threshold: 1
        ),

        // MARK: G. 완곡
        KoreanStyleRule(
            id: "G-1",
            category: .hedging,
            severity: .s2,
            prescription: "추측 종결을 단언으로 바꾼다",
            pattern: "(으로 보입니다|로 보입니다|로 판단됩니다|라고 여겨집니다|인 듯합니다)",
            threshold: 2
        ),
        KoreanStyleRule(
            id: "G-2",
            category: .hedging,
            severity: .s2,
            prescription: "이중 완곡을 하나만 남긴다",
            pattern: "(할 가능성이 있을 수 있|로 보여질 수 있|것으로 예상될 수 있)",
            threshold: 1
        ),

        // MARK: H. 접속사
        KoreanStyleRule(
            id: "H-1",
            category: .conjunctionOveruse,
            severity: .s2,
            prescription: "문두 접속사를 대폭 줄인다",
            pattern: "(?:^|(?<=\\. ))(또한|따라서|즉|나아가|아울러|게다가|더욱이)[,\\s]",
            threshold: 3
        ),
        KoreanStyleRule(
            id: "H-3",
            category: .conjunctionOveruse,
            severity: .s2,
            prescription: "메타 진입구를 본문에 녹인다",
            pattern: "(이는 |이 점에서|이 관점에서|이 말은)",
            threshold: 2
        ),

        // MARK: I. 형식명사
        KoreanStyleRule(
            id: "I-2",
            category: .formalNoun,
            severity: .s2,
            prescription: "형식명사 강조를 직설로 바꾼다",
            pattern: "(주목할 점은|중요한 점은)",
            threshold: 1
        ),
        KoreanStyleRule(
            id: "I-3",
            category: .formalNoun,
            severity: .s1,
            prescription: "\"~다는 것이다\" 결말을 직접 종결로 바꾼다",
            pattern: "다는 것(이다|입니다)\\.",
            replacement: { match, source in
                match.substring(at: 1, in: source) == "입니다" ? "다는 뜻입니다." : "다."
            }
        ),
        KoreanStyleRule(
            id: "I-4",
            category: .formalNoun,
            severity: .s2,
            prescription: "권고형 결말을 구체 동사 단언으로 바꾼다",
            pattern: "(해야 합니다|할 필요가 있습니다|해야 한다)",
            threshold: 4
        ),

        // MARK: J. 시각 장식
        KoreanStyleRule(
            id: "J-1",
            category: .visualDecoration,
            severity: .s2,
            prescription: "회의록 본문의 볼드 강조를 없앤다",
            pattern: "\\*\\*([^*]+)\\*\\*",
            replacement: { match, source in match.substring(at: 1, in: source) }
        ),
        KoreanStyleRule(
            id: "J-3",
            category: .visualDecoration,
            severity: .s2,
            prescription: "엠대시 부가 설명을 쉼표나 별도 문장으로 바꾼다",
            pattern: "\\s—\\s",
            replacement: { _, _ in ", " }
        ),

        // MARK: K. fluent-korean — 의미 명확성
        KoreanStyleRule(
            id: "K-1",
            category: .clarity,
            severity: .s2,
            prescription: "명사구로 끝난 문장에 서술어와 종결어미를 붙인다",
            pattern: "(?:^|\\. )[^.!?\\n]*[가-힣]+(?:함|됨|임|음|기|중|필요|예정|완료)\\.",
            threshold: 1
        ),
        KoreanStyleRule(
            id: "K-2",
            category: .clarity,
            severity: .s2,
            prescription: "조사 없이 명사만 나열한 부분에 조사를 넣는다",
            pattern: "[가-힣]{2,} [가-힣]{2,} [가-힣]{2,} (?:진행|완료|필요|예정|검토)",
            threshold: 1
        ),
        KoreanStyleRule(
            id: "K-3",
            category: .clarity,
            severity: .s2,
            prescription: "관형격 조사 \"~의\"를 3회 이상 겹쳐 쓰지 않는다",
            pattern: "[가-힣]+의 [가-힣]+의",
            threshold: 1
        ),
    ]

    public static func rule(id: String) -> KoreanStyleRule? {
        all.first { $0.id == id }
    }
}

extension NSTextCheckingResult {
    /// 캡처 그룹 문자열
    func substring(at index: Int, in source: String) -> String? {
        guard index < numberOfRanges else { return nil }
        let range = self.range(at: index)
        guard range.location != NSNotFound, let swiftRange = Range(range, in: source) else { return nil }
        return String(source[swiftRange])
    }
}
