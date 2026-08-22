import Foundation

/// 1차(비사고 모드) 추출로 얻은 후보 사실. 아직 회의록에 넣을지 결정되지 않은 상태다.
public struct MeetingFact: Identifiable, Hashable, Sendable, Codable {
    public var id: UUID
    public var meetingId: UUID
    public var windowIndex: Int
    public var kind: Kind
    /// 후보의 내용. 결정/액션/리스크/질문 모두 같은 필드를 쓴다.
    public var content: String
    public var assignee: String?
    public var dueDate: String?
    public var dueDateNote: String?
    /// 결정 후보일 때 확정 여부. 제안과 결정을 섞지 않기 위해 분리한다.
    public var decisionKind: DecisionKind?
    public var severity: RiskSeverity?
    public var evidence: [Evidence]
    public var confidence: Double
    /// 모델이 스스로 애매하다고 표시한 이유(있으면). 라우팅 신호로 사용한다.
    public var ambiguityNotes: [String]
    /// 사고 모드 재검토를 마쳤는지
    public var reviewed: Bool
    /// 재검토 결과 폐기됨
    public var discarded: Bool

    public enum Kind: String, Codable, Sendable, CaseIterable {
        case decision
        case actionItem
        case risk
        case openQuestion
        case topic
    }

    public init(
        id: UUID = UUID(),
        meetingId: UUID,
        windowIndex: Int,
        kind: Kind,
        content: String,
        assignee: String? = nil,
        dueDate: String? = nil,
        dueDateNote: String? = nil,
        decisionKind: DecisionKind? = nil,
        severity: RiskSeverity? = nil,
        evidence: [Evidence] = [],
        confidence: Double = 0,
        ambiguityNotes: [String] = [],
        reviewed: Bool = false,
        discarded: Bool = false
    ) {
        self.id = id
        self.meetingId = meetingId
        self.windowIndex = windowIndex
        self.kind = kind
        self.content = content
        self.assignee = assignee
        self.dueDate = dueDate
        self.dueDateNote = dueDateNote
        self.decisionKind = decisionKind
        self.severity = severity
        self.evidence = evidence
        self.confidence = confidence
        self.ambiguityNotes = ambiguityNotes
        self.reviewed = reviewed
        self.discarded = discarded
    }
}

/// 전사 구간의 회의록 반영 방식 (§9).
public enum RelevanceLabel: String, Codable, Sendable, CaseIterable {
    /// 회의록에 유지
    case keep = "KEEP"
    /// 핵심 의미만 요약
    case condense = "CONDENSE"
    /// 회의록에서 제외
    case exclude = "EXCLUDE"
    /// 중요성 판단이 어려워 최소한으로 보존
    case uncertain = "UNCERTAIN"

    /// 회의록 생성 입력에 포함되는지 여부. EXCLUDE만 빠진다.
    public var isIncludedInNote: Bool {
        self != .exclude
    }
}

/// 세그먼트 단위 사담 판정 결과.
public struct RelevanceDecision: Hashable, Sendable, Codable {
    public var segmentId: UUID
    public var label: RelevanceLabel
    /// 규칙과 모델 판정이 달라 상향 조정된 경우의 근거. 중요한 맥락 삭제를 막기 위한 기록.
    public var reason: String?

    public init(segmentId: UUID, label: RelevanceLabel, reason: String? = nil) {
        self.segmentId = segmentId
        self.label = label
        self.reason = reason
    }
}
