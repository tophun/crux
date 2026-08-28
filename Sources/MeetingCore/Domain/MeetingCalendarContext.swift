import Foundation

/// Qwen3 회의록 생성에 보조 정보로 전달하는 캘린더 메타데이터.
/// 결정·액션아이템의 근거로 사용하지 않으며, 게시 시에는 별도 CalendarEvent가 원천이 된다.
public struct MeetingCalendarContext: Hashable, Sendable {
    public var title: String
    public var startDate: Date
    public var endDate: Date
    public var attendees: [String]
    public var conferenceURL: URL?

    public init(
        title: String,
        startDate: Date,
        endDate: Date,
        attendees: [String] = [],
        conferenceURL: URL? = nil
    ) {
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.attendees = attendees
        self.conferenceURL = conferenceURL
    }

    public init(event: CalendarEvent) {
        self.init(
            title: event.title,
            startDate: event.startDate,
            endDate: event.endDate,
            attendees: event.attendeeDisplayNames,
            conferenceURL: event.conferenceURL
        )
    }
}
