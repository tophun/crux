import CSQLite
import Foundation
import MeetingCore
import MeetingPersistence
import Testing

@Suite("SwiftData 마이그레이션")
struct SwiftDataMigrationTests {
    private let meetingID = "11111111-1111-1111-1111-111111111111"
    private let segmentID = "22222222-2222-2222-2222-222222222222"
    private let trackID = "33333333-3333-3333-3333-333333333333"
    private let decisionID = "44444444-4444-4444-4444-444444444444"
    private let actionID = "55555555-5555-5555-5555-555555555555"
    private let questionID = "66666666-6666-6666-6666-666666666666"
    private let riskID = "77777777-7777-7777-7777-777777777777"
    private let topicID = "88888888-8888-8888-8888-888888888888"
    private let jobID = "99999999-9999-9999-9999-999999999999"
    private let publishID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"

    @Test("기존 meetings.sqlite의 모든 저장소 데이터를 SwiftData로 옮긴다")
    func migratesLegacyStore() throws {
        let directory = try makeTemporaryDirectory()
        let legacyURL = directory.appendingPathComponent("meetings.sqlite")
        try createLegacyDatabase(at: legacyURL)

        let database = try AppDatabase.open(at: legacyURL)
        let repository = MeetingRepository(database: database)
        let jobs = ProcessingJobRepository(database: database)
        let calendar = CalendarRepository(database: database)
        let publishing = PublishRecordRepository(database: database)

        let loadedMeeting = try repository.meeting(id: UUID(uuidString: meetingID)!)
        let meeting = try #require(loadedMeeting)
        #expect(meeting.title == "마이그레이션 회의")
        #expect(meeting.status == .completed)
        #expect(try repository.tracks(meetingId: meeting.id).first?.fileURL.path == "/tmp/meeting.m4a")
        #expect(try repository.transcript(meetingId: meeting.id).first?.text == "배포 일정을 확정합니다.")
        #expect(try repository.note(meetingId: meeting.id)?.decisions.first?.content == "수요일 배포")
        #expect(try repository.note(meetingId: meeting.id)?.actionItems.first?.task == "체크리스트 공유")
        #expect(try jobs.job(meetingId: meeting.id, stage: .transcribe)?.state == .succeeded)
        #expect(try calendar.event(id: "event-1")?.title == "마이그레이션 일정")
        #expect(try calendar.linkedEventId(meetingId: meeting.id) == "event-1")
        #expect(try publishing.isPublished(meetingId: meeting.id, target: .jira))

        let storeURL = AppDatabase.swiftDataURL(for: legacyURL)
        #expect(FileManager.default.fileExists(atPath: storeURL.path))
        // 실패 시 재시도할 수 있도록 원본은 보존한다.
        #expect(FileManager.default.fileExists(atPath: legacyURL.path))

        // 이미 옮긴 저장소를 다시 열어도 중복 데이터가 생기지 않는다.
        let reopened = try AppDatabase.open(at: legacyURL)
        #expect(try MeetingRepository(database: reopened).summaries().count == 1)
    }

    @Test("마이그레이션 중 오류가 나면 새 저장소를 롤백하고 원본을 남긴다")
    func rollsBackFailedMigration() throws {
        let directory = try makeTemporaryDirectory()
        let legacyURL = directory.appendingPathComponent("meetings.sqlite")
        try createInvalidLegacyDatabase(at: legacyURL)
        let storeURL = AppDatabase.swiftDataURL(for: legacyURL)

        var didFail = false
        do {
            _ = try AppDatabase.open(at: legacyURL)
        } catch {
            didFail = true
        }

        #expect(didFail)
        #expect(FileManager.default.fileExists(atPath: legacyURL.path))
        #expect(!FileManager.default.fileExists(atPath: storeURL.path))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("swiftdata-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func createLegacyDatabase(at url: URL) throws {
        let schema = """
        CREATE TABLE meeting (id TEXT PRIMARY KEY, title TEXT NOT NULL, startedAt DATETIME NOT NULL, endedAt DATETIME, status TEXT NOT NULL, storageDirectory TEXT NOT NULL, source TEXT NOT NULL, createdAt DATETIME NOT NULL, updatedAt DATETIME NOT NULL, calendarEventId TEXT);
        CREATE TABLE audioTrack (id TEXT PRIMARY KEY, meetingId TEXT NOT NULL, kind TEXT NOT NULL, filePath TEXT NOT NULL, duration DOUBLE NOT NULL, sampleRate DOUBLE NOT NULL, channelCount INTEGER NOT NULL, byteSize INTEGER NOT NULL, createdAt DATETIME NOT NULL);
        CREATE TABLE transcriptSegment (id TEXT PRIMARY KEY, meetingId TEXT NOT NULL, segmentIndex INTEGER NOT NULL, startTime DOUBLE NOT NULL, endTime DOUBLE NOT NULL, speakerId TEXT, text TEXT NOT NULL, confidence DOUBLE, sourceTrack TEXT NOT NULL, relevanceLabel TEXT, relevanceReason TEXT);
        CREATE TABLE meetingNote (meetingId TEXT PRIMARY KEY, title TEXT NOT NULL, summary TEXT NOT NULL, generatedAt DATETIME NOT NULL, generationJSON TEXT NOT NULL, customDocument TEXT);
        CREATE TABLE decision (id TEXT PRIMARY KEY, meetingId TEXT NOT NULL, position INTEGER NOT NULL, content TEXT NOT NULL, kind TEXT NOT NULL, evidenceJSON TEXT NOT NULL, confidence DOUBLE NOT NULL, reviewed INTEGER NOT NULL);
        CREATE TABLE actionItem (id TEXT PRIMARY KEY, meetingId TEXT NOT NULL, position INTEGER NOT NULL, task TEXT NOT NULL, assignee TEXT, dueDate TEXT, dueDateNote TEXT, status TEXT NOT NULL, evidenceJSON TEXT NOT NULL, confidence DOUBLE NOT NULL, reviewed INTEGER NOT NULL);
        CREATE TABLE openQuestion (id TEXT PRIMARY KEY, meetingId TEXT NOT NULL, position INTEGER NOT NULL, question TEXT NOT NULL, evidenceJSON TEXT NOT NULL, confidence DOUBLE NOT NULL);
        CREATE TABLE riskItem (id TEXT PRIMARY KEY, meetingId TEXT NOT NULL, position INTEGER NOT NULL, content TEXT NOT NULL, severity TEXT NOT NULL, evidenceJSON TEXT NOT NULL, confidence DOUBLE NOT NULL);
        CREATE TABLE topic (id TEXT PRIMARY KEY, meetingId TEXT NOT NULL, position INTEGER NOT NULL, title TEXT NOT NULL, summary TEXT NOT NULL, startTime DOUBLE, endTime DOUBLE);
        CREATE TABLE processingJob (id TEXT PRIMARY KEY, meetingId TEXT NOT NULL, stage TEXT NOT NULL, state TEXT NOT NULL, attempt INTEGER NOT NULL, startedAt DATETIME, finishedAt DATETIME, errorMessage TEXT, checkpoint TEXT);
        CREATE TABLE calendarEvent (id TEXT PRIMARY KEY, title TEXT NOT NULL, startDate DATETIME NOT NULL, endDate DATETIME NOT NULL, isAllDay INTEGER NOT NULL, status TEXT NOT NULL, attendeesJSON TEXT NOT NULL, conferenceURL TEXT, location TEXT, organizerJSON TEXT, calendarTitle TEXT, updatedAt DATETIME NOT NULL);
        CREATE TABLE notifiedEvent (eventId TEXT PRIMARY KEY, notifiedAt DATETIME NOT NULL);
        CREATE TABLE publishRecord (id TEXT PRIMARY KEY, meetingId TEXT NOT NULL, contentId TEXT, target TEXT NOT NULL, externalId TEXT NOT NULL, externalKey TEXT, url TEXT NOT NULL, publishedAt DATETIME NOT NULL);
        INSERT INTO meeting VALUES ('\(
            meetingID
        )', '마이그레이션 회의', '2023-11-14 22:13:20.000', '2023-11-14 23:13:20.000', 'completed', '/tmp/meeting', 'importedFile', '2023-11-14 22:13:20.000', '2023-11-14 23:13:20.000', 'event-1');
        INSERT INTO audioTrack VALUES ('\(trackID)', '\(
            meetingID
        )', 'mixed', '/tmp/meeting.m4a', 60.0, 16000.0, 1, 1234, '2023-11-14 22:13:20.000');
        INSERT INTO transcriptSegment VALUES ('\(segmentID)', '\(
            meetingID
        )', 0, 0.0, 8.0, NULL, '배포 일정을 확정합니다.', 0.95, 'mixed', 'keep', NULL);
        INSERT INTO meetingNote VALUES ('\(meetingID)', '회의록', '배포 일정 확정', '2023-11-14 23:13:20.000', '{}', NULL);
        INSERT INTO decision VALUES ('\(decisionID)', '\(meetingID)', 0, '수요일 배포', 'decided', '[]', 0.9, 1);
        INSERT INTO actionItem VALUES ('\(actionID)', '\(meetingID)', 0, '체크리스트 공유', '홍길동', NULL, NULL, 'confirmed', '[]', 0.8, 0);
        INSERT INTO openQuestion VALUES ('\(questionID)', '\(meetingID)', 0, '가격 정책은?', '[]', 0.5);
        INSERT INTO riskItem VALUES ('\(riskID)', '\(meetingID)', 0, '서버 용량', 'high', '[]', 0.6);
        INSERT INTO topic VALUES ('\(topicID)', '\(meetingID)', 0, '배포 일정', '수요일 배포', 0.0, 8.0);
        INSERT INTO processingJob VALUES ('\(jobID)', '\(
            meetingID
        )', 'transcribe', 'succeeded', 1, '2023-11-14 22:13:20.000', '2023-11-14 23:13:20.000', NULL, NULL);
        INSERT INTO calendarEvent VALUES ('event-1', '마이그레이션 일정', '2023-11-14 22:13:20.000', '2023-11-14 23:13:20.000', 0, 'confirmed', '[]', NULL, NULL, NULL, '업무', '2023-11-14 23:13:20.000');
        INSERT INTO notifiedEvent VALUES ('event-1', '2023-11-14 21:13:20.000');
        INSERT INTO publishRecord VALUES ('\(publishID)', '\(
            meetingID
        )', NULL, 'jira', '10001', 'PROJ-1', 'https://jira.example/PROJ-1', '2023-11-15 00:13:20.000');
        """
        try execute(schema, at: url)
    }

    private func createInvalidLegacyDatabase(at url: URL) throws {
        try execute(
            "CREATE TABLE meeting (id TEXT PRIMARY KEY); INSERT INTO meeting VALUES ('\(meetingID)');",
            at: url
        )
    }

    private func execute(_ sql: String, at url: URL) throws {
        var connection: OpaquePointer?
        let openResult = url.path.withCString { path in
            sqlite3_open_v2(path, &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        }
        guard openResult == SQLITE_OK, let connection else {
            throw FixtureError.sqlite("데이터베이스를 열 수 없습니다")
        }
        defer { sqlite3_close(connection) }

        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sql.withCString { statement in
            sqlite3_exec(connection, statement, nil, nil, &errorMessage)
        }
        defer { sqlite3_free(errorMessage) }
        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "알 수 없는 오류"
            throw FixtureError.sqlite(message)
        }
    }

    private enum FixtureError: Error {
        case sqlite(String)
    }
}
