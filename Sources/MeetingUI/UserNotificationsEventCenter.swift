import Foundation
import MeetingCore
import UserNotifications

/// `UNUserNotificationCenter` 어댑터. Google 알림 API는 호출하지 않는다.
///
/// 일정 본문·토큰은 요청에 넣지 않고 로그에도 남기지 않는다.
public struct UserNotificationsEventCenter: EventNotificationCenter, Sendable {
    public init() {}

    public func authorizationStatus() async -> EventNotificationAuthorization {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return Self.map(settings.authorizationStatus)
    }

    public func requestAuthorization() async -> EventNotificationAuthorization {
        let center = UNUserNotificationCenter.current()
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
        return await authorizationStatus()
    }

    public func pendingIdentifiers() async -> Set<String> {
        let requests = await UNUserNotificationCenter.current().pendingNotificationRequests()
        return Set(requests.map(\.identifier))
    }

    public func add(_ request: EventNotificationRequest) async throws {
        let content = UNMutableNotificationContent()
        content.title = request.title
        content.body = request.body
        content.sound = .default
        content.userInfo = ["eventId": request.eventId]

        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: request.fireDate
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let unRequest = UNNotificationRequest(
            identifier: request.identifier,
            content: content,
            trigger: trigger
        )
        try await UNUserNotificationCenter.current().add(unRequest)
    }

    public func removePending(identifiers: [String]) async {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    static func map(_ status: UNAuthorizationStatus) -> EventNotificationAuthorization {
        switch status {
        case .authorized, .provisional, .ephemeral: .authorized
        case .denied: .denied
        case .notDetermined: .notDetermined
        @unknown default: .notDetermined
        }
    }
}
