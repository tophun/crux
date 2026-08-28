import Foundation

/// 근거가 부족할 때 사용자에게 보여줄 표시. 모델이 임의로 확정하지 않도록 강제한다.
public enum UnresolvedMarker {
    public static let undetermined = "미확정"
    public static let needsConfirmation = "추가 확인 필요"
}

/// 결정사항인지 제안사항인지의 구분. 둘을 섞지 않는다.
/// 결정사항을 화면에 보일 때 붙이는 구분 표시와, 저장할 때 떼어 내는 규칙.
///
/// 확정된 결정에는 아무것도 붙이지 않고, 제안에만 `[검토 중] `을 붙인다.
/// 뗄 때는 **우리가 붙인 문구와 정확히 같을 때만** 뗀다.
/// 아무 대괄호나 떼면 사용자가 직접 쓴 `[백엔드] 배포 확정` 같은 글이 잘린다.
public enum DecisionDisplay {
    public static func text(for decision: Decision) -> String {
        decision.kind == .decided ? decision.content : "[\(decision.kind.displayName)] " + decision.content
    }

    public static func stripped(_ text: String) -> String {
        for kind in DecisionKind.allCases {
            let marker = "[\(kind.displayName)] "
            if text.hasPrefix(marker) {
                return String(text.dropFirst(marker.count))
            }
        }
        return text
    }
}

public enum DecisionKind: String, Codable, Sendable, CaseIterable {
    /// 회의에서 확정된 결정
    case decided
    /// 제안·검토 단계로 확정되지 않은 항목
    case proposed

    public var displayName: String {
        switch self {
        case .decided: "결정"
        case .proposed: "제안"
        }
    }
}

public struct Decision: Identifiable, Hashable, Sendable, Codable {
    public var id: UUID
    public var content: String
    public var kind: DecisionKind
    public var evidence: [Evidence]
    public var confidence: Double
    /// 사고 모드 재검토를 거친 항목인지. 내부 사고 내용은 저장하지 않고 사실만 남긴다.
    public var reviewed: Bool

    public init(
        id: UUID = UUID(),
        content: String,
        kind: DecisionKind = .decided,
        evidence: [Evidence] = [],
        confidence: Double = 0,
        reviewed: Bool = false
    ) {
        self.id = id
        self.content = content
        self.kind = kind
        self.evidence = evidence
        self.confidence = confidence
        self.reviewed = reviewed
    }
}

public enum ActionItemStatus: String, Codable, Sendable, CaseIterable {
    case proposed
    case confirmed
    case inProgress
    case done
    case dropped

    public var displayName: String {
        switch self {
        case .proposed: "제안"
        case .confirmed: "확정"
        case .inProgress: "진행 중"
        case .done: "완료"
        case .dropped: "취소"
        }
    }

    /// 지난 회의에서 다음 회의로 이어 보여줄 상태. 완료·취소는 넣지 않는다.
    public var isUnfinished: Bool {
        switch self {
        case .proposed, .confirmed, .inProgress: true
        case .done, .dropped: false
        }
    }
}

public struct ActionItem: Identifiable, Hashable, Sendable, Codable {
    public var id: UUID
    public var task: String
    /// 원문에서 담당자가 확인되지 않으면 nil. 추론으로 채우지 않는다.
    public var assignee: String?
    /// 원문에서 마감일이 확인되지 않으면 nil. 모호한 표현은 `dueDateNote`에 남긴다.
    public var dueDate: String?
    /// "다음 주 중", "추후" 같은 모호한 일정 표현의 원문 보존용.
    public var dueDateNote: String?
    public var status: ActionItemStatus
    public var evidence: [Evidence]
    public var confidence: Double
    public var reviewed: Bool

    public init(
        id: UUID = UUID(),
        task: String,
        assignee: String? = nil,
        dueDate: String? = nil,
        dueDateNote: String? = nil,
        status: ActionItemStatus = .proposed,
        evidence: [Evidence] = [],
        confidence: Double = 0,
        reviewed: Bool = false
    ) {
        self.id = id
        self.task = task
        self.assignee = assignee
        self.dueDate = dueDate
        self.dueDateNote = dueDateNote
        self.status = status
        self.evidence = evidence
        self.confidence = confidence
        self.reviewed = reviewed
    }

    public var assigneeDisplay: String {
        assignee ?? UnresolvedMarker.undetermined
    }

    public var dueDateDisplay: String {
        if let dueDate {
            return dueDate
        }
        if let dueDateNote {
            return "\(dueDateNote) (\(UnresolvedMarker.needsConfirmation))"
        }
        return UnresolvedMarker.undetermined
    }
}

public struct OpenQuestion: Identifiable, Hashable, Sendable, Codable {
    public var id: UUID
    public var question: String
    public var evidence: [Evidence]
    public var confidence: Double

    public init(
        id: UUID = UUID(),
        question: String,
        evidence: [Evidence] = [],
        confidence: Double = 0
    ) {
        self.id = id
        self.question = question
        self.evidence = evidence
        self.confidence = confidence
    }
}

public enum RiskSeverity: String, Codable, Sendable, CaseIterable {
    case low, medium, high, unknown
}

public struct RiskItem: Identifiable, Hashable, Sendable, Codable {
    public var id: UUID
    public var content: String
    public var severity: RiskSeverity
    public var evidence: [Evidence]
    public var confidence: Double

    public init(
        id: UUID = UUID(),
        content: String,
        severity: RiskSeverity = .unknown,
        evidence: [Evidence] = [],
        confidence: Double = 0
    ) {
        self.id = id
        self.content = content
        self.severity = severity
        self.evidence = evidence
        self.confidence = confidence
    }
}

public struct Topic: Identifiable, Hashable, Sendable, Codable {
    public var id: UUID
    public var title: String
    public var summary: String
    public var startTime: TimeInterval?
    public var endTime: TimeInterval?

    public init(
        id: UUID = UUID(),
        title: String,
        summary: String = "",
        startTime: TimeInterval? = nil,
        endTime: TimeInterval? = nil
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.startTime = startTime
        self.endTime = endTime
    }
}

/// 최종 회의록. 회의에 참석하지 않은 사람이 이것만 읽고 결정·담당·기한·미결·리스크를 알 수 있어야 한다.
public struct MeetingNote: Hashable, Sendable, Codable {
    public var meetingId: UUID
    public var title: String
    public var summary: String
    public var decisions: [Decision]
    public var actionItems: [ActionItem]
    public var openQuestions: [OpenQuestion]
    public var risks: [RiskItem]
    public var topics: [Topic]
    public var generatedAt: Date
    /// 생성 과정의 관측값. 내부 사고 내용은 포함하지 않는다.
    public var generation: GenerationSummary
    /// 사용자 프롬프트로 다시 구성한 문서(마크다운). 없으면 기본 구성을 쓴다.
    ///
    /// 재료는 검증이 끝난 회의록 내용뿐이다 — 전사문·근거는 넣지 않는다.
    /// 회의록을 수동 편집하면 내용이 어긋나므로 비워서 기본 구성으로 되돌린다.
    public var customDocument: String?

    public init(
        meetingId: UUID,
        title: String = "",
        summary: String = "",
        decisions: [Decision] = [],
        actionItems: [ActionItem] = [],
        openQuestions: [OpenQuestion] = [],
        risks: [RiskItem] = [],
        topics: [Topic] = [],
        generatedAt: Date = Date(),
        generation: GenerationSummary = GenerationSummary(),
        customDocument: String? = nil
    ) {
        self.meetingId = meetingId
        self.title = title
        self.summary = summary
        self.decisions = decisions
        self.actionItems = actionItems
        self.openQuestions = openQuestions
        self.risks = risks
        self.topics = topics
        self.generatedAt = generatedAt
        self.generation = generation
        self.customDocument = customDocument
    }
}

/// 자동 사고 모드 라우팅과 사담 제거의 결과 통계. 품질 평가(§16)의 입력이 된다.
public struct GenerationSummary: Hashable, Sendable, Codable {
    public var windowCount: Int
    public var thinkingReviewCount: Int
    public var candidateCount: Int
    public var droppedCandidateCount: Int
    public var mergedDuplicateCount: Int
    public var evidenceRejectedCount: Int
    public var keptSegmentCount: Int
    public var condensedSegmentCount: Int
    public var excludedSegmentCount: Int
    public var uncertainSegmentCount: Int
    public var finalPassUsedThinking: Bool
    public var jsonRepairCount: Int
    /// 한국어 윤문 결과 (요구사항 5)
    public var koreanEditor: KoreanMeetingEditor.Report?
    /// Skill 실행 기록 (요구사항 6)
    public var skills: MeetingSkillTrace?

    public init(
        windowCount: Int = 0,
        thinkingReviewCount: Int = 0,
        candidateCount: Int = 0,
        droppedCandidateCount: Int = 0,
        mergedDuplicateCount: Int = 0,
        evidenceRejectedCount: Int = 0,
        keptSegmentCount: Int = 0,
        condensedSegmentCount: Int = 0,
        excludedSegmentCount: Int = 0,
        uncertainSegmentCount: Int = 0,
        finalPassUsedThinking: Bool = false,
        jsonRepairCount: Int = 0,
        koreanEditor: KoreanMeetingEditor.Report? = nil,
        skills: MeetingSkillTrace? = nil
    ) {
        self.windowCount = windowCount
        self.thinkingReviewCount = thinkingReviewCount
        self.candidateCount = candidateCount
        self.droppedCandidateCount = droppedCandidateCount
        self.mergedDuplicateCount = mergedDuplicateCount
        self.evidenceRejectedCount = evidenceRejectedCount
        self.keptSegmentCount = keptSegmentCount
        self.condensedSegmentCount = condensedSegmentCount
        self.excludedSegmentCount = excludedSegmentCount
        self.uncertainSegmentCount = uncertainSegmentCount
        self.finalPassUsedThinking = finalPassUsedThinking
        self.jsonRepairCount = jsonRepairCount
        self.koreanEditor = koreanEditor
        self.skills = skills
    }
}
