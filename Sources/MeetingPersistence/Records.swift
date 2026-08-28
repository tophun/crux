import Foundation
import MeetingCore
import SwiftData

// SwiftData 모델은 도메인 타입과 분리한다. UUID·URL·열거형·중첩 배열은
// 기존 SQLite 스키마와 호환되는 문자열·숫자·JSON으로 저장한다.

enum JSONColumn {
    static func encode(_ value: some Encodable) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }

    static func decode<T: Decodable>(_ type: T.Type, from string: String) -> T? {
        guard let data = string.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

@Model
final class MeetingModel {
    @Attribute(.unique) var id: String
    var title: String
    var startedAt: Date
    var endedAt: Date?
    var status: String
    var storageDirectory: String
    var source: String
    /// 없으면 일반. 기존 저장소는 필드가 없을 수 있다.
    var meetingType: String?
    var createdAt: Date
    var updatedAt: Date
    var calendarEventId: String?

    init(
        id: String,
        title: String,
        startedAt: Date,
        endedAt: Date?,
        status: String,
        storageDirectory: String,
        source: String,
        createdAt: Date,
        updatedAt: Date,
        calendarEventId: String? = nil
    ) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.status = status
        self.storageDirectory = storageDirectory
        self.source = source
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.calendarEventId = calendarEventId
        meetingType = nil
    }

    convenience init(_ meeting: Meeting) {
        self.init(
            id: meeting.id.uuidString,
            title: meeting.title,
            startedAt: meeting.startedAt,
            endedAt: meeting.endedAt,
            status: meeting.status.rawValue,
            storageDirectory: meeting.storageDirectory.path,
            source: meeting.source.rawValue,
            createdAt: meeting.createdAt,
            updatedAt: meeting.updatedAt
        )
        meetingType = meeting.meetingType.rawValue
    }

    var domain: Meeting? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        var meeting = Meeting(
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
        meeting.meetingType = meetingType.flatMap(MeetingType.parse) ?? .general
        return meeting
    }
}

@Model
final class AudioTrackModel {
    @Attribute(.unique) var id: String
    var meetingId: String
    var kind: String
    var filePath: String
    var duration: Double
    var sampleRate: Double
    var channelCount: Int
    var byteSize: Int64
    var createdAt: Date

    init(
        id: String,
        meetingId: String,
        kind: String,
        filePath: String,
        duration: Double,
        sampleRate: Double,
        channelCount: Int,
        byteSize: Int64,
        createdAt: Date
    ) {
        self.id = id
        self.meetingId = meetingId
        self.kind = kind
        self.filePath = filePath
        self.duration = duration
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.byteSize = byteSize
        self.createdAt = createdAt
    }

    convenience init(_ track: AudioTrack) {
        self.init(
            id: track.id.uuidString,
            meetingId: track.meetingId.uuidString,
            kind: track.kind.rawValue,
            filePath: track.fileURL.path,
            duration: track.duration,
            sampleRate: track.sampleRate,
            channelCount: track.channelCount,
            byteSize: track.byteSize,
            createdAt: track.createdAt
        )
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

@Model
final class TranscriptSegmentModel {
    @Attribute(.unique) var id: String
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

    init(
        id: String,
        meetingId: String,
        segmentIndex: Int,
        startTime: Double,
        endTime: Double,
        speakerId: String?,
        text: String,
        confidence: Double?,
        sourceTrack: String,
        relevanceLabel: String?,
        relevanceReason: String?
    ) {
        self.id = id
        self.meetingId = meetingId
        self.segmentIndex = segmentIndex
        self.startTime = startTime
        self.endTime = endTime
        self.speakerId = speakerId
        self.text = text
        self.confidence = confidence
        self.sourceTrack = sourceTrack
        self.relevanceLabel = relevanceLabel
        self.relevanceReason = relevanceReason
    }

    convenience init(_ segment: TranscriptSegment, relevance: RelevanceDecision? = nil) {
        self.init(
            id: segment.id.uuidString,
            meetingId: segment.meetingId.uuidString,
            segmentIndex: segment.index,
            startTime: segment.startTime,
            endTime: segment.endTime,
            speakerId: segment.speakerId,
            text: segment.text,
            confidence: segment.confidence,
            sourceTrack: segment.sourceTrack.rawValue,
            relevanceLabel: relevance?.label.rawValue,
            relevanceReason: relevance?.reason
        )
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

@Model
final class NoteModel {
    @Attribute(.unique) var meetingId: String
    var title: String
    var summary: String
    var generatedAt: Date
    var generationJSON: String
    var customDocument: String?

    init(
        meetingId: String,
        title: String,
        summary: String,
        generatedAt: Date,
        generationJSON: String,
        customDocument: String?
    ) {
        self.meetingId = meetingId
        self.title = title
        self.summary = summary
        self.generatedAt = generatedAt
        self.generationJSON = generationJSON
        self.customDocument = customDocument
    }

    convenience init(_ note: MeetingNote) {
        self.init(
            meetingId: note.meetingId.uuidString,
            title: note.title,
            summary: note.summary,
            generatedAt: note.generatedAt,
            generationJSON: JSONColumn.encode(note.generation),
            customDocument: note.customDocument
        )
    }
}

@Model
final class DecisionModel {
    @Attribute(.unique) var id: String
    var meetingId: String
    var position: Int
    var content: String
    var kind: String
    var evidenceJSON: String
    var confidence: Double
    var reviewed: Bool

    init(
        id: String,
        meetingId: String,
        position: Int,
        content: String,
        kind: String,
        evidenceJSON: String,
        confidence: Double,
        reviewed: Bool
    ) {
        self.id = id
        self.meetingId = meetingId
        self.position = position
        self.content = content
        self.kind = kind
        self.evidenceJSON = evidenceJSON
        self.confidence = confidence
        self.reviewed = reviewed
    }

    convenience init(_ decision: Decision, meetingId: UUID, position: Int) {
        self.init(
            id: decision.id.uuidString,
            meetingId: meetingId.uuidString,
            position: position,
            content: decision.content,
            kind: decision.kind.rawValue,
            evidenceJSON: JSONColumn.encode(decision.evidence),
            confidence: decision.confidence,
            reviewed: decision.reviewed
        )
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

@Model
final class ActionItemModel {
    @Attribute(.unique) var id: String
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

    init(
        id: String,
        meetingId: String,
        position: Int,
        task: String,
        assignee: String?,
        dueDate: String?,
        dueDateNote: String?,
        status: String,
        evidenceJSON: String,
        confidence: Double,
        reviewed: Bool
    ) {
        self.id = id
        self.meetingId = meetingId
        self.position = position
        self.task = task
        self.assignee = assignee
        self.dueDate = dueDate
        self.dueDateNote = dueDateNote
        self.status = status
        self.evidenceJSON = evidenceJSON
        self.confidence = confidence
        self.reviewed = reviewed
    }

    convenience init(_ item: ActionItem, meetingId: UUID, position: Int) {
        self.init(
            id: item.id.uuidString,
            meetingId: meetingId.uuidString,
            position: position,
            task: item.task,
            assignee: item.assignee,
            dueDate: item.dueDate,
            dueDateNote: item.dueDateNote,
            status: item.status.rawValue,
            evidenceJSON: JSONColumn.encode(item.evidence),
            confidence: item.confidence,
            reviewed: item.reviewed
        )
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

@Model
final class OpenQuestionModel {
    @Attribute(.unique) var id: String
    var meetingId: String
    var position: Int
    var question: String
    var evidenceJSON: String
    var confidence: Double

    init(id: String, meetingId: String, position: Int, question: String, evidenceJSON: String, confidence: Double) {
        self.id = id
        self.meetingId = meetingId
        self.position = position
        self.question = question
        self.evidenceJSON = evidenceJSON
        self.confidence = confidence
    }

    convenience init(_ item: OpenQuestion, meetingId: UUID, position: Int) {
        self.init(
            id: item.id.uuidString,
            meetingId: meetingId.uuidString,
            position: position,
            question: item.question,
            evidenceJSON: JSONColumn.encode(item.evidence),
            confidence: item.confidence
        )
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

@Model
final class RiskItemModel {
    @Attribute(.unique) var id: String
    var meetingId: String
    var position: Int
    var content: String
    var severity: String
    var evidenceJSON: String
    var confidence: Double

    init(id: String, meetingId: String, position: Int, content: String, severity: String, evidenceJSON: String, confidence: Double) {
        self.id = id
        self.meetingId = meetingId
        self.position = position
        self.content = content
        self.severity = severity
        self.evidenceJSON = evidenceJSON
        self.confidence = confidence
    }

    convenience init(_ item: RiskItem, meetingId: UUID, position: Int) {
        self.init(
            id: item.id.uuidString,
            meetingId: meetingId.uuidString,
            position: position,
            content: item.content,
            severity: item.severity.rawValue,
            evidenceJSON: JSONColumn.encode(item.evidence),
            confidence: item.confidence
        )
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

@Model
final class TopicModel {
    @Attribute(.unique) var id: String
    var meetingId: String
    var position: Int
    var title: String
    var summary: String
    var startTime: Double?
    var endTime: Double?

    init(id: String, meetingId: String, position: Int, title: String, summary: String, startTime: Double?, endTime: Double?) {
        self.id = id
        self.meetingId = meetingId
        self.position = position
        self.title = title
        self.summary = summary
        self.startTime = startTime
        self.endTime = endTime
    }

    convenience init(_ topic: Topic, meetingId: UUID, position: Int) {
        self.init(
            id: topic.id.uuidString,
            meetingId: meetingId.uuidString,
            position: position,
            title: topic.title,
            summary: topic.summary,
            startTime: topic.startTime,
            endTime: topic.endTime
        )
    }

    var domain: Topic? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        return Topic(id: uuid, title: title, summary: summary, startTime: startTime, endTime: endTime)
    }
}

@Model
final class ProcessingJobModel {
    @Attribute(.unique) var id: String
    var meetingId: String
    var stage: String
    var state: String
    var attempt: Int
    var startedAt: Date?
    var finishedAt: Date?
    var errorMessage: String?
    var checkpoint: String?

    init(
        id: String,
        meetingId: String,
        stage: String,
        state: String,
        attempt: Int,
        startedAt: Date?,
        finishedAt: Date?,
        errorMessage: String?,
        checkpoint: String?
    ) {
        self.id = id
        self.meetingId = meetingId
        self.stage = stage
        self.state = state
        self.attempt = attempt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.errorMessage = errorMessage
        self.checkpoint = checkpoint
    }

    convenience init(_ job: ProcessingJob) {
        self.init(
            id: job.id.uuidString,
            meetingId: job.meetingId.uuidString,
            stage: job.stage.rawValue,
            state: job.state.rawValue,
            attempt: job.attempt,
            startedAt: job.startedAt,
            finishedAt: job.finishedAt,
            errorMessage: job.errorMessage,
            checkpoint: job.checkpoint
        )
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

@Model
final class CalendarEventModel {
    @Attribute(.unique) var id: String
    var seriesId: String?
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

    init(
        id: String,
        title: String,
        startDate: Date,
        endDate: Date,
        isAllDay: Bool,
        status: String,
        attendeesJSON: String,
        conferenceURL: String?,
        location: String?,
        organizerJSON: String?,
        calendarTitle: String?,
        updatedAt: Date,
        seriesId: String? = nil
    ) {
        self.id = id
        self.seriesId = seriesId
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.isAllDay = isAllDay
        self.status = status
        self.attendeesJSON = attendeesJSON
        self.conferenceURL = conferenceURL
        self.location = location
        self.organizerJSON = organizerJSON
        self.calendarTitle = calendarTitle
        self.updatedAt = updatedAt
    }

    convenience init(_ event: CalendarEvent, updatedAt: Date = Date()) {
        self.init(
            id: event.id,
            title: event.title,
            startDate: event.startDate,
            endDate: event.endDate,
            isAllDay: event.isAllDay,
            status: event.status.rawValue,
            attendeesJSON: JSONColumn.encode(event.attendees),
            conferenceURL: event.conferenceURL?.absoluteString,
            location: event.location,
            organizerJSON: event.organizer.map { JSONColumn.encode($0) },
            calendarTitle: event.calendarTitle,
            updatedAt: updatedAt,
            seriesId: event.seriesId
        )
    }

    var domain: CalendarEvent {
        CalendarEvent(
            id: id,
            seriesId: seriesId,
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

@Model
final class NotifiedEventModel {
    @Attribute(.unique) var eventId: String
    var notifiedAt: Date

    init(eventId: String, notifiedAt: Date) {
        self.eventId = eventId
        self.notifiedAt = notifiedAt
    }
}

/// 사용자가 직접 묶은 회의. 한 회의는 그룹 하나에만 속한다.
@Model
final class MeetingGroupMembershipModel {
    @Attribute(.unique) var meetingId: String
    var groupId: String

    init(meetingId: String, groupId: String) {
        self.meetingId = meetingId
        self.groupId = groupId
    }
}

@Model
final class SkippedEventModel {
    @Attribute(.unique) var id: String
    var eventId: String
    var seriesId: String?
    var startDate: Date
    var scope: String
    var skippedAt: Date

    init(
        id: String,
        eventId: String,
        seriesId: String?,
        startDate: Date,
        scope: String,
        skippedAt: Date
    ) {
        self.id = id
        self.eventId = eventId
        self.seriesId = seriesId
        self.startDate = startDate
        self.scope = scope
        self.skippedAt = skippedAt
    }

    convenience init(_ record: EventSkipRecord) {
        self.init(
            id: record.id,
            eventId: record.eventId,
            seriesId: record.seriesId,
            startDate: record.startDate,
            scope: record.scope.rawValue,
            skippedAt: record.skippedAt
        )
    }

    var domain: EventSkipRecord? {
        guard let scope = EventSkipScope(rawValue: scope) else { return nil }
        return EventSkipRecord(
            id: id,
            eventId: eventId,
            seriesId: seriesId,
            startDate: startDate,
            scope: scope,
            skippedAt: skippedAt
        )
    }
}

enum PersistenceSchema {
    static let schema = Schema([
        MeetingModel.self,
        AudioTrackModel.self,
        TranscriptSegmentModel.self,
        NoteModel.self,
        DecisionModel.self,
        ActionItemModel.self,
        OpenQuestionModel.self,
        RiskItemModel.self,
        TopicModel.self,
        ProcessingJobModel.self,
        CalendarEventModel.self,
        NotifiedEventModel.self,
        PublishRecordModel.self,
        MeetingGroupMembershipModel.self,
        SkippedEventModel.self
    ])
}

extension ModelContext {
    func all<Model: PersistentModel>(_: Model.Type) throws -> [Model] {
        try fetch(FetchDescriptor<Model>())
    }
}
