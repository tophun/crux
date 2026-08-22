import Foundation
import GRDB
import MeetingCore

/// 처리 작업 저장소. 앱이 강제 종료돼도 어디서부터 재처리할지 남긴다(§13, §15).
public struct ProcessingJobRepository: Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func upsert(_ job: ProcessingJob) throws {
        try database.writer.write { db in
            if let existing = try ProcessingJobRecord
                .filter(Column("meetingId") == job.meetingId.uuidString)
                .filter(Column("stage") == job.stage.rawValue)
                .fetchOne(db) {
                var record = ProcessingJobRecord(job)
                record.id = existing.id
                try record.update(db)
            } else {
                try ProcessingJobRecord(job).insert(db)
            }
        }
    }

    public func jobs(meetingId: UUID) throws -> [ProcessingJob] {
        try database.writer.read { db in
            try ProcessingJobRecord
                .filter(Column("meetingId") == meetingId.uuidString)
                .fetchAll(db)
                .compactMap(\.domain)
                .sorted { lhs, rhs in
                    let order = ProcessingStage.allCases
                    return (order.firstIndex(of: lhs.stage) ?? 0) < (order.firstIndex(of: rhs.stage) ?? 0)
                }
        }
    }

    public func job(meetingId: UUID, stage: ProcessingStage) throws -> ProcessingJob? {
        try database.writer.read { db in
            try ProcessingJobRecord
                .filter(Column("meetingId") == meetingId.uuidString)
                .filter(Column("stage") == stage.rawValue)
                .fetchOne(db)?
                .domain
        }
    }

    /// 앱 시작 시 호출한다. 실행 중이던 작업을 중단 상태로 바꿔 재처리 대상으로 만든다.
    @discardableResult
    public func markRunningJobsInterrupted() throws -> Int {
        try database.writer.write { db in
            try db.execute(
                sql: """
                UPDATE processingJob
                SET state = ?, errorMessage = COALESCE(errorMessage, ?)
                WHERE state = ?
                """,
                arguments: [
                    ProcessingJobState.interrupted.rawValue,
                    "앱이 종료되어 중단됨 — 재처리 가능",
                    ProcessingJobState.running.rawValue,
                ]
            )
            return db.changesCount
        }
    }

    /// 재처리가 필요한 회의 목록.
    public func meetingsNeedingRetry() throws -> [UUID] {
        try database.writer.read { db in
            let ids = try String.fetchAll(
                db,
                sql: """
                SELECT DISTINCT meetingId FROM processingJob WHERE state IN (?, ?)
                """,
                arguments: [ProcessingJobState.failed.rawValue, ProcessingJobState.interrupted.rawValue]
            )
            return ids.compactMap(UUID.init(uuidString:))
        }
    }

    /// 실패·중단된 작업을 다시 대기 상태로 만든다.
    public func resetForRetry(meetingId: UUID) throws {
        try database.writer.write { db in
            try db.execute(
                sql: """
                UPDATE processingJob
                SET state = ?, errorMessage = NULL, finishedAt = NULL
                WHERE meetingId = ? AND state IN (?, ?)
                """,
                arguments: [
                    ProcessingJobState.pending.rawValue,
                    meetingId.uuidString,
                    ProcessingJobState.failed.rawValue,
                    ProcessingJobState.interrupted.rawValue,
                ]
            )
        }
    }
}
