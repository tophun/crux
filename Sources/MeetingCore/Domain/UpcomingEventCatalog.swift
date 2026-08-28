import Foundation

/// 다가오는 일정 목록에 그릴 한 줄. 상세는 원본 `CalendarEvent`를 쓴다.
public struct UpcomingEventRow: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var startDate: Date
    public var endDate: Date
    public var calendarTitle: String?
    public var conferenceURL: URL?

    public init(
        id: String,
        title: String,
        startDate: Date,
        endDate: Date,
        calendarTitle: String? = nil,
        conferenceURL: URL? = nil
    ) {
        self.id = id
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.calendarTitle = calendarTitle
        self.conferenceURL = conferenceURL
    }

    public init(_ event: CalendarEvent) {
        self.init(
            id: event.id,
            title: event.title,
            startDate: event.startDate,
            endDate: event.endDate,
            calendarTitle: event.calendarTitle,
            conferenceURL: event.conferenceURL
        )
    }
}

/// 다가오는 일정 목록의 필터와 행 매핑.
///
/// 감지의 `MeetingDetectionPolicy`를 재사용한다. 목록은 훑어보는 화면이라
/// 참석자 수 제한은 끄고, 종일·취소·거절만 기본 숨긴다.
/// 네트워크로 오디오·전사문을 보내지 않는다. EventKit 메타데이터만 다룬다.
public struct UpcomingEventCatalog: Sendable {
    /// 끝난 일정을 얼마나 거슬러 볼지. 어제 시작해 아직 진행 중인 회의를 남긴다.
    public static let lookback: TimeInterval = 24 * 60 * 60
    /// 기본 조회 범위. 오늘과 앞으로 2주.
    public static let defaultHorizon: TimeInterval = 14 * 24 * 60 * 60

    public var horizon: TimeInterval
    public var detection: MeetingDetectionPolicy

    public init(
        horizon: TimeInterval = UpcomingEventCatalog.defaultHorizon,
        detection: MeetingDetectionPolicy = MeetingDetectionPolicy(
            configuration: MeetingDetectionPolicy.Configuration(minimumAttendees: 0)
        )
    ) {
        self.horizon = horizon
        self.detection = detection
    }

    /// EventKit 조회 시작. 진행 중인 일정을 놓치지 않도록 하루를 거슬러 본다.
    public func fetchStart(now: Date) -> Date {
        now.addingTimeInterval(-Self.lookback)
    }

    /// EventKit 조회 끝.
    public func fetchEnd(now: Date) -> Date {
        now.addingTimeInterval(horizon)
    }

    /// 목록에 올릴 일정. 감지 필터를 거친 뒤, 이미 끝났거나 범위 밖인 것을 뺀다.
    public func visibleEvents(_ events: [CalendarEvent], now: Date) -> [CalendarEvent] {
        let limit = now.addingTimeInterval(horizon)
        return detection.eligibleEvents(events).filter { event in
            event.endDate > now && event.startDate <= limit
        }
    }

    /// 목록 행. 제목·시작/끝·캘린더·회의 링크만 옮긴다.
    public func rows(from events: [CalendarEvent], now: Date) -> [UpcomingEventRow] {
        visibleEvents(events, now: now).map(UpcomingEventRow.init)
    }
}
