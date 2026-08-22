import Foundation
import GRDB
import MeetingCore

/// 회의 데이터 저장소. 모든 읽기·쓰기는 로컬 SQLite에만 일어난다.
public struct MeetingRepository: Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    // MARK: - 회의

    public func save(_ meeting: Meeting) throws {
        try database.writer.write { db in
            try MeetingRecord(meeting).save(db)
        }
    }

    public func meeting(id: UUID) throws -> Meeting? {
        try database.writer.read { db in
            try MeetingRecord.fetchOne(db, key: id.uuidString)?.domain
        }
    }

    public func updateStatus(_ status: MeetingStatus, meetingId: UUID) throws {
        try database.writer.write { db in
            try db.execute(
                sql: "UPDATE meeting SET status = ?, updatedAt = ? WHERE id = ?",
                arguments: [status.rawValue, Date(), meetingId.uuidString]
            )
        }
    }

    public func delete(meetingId: UUID) throws {
        try database.writer.write { db in
            _ = try MeetingRecord.deleteOne(db, key: meetingId.uuidString)
        }
    }

    /// 회의 목록. 최근 회의가 먼저 온다.
    public func summaries(matching query: String? = nil) throws -> [MeetingSummary] {
        try database.writer.read { db in
            var meetings = try MeetingRecord
                .order(Column("startedAt").desc)
                .fetchAll(db)
                .compactMap(\.domain)

            var noteTitles: [String: String] = [:]
            var notePreviews: [String: String] = [:]
            for note in try NoteRecord.fetchAll(db) {
                noteTitles[note.meetingId] = note.title
                notePreviews[note.meetingId] = note.summary
            }

            func counts(_ table: String) throws -> [String: Int] {
                var result: [String: Int] = [:]
                let rows = try Row.fetchAll(
                    db,
                    sql: "SELECT meetingId, COUNT(*) AS total FROM \(table) GROUP BY meetingId"
                )
                for row in rows {
                    result[row["meetingId"]] = row["total"]
                }
                return result
            }

            let decisions = try counts("decision")
            let actions = try counts("actionItem")
            let questions = try counts("openQuestion")
            let risks = try counts("riskItem")

            if let query, !query.trimmingCharacters(in: .whitespaces).isEmpty {
                let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
                let matchingIds = try Set(
                    String.fetchAll(
                        db,
                        sql: """
                        SELECT DISTINCT meetingId FROM transcriptSegment WHERE LOWER(text) LIKE ?
                        UNION SELECT DISTINCT meetingId FROM actionItem WHERE LOWER(task) LIKE ?
                        UNION SELECT DISTINCT meetingId FROM decision WHERE LOWER(content) LIKE ?
                        UNION SELECT meetingId FROM meetingNote WHERE LOWER(title) LIKE ? OR LOWER(summary) LIKE ?
                        """,
                        arguments: StatementArguments(Array(repeating: "%\(needle)%", count: 5))
                    )
                )
                meetings = meetings.filter {
                    matchingIds.contains($0.id.uuidString) || $0.title.lowercased().contains(needle)
                }
            }

            return meetings.map { meeting in
                let key = meeting.id.uuidString
                return MeetingSummary(
                    meeting: meeting,
                    noteTitle: noteTitles[key],
                    summaryPreview: notePreviews[key],
                    decisionCount: decisions[key] ?? 0,
                    actionItemCount: actions[key] ?? 0,
                    openQuestionCount: questions[key] ?? 0,
                    riskCount: risks[key] ?? 0
                )
            }
        }
    }

    // MARK: - 오디오 트랙

    public func save(tracks: [AudioTrack]) throws {
        try database.writer.write { db in
            for track in tracks {
                try AudioTrackRecord(track).save(db)
            }
        }
    }

    public func tracks(meetingId: UUID) throws -> [AudioTrack] {
        try database.writer.read { db in
            try AudioTrackRecord
                .filter(Column("meetingId") == meetingId.uuidString)
                .fetchAll(db)
                .compactMap(\.domain)
        }
    }

    /// 원본 오디오 삭제(§11). 회의록과 전사문은 남긴다.
    @discardableResult
    public func deleteAudioFiles(meetingId: UUID, fileManager: FileManager = .default) throws -> Int {
        let tracks = try tracks(meetingId: meetingId)
        var removed = 0
        for track in tracks where fileManager.fileExists(atPath: track.fileURL.path) {
            try fileManager.removeItem(at: track.fileURL)
            removed += 1
        }
        try database.writer.write { db in
            try db.execute(
                sql: "DELETE FROM audioTrack WHERE meetingId = ?",
                arguments: [meetingId.uuidString]
            )
        }
        return removed
    }

    /// 트랙 기록만 지운다. 파일 삭제는 호출한 쪽에서 정책에 맞게 처리한다.
    public func deleteTrackRows(ids: [UUID]) throws {
        guard !ids.isEmpty else { return }
        try database.writer.write { db in
            for id in ids {
                try db.execute(sql: "DELETE FROM audioTrack WHERE id = ?", arguments: [id.uuidString])
            }
        }
    }

    /// 오디오 자동 삭제 판단에 필요한 값만 모아 온다(§11).
    ///
    /// 기준 시각은 종료 시각, 없으면 생성 시각이다.
    /// `isCompleted`는 상태가 완료이면서 회의록 행이 실제로 있는 경우만 참이다.
    /// 회의록이 없으면 오디오가 유일한 재시도 수단이므로 지우면 안 된다.
    public func audioRetentionCandidates() throws -> [AudioRetentionPolicy.Candidate] {
        try database.writer.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT m.id AS id,
                       m.endedAt AS endedAt,
                       m.createdAt AS createdAt,
                       m.status AS status,
                       (SELECT COUNT(*) FROM audioTrack t WHERE t.meetingId = m.id) AS trackCount,
                       (SELECT COUNT(*) FROM meetingNote n WHERE n.meetingId = m.id) AS noteCount
                FROM meeting m
                """
            )
            return rows.compactMap { row in
                guard let id = UUID(uuidString: row["id"]) else { return nil }
                let endedAt: Date? = row["endedAt"]
                let createdAt: Date = row["createdAt"]
                let status = MeetingStatus(rawValue: row["status"] ?? "") ?? .recorded
                let noteCount: Int = row["noteCount"] ?? 0
                let trackCount: Int = row["trackCount"] ?? 0
                return AudioRetentionPolicy.Candidate(
                    meetingId: id,
                    referenceDate: endedAt ?? createdAt,
                    isCompleted: status == .completed && noteCount > 0,
                    hasAudio: trackCount > 0
                )
            }
        }
    }

    /// 저장된 오디오 사용량. 설정 화면에 보여 준다.
    public func audioStorageUsage() throws -> (trackCount: Int, bytes: Int64) {
        try database.writer.read { db in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT COUNT(*) AS total, COALESCE(SUM(byteSize), 0) AS bytes FROM audioTrack"
            )
            return (trackCount: row?["total"] ?? 0, bytes: row?["bytes"] ?? 0)
        }
    }

    // MARK: - 전사문

    public func save(
        segments: [TranscriptSegment],
        relevance: [RelevanceDecision] = [],
        meetingId: UUID
    ) throws {
        let labels = Dictionary(relevance.map { ($0.segmentId, $0) }, uniquingKeysWith: { first, _ in first })
        try database.writer.write { db in
            try db.execute(
                sql: "DELETE FROM transcriptSegment WHERE meetingId = ?",
                arguments: [meetingId.uuidString]
            )
            for segment in segments {
                try TranscriptSegmentRecord(segment, relevance: labels[segment.id]).save(db)
            }
        }
    }

    /// 사담 판정만 갱신한다. 전사문 원문은 그대로 보존된다(§9).
    public func updateRelevance(_ relevance: [RelevanceDecision]) throws {
        try database.writer.write { db in
            for decision in relevance {
                try db.execute(
                    sql: "UPDATE transcriptSegment SET relevanceLabel = ?, relevanceReason = ? WHERE id = ?",
                    arguments: [decision.label.rawValue, decision.reason, decision.segmentId.uuidString]
                )
            }
        }
    }

    public func transcript(meetingId: UUID) throws -> [TranscriptSegment] {
        try database.writer.read { db in
            try TranscriptSegmentRecord
                .filter(Column("meetingId") == meetingId.uuidString)
                .order(Column("segmentIndex"))
                .fetchAll(db)
                .compactMap(\.domain)
        }
    }

    public func relevance(meetingId: UUID) throws -> [RelevanceDecision] {
        try database.writer.read { db in
            try TranscriptSegmentRecord
                .filter(Column("meetingId") == meetingId.uuidString)
                .order(Column("segmentIndex"))
                .fetchAll(db)
                .compactMap(\.relevance)
        }
    }

    // MARK: - 회의록

    public func save(note: MeetingNote) throws {
        try database.writer.write { db in
            let key = note.meetingId.uuidString
            for table in ["decision", "actionItem", "openQuestion", "riskItem", "topic"] {
                try db.execute(sql: "DELETE FROM \(table) WHERE meetingId = ?", arguments: [key])
            }
            try NoteRecord(note).save(db)
            for (index, decision) in note.decisions.enumerated() {
                try DecisionRecord(decision, meetingId: note.meetingId, position: index).save(db)
            }
            for (index, item) in note.actionItems.enumerated() {
                try ActionItemRecord(item, meetingId: note.meetingId, position: index).save(db)
            }
            for (index, item) in note.openQuestions.enumerated() {
                try OpenQuestionRecord(item, meetingId: note.meetingId, position: index).save(db)
            }
            for (index, item) in note.risks.enumerated() {
                try RiskItemRecord(item, meetingId: note.meetingId, position: index).save(db)
            }
            for (index, topic) in note.topics.enumerated() {
                try TopicRecord(topic, meetingId: note.meetingId, position: index).save(db)
            }
        }
    }

    public func note(meetingId: UUID) throws -> MeetingNote? {
        try database.writer.read { db in
            let key = meetingId.uuidString
            guard let record = try NoteRecord.fetchOne(db, key: key) else { return nil }
            var note = MeetingNote(
                meetingId: meetingId,
                title: record.title,
                summary: record.summary,
                generatedAt: record.generatedAt,
                generation: JSONColumn.decode(GenerationSummary.self, from: record.generationJSON)
                    ?? GenerationSummary(),
                customDocument: record.customDocument
            )
            note.decisions = try DecisionRecord
                .filter(Column("meetingId") == key).order(Column("position"))
                .fetchAll(db).compactMap(\.domain)
            note.actionItems = try ActionItemRecord
                .filter(Column("meetingId") == key).order(Column("position"))
                .fetchAll(db).compactMap(\.domain)
            note.openQuestions = try OpenQuestionRecord
                .filter(Column("meetingId") == key).order(Column("position"))
                .fetchAll(db).compactMap(\.domain)
            note.risks = try RiskItemRecord
                .filter(Column("meetingId") == key).order(Column("position"))
                .fetchAll(db).compactMap(\.domain)
            note.topics = try TopicRecord
                .filter(Column("meetingId") == key).order(Column("position"))
                .fetchAll(db).compactMap(\.domain)
            return note
        }
    }

    /// 액션아이템 사용자 수정(§11).
    public func update(actionItem: ActionItem, meetingId: UUID) throws {
        try database.writer.write { db in
            guard let existing = try ActionItemRecord.fetchOne(db, key: actionItem.id.uuidString) else {
                throw PersistenceError.notFound("actionItem \(actionItem.id)")
            }
            try ActionItemRecord(actionItem, meetingId: meetingId, position: existing.position).update(db)
        }
    }

    public func update(decision: Decision, meetingId: UUID) throws {
        try database.writer.write { db in
            guard let existing = try DecisionRecord.fetchOne(db, key: decision.id.uuidString) else {
                throw PersistenceError.notFound("decision \(decision.id)")
            }
            try DecisionRecord(decision, meetingId: meetingId, position: existing.position).update(db)
        }
    }
}

public enum PersistenceError: Error, LocalizedError, Sendable {
    case notFound(String)

    public var errorDescription: String? {
        switch self {
        case let .notFound(what): "저장된 항목을 찾을 수 없습니다: \(what)"
        }
    }
}
