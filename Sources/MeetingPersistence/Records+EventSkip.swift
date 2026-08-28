import Foundation
import MeetingCore
import SwiftData

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
