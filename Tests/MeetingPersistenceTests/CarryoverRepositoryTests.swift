import Foundation
@testable import MeetingCore
@testable import MeetingPersistence
import Testing

@Suite("지난 액션 저장소")
struct CarryoverRepositoryTests {
    struct Harness {
        var repository: MeetingRepository
        var calendar: CalendarRepository
        var publishes: PublishRecordRepository
        var directory: URL
    }

    func makeHarness() throws -> Harness {
        let database = try AppDatabase.inMemory()
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("carryover-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return Harness(
            repository: MeetingRepository(database: database),
            calendar: CalendarRepository(database: database),
            publishes: PublishRecordRepository(database: database),
            directory: directory
        )
    }

    func saveMeeting(
        _ harness: Harness,
        title: String,
        startedAt: Date,
        event: CalendarEvent? = nil
    ) throws -> Meeting {
        let meeting = Meeting(
            title: title,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(3600),
            storageDirectory: harness.directory
        )
        try harness.repository.save(meeting)
        if let event {
            try harness.calendar.save(events: [event])
            try harness.calendar.link(meetingId: meeting.id, eventId: event.id)
        }
        return meeting
    }

    func saveNote(
        _ harness: Harness,
        meetingId: UUID,
        items: [ActionItem]
    ) throws {
        var note = MeetingNote(meetingId: meetingId, title: "회의록")
        note.actionItems = items
        try harness.repository.save(note: note)
    }

    func event(id: String, title: String, start: Date) -> CalendarEvent {
        CalendarEvent(
            id: id,
            title: title,
            startDate: start,
            endDate: start.addingTimeInterval(3600)
        )
    }

    @Test("같은 캘린더 제목의 미완료 액션과 Jira 키를 새 회의에 붙인다")
    func loadsUnfinishedActionsWithJiraKey() throws {
        let harness = try makeHarness()
        let lastWeek = Date(timeIntervalSince1970: 1_700_000_000)
        let today = lastWeek.addingTimeInterval(86400)
        let previous = try saveMeeting(
            harness,
            title: "주간 스탠드업",
            startedAt: lastWeek,
            event: event(id: "standup-1", title: "주간 스탠드업", start: lastWeek)
        )
        let current = try saveMeeting(
            harness,
            title: "주간 스탠드업",
            startedAt: today,
            event: event(id: "standup-2", title: "주간 스탠드업", start: today)
        )
        try saveNote(harness, meetingId: previous.id, items: [
            ActionItem(task: "체크리스트 공유", status: .confirmed),
            ActionItem(task: "공지 발송", status: .done),
            ActionItem(task: "임시 우회", status: .dropped)
        ])
        try harness.publishes.save([
            PublishRecord(
                meetingId: previous.id,
                contentId: ContentId.actionItem(0),
                target: .jira,
                externalId: "CRUX-21",
                externalKey: "CRUX-21",
                url: "https://example.atlassian.net/browse/CRUX-21"
            )
        ])

        let carryover = try harness.repository.carryoverActions(for: current.id)
        #expect(carryover.map(\.action.task) == ["체크리스트 공유"])
        #expect(carryover[0].action.status == .confirmed)
        #expect(carryover[0].displayJiraKey == "CRUX-21")
        #expect(try harness.repository.note(meetingId: previous.id)?.actionItems[0].status == .confirmed)
    }

    @Test("사용자가 묶은 회의의 미완료 액션만 가져온다")
    func loadsUserGroupedMeetings() throws {
        let harness = try makeHarness()
        let lastWeek = Date(timeIntervalSince1970: 1_700_000_000)
        let today = lastWeek.addingTimeInterval(86400)
        let payment = try saveMeeting(harness, title: "결제 점검", startedAt: lastWeek)
        let hiring = try saveMeeting(harness, title: "채용 회의", startedAt: lastWeek.addingTimeInterval(60))
        let launch = try saveMeeting(harness, title: "출시 준비", startedAt: today)
        try saveNote(harness, meetingId: payment.id, items: [
            ActionItem(task: "한도 확인", status: .inProgress)
        ])
        try saveNote(harness, meetingId: hiring.id, items: [
            ActionItem(task: "면접 일정", status: .confirmed)
        ])

        try harness.repository.groupMeetings(launch.id, with: payment.id)
        let carryover = try harness.repository.carryoverActions(for: launch.id)
        let launchGroup = try harness.repository.relatedGroupId(meetingId: launch.id)
        let paymentGroup = try harness.repository.relatedGroupId(meetingId: payment.id)
        #expect(carryover.map(\.action.task) == ["한도 확인"])
        #expect(launchGroup != nil)
        #expect(launchGroup == paymentGroup)
    }

    @Test("회의를 삭제하면 그룹 기록도 지운다")
    func deletesGroupMembership() throws {
        let harness = try makeHarness()
        let first = try saveMeeting(harness, title: "A", startedAt: Date(timeIntervalSince1970: 1))
        let second = try saveMeeting(harness, title: "B", startedAt: Date(timeIntervalSince1970: 2))
        try harness.repository.groupMeetings(first.id, with: second.id)
        try harness.repository.delete(meetingId: first.id)
        #expect(try harness.repository.relatedGroupId(meetingId: first.id) == nil)
        #expect(try harness.repository.relatedGroupId(meetingId: second.id) != nil)
    }
}
