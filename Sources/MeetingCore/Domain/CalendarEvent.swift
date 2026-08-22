import Foundation

/// 캘린더 참석자. 회의록 참석자 목록의 원천이며 임의로 추가하지 않는다.
public struct EventAttendee: Hashable, Sendable, Codable {
    public var name: String?
    public var email: String?
    public var isOrganizer: Bool
    public var isCurrentUser: Bool

    public init(name: String? = nil, email: String? = nil, isOrganizer: Bool = false, isCurrentUser: Bool = false) {
        self.name = name
        self.email = email
        self.isOrganizer = isOrganizer
        self.isCurrentUser = isCurrentUser
    }

    /// 사람이 읽을 표시 이름. 이름이 없으면 이메일 로컬파트를 쓴다.
    public var displayName: String {
        if let name, !name.isEmpty { return name }
        if let email, let local = email.split(separator: "@").first { return String(local) }
        return email ?? "알 수 없는 참석자"
    }
}

public enum CalendarEventStatus: String, Sendable, Codable, CaseIterable {
    case confirmed
    case tentative
    case canceled
    case unknown
}

/// 캘린더 일정. 회의록 메타데이터(제목·날짜·참석자·회의 링크)의 기본값이 된다.
///
/// 이 정보는 로컬에만 저장한다. 회의 오디오·전사문·요약은 온디바이스로 처리한다.
public struct CalendarEvent: Identifiable, Hashable, Sendable, Codable {
    /// 캘린더 제공자가 준 이벤트 식별자. 중복 알림 방지의 기준이다.
    public var id: String
    public var title: String
    public var startDate: Date
    public var endDate: Date
    public var isAllDay: Bool
    public var status: CalendarEventStatus
    public var attendees: [EventAttendee]
    /// Zoom·Meet·Teams 링크
    public var conferenceURL: URL?
    public var location: String?
    public var organizer: EventAttendee?
    public var calendarTitle: String?
    /// 일정에 설정된 알림. 시작 기준 상대 초이며 **시작 전이면 음수**다(예: 1분 전 = -60).
    ///
    /// 캡슐을 언제 띄울지의 기준이 된다. 사용자가 캘린더에서 정한 시각에 맞추는 것이
    /// 앱이 임의로 정한 시각보다 예측 가능하다.
    /// 로컬 데이터베이스에는 저장하지 않는다 — 감지 때마다 캘린더에서 새로 읽는다.
    public var alarmOffsets: [TimeInterval]

    public init(
        id: String,
        title: String,
        startDate: Date,
        endDate: Date,
        isAllDay: Bool = false,
        status: CalendarEventStatus = .confirmed,
        attendees: [EventAttendee] = [],
        conferenceURL: URL? = nil,
        location: String? = nil,
        organizer: EventAttendee? = nil,
        calendarTitle: String? = nil,
        alarmOffsets: [TimeInterval] = []
    ) {
        self.id = id
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.isAllDay = isAllDay
        self.status = status
        self.attendees = attendees
        self.conferenceURL = conferenceURL
        self.location = location
        self.organizer = organizer
        self.calendarTitle = calendarTitle
        self.alarmOffsets = alarmOffsets
    }

    /// 시작 전에 울리는 알림 중 **가장 이른 것**까지 남은 시간. 알림이 없으면 nil.
    ///
    /// 여러 개면 첫 알림에 맞춘다. 사용자는 첫 알림을 보고 회의를 준비한다.
    public var earliestAlarmLeadTime: TimeInterval? {
        alarmOffsets.filter { $0 < 0 }.map { -$0 }.max()
    }

    public var duration: TimeInterval { max(0, endDate.timeIntervalSince(startDate)) }

    /// 회의록 참석자 표기. 주최자를 먼저 두고 캘린더에 있는 사람만 넣는다.
    public var attendeeDisplayNames: [String] {
        let ordered = attendees.sorted { lhs, rhs in
            if lhs.isOrganizer != rhs.isOrganizer { return lhs.isOrganizer }
            return lhs.displayName < rhs.displayName
        }
        var seen: Set<String> = []
        return ordered.compactMap { attendee in
            let name = attendee.displayName
            return seen.insert(name).inserted ? name : nil
        }
    }
}

/// 실행 중인 회의 앱 감지 결과.
public struct ConferenceAppSignal: Hashable, Sendable {
    public var appName: String
    public var isFrontmost: Bool
    /// 오디오 입력을 쓰고 있다고 판단되는지 (Phase 2 캡처와 함께 정교해진다)
    public var usesAudio: Bool

    public init(appName: String, isFrontmost: Bool = false, usesAudio: Bool = false) {
        self.appName = appName
        self.isFrontmost = isFrontmost
        self.usesAudio = usesAudio
    }

    /// 회의 앱으로 볼 번들 식별자·앱 이름 조각
    public static let knownConferenceApps: [String] = [
        "us.zoom.xos", "zoom.us", "Zoom",
        "com.microsoft.teams", "com.microsoft.teams2", "Microsoft Teams",
        "com.google.Chrome", "com.apple.Safari",  // Google Meet은 브라우저에서 열린다
        "com.hnc.Discord", "com.tinyspeck.slackmacgap", "Slack",
        "com.webex.meetingmanager", "Webex",
    ]
}
