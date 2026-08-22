import Foundation
import GRDB
import MeetingCore

// 도메인 타입을 그대로 저장하지 않고 레코드로 매핑한다.
// URL·UUID·중첩 배열의 저장 형식을 스키마에서 명시적으로 통제하기 위함이다.

enum JSONColumn {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
    static let decoder = JSONDecoder()

    static func encode<T: Encodable>(_ value: T) -> String {
        guard let data = try? encoder.encode(value) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }

    static func decode<T: Decodable>(_ type: T.Type, from string: String) -> T? {
        guard let data = string.data(using: .utf8) else { return nil }
        return try? decoder.decode(type, from: data)
    }
}

struct MeetingRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "meeting"

    var id: String
    var title: String
    var startedAt: Date
    var endedAt: Date?
    var status: String
    var storageDirectory: String
    var source: String
    var createdAt: Date
    var updatedAt: Date

    init(_ meeting: Meeting) {
        id = meeting.id.uuidString
        title = meeting.title
        startedAt = meeting.startedAt
        endedAt = meeting.endedAt
        status = meeting.status.rawValue
        storageDirectory = meeting.storageDirectory.path
        source = meeting.source.rawValue
        createdAt = meeting.createdAt
        updatedAt = meeting.updatedAt
    }

    var domain: Meeting? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        return Meeting(
            id: uuid,
            title: title,
            startedAt: startedAt,
            endedAt: endedAt,
            status: MeetingStatus(rawValue: status) ?? .recorded,
            storageDirectory: URL(fileURLWithPath: storageDirectory),
            source: MeetingSource(rawValue: source) ?? .importedFile,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

struct AudioTrackRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "audioTrack"

    var id: String
    var meetingId: String
    var kind: String
    var filePath: String
    var duration: Double
    var sampleRate: Double
    var channelCount: Int
    var byteSize: Int64
    var createdAt: Date

    init(_ track: AudioTrack) {
        id = track.id.uuidString
        meetingId = track.meetingId.uuidString
        kind = track.kind.rawValue
        filePath = track.fileURL.path
        duration = track.duration
        sampleRate = track.sampleRate
        channelCount = track.channelCount
        byteSize = track.byteSize
        createdAt = track.createdAt
    }

    var domain: AudioTrack? {
        guard let uuid = UUID(uuidString: id), let meeting = UUID(uuidString: meetingId) else { return nil }
        return AudioTrack(
            id: uuid,
            meetingId: meeting,
            kind: AudioTrackKind(rawValue: kind) ?? .mixed,
            fileURL: URL(fileURLWithPath: filePath),
            duration: duration,
            sampleRate: sampleRate,
            channelCount: channelCount,
            byteSize: byteSize,
            createdAt: createdAt
        )
    }
}

struct TranscriptSegmentRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "transcriptSegment"

    var id: String
    var meetingId: String
    var segmentIndex: Int
    var startTime: Double
    var endTime: Double
    var speakerId: String?
    var text: String
    var confidence: Double?
    var sourceTrack: String
    var relevanceLabel: String?
    var relevanceReason: String?

    init(_ segment: TranscriptSegment, relevance: RelevanceDecision? = nil) {
        id = segment.id.uuidString
        meetingId = segment.meetingId.uuidString
        segmentIndex = segment.index
        startTime = segment.startTime
        endTime = segment.endTime
        speakerId = segment.speakerId
        text = segment.text
        confidence = segment.confidence
        sourceTrack = segment.sourceTrack.rawValue
        relevanceLabel = relevance?.label.rawValue
        relevanceReason = relevance?.reason
    }

    var domain: TranscriptSegment? {
        guard let uuid = UUID(uuidString: id), let meeting = UUID(uuidString: meetingId) else { return nil }
        return TranscriptSegment(
            id: uuid,
            meetingId: meeting,
            index: segmentIndex,
            startTime: startTime,
            endTime: endTime,
            speakerId: speakerId,
            text: text,
            confidence: confidence,
            sourceTrack: AudioTrackKind(rawValue: sourceTrack) ?? .mixed
        )
    }

    var relevance: RelevanceDecision? {
        guard let uuid = UUID(uuidString: id),
              let label = relevanceLabel.flatMap(RelevanceLabel.init(rawValue:)) else { return nil }
        return RelevanceDecision(segmentId: uuid, label: label, reason: relevanceReason)
    }
}

struct NoteRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "meetingNote"

    var meetingId: String
    var title: String
    var summary: String
    var generatedAt: Date
    var generationJSON: String
    var customDocument: String?

    init(_ note: MeetingNote) {
        meetingId = note.meetingId.uuidString
        title = note.title
        summary = note.summary
        generatedAt = note.generatedAt
        generationJSON = JSONColumn.encode(note.generation)
        customDocument = note.customDocument
    }
}

struct DecisionRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "decision"

    var id: String
    var meetingId: String
    var position: Int
    var content: String
    var kind: String
    var evidenceJSON: String
    var confidence: Double
    var reviewed: Bool

    init(_ decision: Decision, meetingId: UUID, position: Int) {
        id = decision.id.uuidString
        self.meetingId = meetingId.uuidString
        self.position = position
        content = decision.content
        kind = decision.kind.rawValue
        evidenceJSON = JSONColumn.encode(decision.evidence)
        confidence = decision.confidence
        reviewed = decision.reviewed
    }

    var domain: Decision? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        return Decision(
            id: uuid,
            content: content,
            kind: DecisionKind(rawValue: kind) ?? .proposed,
            evidence: JSONColumn.decode([Evidence].self, from: evidenceJSON) ?? [],
            confidence: confidence,
            reviewed: reviewed
        )
    }
}

struct ActionItemRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "actionItem"

    var id: String
    var meetingId: String
    var position: Int
    var task: String
    var assignee: String?
    var dueDate: String?
    var dueDateNote: String?
    var status: String
    var evidenceJSON: String
    var confidence: Double
    var reviewed: Bool

    init(_ item: ActionItem, meetingId: UUID, position: Int) {
        id = item.id.uuidString
        self.meetingId = meetingId.uuidString
        self.position = position
        task = item.task
        assignee = item.assignee
        dueDate = item.dueDate
        dueDateNote = item.dueDateNote
        status = item.status.rawValue
        evidenceJSON = JSONColumn.encode(item.evidence)
        confidence = item.confidence
        reviewed = item.reviewed
    }

    var domain: ActionItem? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        return ActionItem(
            id: uuid,
            task: task,
            assignee: assignee,
            dueDate: dueDate,
            dueDateNote: dueDateNote,
            status: ActionItemStatus(rawValue: status) ?? .proposed,
            evidence: JSONColumn.decode([Evidence].self, from: evidenceJSON) ?? [],
            confidence: confidence,
            reviewed: reviewed
        )
    }
}

struct OpenQuestionRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "openQuestion"

    var id: String
    var meetingId: String
    var position: Int
    var question: String
    var evidenceJSON: String
    var confidence: Double

    init(_ item: OpenQuestion, meetingId: UUID, position: Int) {
        id = item.id.uuidString
        self.meetingId = meetingId.uuidString
        self.position = position
        question = item.question
        evidenceJSON = JSONColumn.encode(item.evidence)
        confidence = item.confidence
    }

    var domain: OpenQuestion? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        return OpenQuestion(
            id: uuid,
            question: question,
            evidence: JSONColumn.decode([Evidence].self, from: evidenceJSON) ?? [],
            confidence: confidence
        )
    }
}

struct RiskItemRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "riskItem"

    var id: String
    var meetingId: String
    var position: Int
    var content: String
    var severity: String
    var evidenceJSON: String
    var confidence: Double

    init(_ item: RiskItem, meetingId: UUID, position: Int) {
        id = item.id.uuidString
        self.meetingId = meetingId.uuidString
        self.position = position
        content = item.content
        severity = item.severity.rawValue
        evidenceJSON = JSONColumn.encode(item.evidence)
        confidence = item.confidence
    }

    var domain: RiskItem? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        return RiskItem(
            id: uuid,
            content: content,
            severity: RiskSeverity(rawValue: severity) ?? .unknown,
            evidence: JSONColumn.decode([Evidence].self, from: evidenceJSON) ?? [],
            confidence: confidence
        )
    }
}

struct TopicRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "topic"

    var id: String
    var meetingId: String
    var position: Int
    var title: String
    var summary: String
    var startTime: Double?
    var endTime: Double?

    init(_ topic: Topic, meetingId: UUID, position: Int) {
        id = topic.id.uuidString
        self.meetingId = meetingId.uuidString
        self.position = position
        title = topic.title
        summary = topic.summary
        startTime = topic.startTime
        endTime = topic.endTime
    }

    var domain: Topic? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        return Topic(id: uuid, title: title, summary: summary, startTime: startTime, endTime: endTime)
    }
}

struct ProcessingJobRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "processingJob"

    var id: String
    var meetingId: String
    var stage: String
    var state: String
    var attempt: Int
    var startedAt: Date?
    var finishedAt: Date?
    var errorMessage: String?
    var checkpoint: String?

    init(_ job: ProcessingJob) {
        id = job.id.uuidString
        meetingId = job.meetingId.uuidString
        stage = job.stage.rawValue
        state = job.state.rawValue
        attempt = job.attempt
        startedAt = job.startedAt
        finishedAt = job.finishedAt
        errorMessage = job.errorMessage
        checkpoint = job.checkpoint
    }

    var domain: ProcessingJob? {
        guard let uuid = UUID(uuidString: id),
              let meeting = UUID(uuidString: meetingId),
              let stage = ProcessingStage(rawValue: stage),
              let state = ProcessingJobState(rawValue: state) else { return nil }
        return ProcessingJob(
            id: uuid,
            meetingId: meeting,
            stage: stage,
            state: state,
            attempt: attempt,
            startedAt: startedAt,
            finishedAt: finishedAt,
            errorMessage: errorMessage,
            checkpoint: checkpoint
        )
    }
}

// MARK: - v2: 캘린더 · 게시 기록

struct CalendarEventRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "calendarEvent"

    var id: String
    var title: String
    var startDate: Date
    var endDate: Date
    var isAllDay: Bool
    var status: String
    var attendeesJSON: String
    var conferenceURL: String?
    var location: String?
    var organizerJSON: String?
    var calendarTitle: String?
    var updatedAt: Date

    init(_ event: CalendarEvent, updatedAt: Date = Date()) {
        id = event.id
        title = event.title
        startDate = event.startDate
        endDate = event.endDate
        isAllDay = event.isAllDay
        status = event.status.rawValue
        attendeesJSON = JSONColumn.encode(event.attendees)
        conferenceURL = event.conferenceURL?.absoluteString
        location = event.location
        organizerJSON = event.organizer.map { JSONColumn.encode($0) }
        calendarTitle = event.calendarTitle
        self.updatedAt = updatedAt
    }

    var domain: CalendarEvent {
        CalendarEvent(
            id: id,
            title: title,
            startDate: startDate,
            endDate: endDate,
            isAllDay: isAllDay,
            status: CalendarEventStatus(rawValue: status) ?? .unknown,
            attendees: JSONColumn.decode([EventAttendee].self, from: attendeesJSON) ?? [],
            conferenceURL: conferenceURL.flatMap(URL.init(string:)),
            location: location,
            organizer: organizerJSON.flatMap { JSONColumn.decode(EventAttendee.self, from: $0) },
            calendarTitle: calendarTitle
        )
    }
}

struct NotifiedEventRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "notifiedEvent"

    var eventId: String
    var notifiedAt: Date
}

/// 게시 결과. `contentId`↔외부 식별자 연결은 로컬에만 존재한다.
public struct PublishRecord: Identifiable, Hashable, Sendable, Codable {
    public enum Target: String, Sendable, Codable {
        case confluence
        case jira
    }

    public var id: UUID
    public var meetingId: UUID
    /// 회의록 항목의 내부 식별자 (페이지 게시는 nil)
    public var contentId: String?
    public var target: Target
    /// Confluence pageId 또는 Jira issue id
    public var externalId: String
    /// Jira 이슈 키 (예: PROJ-123)
    public var externalKey: String?
    public var url: String
    public var publishedAt: Date

    public init(
        id: UUID = UUID(),
        meetingId: UUID,
        contentId: String? = nil,
        target: Target,
        externalId: String,
        externalKey: String? = nil,
        url: String,
        publishedAt: Date = Date()
    ) {
        self.id = id
        self.meetingId = meetingId
        self.contentId = contentId
        self.target = target
        self.externalId = externalId
        self.externalKey = externalKey
        self.url = url
        self.publishedAt = publishedAt
    }
}

struct PublishRecordRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "publishRecord"

    var id: String
    var meetingId: String
    var contentId: String?
    var target: String
    var externalId: String
    var externalKey: String?
    var url: String
    var publishedAt: Date

    init(_ record: PublishRecord) {
        id = record.id.uuidString
        meetingId = record.meetingId.uuidString
        contentId = record.contentId
        target = record.target.rawValue
        externalId = record.externalId
        externalKey = record.externalKey
        url = record.url
        publishedAt = record.publishedAt
    }

    var domain: PublishRecord? {
        guard let uuid = UUID(uuidString: id),
              let meeting = UUID(uuidString: meetingId),
              let target = PublishRecord.Target(rawValue: target) else { return nil }
        return PublishRecord(
            id: uuid,
            meetingId: meeting,
            contentId: contentId,
            target: target,
            externalId: externalId,
            externalKey: externalKey,
            url: url,
            publishedAt: publishedAt
        )
    }
}
