import Foundation

/// 작업별 Skill 식별자(요구사항 6).
///
/// 이미 검증된 파이프라인을 갈아엎지 않고, 각 단계에 이름을 붙여 추적한다.
/// 실제 신규 단계는 `korean-meeting-editor`, `confluence-writer`, `jira-task-writer`다.
public enum MeetingSkillId: String, Sendable, CaseIterable, Codable {
    case factExtractor = "meeting-fact-extractor"
    case cleaner = "meeting-cleaner"
    case actionItemExtractor = "action-item-extractor"
    case koreanEditor = "korean-meeting-editor"
    case confluenceWriter = "confluence-writer"
    case jiraTaskWriter = "jira-task-writer"
    case qualityChecker = "meeting-quality-checker"

    public var responsibility: String {
        switch self {
        case .factExtractor: "구간별 사실 추출 (결정·액션·리스크·질문 후보)"
        case .cleaner: "사담 분류와 제외"
        case .actionItemExtractor: "액션아이템 확정과 담당자·기한 근거 검증"
        case .koreanEditor: "한국어 윤문 (번역투·AI 관용구 제거, 의미 보존)"
        case .confluenceWriter: "Confluence 페이지 본문 구성"
        case .jiraTaskWriter: "Jira 이슈 초안 구성"
        case .qualityChecker: "게시 전 품질 검증"
        }
    }
}

/// 한 Skill의 실행 기록. Preview Viewer와 로그에 그대로 노출한다.
public struct MeetingSkillRun: Hashable, Sendable, Codable {
    public var skill: MeetingSkillId
    public var succeeded: Bool
    /// 처리한 항목 수 (구간·후보·필드 등 단계별 의미)
    public var itemCount: Int
    public var notes: [String]

    public init(skill: MeetingSkillId, succeeded: Bool, itemCount: Int, notes: [String] = []) {
        self.skill = skill
        self.succeeded = succeeded
        self.itemCount = itemCount
        self.notes = notes
    }
}

/// 파이프라인 전체의 Skill 실행 기록.
public struct MeetingSkillTrace: Hashable, Sendable, Codable {
    public var runs: [MeetingSkillRun]

    public init(runs: [MeetingSkillRun] = []) {
        self.runs = runs
    }

    public mutating func record(_ run: MeetingSkillRun) {
        runs.removeAll { $0.skill == run.skill }
        runs.append(run)
    }

    public func run(_ skill: MeetingSkillId) -> MeetingSkillRun? {
        runs.first { $0.skill == skill }
    }

    public var allSucceeded: Bool {
        runs.allSatisfy(\.succeeded)
    }
}
