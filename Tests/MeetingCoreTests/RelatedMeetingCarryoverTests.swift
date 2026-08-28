import Foundation
@testable import MeetingCore
import Testing

@Suite("지난 액션 이어보기")
struct RelatedMeetingCarryoverTests {
    let standup = Date(timeIntervalSince1970: 1_700_000_000)
    let today = Date(timeIntervalSince1970: 1_700_086_400)

    func meeting(
        id: UUID = UUID(),
        title: String,
        startedAt: Date,
        calendarEventId: String? = nil,
        calendarEventTitle: String? = nil,
        relatedGroupId: UUID? = nil
    ) -> RelatedMeetingRef {
        RelatedMeetingRef(
            id: id,
            startedAt: startedAt,
            title: title,
            calendarEventId: calendarEventId,
            calendarEventTitle: calendarEventTitle,
            relatedGroupId: relatedGroupId
        )
    }

    func action(_ task: String, status: ActionItemStatus) -> ActionItem {
        ActionItem(task: task, status: status)
    }

    @Test("같은 캘린더 제목의 이전 회의는 관련이다")
    func groupsByCalendarTitle() {
        let previous = meeting(
            title: "주간 스탠드업",
            startedAt: standup,
            calendarEventId: "evt-last-week",
            calendarEventTitle: "주간 스탠드업"
        )
        let current = meeting(
            title: "주간 스탠드업",
            startedAt: today,
            calendarEventId: "evt-this-week",
            calendarEventTitle: " 주간   스탠드업 "
        )
        #expect(RelatedMeetingGrouping.areRelated(current, previous))
    }

    @Test("같은 캘린더 시리즈의 발생분은 제목이 달라도 관련이다")
    func groupsByCalendarSeries() throws {
        let previous = meeting(
            title: "주간 스탠드업",
            startedAt: standup,
            calendarEventId: "series-abc/RID=1700000000.000000",
            calendarEventTitle: "주간 스탠드업"
        )
        let current = meeting(
            title: "주간 스탠드업 (변경)",
            startedAt: today,
            calendarEventId: "series-abc/RID=1700086400.000000",
            calendarEventTitle: "주간 스탠드업 (변경)"
        )
        let eventId = try #require(current.calendarEventId)
        #expect(RelatedMeetingGrouping.seriesKey(eventId: eventId) == "series-abc")
        #expect(RelatedMeetingGrouping.areRelated(current, previous))
    }

    @Test("사용자가 묶은 회의는 제목이 달라도 관련이다")
    func groupsByUserLink() {
        let group = UUID()
        let previous = meeting(
            title: "결제 점검",
            startedAt: standup,
            relatedGroupId: group
        )
        let current = meeting(
            title: "출시 준비",
            startedAt: today,
            relatedGroupId: group
        )
        #expect(RelatedMeetingGrouping.areRelated(current, previous))
    }

    @Test("제목만 같고 캘린더·그룹이 없으면 묶지 않는다")
    func ignoresTitleOnlyMatch() {
        let previous = meeting(title: "회의", startedAt: standup)
        let current = meeting(title: "회의", startedAt: today)
        #expect(!RelatedMeetingGrouping.areRelated(current, previous))
    }

    @Test("다른 시리즈·제목·그룹은 관련 없다")
    func rejectsUnrelatedMeetings() {
        let previous = meeting(
            title: "채용 회의",
            startedAt: standup,
            calendarEventId: "hire-1",
            calendarEventTitle: "채용 회의"
        )
        let current = meeting(
            title: "주간 스탠드업",
            startedAt: today,
            calendarEventId: "standup-1",
            calendarEventTitle: "주간 스탠드업"
        )
        #expect(!RelatedMeetingGrouping.areRelated(current, previous))
    }

    @Test("미완료 액션만 모으고 완료·취소는 빼며 상태는 바꾸지 않는다")
    func collectsUnfinishedOnlyWithoutCompleting() {
        let previous = meeting(
            title: "주간 스탠드업",
            startedAt: standup,
            calendarEventId: "evt-1",
            calendarEventTitle: "주간 스탠드업"
        )
        let current = meeting(
            title: "주간 스탠드업",
            startedAt: today,
            calendarEventId: "evt-2",
            calendarEventTitle: "주간 스탠드업"
        )
        let open = action("체크리스트 공유", status: .confirmed)
        let progressing = action("서버 증설", status: .inProgress)
        let done = action("공지 발송", status: .done)
        let dropped = action("임시 우회", status: .dropped)
        let snapshot = CarryoverMeetingSnapshot(
            meeting: previous,
            actionItems: [open, progressing, done, dropped]
        )

        let collected = CarryoverActionCollector.collect(current: current, previous: [snapshot])
        #expect(collected.map(\.action.task) == ["체크리스트 공유", "서버 증설"])
        #expect(collected.map(\.action.status) == [.confirmed, .inProgress])
        #expect(open.status == .confirmed)
        #expect(progressing.status == .inProgress)
        #expect(done.status == .done)
        #expect(dropped.status == .dropped)
    }

    @Test("로컬 publishRecord에 Jira 키가 있으면 화면에 붙일 값을 준다")
    func showsJiraKeyWhenPresent() {
        let previous = meeting(
            title: "주간 스탠드업",
            startedAt: standup,
            calendarEventId: "evt-1",
            calendarEventTitle: "주간 스탠드업"
        )
        let current = meeting(
            title: "주간 스탠드업",
            startedAt: today,
            calendarEventId: "evt-2",
            calendarEventTitle: "주간 스탠드업"
        )
        let withJira = action("배포 체크리스트", status: .proposed)
        let withoutJira = action("후속 점검", status: .confirmed)
        let snapshot = CarryoverMeetingSnapshot(
            meeting: previous,
            actionItems: [withJira, withoutJira],
            issues: [
                LocalIssueRef(contentId: ContentId.actionItem(0), key: "CRUX-21", url: "https://example.atlassian.net/browse/CRUX-21")
            ]
        )

        let collected = CarryoverActionCollector.collect(current: current, previous: [snapshot])
        #expect(collected.count == 2)
        #expect(collected[0].displayJiraKey == "CRUX-21")
        #expect(collected[0].jiraURL == "https://example.atlassian.net/browse/CRUX-21")
        #expect(collected[1].displayJiraKey == nil)
    }

    @Test("이후 회의나 관련 없는 회의의 액션은 가져오지 않는다")
    func skipsFutureAndUnrelated() {
        let current = meeting(
            title: "주간 스탠드업",
            startedAt: today,
            calendarEventId: "evt-today",
            calendarEventTitle: "주간 스탠드업"
        )
        let future = CarryoverMeetingSnapshot(
            meeting: meeting(
                title: "주간 스탠드업",
                startedAt: today.addingTimeInterval(86400),
                calendarEventId: "evt-next",
                calendarEventTitle: "주간 스탠드업"
            ),
            actionItems: [action("미래 작업", status: .confirmed)]
        )
        let other = CarryoverMeetingSnapshot(
            meeting: meeting(
                title: "채용 회의",
                startedAt: standup,
                calendarEventId: "evt-hire",
                calendarEventTitle: "채용 회의"
            ),
            actionItems: [action("면접 일정", status: .confirmed)]
        )

        #expect(CarryoverActionCollector.collect(current: current, previous: [future, other]).isEmpty)
    }
}
