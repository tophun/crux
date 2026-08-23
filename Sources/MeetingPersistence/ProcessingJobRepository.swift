import Foundation
import MeetingCore

/// 처리 작업 저장소. 앱이 강제 종료돼도 어디서부터 재처리할지 남긴다(§13, §15).
public struct ProcessingJobRepository: Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func upsert(_ job: ProcessingJob) throws {
        try database.write { context in
            if let model = try context.all(ProcessingJobModel.self).first(where: {
                $0.meetingId == job.meetingId.uuidString && $0.stage == job.stage.rawValue
            }) {
                model.state = job.state.rawValue
                model.attempt = job.attempt
                model.startedAt = job.startedAt
                model.finishedAt = job.finishedAt
                model.errorMessage = job.errorMessage
                model.checkpoint = job.checkpoint
            } else {
                context.insert(ProcessingJobModel(job))
            }
        }
    }

    public func jobs(meetingId: UUID) throws -> [ProcessingJob] {
        try database.read { context in
            let order = ProcessingStage.allCases
            return try context.all(ProcessingJobModel.self)
                .filter { $0.meetingId == meetingId.uuidString }
                .compactMap(\.domain)
                .sorted {
                    (order.firstIndex(of: $0.stage) ?? 0) < (order.firstIndex(of: $1.stage) ?? 0)
                }
        }
    }

    public func job(meetingId: UUID, stage: ProcessingStage) throws -> ProcessingJob? {
        try database.read { context in
            try context.all(ProcessingJobModel.self)
                .first { $0.meetingId == meetingId.uuidString && $0.stage == stage.rawValue }?
                .domain
        }
    }

    /// 앱 시작 시 호출한다. 실행 중이던 작업을 중단 상태로 바꿔 재처리 대상으로 만든다.
    @discardableResult
    public func markRunningJobsInterrupted() throws -> Int {
        try database.write { context in
            let running = try context.all(ProcessingJobModel.self).filter {
                $0.state == ProcessingJobState.running.rawValue
            }
            for model in running {
                model.state = ProcessingJobState.interrupted.rawValue
                if model.errorMessage == nil {
                    model.errorMessage = "앱이 종료되어 중단됨 — 재처리 가능"
                }
            }
            return running.count
        }
    }

    /// 재처리가 필요한 회의 목록.
    public func meetingsNeedingRetry() throws -> [UUID] {
        try database.read { context in
            let ids = try context.all(ProcessingJobModel.self)
                .filter {
                    $0.state == ProcessingJobState.failed.rawValue
                        || $0.state == ProcessingJobState.interrupted.rawValue
                }
                .compactMap { UUID(uuidString: $0.meetingId) }
            return Array(Set(ids))
        }
    }

    /// 실패·중단된 작업을 다시 대기 상태로 만든다.
    public func resetForRetry(meetingId: UUID) throws {
        try database.write { context in
            for model in try context.all(ProcessingJobModel.self).filter({
                $0.meetingId == meetingId.uuidString
                    && ($0.state == ProcessingJobState.failed.rawValue
                        || $0.state == ProcessingJobState.interrupted.rawValue)
            }) {
                model.state = ProcessingJobState.pending.rawValue
                model.errorMessage = nil
                model.finishedAt = nil
            }
        }
    }
}
