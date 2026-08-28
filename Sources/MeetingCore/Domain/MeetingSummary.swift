import Foundation

/// 회의 목록 화면에 필요한 요약 정보(§11).
public struct MeetingSummary: Identifiable, Hashable, Sendable {
    public var meeting: Meeting
    public var noteTitle: String?
    public var summaryPreview: String?
    public var decisionCount: Int
    public var actionItemCount: Int
    public var openQuestionCount: Int
    public var riskCount: Int
    /// 검색 중일 때만 채운다. 상세에서 맞춘 문장을 보여 줄 때 쓴다.
    public var searchHit: MeetingSearch.Hit?

    public var id: UUID {
        meeting.id
    }

    public init(
        meeting: Meeting,
        noteTitle: String? = nil,
        summaryPreview: String? = nil,
        decisionCount: Int = 0,
        actionItemCount: Int = 0,
        openQuestionCount: Int = 0,
        riskCount: Int = 0
    ) {
        self.meeting = meeting
        self.noteTitle = noteTitle
        self.summaryPreview = summaryPreview
        self.decisionCount = decisionCount
        self.actionItemCount = actionItemCount
        self.openQuestionCount = openQuestionCount
        self.riskCount = riskCount
        searchHit = nil
    }

    public var displayTitle: String {
        if let noteTitle, !noteTitle.isEmpty {
            return noteTitle
        }
        return meeting.title
    }
}
