import CSQLite
import Foundation
import MeetingCore
import SwiftData

/// SwiftData 컨테이너와 저장소 접근을 묶는다.
///
/// 기존 `meetings.sqlite`는 삭제하거나 덮어쓰지 않고 `<이름>.swiftdata`로 한 번
/// 옮긴다. 마이그레이션은 임시 저장소에 먼저 저장한 뒤 성공할 때만 이동하므로,
/// 실패하면 원본과 새 저장소를 모두 재시도 가능한 상태로 남긴다.
public final class AppDatabase: @unchecked Sendable {
    public let container: ModelContainer
    public let storeURL: URL?

    public init(container: ModelContainer, storeURL: URL? = nil) {
        self.container = container
        self.storeURL = storeURL
    }

    /// 파일 기반 SwiftData 저장소를 연다. `url`이 기존 SQLite 경로면 옆에 SwiftData
    /// 파일을 만들고 최초 한 번 레거시 데이터를 가져온다.
    public static func open(at url: URL) throws -> AppDatabase {
        let storeURL = swiftDataURL(for: url)
        try FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if !FileManager.default.fileExists(atPath: storeURL.path),
           FileManager.default.fileExists(atPath: url.path),
           url.standardizedFileURL != storeURL.standardizedFileURL {
            try migrateLegacyStore(from: url, to: storeURL)
        }

        do {
            let configuration = ModelConfiguration(
                "MeetingPersistence",
                schema: PersistenceSchema.schema,
                url: storeURL,
                cloudKitDatabase: .none
            )
            let container = try ModelContainer(
                for: PersistenceSchema.schema,
                configurations: [configuration]
            )
            return AppDatabase(container: container, storeURL: storeURL)
        } catch {
            throw PersistenceError.migrationFailed("SwiftData 저장소를 열 수 없습니다: \(error.localizedDescription)")
        }
    }

    /// 테스트용 인메모리 SwiftData 저장소.
    public static func inMemory() throws -> AppDatabase {
        let configuration = ModelConfiguration(
            "MeetingPersistenceInMemory",
            schema: PersistenceSchema.schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(
            for: PersistenceSchema.schema,
            configurations: [configuration]
        )
        return AppDatabase(container: container)
    }

    /// 기존 호출부가 넘기는 호환 경로. 실제 새 저장소는 SwiftData 경로에 생성된다.
    public static var defaultURL: URL {
        AppIdentity.dataDirectory().appendingPathComponent("meetings.sqlite")
    }

    public static func swiftDataURL(for url: URL) -> URL {
        let standardized = url.standardizedFileURL
        if standardized.pathExtension.lowercased() == "swiftdata" {
            return standardized
        }
        if standardized.pathExtension.isEmpty {
            return standardized.appendingPathExtension("swiftdata")
        }
        return standardized.deletingPathExtension().appendingPathExtension("swiftdata")
    }

    /// 매 작업마다 독립적인 ModelContext를 만들어 컨텍스트의 스레드 경계를 지킨다.
    func read<T>(_ body: (ModelContext) throws -> T) throws -> T {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return try body(context)
    }

    /// 하나의 작업을 하나의 save 단위로 처리한다. body 또는 save가 실패하면 변경을
    /// 롤백해 부분 저장을 남기지 않는다.
    @discardableResult
    func write<T>(_ body: (ModelContext) throws -> T) throws -> T {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        do {
            let result = try body(context)
            try context.save()
            return result
        } catch {
            context.rollback()
            throw error
        }
    }

    private static func migrateLegacyStore(from sourceURL: URL, to destinationURL: URL) throws {
        let temporaryURL = destinationURL.deletingLastPathComponent()
            .appendingPathComponent(".\(destinationURL.lastPathComponent).migration-\(UUID().uuidString)")
        let fileManager = FileManager.default

        do {
            try populateTemporaryStore(from: sourceURL, at: temporaryURL)
            try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        } catch let error as PersistenceError {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw PersistenceError.migrationFailed(error.localizedDescription)
        }
    }

    /// 이 메서드가 반환된 뒤에만 임시 ModelContainer를 이동한다. 따라서 SwiftData의
    /// 보조 파일이 열린 채로 이동되지 않는다.
    private static func populateTemporaryStore(from sourceURL: URL, at temporaryURL: URL) throws {
        do {
            let configuration = ModelConfiguration(
                "MeetingPersistenceMigration",
                schema: PersistenceSchema.schema,
                url: temporaryURL,
                cloudKitDatabase: .none
            )
            let container = try ModelContainer(
                for: PersistenceSchema.schema,
                configurations: [configuration]
            )
            let database = AppDatabase(container: container, storeURL: temporaryURL)
            try LegacySQLiteMigrator(sourceURL: sourceURL).migrate(to: database)
        } catch let error as PersistenceError {
            throw error
        } catch {
            throw PersistenceError.migrationFailed(error.localizedDescription)
        }
    }
}

private struct LegacySQLiteRow {
    let values: [String: String?]

    func optional(_ name: String) -> String? {
        values[name] ?? nil
    }

    func required(_ name: String) throws -> String {
        guard let value = optional(name), !value.isEmpty else {
            throw LegacySQLiteError.missingValue(name)
        }
        return value
    }

    func date(_ name: String) throws -> Date {
        try LegacySQLiteDateParser.parse(required(name))
    }

    func optionalDate(_ name: String) throws -> Date? {
        guard let value = optional(name), !value.isEmpty else { return nil }
        return try LegacySQLiteDateParser.parse(value)
    }

    func double(_ name: String) throws -> Double {
        guard let value = try Double(required(name)) else {
            throw LegacySQLiteError.invalidValue(name)
        }
        return value
    }

    func optionalDouble(_ name: String) throws -> Double? {
        guard let value = optional(name), !value.isEmpty else { return nil }
        guard let number = Double(value) else { throw LegacySQLiteError.invalidValue(name) }
        return number
    }

    func int(_ name: String) throws -> Int {
        guard let value = try Int(required(name)) else {
            throw LegacySQLiteError.invalidValue(name)
        }
        return value
    }

    func int64(_ name: String) throws -> Int64 {
        guard let value = try Int64(required(name)) else {
            throw LegacySQLiteError.invalidValue(name)
        }
        return value
    }

    func bool(_ name: String) throws -> Bool {
        switch try required(name).lowercased() {
        case "1", "true": return true
        case "0", "false": return false
        default: throw LegacySQLiteError.invalidValue(name)
        }
    }
}

private final class LegacySQLiteReader {
    private var connection: OpaquePointer?

    init(sourceURL: URL) throws {
        let result = sourceURL.path.withCString { path in
            sqlite3_open_v2(path, &connection, SQLITE_OPEN_READONLY, nil)
        }
        guard result == SQLITE_OK, connection != nil else {
            throw LegacySQLiteError.openFailed(Self.message(for: connection))
        }
    }

    deinit {
        if let connection {
            sqlite3_close(connection)
        }
    }

    func tableExists(_ table: String) throws -> Bool {
        let rows = try rows(
            sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name = '\(table)'"
        )
        return !rows.isEmpty
    }

    func rows(from table: String) throws -> [LegacySQLiteRow] {
        try rows(sql: "SELECT * FROM \(table)")
    }

    private func rows(sql: String) throws -> [LegacySQLiteRow] {
        guard let connection else { throw LegacySQLiteError.openFailed("연결이 닫혔습니다") }
        var statement: OpaquePointer?
        let prepareResult = sql.withCString { sql in
            sqlite3_prepare_v2(connection, sql, -1, &statement, nil)
        }
        guard prepareResult == SQLITE_OK, let statement else {
            throw LegacySQLiteError.queryFailed(Self.message(for: connection))
        }
        defer { sqlite3_finalize(statement) }

        let columnCount = sqlite3_column_count(statement)
        var columnNames: [String] = []
        for index in 0 ..< columnCount {
            guard let name = sqlite3_column_name(statement, index) else {
                throw LegacySQLiteError.queryFailed("열 이름을 읽을 수 없습니다")
            }
            columnNames.append(String(cString: name))
        }

        var result: [LegacySQLiteRow] = []
        while true {
            let stepResult = sqlite3_step(statement)
            if stepResult == SQLITE_DONE {
                break
            }
            guard stepResult == SQLITE_ROW else {
                throw LegacySQLiteError.queryFailed(Self.message(for: connection))
            }

            var values: [String: String?] = [:]
            for index in 0 ..< columnCount {
                if sqlite3_column_type(statement, index) == SQLITE_NULL {
                    values[columnNames[Int(index)]] = nil
                } else if let text = sqlite3_column_text(statement, index) {
                    values[columnNames[Int(index)]] = String(cString: text)
                } else {
                    values[columnNames[Int(index)]] = ""
                }
            }
            result.append(LegacySQLiteRow(values: values))
        }
        return result
    }

    private static func message(for connection: OpaquePointer?) -> String {
        guard let connection, let message = sqlite3_errmsg(connection) else { return "알 수 없는 SQLite 오류" }
        return String(cString: message)
    }
}

private enum LegacySQLiteDateParser {
    static func parse(_ value: String) throws -> Date {
        if let seconds = Double(value) {
            return Date(timeIntervalSince1970: seconds)
        }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: value) {
            return date
        }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: value) {
            return date
        }

        for format in ["yyyy-MM-dd HH:mm:ss.SSSSSS", "yyyy-MM-dd HH:mm:ss.SSS", "yyyy-MM-dd HH:mm:ss"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            if let date = formatter.date(from: value) {
                return date
            }
        }
        throw LegacySQLiteError.invalidDate(value)
    }
}

private enum LegacySQLiteError: Error, LocalizedError {
    case openFailed(String)
    case queryFailed(String)
    case missingValue(String)
    case invalidValue(String)
    case invalidDate(String)

    var errorDescription: String? {
        switch self {
        case let .openFailed(message), let .queryFailed(message): message
        case let .missingValue(name): "레거시 SQLite 필드가 없습니다: \(name)"
        case let .invalidValue(name): "레거시 SQLite 필드 값이 잘못되었습니다: \(name)"
        case let .invalidDate(value): "레거시 SQLite 날짜를 읽을 수 없습니다: \(value)"
        }
    }
}

private struct LegacySQLiteMigrator {
    let sourceURL: URL

    func migrate(to database: AppDatabase) throws {
        let reader = try LegacySQLiteReader(sourceURL: sourceURL)
        guard try reader.tableExists("meeting") else {
            throw PersistenceError.migrationFailed("레거시 SQLite에 meeting 테이블이 없습니다")
        }

        do {
            try database.write { context in
                for row in try reader.rows(from: "meeting") {
                    try context.insert(MeetingModel(
                        id: row.required("id"),
                        title: row.required("title"),
                        startedAt: row.date("startedAt"),
                        endedAt: row.optionalDate("endedAt"),
                        status: row.required("status"),
                        storageDirectory: row.required("storageDirectory"),
                        source: row.required("source"),
                        createdAt: row.date("createdAt"),
                        updatedAt: row.date("updatedAt"),
                        calendarEventId: row.optional("calendarEventId")
                    ))
                }

                if try reader.tableExists("audioTrack") {
                    for row in try reader.rows(from: "audioTrack") {
                        try context.insert(AudioTrackModel(
                            id: row.required("id"), meetingId: row.required("meetingId"),
                            kind: row.required("kind"), filePath: row.required("filePath"),
                            duration: row.double("duration"), sampleRate: row.double("sampleRate"),
                            channelCount: row.int("channelCount"), byteSize: row.int64("byteSize"),
                            createdAt: row.date("createdAt")
                        ))
                    }
                }

                if try reader.tableExists("transcriptSegment") {
                    for row in try reader.rows(from: "transcriptSegment") {
                        try context.insert(TranscriptSegmentModel(
                            id: row.required("id"), meetingId: row.required("meetingId"),
                            segmentIndex: row.int("segmentIndex"), startTime: row.double("startTime"),
                            endTime: row.double("endTime"), speakerId: row.optional("speakerId"),
                            text: row.required("text"), confidence: row.optionalDouble("confidence"),
                            sourceTrack: row.required("sourceTrack"),
                            relevanceLabel: row.optional("relevanceLabel"), relevanceReason: row.optional("relevanceReason")
                        ))
                    }
                }

                if try reader.tableExists("meetingNote") {
                    for row in try reader.rows(from: "meetingNote") {
                        try context.insert(NoteModel(
                            meetingId: row.required("meetingId"), title: row.required("title"),
                            summary: row.required("summary"), generatedAt: row.date("generatedAt"),
                            generationJSON: row.required("generationJSON"), customDocument: row.optional("customDocument")
                        ))
                    }
                }

                if try reader.tableExists("decision") {
                    for row in try reader.rows(from: "decision") {
                        try context.insert(DecisionModel(
                            id: row.required("id"), meetingId: row.required("meetingId"),
                            position: row.int("position"), content: row.required("content"),
                            kind: row.required("kind"), evidenceJSON: row.required("evidenceJSON"),
                            confidence: row.double("confidence"), reviewed: row.bool("reviewed")
                        ))
                    }
                }

                if try reader.tableExists("actionItem") {
                    for row in try reader.rows(from: "actionItem") {
                        try context.insert(ActionItemModel(
                            id: row.required("id"), meetingId: row.required("meetingId"),
                            position: row.int("position"), task: row.required("task"),
                            assignee: row.optional("assignee"), dueDate: row.optional("dueDate"),
                            dueDateNote: row.optional("dueDateNote"), status: row.required("status"),
                            evidenceJSON: row.required("evidenceJSON"), confidence: row.double("confidence"),
                            reviewed: row.bool("reviewed")
                        ))
                    }
                }

                if try reader.tableExists("openQuestion") {
                    for row in try reader.rows(from: "openQuestion") {
                        try context.insert(OpenQuestionModel(
                            id: row.required("id"), meetingId: row.required("meetingId"),
                            position: row.int("position"), question: row.required("question"),
                            evidenceJSON: row.required("evidenceJSON"), confidence: row.double("confidence")
                        ))
                    }
                }

                if try reader.tableExists("riskItem") {
                    for row in try reader.rows(from: "riskItem") {
                        try context.insert(RiskItemModel(
                            id: row.required("id"), meetingId: row.required("meetingId"),
                            position: row.int("position"), content: row.required("content"),
                            severity: row.required("severity"), evidenceJSON: row.required("evidenceJSON"),
                            confidence: row.double("confidence")
                        ))
                    }
                }

                if try reader.tableExists("topic") {
                    for row in try reader.rows(from: "topic") {
                        try context.insert(TopicModel(
                            id: row.required("id"), meetingId: row.required("meetingId"),
                            position: row.int("position"), title: row.required("title"),
                            summary: row.required("summary"), startTime: row.optionalDouble("startTime"),
                            endTime: row.optionalDouble("endTime")
                        ))
                    }
                }

                if try reader.tableExists("processingJob") {
                    for row in try reader.rows(from: "processingJob") {
                        try context.insert(ProcessingJobModel(
                            id: row.required("id"), meetingId: row.required("meetingId"),
                            stage: row.required("stage"), state: row.required("state"),
                            attempt: row.int("attempt"), startedAt: row.optionalDate("startedAt"),
                            finishedAt: row.optionalDate("finishedAt"), errorMessage: row.optional("errorMessage"),
                            checkpoint: row.optional("checkpoint")
                        ))
                    }
                }

                if try reader.tableExists("calendarEvent") {
                    for row in try reader.rows(from: "calendarEvent") {
                        try context.insert(CalendarEventModel(
                            id: row.required("id"), title: row.required("title"),
                            startDate: row.date("startDate"), endDate: row.date("endDate"),
                            isAllDay: row.bool("isAllDay"), status: row.required("status"),
                            attendeesJSON: row.required("attendeesJSON"), conferenceURL: row.optional("conferenceURL"),
                            location: row.optional("location"), organizerJSON: row.optional("organizerJSON"),
                            calendarTitle: row.optional("calendarTitle"), updatedAt: row.date("updatedAt")
                        ))
                    }
                }

                if try reader.tableExists("notifiedEvent") {
                    for row in try reader.rows(from: "notifiedEvent") {
                        try context.insert(NotifiedEventModel(
                            eventId: row.required("eventId"), notifiedAt: row.date("notifiedAt")
                        ))
                    }
                }

                if try reader.tableExists("publishRecord") {
                    for row in try reader.rows(from: "publishRecord") {
                        try context.insert(PublishRecordModel(
                            id: row.required("id"), meetingId: row.required("meetingId"),
                            contentId: row.optional("contentId"), target: row.required("target"),
                            externalId: row.required("externalId"), externalKey: row.optional("externalKey"),
                            url: row.required("url"), publishedAt: row.date("publishedAt")
                        ))
                    }
                }
            }
        } catch let error as PersistenceError {
            throw error
        } catch {
            throw PersistenceError.migrationFailed(error.localizedDescription)
        }
    }
}
