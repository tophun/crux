import Foundation
import MeetingCore
import SwiftData

/// 캘린더 메타데이터와 알림 기록 저장소. 모두 로컬에만 저장한다.
public struct CalendarRepository: NotifiedEventStore, Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func save(events: [CalendarEvent]) throws {
        try database.write { context in
            try Self.upsert(events, existing: context.all(CalendarEventModel.self), in: context)
        }
    }

    /// API가 반환한 시간 범위의 현재 결과로 **같은 제공자** 캐시를 교체한다.
    ///
    /// Google primary가 돌려주지 않는 EventKit 일정을 지우지 않는다.
    /// `source`가 없고 들어온 일정도 없으면 삭제를 건너뛴다.
    public func replace(
        events: [CalendarEvent],
        from: Date,
        to: Date,
        source: CalendarEventSource? = nil
    ) throws {
        let incomingIDs = Set(events.map(\.id))
        let scoped = source ?? events.first?.source
        try database.write { context in
            let existing = try context.all(CalendarEventModel.self)
            if let scoped {
                for model in existing where model.startDate >= from && model.startDate <= to
                    && !incomingIDs.contains(model.id)
                    && Self.modelSource(model) == scoped {
                    context.delete(model)
                }
            }
            Self.upsert(events, existing: existing, in: context)
        }
    }

    /// 회의에 연결된 일정을 회의록 생성용 컨텍스트로 읽는다. 연결이 없으면 nil.
    public func calendarContext(meetingId: UUID) throws -> MeetingCalendarContext? {
        guard let eventId = try linkedEventId(meetingId: meetingId),
              let event = try event(id: eventId) else { return nil }
        return MeetingCalendarContext(event: event)
    }

    public func event(id: String) throws -> CalendarEvent? {
        try database.read { context in
            try context.all(CalendarEventModel.self).first(where: { $0.id == id })?.domain
        }
    }

    public func events(from: Date, to: Date) throws -> [CalendarEvent] {
        try database.read { context in
            try context.all(CalendarEventModel.self)
                .filter { $0.startDate >= from && $0.startDate <= to }
                .sorted { $0.startDate < $1.startDate }
                .map(\.domain)
        }
    }

    /// Google Calendar에서 삭제된 일정을 로컬 캐시에서도 제거한다.
    public func delete(eventId: String) throws {
        try database.write { context in
            for model in try context.all(CalendarEventModel.self).filter({ $0.id == eventId }) {
                context.delete(model)
            }
        }
    }

    /// 회의와 캘린더 이벤트를 연결한다.
    public func link(meetingId: UUID, eventId: String) throws {
        try database.write { context in
            guard let meeting = try context.all(MeetingModel.self)
                .first(where: { $0.id == meetingId.uuidString }) else { return }
            meeting.calendarEventId = eventId
            meeting.updatedAt = Date()
        }
    }

    public func linkedEventId(meetingId: UUID) throws -> String? {
        try database.read { context in
            try context.all(MeetingModel.self)
                .first(where: { $0.id == meetingId.uuidString })?.calendarEventId
        }
    }

    private static func upsert(_ events: [CalendarEvent], existing: [CalendarEventModel], in context: ModelContext) {
        let byId = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for event in events {
            if let model = byId[event.id] {
                apply(event, to: model)
            } else {
                context.insert(CalendarEventModel(event))
            }
        }
    }

    private static func apply(_ event: CalendarEvent, to model: CalendarEventModel) {
        model.seriesId = event.seriesId
        model.title = event.title
        model.startDate = event.startDate
        model.endDate = event.endDate
        model.isAllDay = event.isAllDay
        model.status = event.status.rawValue
        model.attendeesJSON = JSONColumn.encode(event.attendees)
        model.conferenceURL = event.conferenceURL?.absoluteString
        model.location = event.location
        model.organizerJSON = event.organizer.map { JSONColumn.encode($0) }
        model.calendarTitle = event.calendarTitle
        model.source = event.source.rawValue
        model.etag = event.etag
        model.recurringEventId = event.recurringEventId
        model.originalStartDate = event.originalStartDate
        model.updatedAt = Date()
    }

    private static func modelSource(_ model: CalendarEventModel) -> CalendarEventSource {
        CalendarEventSource(rawValue: model.source ?? "") ?? .eventKit
    }

    // MARK: - NotifiedEventStore

    public func notifiedEventIds() throws -> Set<String> {
        try database.read { context in
            try Set(context.all(NotifiedEventModel.self).map(\.eventId))
        }
    }

    public func markNotified(eventId: String, at date: Date) throws {
        try database.write { context in
            if let model = try context.all(NotifiedEventModel.self).first(where: { $0.eventId == eventId }) {
                model.notifiedAt = date
            } else {
                context.insert(NotifiedEventModel(eventId: eventId, notifiedAt: date))
            }
        }
    }

    public func pruneNotified(before date: Date) throws {
        try database.write { context in
            for model in try context.all(NotifiedEventModel.self).filter({ $0.notifiedAt < date }) {
                context.delete(model)
            }
        }
    }

    // MARK: - 일정 스킵 (이 기기 로컬)

    public func skipRecords() throws -> [EventSkipRecord] {
        try database.read { context in
            try context.all(SkippedEventModel.self).compactMap(\.domain)
        }
    }

    public func upsertSkip(_ record: EventSkipRecord) throws {
        try database.write { context in
            if let model = try context.all(SkippedEventModel.self).first(where: { $0.id == record.id }) {
                model.eventId = record.eventId
                model.seriesId = record.seriesId
                model.startDate = record.startDate
                model.scope = record.scope.rawValue
                model.skippedAt = record.skippedAt
            } else {
                context.insert(SkippedEventModel(record))
            }
        }
    }

    public func removeSkips(ids: [String]) throws {
        guard !ids.isEmpty else { return }
        let idSet = Set(ids)
        try database.write { context in
            for model in try context.all(SkippedEventModel.self) where idSet.contains(model.id) {
                context.delete(model)
            }
        }
    }

    public func removeSkips(matching event: CalendarEvent) throws {
        let records = try skipRecords()
        let remaining = EventSkipPolicy.removing(event: event, from: records)
        let removed = Set(records.map(\.id)).subtracting(remaining.map(\.id))
        try removeSkips(ids: Array(removed))
    }
}

/// 게시 기록 저장소.
public struct PublishRecordRepository: Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func save(_ records: [PublishRecord]) throws {
        try database.write { context in
            let existing = try context.all(PublishRecordModel.self)
            for record in records {
                if let model = existing.first(where: { $0.id == record.id.uuidString }) {
                    model.meetingId = record.meetingId.uuidString
                    model.contentId = record.contentId
                    model.target = record.target.rawValue
                    model.externalId = record.externalId
                    model.externalKey = record.externalKey
                    model.url = record.url
                    model.publishedAt = record.publishedAt
                } else {
                    context.insert(PublishRecordModel(record))
                }
            }
        }
    }

    public func records(meetingId: UUID) throws -> [PublishRecord] {
        try database.read { context in
            try context.all(PublishRecordModel.self)
                .filter { $0.meetingId == meetingId.uuidString }
                .sorted { $0.publishedAt < $1.publishedAt }
                .compactMap(\.domain)
        }
    }

    /// 이미 게시했는지 확인한다. 같은 회의를 두 번 게시하지 않기 위한 확인용.
    public func isPublished(meetingId: UUID, target: PublishRecord.Target) throws -> Bool {
        try database.read { context in
            try context.all(PublishRecordModel.self).contains {
                $0.meetingId == meetingId.uuidString && $0.target == target.rawValue
            }
        }
    }
}
