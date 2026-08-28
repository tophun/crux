import Foundation

/// 일정 로컬 알림의 기본 시각. 설정에서 바꾸고, 일정 상세는 이 값을 기본으로 쓴다.
///
/// Google·캘린더 알림과는 별개다. 이 값은 이 기기 `UNUserNotificationCenter` 예약에만 쓴다.
public struct EventNotificationSettings: Hashable, Sendable, Codable {
    /// 공장 기본값. 시작 10분 전.
    public static let defaultLeadMinutes = 10
    /// 설정 화면에서 고를 수 있는 값.
    public static let allowedLeadMinutes = [5, 10, 15, 30]

    public var leadMinutes: Int

    public init(leadMinutes: Int = defaultLeadMinutes) {
        self.leadMinutes = Self.clamped(leadMinutes)
    }

    public static let standard = EventNotificationSettings()

    /// 허용 목록에 없으면 기본값으로 되돌린다.
    public static func clamped(_ minutes: Int) -> Int {
        allowedLeadMinutes.contains(minutes) ? minutes : defaultLeadMinutes
    }

    /// 시작 시각에서 오프셋을 뺀 알림 시각.
    public func fireDate(for start: Date) -> Date {
        start.addingTimeInterval(-TimeInterval(leadMinutes * 60))
    }
}

/// 로컬 알림 한 건. 일정 본문·토큰은 담지 않는다.
public struct EventNotificationRequest: Hashable, Sendable, Identifiable {
    public var id: String {
        identifier
    }

    public var identifier: String
    public var eventId: String
    public var fireDate: Date
    public var title: String
    public var body: String
    public var leadMinutes: Int

    public init(
        identifier: String,
        eventId: String,
        fireDate: Date,
        title: String,
        body: String,
        leadMinutes: Int
    ) {
        self.identifier = identifier
        self.eventId = eventId
        self.fireDate = fireDate
        self.title = title
        self.body = body
        self.leadMinutes = leadMinutes
    }
}

public enum EventNotificationAuthorization: String, Sendable, CaseIterable {
    case notDetermined
    case denied
    case authorized

    public var allowsScheduling: Bool {
        self == .authorized
    }

    public var displayName: String {
        switch self {
        case .notDetermined: "확인 필요"
        case .denied: "거부됨"
        case .authorized: "허용됨"
        }
    }
}

public enum EventNotificationError: Error, Equatable, Sendable {
    /// 시스템 알림 권한이 없다. UI는 설정으로 안내한다.
    case denied
    /// 알림 시각이 이미 지났다.
    case fireDatePassed
    /// 건너뛴 일정에는 알림을 걸 수 없다.
    case skipped

    public var errorDescription: String? {
        switch self {
        case .denied: "알림 권한이 없습니다"
        case .fireDatePassed: "이미 지난 시각이라 알림을 걸 수 없습니다"
        case .skipped: "건너뛴 일정에는 알림을 걸 수 없습니다"
        }
    }
}

extension EventNotificationError: LocalizedError {}
