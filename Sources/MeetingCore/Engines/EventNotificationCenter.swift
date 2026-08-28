import Foundation

/// 로컬 알림 전달. 구현은 `UNUserNotificationCenter` 한 곳이다.
///
/// Google Calendar 알림 API는 쓰지 않는다. 일정 본문·토큰은 로그에 남기지 않는다.
public protocol EventNotificationCenter: Sendable {
    func authorizationStatus() async -> EventNotificationAuthorization
    /// 아직 정해지지 않았으면 시스템 대화상자를 띄운다.
    func requestAuthorization() async -> EventNotificationAuthorization
    func pendingIdentifiers() async -> Set<String>
    func add(_ request: EventNotificationRequest) async throws
    /// 대기 중인 예약만 지운다. 이미 전달된 알림은 건드리지 않는다.
    func removePending(identifiers: [String]) async
}

/// 일정별 로컬 알림 예약·해제.
///
/// 식별자는 일정 ID에 고정해, 같은 일정에 중복으로 걸리지 않게 한다.
/// 스킵 저장소가 없으면 스킵 여부를 보지 않는다.
public struct EventNotificationScheduler: Sendable {
    public static let identifierPrefix = "crux.event."

    private let center: any EventNotificationCenter

    public init(center: any EventNotificationCenter) {
        self.center = center
    }

    public static func identifier(eventId: String) -> String {
        identifierPrefix + eventId
    }

    public static func eventId(from identifier: String) -> String? {
        guard identifier.hasPrefix(identifierPrefix) else { return nil }
        return String(identifier.dropFirst(identifierPrefix.count))
    }

    public func authorizationStatus() async -> EventNotificationAuthorization {
        await center.authorizationStatus()
    }

    public func requestAuthorization() async -> EventNotificationAuthorization {
        await center.requestAuthorization()
    }

    public func isScheduled(eventId: String) async -> Bool {
        let pending = await center.pendingIdentifiers()
        return pending.contains(Self.identifier(eventId: eventId))
    }

    public func scheduledEventIds() async -> Set<String> {
        let pending = await center.pendingIdentifiers()
        return Set(pending.compactMap(Self.eventId(from:)))
    }

    /// 시작 N분 전에 로컬 알림을 건다. 같은 일정의 기존 예약은 덮어쓴다.
    ///
    /// 권한은 여기서 요청한다. 거부되면 예약을 만들지 않는다.
    public func schedule(
        event: CalendarEvent,
        settings: EventNotificationSettings = .standard,
        now: Date = Date()
    ) async throws -> EventNotificationRequest {
        var authorization = await center.authorizationStatus()
        if authorization == .notDetermined {
            authorization = await center.requestAuthorization()
        }
        guard authorization.allowsScheduling else {
            throw EventNotificationError.denied
        }

        let leadMinutes = EventNotificationSettings.clamped(settings.leadMinutes)
        let fireDate = EventNotificationSettings(leadMinutes: leadMinutes).fireDate(for: event.startDate)
        guard fireDate > now else {
            throw EventNotificationError.fireDatePassed
        }

        let request = EventNotificationRequest(
            identifier: Self.identifier(eventId: event.id),
            eventId: event.id,
            fireDate: fireDate,
            title: event.title,
            body: Self.reminderBody(leadMinutes: leadMinutes),
            leadMinutes: leadMinutes
        )
        try await center.add(request)
        return request
    }

    /// 대기 중인 예약만 지운다. 캘린더 일정은 그대로 둔다.
    public func cancel(eventId: String) async {
        await center.removePending(identifiers: [Self.identifier(eventId: eventId)])
    }

    public static func reminderBody(leadMinutes: Int) -> String {
        "\(leadMinutes)분 후 시작합니다"
    }
}
