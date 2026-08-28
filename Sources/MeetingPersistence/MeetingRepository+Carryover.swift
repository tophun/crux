import Foundation
import MeetingCore

public extension MeetingRepository {
    /// 두 회의를 같은 그룹으로 묶는다. 이미 다른 그룹에 있으면 합친다.
    func groupMeetings(_ firstId: UUID, with secondId: UUID) throws {
        guard firstId != secondId else { return }
        try database.write { context in
            let memberships = try context.all(MeetingGroupMembershipModel.self)
            let first = memberships.first { $0.meetingId == firstId.uuidString }
            let second = memberships.first { $0.meetingId == secondId.uuidString }
            let groupId: String
            if let first, let second, first.groupId != second.groupId {
                groupId = first.groupId
                for member in memberships where member.groupId == second.groupId {
                    member.groupId = groupId
                }
            } else if let first {
                groupId = first.groupId
            } else if let second {
                groupId = second.groupId
            } else {
                groupId = UUID().uuidString
            }
            if first == nil {
                context.insert(MeetingGroupMembershipModel(meetingId: firstId.uuidString, groupId: groupId))
            } else {
                first?.groupId = groupId
            }
            if second == nil {
                context.insert(MeetingGroupMembershipModel(meetingId: secondId.uuidString, groupId: groupId))
            } else {
                second?.groupId = groupId
            }
        }
    }

    func relatedGroupId(meetingId: UUID) throws -> UUID? {
        try database.read { context in
            try context.all(MeetingGroupMembershipModel.self)
                .first { $0.meetingId == meetingId.uuidString }
                .flatMap { UUID(uuidString: $0.groupId) }
        }
    }

    /// 관련 이전 회의의 미완료 액션. 로컬 publishRecord의 Jira 키가 있으면 같이 붙인다.
    ///
    /// 액션 상태를 바꾸지 않는다.
    func carryoverActions(for meetingId: UUID) throws -> [CarryoverAction] {
        try database.read { context in
            let meetings = try context.all(MeetingModel.self)
            guard let currentModel = meetings.first(where: { $0.id == meetingId.uuidString }) else {
                return []
            }
            let eventsById = try Dictionary(
                context.all(CalendarEventModel.self).map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            let groupByMeeting = try Dictionary(
                context.all(MeetingGroupMembershipModel.self).map { ($0.meetingId, $0.groupId) },
                uniquingKeysWith: { first, _ in first }
            )
            let actionsByMeeting = try Dictionary(grouping: context.all(ActionItemModel.self), by: \.meetingId)
            let recordsByMeeting = try Dictionary(grouping: context.all(PublishRecordModel.self), by: \.meetingId)

            func ref(for model: MeetingModel) -> RelatedMeetingRef? {
                guard let meeting = model.domain else { return nil }
                let event = model.calendarEventId.flatMap { eventsById[$0] }
                return RelatedMeetingRef(
                    id: meeting.id,
                    startedAt: meeting.startedAt,
                    title: meeting.title,
                    calendarEventId: model.calendarEventId,
                    calendarEventTitle: event?.title,
                    relatedGroupId: groupByMeeting[model.id].flatMap(UUID.init(uuidString:))
                )
            }

            guard let current = ref(for: currentModel) else { return [] }
            let snapshots: [CarryoverMeetingSnapshot] = meetings.compactMap { model in
                guard model.id != currentModel.id, let related = ref(for: model) else { return nil }
                let items = (actionsByMeeting[model.id] ?? [])
                    .sorted { $0.position < $1.position }
                    .compactMap(\.domain)
                let issues = (recordsByMeeting[model.id] ?? []).compactMap { record -> LocalIssueRef? in
                    guard record.target == PublishRecord.Target.jira.rawValue,
                          let contentId = record.contentId else { return nil }
                    let key = record.externalKey ?? record.externalId
                    guard !key.isEmpty else { return nil }
                    return LocalIssueRef(contentId: contentId, key: key, url: record.url)
                }
                return CarryoverMeetingSnapshot(meeting: related, actionItems: items, issues: issues)
            }
            return CarryoverActionCollector.collect(current: current, previous: snapshots)
        }
    }
}
