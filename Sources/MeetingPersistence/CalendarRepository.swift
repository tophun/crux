import Foundation
import MeetingCore

/// 캘린더 메타데이터와 알림 기록 저장소. 모두 로컬에만 저장한다.
public struct CalendarRepository: NotifiedEventStore, Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func save(events: [CalendarEvent]) throws {
        try database.write { context in
            let existing = try context.all(CalendarEventModel.self)
            for event in events {
                if let model = existing.first(where: { $0.id == event.id }) {
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
                    model.updatedAt = Date()
                } else {
                    context.insert(CalendarEventModel(event))
                }
            }
        }
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
