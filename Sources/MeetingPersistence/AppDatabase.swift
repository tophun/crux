import Foundation
import GRDB
import MeetingCore

/// SQLite 데이터베이스. 오디오 바이트는 저장하지 않고 파일 경로와 메타데이터만 넣는다(§5).
public final class AppDatabase: Sendable {
    public let writer: DatabaseWriter

    public init(writer: DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    /// 파일 기반 데이터베이스. 기본 위치는 앱 지원 디렉터리 안이다.
    public static func open(at url: URL) throws -> AppDatabase {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let queue = try DatabaseQueue(path: url.path, configuration: configuration)
        return try AppDatabase(writer: queue)
    }

    /// 테스트용 인메모리 데이터베이스.
    public static func inMemory() throws -> AppDatabase {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        return try AppDatabase(writer: DatabaseQueue(configuration: configuration))
    }

    public static var defaultURL: URL {
        AppIdentity.dataDirectory().appendingPathComponent("meetings.sqlite")
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_core") { db in
            try db.create(table: "meeting") { table in
                table.primaryKey("id", .text)
                table.column("title", .text).notNull()
                table.column("startedAt", .datetime).notNull()
                table.column("endedAt", .datetime)
                table.column("status", .text).notNull()
                table.column("storageDirectory", .text).notNull()
                table.column("source", .text).notNull()
                table.column("createdAt", .datetime).notNull()
                table.column("updatedAt", .datetime).notNull()
            }

            try db.create(table: "audioTrack") { table in
                table.primaryKey("id", .text)
                table.column("meetingId", .text).notNull()
                    .indexed()
                    .references("meeting", onDelete: .cascade)
                table.column("kind", .text).notNull()
                table.column("filePath", .text).notNull()
                table.column("duration", .double).notNull()
                table.column("sampleRate", .double).notNull()
                table.column("channelCount", .integer).notNull()
                table.column("byteSize", .integer).notNull()
                table.column("createdAt", .datetime).notNull()
            }

            try db.create(table: "transcriptSegment") { table in
                table.primaryKey("id", .text)
                table.column("meetingId", .text).notNull()
                    .indexed()
                    .references("meeting", onDelete: .cascade)
                table.column("segmentIndex", .integer).notNull()
                table.column("startTime", .double).notNull()
                table.column("endTime", .double).notNull()
                table.column("speakerId", .text)
                table.column("text", .text).notNull()
                table.column("confidence", .double)
                table.column("sourceTrack", .text).notNull()
                table.column("relevanceLabel", .text)
                table.column("relevanceReason", .text)
            }

            try db.create(table: "meetingNote") { table in
                table.primaryKey("meetingId", .text)
                    .references("meeting", onDelete: .cascade)
                table.column("title", .text).notNull()
                table.column("summary", .text).notNull()
                table.column("generatedAt", .datetime).notNull()
                table.column("generationJSON", .text).notNull()
            }

            try db.create(table: "decision") { table in
                table.primaryKey("id", .text)
                table.column("meetingId", .text).notNull()
                    .indexed()
                    .references("meeting", onDelete: .cascade)
                table.column("position", .integer).notNull()
                table.column("content", .text).notNull()
                table.column("kind", .text).notNull()
                table.column("evidenceJSON", .text).notNull()
                table.column("confidence", .double).notNull()
                table.column("reviewed", .boolean).notNull()
            }

            try db.create(table: "actionItem") { table in
                table.primaryKey("id", .text)
                table.column("meetingId", .text).notNull()
                    .indexed()
                    .references("meeting", onDelete: .cascade)
                table.column("position", .integer).notNull()
                table.column("task", .text).notNull()
                table.column("assignee", .text)
                table.column("dueDate", .text)
                table.column("dueDateNote", .text)
                table.column("status", .text).notNull()
                table.column("evidenceJSON", .text).notNull()
                table.column("confidence", .double).notNull()
                table.column("reviewed", .boolean).notNull()
            }

            try db.create(table: "openQuestion") { table in
                table.primaryKey("id", .text)
                table.column("meetingId", .text).notNull()
                    .indexed()
                    .references("meeting", onDelete: .cascade)
                table.column("position", .integer).notNull()
                table.column("question", .text).notNull()
                table.column("evidenceJSON", .text).notNull()
                table.column("confidence", .double).notNull()
            }

            try db.create(table: "riskItem") { table in
                table.primaryKey("id", .text)
                table.column("meetingId", .text).notNull()
                    .indexed()
                    .references("meeting", onDelete: .cascade)
                table.column("position", .integer).notNull()
                table.column("content", .text).notNull()
                table.column("severity", .text).notNull()
                table.column("evidenceJSON", .text).notNull()
                table.column("confidence", .double).notNull()
            }

            try db.create(table: "topic") { table in
                table.primaryKey("id", .text)
                table.column("meetingId", .text).notNull()
                    .indexed()
                    .references("meeting", onDelete: .cascade)
                table.column("position", .integer).notNull()
                table.column("title", .text).notNull()
                table.column("summary", .text).notNull()
                table.column("startTime", .double)
                table.column("endTime", .double)
            }

            try db.create(table: "processingJob") { table in
                table.primaryKey("id", .text)
                table.column("meetingId", .text).notNull()
                    .indexed()
                    .references("meeting", onDelete: .cascade)
                table.column("stage", .text).notNull()
                table.column("state", .text).notNull()
                table.column("attempt", .integer).notNull()
                table.column("startedAt", .datetime)
                table.column("finishedAt", .datetime)
                table.column("errorMessage", .text)
                table.column("checkpoint", .text)
                table.uniqueKey(["meetingId", "stage"])
            }
        }

        migrator.registerMigration("v2_calendar_publish") { db in
            // 캘린더 메타데이터는 로컬에만 저장한다.
            try db.create(table: "calendarEvent") { table in
                table.primaryKey("id", .text)
                table.column("title", .text).notNull()
                table.column("startDate", .datetime).notNull()
                table.column("endDate", .datetime).notNull()
                table.column("isAllDay", .boolean).notNull()
                table.column("status", .text).notNull()
                table.column("attendeesJSON", .text).notNull()
                table.column("conferenceURL", .text)
                table.column("location", .text)
                table.column("organizerJSON", .text)
                table.column("calendarTitle", .text)
                table.column("updatedAt", .datetime).notNull()
            }

            // 같은 회의에 중복 알림을 띄우지 않기 위한 기록. 앱 재실행 후에도 유지된다.
            try db.create(table: "notifiedEvent") { table in
                table.primaryKey("eventId", .text)
                table.column("notifiedAt", .datetime).notNull()
            }

            // 게시 결과. 내부 contentId와 외부 식별자를 로컬에서만 연결한다.
            try db.create(table: "publishRecord") { table in
                table.primaryKey("id", .text)
                table.column("meetingId", .text).notNull()
                    .indexed()
                    .references("meeting", onDelete: .cascade)
                table.column("contentId", .text)
                table.column("target", .text).notNull()
                table.column("externalId", .text).notNull()
                table.column("externalKey", .text)
                table.column("url", .text).notNull()
                table.column("publishedAt", .datetime).notNull()
            }

            // 회의와 캘린더 이벤트 연결
            try db.alter(table: "meeting") { table in
                table.add(column: "calendarEventId", .text)
            }
        }

        migrator.registerMigration("v3_custom_document") { db in
            // 사용자 프롬프트로 구성한 문서. 기존 회의록은 비어 있고 기본 구성을 쓴다.
            try db.alter(table: "meetingNote") { table in
                table.add(column: "customDocument", .text)
            }
        }

        return migrator
    }
}
