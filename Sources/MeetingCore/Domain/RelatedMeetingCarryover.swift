import Foundation

/// 지난 액션을 이을지 판단할 때 쓰는 회의 한 건.
///
/// 캘린더 제목·시리즈 또는 사용자가 묶은 그룹만 본다. 제목만 같고 캘린더가 없으면 묶지 않는다.
public struct RelatedMeetingRef: Hashable, Sendable {
    public var id: UUID
    public var startedAt: Date
    public var title: String
    public var calendarEventId: String?
    public var calendarEventTitle: String?
    public var relatedGroupId: UUID?

    public init(
        id: UUID,
        startedAt: Date,
        title: String,
        calendarEventId: String? = nil,
        calendarEventTitle: String? = nil,
        relatedGroupId: UUID? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.title = title
        self.calendarEventId = calendarEventId
        self.calendarEventTitle = calendarEventTitle
        self.relatedGroupId = relatedGroupId
    }

    public var seriesKey: String? {
        guard let calendarEventId, !calendarEventId.isEmpty else { return nil }
        return RelatedMeetingGrouping.seriesKey(eventId: calendarEventId)
    }

    public var isCalendarLinked: Bool {
        guard let calendarEventId else { return false }
        return !calendarEventId.isEmpty
    }
}

/// 같은 시리즈로 볼지 정하는 규칙.
public enum RelatedMeetingGrouping {
    /// EventKit 반복 일정의 발생분 식별자에서 시리즈 키를 뺀다.
    public static func seriesKey(eventId: String) -> String {
        if let range = eventId.range(of: "/RID=", options: .caseInsensitive)
            ?? eventId.range(of: "/ROWID=", options: .caseInsensitive) {
            return String(eventId[..<range.lowerBound])
        }
        return eventId
    }

    public static func normalizedTitle(_ title: String) -> String {
        title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split { $0.isWhitespace }
            .joined(separator: " ")
    }

    public static func areRelated(_ lhs: RelatedMeetingRef, _ rhs: RelatedMeetingRef) -> Bool {
        guard lhs.id != rhs.id else { return false }
        if let leftGroup = lhs.relatedGroupId, leftGroup == rhs.relatedGroupId {
            return true
        }
        if let leftSeries = lhs.seriesKey, let rightSeries = rhs.seriesKey, leftSeries == rightSeries {
            return true
        }
        let leftCalendarTitle = normalizedTitle(lhs.calendarEventTitle ?? "")
        let rightCalendarTitle = normalizedTitle(rhs.calendarEventTitle ?? "")
        if !leftCalendarTitle.isEmpty, leftCalendarTitle == rightCalendarTitle {
            return true
        }
        // 캘린더에 연결됐는데 일정 행이 없으면 회의 제목으로 같은 시리즈인지 본다.
        if lhs.isCalendarLinked, rhs.isCalendarLinked {
            let leftTitle = normalizedTitle(lhs.title)
            let rightTitle = normalizedTitle(rhs.title)
            if !leftTitle.isEmpty, leftTitle == rightTitle {
                return true
            }
        }
        return false
    }
}

/// 로컬 `publishRecord`에서 읽은 Jira 키. 네트워크로 상태를 확인하지 않는다.
public struct LocalIssueRef: Hashable, Sendable {
    public var contentId: String
    public var key: String
    public var url: String?

    public init(contentId: String, key: String, url: String? = nil) {
        self.contentId = contentId
        self.key = key
        self.url = url
    }
}

/// 이전 회의 한 건의 액션과 로컬 게시 기록.
public struct CarryoverMeetingSnapshot: Hashable, Sendable {
    public var meeting: RelatedMeetingRef
    public var actionItems: [ActionItem]
    public var issues: [LocalIssueRef]

    public init(meeting: RelatedMeetingRef, actionItems: [ActionItem], issues: [LocalIssueRef] = []) {
        self.meeting = meeting
        self.actionItems = actionItems
        self.issues = issues
    }
}

/// 새 회의 상세 상단에 보여줄 지난 미완료 액션.
public struct CarryoverAction: Identifiable, Hashable, Sendable {
    public var action: ActionItem
    public var sourceMeetingId: UUID
    public var sourceMeetingTitle: String
    public var sourceStartedAt: Date
    public var jiraKey: String?
    public var jiraURL: String?

    public var id: UUID { action.id }

    public init(
        action: ActionItem,
        sourceMeetingId: UUID,
        sourceMeetingTitle: String,
        sourceStartedAt: Date,
        jiraKey: String? = nil,
        jiraURL: String? = nil
    ) {
        self.action = action
        self.sourceMeetingId = sourceMeetingId
        self.sourceMeetingTitle = sourceMeetingTitle
        self.sourceStartedAt = sourceStartedAt
        self.jiraKey = jiraKey
        self.jiraURL = jiraURL
    }

    /// 로컬에 Jira 키가 있을 때만 화면에 붙인다.
    public var displayJiraKey: String? {
        guard let jiraKey else { return nil }
        let trimmed = jiraKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// 관련 이전 회의의 미완료 액션만 모은다. 상태를 바꾸지 않는다.
public enum CarryoverActionCollector {
    public static func collect(
        current: RelatedMeetingRef,
        previous: [CarryoverMeetingSnapshot]
    ) -> [CarryoverAction] {
        previous
            .filter { $0.meeting.startedAt < current.startedAt }
            .filter { RelatedMeetingGrouping.areRelated(current, $0.meeting) }
            .sorted { $0.meeting.startedAt > $1.meeting.startedAt }
            .flatMap { snapshot in
                snapshot.actionItems.enumerated().compactMap { index, item -> CarryoverAction? in
                    guard item.status.isUnfinished else { return nil }
                    let issue = snapshot.issues.first { $0.contentId == ContentId.actionItem(index) }
                    return CarryoverAction(
                        action: item,
                        sourceMeetingId: snapshot.meeting.id,
                        sourceMeetingTitle: snapshot.meeting.title,
                        sourceStartedAt: snapshot.meeting.startedAt,
                        jiraKey: issue?.key,
                        jiraURL: issue?.url
                    )
                }
            }
    }
}
