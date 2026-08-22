import Foundation

/// 사고 모드 전환을 유발하는 신호(§8). 사용자에게 노출되지 않는 내부 판단 근거다.
public enum RoutingSignal: String, Hashable, Sendable, CaseIterable, Codable {
    /// 결정인지 제안인지 불명확
    case decisionAmbiguous
    /// 담당자가 직접 언급되지 않음
    case assigneeMissing
    /// 마감일이 모호함
    case dueDateVague
    /// 여러 발언을 연결해야 함
    case multiSegmentEvidence
    /// 발언 사이에 충돌이 있음
    case conflictingStatements
    /// 이전 발언과 현재 발언을 비교해야 함
    case crossWindowComparison
    /// 전사 confidence가 낮음
    case lowTranscriptConfidence
    /// "검토", "추후", "일단", "보류" 등 모호한 표현
    case vagueExpression
    /// 여러 후보 중 최종 결론을 판단해야 함
    case multipleCandidates
    /// 액션아이템 후보가 서로 중복되거나 충돌함
    case duplicateOrConflictingActions
    /// 근거가 아예 없음
    case missingEvidence

    public var weight: Double {
        switch self {
        case .decisionAmbiguous: 1.0
        case .assigneeMissing: 0.7
        case .dueDateVague: 0.7
        case .multiSegmentEvidence: 0.5
        case .conflictingStatements: 1.0
        case .crossWindowComparison: 0.8
        case .lowTranscriptConfidence: 0.6
        case .vagueExpression: 0.8
        case .multipleCandidates: 0.7
        case .duplicateOrConflictingActions: 0.9
        case .missingEvidence: 1.0
        }
    }

    public var explanation: String {
        switch self {
        case .decisionAmbiguous: "결정인지 제안인지 불명확"
        case .assigneeMissing: "담당자가 직접 언급되지 않음"
        case .dueDateVague: "마감일 표현이 모호함"
        case .multiSegmentEvidence: "여러 발언을 연결해야 함"
        case .conflictingStatements: "발언 사이에 충돌이 있음"
        case .crossWindowComparison: "다른 구간의 발언과 비교해야 함"
        case .lowTranscriptConfidence: "전사 신뢰도가 낮음"
        case .vagueExpression: "모호한 표현이 포함됨"
        case .multipleCandidates: "여러 후보 중 결론을 판단해야 함"
        case .duplicateOrConflictingActions: "액션아이템 후보가 중복되거나 충돌함"
        case .missingEvidence: "원문 근거가 없음"
        }
    }
}

public struct RoutingDecision: Hashable, Sendable {
    public var mode: ReasoningMode
    public var score: Double
    public var signals: [RoutingSignal]

    public init(mode: ReasoningMode, score: Double, signals: [RoutingSignal]) {
        self.mode = mode
        self.score = score
        self.signals = signals
    }

    public var needsThinking: Bool {
        mode == .thinking
    }
}

/// 사용자가 아니라 앱이 사고 모드를 결정한다(§8).
/// 순수 함수로 구현해 테스트로 라우팅 규칙을 고정한다.
public struct ReasoningRouter: Sendable {
    public struct Configuration: Sendable {
        /// 이 점수 이상이면 사고 모드로 재검토한다.
        public var thinkingThreshold: Double
        /// 이 값보다 낮은 전사 신뢰도는 낮은 것으로 본다.
        public var lowTranscriptConfidence: Double
        /// 이 값보다 낮은 후보 신뢰도는 재검토 신호로 본다.
        public var lowFactConfidence: Double
        /// 최종 종합을 사고 모드로 돌릴 재검토 비율 임계
        public var finalPassThinkingRatio: Double

        public init(
            thinkingThreshold: Double = 0.8,
            lowTranscriptConfidence: Double = 0.55,
            lowFactConfidence: Double = 0.6,
            finalPassThinkingRatio: Double = 0.25
        ) {
            self.thinkingThreshold = thinkingThreshold
            self.lowTranscriptConfidence = lowTranscriptConfidence
            self.lowFactConfidence = lowFactConfidence
            self.finalPassThinkingRatio = finalPassThinkingRatio
        }
    }

    /// 모호한 표현. 있으면 결정 여부를 사고 모드로 다시 본다.
    static let vagueExpressions: [String] = [
        "검토", "추후", "일단", "보류", "나중에", "다시 논의", "논의해", "고민", "아마",
        "될 것 같", "될 것같", "가능할 것", "해보고", "확인해보", "정도", "쯤", "언젠가",
        "협의", "조율", "봐야", "대략", "웬만하면", "웬만", "가급적"
    ]

    /// 마감일로 확정하기 어려운 표현
    static let vagueDueDates: [String] = [
        "쯤", "정도", "이내", "안에", "무렵", "다음에", "추후", "빠르게", "조만간", "가능하면",
        "이번 중", "다음 중", "곧"
    ]

    public var configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// 후보 하나에 대한 라우팅 판단.
    /// - Parameters:
    ///   - fact: 1차 추출 후보
    ///   - segments: 근거로 지목된 전사 세그먼트 (전사 신뢰도 확인용)
    ///   - peers: 같은 회의의 다른 후보 (중복·충돌 확인용)
    public func decide(
        for fact: MeetingFact,
        segments: [TranscriptSegment],
        peers: [MeetingFact] = []
    ) -> RoutingDecision {
        var signals: Set<RoutingSignal> = []

        if fact.evidence.isEmpty {
            signals.insert(.missingEvidence)
        } else if fact.evidence.count >= 2 {
            signals.insert(.multiSegmentEvidence)
        }

        if fact.kind == .decision {
            if fact.decisionKind == nil || fact.decisionKind == .proposed {
                signals.insert(.decisionAmbiguous)
            }
        }

        if fact.kind == .actionItem, fact.assignee == nil {
            signals.insert(.assigneeMissing)
        }

        if fact.kind == .actionItem {
            if fact.dueDate == nil, fact.dueDateNote != nil {
                signals.insert(.dueDateVague)
            } else if let dueDate = fact.dueDate,
                      Self.vagueDueDates.contains(where: { dueDate.contains($0) }) {
                signals.insert(.dueDateVague)
            }
        }

        let haystack = ([fact.content, fact.dueDateNote ?? ""] + fact.evidence.map(\.quote))
            .joined(separator: " ")
        if Self.vagueExpressions.contains(where: { haystack.contains($0) }) {
            signals.insert(.vagueExpression)
        }

        if fact.confidence < configuration.lowFactConfidence {
            signals.insert(.multipleCandidates)
        }

        let evidenceSegmentIds = Set(fact.evidence.map(\.segmentId))
        let relevantSegments = segments.filter { evidenceSegmentIds.contains($0.id.uuidString) }
        if relevantSegments.contains(where: { ($0.confidence ?? 1) < configuration.lowTranscriptConfidence }) {
            signals.insert(.lowTranscriptConfidence)
        }

        if !fact.ambiguityNotes.isEmpty {
            signals.insert(.decisionAmbiguous)
        }

        // 다른 후보와의 관계
        let similar = peers.filter { $0.id != fact.id && Self.isSimilar($0, fact) }
        if !similar.isEmpty {
            if similar.contains(where: { $0.windowIndex != fact.windowIndex }) {
                signals.insert(.crossWindowComparison)
            }
            if fact.kind == .actionItem,
               similar.contains(where: {
                   ($0.assignee ?? "") != (fact.assignee ?? "") || ($0.dueDate ?? "") != (fact.dueDate ?? "")
               }) {
                signals.insert(.duplicateOrConflictingActions)
            }
            if fact.kind == .decision,
               similar.contains(where: { $0.decisionKind != fact.decisionKind || $0.content != fact.content }) {
                signals.insert(.conflictingStatements)
            }
            signals.insert(.multipleCandidates)
        }

        let ordered = RoutingSignal.allCases.filter { signals.contains($0) }
        let score = ordered.reduce(0) { $0 + $1.weight }
        // §8의 전환 조건은 "하나 이상"이다. 점수는 재검토 예산이 부족할 때 우선순위를 정하는 데만 쓴다.
        return RoutingDecision(
            mode: ordered.isEmpty ? .nonThinking : .thinking,
            score: score,
            signals: ordered
        )
    }

    /// 최종 종합 단계의 모드. 단순한 회의는 비사고 모드로 정리한다(§8).
    public func decideFinalPass(
        totalCandidates: Int,
        reviewedCandidates: Int,
        conflictCount: Int,
        unresolvedCount: Int
    ) -> RoutingDecision {
        var signals: Set<RoutingSignal> = []
        if conflictCount > 0 {
            signals.insert(.conflictingStatements)
        }
        if unresolvedCount > 0 {
            signals.insert(.decisionAmbiguous)
        }

        let ratio = totalCandidates > 0 ? Double(reviewedCandidates) / Double(totalCandidates) : 0
        if ratio >= configuration.finalPassThinkingRatio, reviewedCandidates > 0 {
            signals.insert(.multipleCandidates)
        }

        let ordered = RoutingSignal.allCases.filter { signals.contains($0) }
        let score = ordered.reduce(0) { $0 + $1.weight }
        return RoutingDecision(
            mode: score >= configuration.thinkingThreshold ? .thinking : .nonThinking,
            score: score,
            signals: ordered
        )
    }

    /// 내용이 사실상 같은 후보인지. 반복 발언 통합과 충돌 탐지에 함께 쓴다.
    static func isSimilar(_ lhs: MeetingFact, _ rhs: MeetingFact) -> Bool {
        guard lhs.kind == rhs.kind else { return false }
        return TextSimilarity.overlap(lhs.content, rhs.content) >= 0.6
    }
}

/// 한국어 문장 유사도. 형태소 분석 없이 문자 bigram으로 근사한다.
public enum TextSimilarity {
    public static func bigrams(_ text: String) -> Set<String> {
        let cleaned = text.lowercased().filter { $0.isLetter || $0.isNumber }
        let characters = Array(cleaned)
        guard characters.count > 1 else { return Set(characters.map(String.init)) }
        var result: Set<String> = []
        for index in 0 ..< (characters.count - 1) {
            result.insert(String(characters[index ... index + 1]))
        }
        return result
    }

    public static func jaccard(_ lhs: String, _ rhs: String) -> Double {
        let left = bigrams(lhs)
        let right = bigrams(rhs)
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        let intersection = left.intersection(right).count
        let union = left.union(right).count
        return union == 0 ? 0 : Double(intersection) / Double(union)
    }

    /// 겹침 계수. 길이가 다른 한국어 문장(어미·조사 차이)의 동일성 판정에 jaccard보다 잘 맞는다.
    /// 짧은 문장이 우연히 포함되는 것을 막기 위해 최소 길이를 요구한다.
    public static func overlap(_ lhs: String, _ rhs: String, minimumBigrams: Int = 3) -> Double {
        let left = bigrams(lhs)
        let right = bigrams(rhs)
        guard left.count >= minimumBigrams, right.count >= minimumBigrams else { return 0 }
        let intersection = left.intersection(right).count
        return Double(intersection) / Double(min(left.count, right.count))
    }
}
