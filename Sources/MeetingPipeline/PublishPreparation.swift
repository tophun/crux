import Foundation
import MeetingCore
import MeetingPersistence
import MeetingPublishing

/// Preview Viewer와 실제 게시가 **같은 구조화 데이터**에서 렌더링되도록 게시 묶음을 준비한다(요구사항 4).
public struct PublishPreparation: Sendable {
    public struct Prepared: Sendable {
        public var meeting: Meeting
        public var note: MeetingNote
        public var event: CalendarEvent?
        public var bundle: PublishBundle
        public var evidence: EvidenceBundle
        public var findings: [MeetingQualityChecker.Finding]
        public var alreadyPublished: [PublishRecord]

        public var canPublish: Bool {
            MeetingQualityChecker().canPublish(findings)
        }
    }

    private let repository: MeetingRepository
    private let calendar: CalendarRepository
    private let publishRecords: PublishRecordRepository
    private let evidenceStore: EvidenceFileStore

    public init(
        repository: MeetingRepository,
        calendar: CalendarRepository,
        publishRecords: PublishRecordRepository,
        evidenceStore: EvidenceFileStore = EvidenceFileStore()
    ) {
        self.repository = repository
        self.calendar = calendar
        self.publishRecords = publishRecords
        self.evidenceStore = evidenceStore
    }

    public func prepare(
        meetingId: UUID,
        options: PublishBundleBuilder.Options
    ) throws -> Prepared {
        guard let meeting = try repository.meeting(id: meetingId) else {
            throw PipelineError.meetingNotFound(meetingId)
        }
        guard let note = try repository.note(meetingId: meetingId) else {
            throw PublishError.nothingToPublish
        }
        let event = try calendar.linkedEventId(meetingId: meetingId).flatMap { try? calendar.event(id: $0) }
        // 근거는 저장된 파일을 우선 사용하고 없으면 회의록에서 다시 만든다.
        let storedEvidence = try? evidenceStore.read(for: meeting)
        let evidence: EvidenceBundle = storedEvidence.flatMap { $0 } ?? EvidenceBundle.make(from: note)
        let bundle = PublishBundleBuilder().build(
            note: note,
            meeting: meeting,
            event: event,
            options: options
        )
        let findings = MeetingQualityChecker().check(note: note, bundle: bundle, evidence: evidence)

        return try Prepared(
            meeting: meeting,
            note: note,
            event: event,
            bundle: bundle,
            evidence: evidence,
            findings: findings,
            alreadyPublished: publishRecords.records(meetingId: meetingId)
        )
    }

    /// 게시 결과를 로컬에 기록한다. contentId ↔ 외부 식별자 연결은 여기에만 존재한다.
    public func recordOutcome(
        _ outcome: MeetingPublisher.Outcome,
        meetingId: UUID,
        spaceKey: String
    ) throws {
        var records: [PublishRecord] = [
            PublishRecord(
                meetingId: meetingId,
                contentId: nil,
                target: .confluence,
                externalId: outcome.pageId,
                externalKey: spaceKey,
                url: outcome.pageURL
            )
        ]
        records += outcome.issues.map { issue in
            PublishRecord(
                meetingId: meetingId,
                contentId: issue.contentId,
                target: .jira,
                externalId: issue.key,
                externalKey: issue.key,
                url: issue.url
            )
        }
        try publishRecords.save(records)
    }
}
