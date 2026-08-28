import Foundation
import MeetingCore

/// Google이 연결되어 있으면 Google을, 아니면 EventKit을 쓰는 캘린더 제공자.
///
/// 다가오는 일정 목록·알림·스킵은 EventKit만으로도 동작한다. Google은 추가 소스다.
public final class PreferredCalendarProvider: CalendarProvider, @unchecked Sendable {
    public let eventKit: EventKitCalendarProvider
    public let google: GoogleCalendarProvider

    public init(eventKit: EventKitCalendarProvider, google: GoogleCalendarProvider) {
        self.eventKit = eventKit
        self.google = google
    }

    public var isGoogleConnected: Bool {
        google.authorizationStatus().canReadEvents
    }

    public func eventKitStatus() -> CalendarAuthorizationStatus {
        eventKit.authorizationStatus()
    }

    public func googleStatus() -> CalendarAuthorizationStatus {
        google.authorizationStatus()
    }

    public func authorizationStatus() -> CalendarAuthorizationStatus {
        if isGoogleConnected {
            return google.authorizationStatus()
        }
        return eventKit.authorizationStatus()
    }

    /// EventKit 캘린더 권한을 요청한다. Google OAuth는 `requestGoogleAccess()`를 쓴다.
    public func requestAccess() async throws -> Bool {
        try await eventKit.requestAccess()
    }

    public func requestGoogleAccess() async throws -> Bool {
        try await google.requestAccess()
    }

    public func events(from: Date, to: Date) async throws -> [CalendarEvent] {
        if isGoogleConnected {
            return try await google.events(from: from, to: to)
        }
        return try await eventKit.events(from: from, to: to)
    }

    public func disconnect() async throws {
        try await google.disconnect()
    }
}
