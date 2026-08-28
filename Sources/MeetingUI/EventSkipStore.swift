import Foundation
import MeetingCore
import MeetingPersistence
import Observation

/// 일정 스킵 상태. 목록·알림 저장소와 분리한다.
///
/// Google·EventKit 참석 상태는 바꾸지 않는다. 이 기기 로컬 기록만 다룬다.
@MainActor
@Observable
public final class EventSkipStore {
    public private(set) var records: [EventSkipRecord] = []

    private let repository: CalendarRepository
    private let notifications: EventNotificationStore

    public init(repository: CalendarRepository, notifications: EventNotificationStore) {
        self.repository = repository
        self.notifications = notifications
        refresh()
    }

    public var index: EventSkipIndex {
        EventSkipIndex(records: records)
    }

    public func isSkipped(_ event: CalendarEvent) -> Bool {
        index.isSkipped(event)
    }

    public func isSkipped(_ row: UpcomingEventRow) -> Bool {
        index.isSkipped(id: row.id, seriesId: row.seriesId, startDate: row.startDate)
    }

    public func scope(for event: CalendarEvent) -> EventSkipScope? {
        index.scope(for: event)
    }

    public func refresh() {
        records = (try? repository.skipRecords()) ?? []
    }

    /// 이번만 또는 시리즈를 건너뛴다. 대기 중인 로컬 알림은 지운다.
    public func skip(
        _ event: CalendarEvent,
        scope: EventSkipScope,
        among events: [CalendarEvent]
    ) async {
        let record = EventSkipPolicy.record(for: event, scope: scope)
        try? repository.upsertSkip(record)
        refresh()
        let ids = EventSkipPolicy.canceledEventIds(for: record, among: events)
        await notifications.cancel(eventIds: ids)
    }

    /// 이 일정을 다시 대상으로 만든다. 알림은 자동으로 다시 걸지 않는다.
    public func unskip(_ event: CalendarEvent) {
        try? repository.removeSkips(matching: event)
        refresh()
    }
}
