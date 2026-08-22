import Foundation
import GRDB
import MeetingCore

/// 캘린더 메타데이터와 알림 기록 저장소. 모두 로컬에만 저장한다.
public struct CalendarRepository: NotifiedEventStore, Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func save(events: [CalendarEvent]) throws {
        try database.writer.write { db in
            for event in events {
                try CalendarEventRecord(event).save(db)
            }
        }
    }

    public func event(id: String) throws -> CalendarEvent? {
        try database.writer.read { db in
            try CalendarEventRecord.fetchOne(db, key: id)?.domain
        }
    }

    public func events(from: Date, to: Date) throws -> [CalendarEvent] {
        try database.writer.read { db in
            try CalendarEventRecord
                .filter(Column("startDate") >= from && Column("startDate") <= to)
                .order(Column("startDate"))
                .fetchAll(db)
                .map(\.domain)
        }
    }

    /// 회의와 캘린더 이벤트를 연결한다.
    public func link(meetingId: UUID, eventId: String) throws {
        try database.writer.write { db in
            try db.execute(
                sql: "UPDATE meeting SET calendarEventId = ?, updatedAt = ? WHERE id = ?",
                arguments: [eventId, Date(), meetingId.uuidString]
            )
        }
    }

    public func linkedEventId(meetingId: UUID) throws -> String? {
        try database.writer.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT calendarEventId FROM meeting WHERE id = ?",
                arguments: [meetingId.uuidString]
            )
        }
    }

    // MARK: - NotifiedEventStore

    public func notifiedEventIds() throws -> Set<String> {
        try database.writer.read { db in
            Set(try String.fetchAll(db, sql: "SELECT eventId FROM notifiedEvent"))
        }
    }

    public func markNotified(eventId: String, at date: Date) throws {
        try database.writer.write { db in
            try NotifiedEventRecord(eventId: eventId, notifiedAt: date).save(db)
        }
    }

    public func pruneNotified(before date: Date) throws {
        try database.writer.write { db in
            try db.execute(sql: "DELETE FROM notifiedEvent WHERE notifiedAt < ?", arguments: [date])
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
        try database.writer.write { db in
            for record in records {
                try PublishRecordRow(record).save(db)
            }
        }
    }

    public func records(meetingId: UUID) throws -> [PublishRecord] {
        try database.writer.read { db in
            try PublishRecordRow
                .filter(Column("meetingId") == meetingId.uuidString)
                .order(Column("publishedAt"))
                .fetchAll(db)
                .compactMap(\.domain)
        }
    }

    /// 이미 게시했는지 확인한다. 같은 회의를 두 번 게시하지 않기 위한 확인용.
    public func isPublished(meetingId: UUID, target: PublishRecord.Target) throws -> Bool {
        try database.writer.read { db in
            try PublishRecordRow
                .filter(Column("meetingId") == meetingId.uuidString)
                .filter(Column("target") == target.rawValue)
                .fetchCount(db) > 0
        }
    }
}
