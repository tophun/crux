import Foundation

public enum CalendarAuthorizationStatus: String, Sendable, CaseIterable {
    case notDetermined
    case denied
    case restricted
    case authorized
    /// 쓰기 전용 권한 — 일정을 읽을 수 없다
    case writeOnly

    public var canReadEvents: Bool {
        self == .authorized
    }

    public var displayName: String {
        switch self {
        case .notDetermined: "확인 필요"
        case .denied: "거부됨"
        case .restricted: "제한됨"
        case .authorized: "허용됨"
        case .writeOnly: "읽기 권한 없음"
        }
    }
}

/// 캘린더 읽기 추상화. EventKit이 기본이고, Google이 연결되어 있으면 그쪽을 우선한다.
public protocol CalendarProvider: Sendable {
    func authorizationStatus() -> CalendarAuthorizationStatus
    /// 권한을 요청한다. 이미 허용돼 있으면 즉시 true.
    func requestAccess() async throws -> Bool
    func events(from: Date, to: Date) async throws -> [CalendarEvent]
    /// 연결을 해제하고 저장된 자격 증명을 폐기한다. EventKit은 할 일이 없다.
    func disconnect() async throws
}

public extension CalendarProvider {
    func disconnect() async throws {}
}

/// 일정 생성·수정·삭제 때 참석자에게 보낼 알림 정책.
public enum CalendarNotificationPolicy: String, Codable, Sendable, CaseIterable {
    case all
    case externalOnly
    case none
}

/// Google Calendar 일정에 추가할 참석자.
public struct CalendarAttendeeInput: Hashable, Codable, Sendable {
    public var email: String
    public var displayName: String?
    public var optional: Bool

    public init(email: String, displayName: String? = nil, optional: Bool = false) {
        self.email = email
        self.displayName = displayName
        self.optional = optional
    }
}

/// 새 일정을 만들 때 사용하는 입력.
public struct CalendarEventDraft: Hashable, Codable, Sendable {
    public var title: String
    public var startDate: Date
    public var endDate: Date
    public var isAllDay: Bool
    public var timeZoneIdentifier: String?
    public var description: String?
    public var location: String?
    public var attendees: [CalendarAttendeeInput]

    public init(
        title: String,
        startDate: Date,
        endDate: Date,
        isAllDay: Bool = false,
        timeZoneIdentifier: String? = nil,
        description: String? = nil,
        location: String? = nil,
        attendees: [CalendarAttendeeInput] = []
    ) {
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.isAllDay = isAllDay
        self.timeZoneIdentifier = timeZoneIdentifier
        self.description = description
        self.location = location
        self.attendees = attendees
    }
}

/// 일정 수정 필드의 변경 의도를 보존한다. `clear`와 `unchanged`를 구분한다.
public enum CalendarFieldUpdate<Value: Hashable & Sendable>: Hashable, Sendable {
    case unchanged
    case set(Value)
    case clear
}

/// Google Calendar 일정 부분 수정 입력.
public struct CalendarEventPatch: Hashable, Sendable {
    public var title: CalendarFieldUpdate<String>
    public var startDate: CalendarFieldUpdate<Date>
    public var endDate: CalendarFieldUpdate<Date>
    public var isAllDay: CalendarFieldUpdate<Bool>
    public var timeZoneIdentifier: CalendarFieldUpdate<String>
    public var description: CalendarFieldUpdate<String>
    public var location: CalendarFieldUpdate<String>
    public var attendees: CalendarFieldUpdate<[CalendarAttendeeInput]>

    public init(
        title: CalendarFieldUpdate<String> = .unchanged,
        startDate: CalendarFieldUpdate<Date> = .unchanged,
        endDate: CalendarFieldUpdate<Date> = .unchanged,
        isAllDay: CalendarFieldUpdate<Bool> = .unchanged,
        timeZoneIdentifier: CalendarFieldUpdate<String> = .unchanged,
        description: CalendarFieldUpdate<String> = .unchanged,
        location: CalendarFieldUpdate<String> = .unchanged,
        attendees: CalendarFieldUpdate<[CalendarAttendeeInput]> = .unchanged
    ) {
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.isAllDay = isAllDay
        self.timeZoneIdentifier = timeZoneIdentifier
        self.description = description
        self.location = location
        self.attendees = attendees
    }
}

/// 읽기와 분리된 일정 쓰기 경계. 읽기 전용 구현도 계속 사용할 수 있다.
public protocol CalendarEventWriter: Sendable {
    func createEvent(
        _ draft: CalendarEventDraft,
        notification: CalendarNotificationPolicy
    ) async throws -> CalendarEvent

    func updateEvent(
        id: String,
        changes: CalendarEventPatch,
        notification: CalendarNotificationPolicy
    ) async throws -> CalendarEvent

    func deleteEvent(
        id: String,
        notification: CalendarNotificationPolicy
    ) async throws
}

/// 회의 링크 추출. 캘린더 필드에 흩어져 있는 회의 URL을 찾는다.
public enum ConferenceLinkExtractor {
    static let hosts = [
        "zoom.us", "meet.google.com", "teams.microsoft.com", "teams.live.com",
        "webex.com", "whereby.com", "discord.gg", "slack.com"
    ]

    /// 여러 후보 문자열에서 첫 회의 링크를 찾는다.
    public static func extract(from candidates: [String?]) -> URL? {
        for candidate in candidates.compactMap(\.self) {
            if let url = extract(from: candidate) {
                return url
            }
        }
        return nil
    }

    public static func extract(from text: String) -> URL? {
        guard let regex = try? NSRegularExpression(pattern: "https?://[^\\s<>\"']+") else { return nil }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches {
            guard let raw = match.substring(at: 0, in: text) else { continue }
            let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: ".,)]>"))
            guard let url = URL(string: trimmed), let host = url.host?.lowercased() else { continue }
            if hosts.contains(where: { host.contains($0) }) {
                return url
            }
        }
        return nil
    }
}
