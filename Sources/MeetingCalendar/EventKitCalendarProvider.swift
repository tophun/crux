import EventKit
import Foundation
import MeetingCore

/// EventKit 기반 캘린더 읽기.
///
/// macOS 캘린더 앱에 Google 계정을 추가해 두면 Google Calendar 일정을 읽는다.
/// 네트워크 요청을 하지 않고, 읽은 메타데이터는 로컬에만 저장한다.
///
/// 권한: `NSCalendarsFullAccessUsageDescription`이 있는 앱 번들에서만 동작한다.
public final class EventKitCalendarProvider: CalendarProvider, @unchecked Sendable {
    private let store: EKEventStore

    public init(store: EKEventStore = EKEventStore()) {
        self.store = store
    }

    public func authorizationStatus() -> CalendarAuthorizationStatus {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied: .denied
        case .fullAccess: .authorized
        case .writeOnly: .writeOnly
        @unknown default: .notDetermined
        }
    }

    public func requestAccess() async throws -> Bool {
        if authorizationStatus() == .authorized {
            return true
        }
        return try await store.requestFullAccessToEvents()
    }

    public func events(from: Date, to: Date) async throws -> [CalendarEvent] {
        guard authorizationStatus() == .authorized else { return [] }
        // EKEventStore는 읽은 내용을 캐시한다. 앱을 켠 뒤에 만든 일정이 그대로 안 보일 수 있어
        // 조회 전에 캐시를 비운다. 15초마다 부르는 가벼운 로컬 조회라 비용이 크지 않다.
        store.reset()
        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: nil)
        return store.events(matching: predicate).map(Self.map)
    }

    static func map(_ event: EKEvent) -> CalendarEvent {
        let attendees: [EventAttendee] = (event.attendees ?? []).map { participant in
            EventAttendee(
                name: participant.name,
                email: Self.email(from: participant.url),
                isOrganizer: participant.participantRole == .chair,
                isCurrentUser: participant.isCurrentUser,
                responseStatus: Self.responseStatus(participant.participantStatus)
            )
        }
        let organizer = event.organizer.map { participant in
            EventAttendee(
                name: participant.name,
                email: Self.email(from: participant.url),
                isOrganizer: true,
                isCurrentUser: participant.isCurrentUser,
                responseStatus: Self.responseStatus(participant.participantStatus)
            )
        }
        // 주최자가 참석자 목록에 없으면 함께 넣는다. 없는 사람을 만들지는 않는다.
        var merged = attendees
        if let organizer, !merged.contains(where: { $0.email == organizer.email && organizer.email != nil }) {
            merged.insert(organizer, at: 0)
        } else if let index = merged.firstIndex(where: { $0.email == organizer?.email }) {
            merged[index].isOrganizer = true
        }

        // 일정에 걸린 알림을 시작 기준 상대 초로 바꾼다. 절대 시각 알림도 같은 기준으로 환산한다.
        let alarmOffsets: [TimeInterval] = (event.alarms ?? []).compactMap { alarm in
            if let absolute = alarm.absoluteDate {
                return absolute.timeIntervalSince(event.startDate)
            }
            return alarm.relativeOffset
        }

        let rawId = event.eventIdentifier ?? event.calendarItemIdentifier
        let identity = CalendarEvent.identity(
            eventIdentifier: rawId.isEmpty ? UUID().uuidString : rawId,
            startDate: event.startDate,
            isRecurring: event.hasRecurrenceRules
        )
        return CalendarEvent(
            id: identity.id,
            seriesId: identity.seriesId,
            title: event.title ?? "제목 없는 일정",
            startDate: event.startDate,
            endDate: event.endDate,
            isAllDay: event.isAllDay,
            status: Self.status(event.status),
            attendees: merged,
            conferenceURL: ConferenceLinkExtractor.extract(
                from: [event.url?.absoluteString, event.location, event.notes]
            ),
            location: event.location,
            organizer: organizer,
            calendarTitle: event.calendar?.title,
            alarmOffsets: alarmOffsets
        )
    }

    static func status(_ status: EKEventStatus) -> CalendarEventStatus {
        switch status {
        case .confirmed: .confirmed
        case .tentative: .tentative
        case .canceled: .canceled
        case .none: .unknown
        @unknown default: .unknown
        }
    }

    static func responseStatus(_ status: EKParticipantStatus) -> AttendeeResponseStatus {
        switch status {
        case .accepted: .accepted
        case .declined: .declined
        case .tentative: .tentative
        case .pending: .pending
        case .unknown, .delegated, .completed, .inProcess: .unknown
        @unknown default: .unknown
        }
    }

    static func email(from url: URL?) -> String? {
        guard let url, url.scheme?.lowercased() == "mailto" else { return nil }
        return url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
    }
}
