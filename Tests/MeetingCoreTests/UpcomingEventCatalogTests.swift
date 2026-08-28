import Foundation
@testable import MeetingCore
import Testing

@Suite("다가오는 일정 필터")
struct UpcomingEventCatalogFilterTests {
    let now = Date(timeIntervalSince1970: 1_772_000_000)
    let catalog = UpcomingEventCatalog()

    private func makeEvent(
        id: String,
        startOffset: TimeInterval,
        duration: TimeInterval = 3600,
        isAllDay: Bool = false,
        status: CalendarEventStatus = .confirmed,
        attendees: [EventAttendee]? = nil
    ) -> CalendarEvent {
        let start = now.addingTimeInterval(startOffset)
        return CalendarEvent(
            id: id,
            title: "일정 \(id)",
            startDate: start,
            endDate: start.addingTimeInterval(duration),
            isAllDay: isAllDay,
            status: status,
            attendees: attendees ?? [
                EventAttendee(name: "김민수", email: "a@example.com", isOrganizer: true, responseStatus: .accepted),
                EventAttendee(name: "나", email: "me@example.com", isCurrentUser: true, responseStatus: .accepted)
            ],
            conferenceURL: URL(string: "https://meet.google.com/abc-defg-hij"),
            calendarTitle: "업무"
        )
    }

    @Test("종일·취소·내가 거절한 일정은 기본 숨긴다")
    func hidesAllDayCanceledDeclined() {
        let visible = makeEvent(id: "ok", startOffset: 600)
        let allDay = makeEvent(id: "allday", startOffset: 600, isAllDay: true)
        let canceled = makeEvent(id: "canceled", startOffset: 600, status: .canceled)
        let declined = makeEvent(
            id: "declined",
            startOffset: 600,
            attendees: [
                EventAttendee(name: "김민수", isOrganizer: true, responseStatus: .accepted),
                EventAttendee(name: "나", isCurrentUser: true, responseStatus: .declined)
            ]
        )
        let ids = catalog.visibleEvents([visible, allDay, canceled, declined], now: now).map(\.id)
        #expect(ids == ["ok"])
    }

    @Test("다른 사람이 거절한 일정은 남긴다")
    func keepsEventDeclinedBySomeoneElse() {
        let otherDeclined = makeEvent(
            id: "other-declined",
            startOffset: 600,
            attendees: [
                EventAttendee(name: "상대", responseStatus: .declined),
                EventAttendee(name: "나", isCurrentUser: true, responseStatus: .accepted)
            ]
        )
        #expect(catalog.visibleEvents([otherDeclined], now: now).map(\.id) == ["other-declined"])
    }

    @Test("이미 끝난 일정은 빼고 진행 중인 일정은 남긴다")
    func hidesEndedKeepsInProgress() {
        let ended = makeEvent(id: "ended", startOffset: -7200, duration: 1800)
        let inProgress = makeEvent(id: "live", startOffset: -600, duration: 3600)
        let upcoming = makeEvent(id: "soon", startOffset: 1800)
        let ids = catalog.visibleEvents([ended, inProgress, upcoming], now: now).map(\.id)
        #expect(ids == ["live", "soon"])
    }

    @Test("조회 범위 밖의 먼 일정은 빼되 경계는 남긴다")
    func hidesBeyondHorizon() {
        let justInside = makeEvent(id: "inside", startOffset: UpcomingEventCatalog.defaultHorizon)
        let justOutside = makeEvent(id: "outside", startOffset: UpcomingEventCatalog.defaultHorizon + 60)
        let ids = catalog.visibleEvents([justInside, justOutside], now: now).map(\.id)
        #expect(ids == ["inside"])
    }

    @Test("목록은 참석자 수와 관계없이 보여 준다")
    func showsSoloEvents() {
        let solo = makeEvent(
            id: "solo",
            startOffset: 600,
            attendees: [EventAttendee(name: "나", isCurrentUser: true, responseStatus: .accepted)]
        )
        #expect(catalog.visibleEvents([solo], now: now).map(\.id) == ["solo"])
    }
}

@Suite("다가오는 일정 목록 매핑")
struct UpcomingEventCatalogMappingTests {
    let now = Date(timeIntervalSince1970: 1_772_000_000)
    let catalog = UpcomingEventCatalog()

    @Test("행은 제목·시작/끝·캘린더·회의 링크를 옮긴다")
    func mapsListFields() {
        let start = now.addingTimeInterval(1800)
        let end = start.addingTimeInterval(2700)
        let link = URL(string: "https://zoom.us/j/123")
        let event = CalendarEvent(
            id: "evt-map",
            title: "주간 유저성장 회의",
            startDate: start,
            endDate: end,
            attendees: [
                EventAttendee(name: "김민수", isOrganizer: true),
                EventAttendee(name: "나", isCurrentUser: true)
            ],
            conferenceURL: link,
            calendarTitle: "제품"
        )

        let rows = catalog.rows(from: [event], now: now)
        #expect(rows.count == 1)
        let row = rows[0]
        #expect(row.id == "evt-map")
        #expect(row.title == "주간 유저성장 회의")
        #expect(row.startDate == start)
        #expect(row.endDate == end)
        #expect(row.calendarTitle == "제품")
        #expect(row.conferenceURL == link)
    }

    @Test("숨긴 일정은 행으로 만들지 않고 시작 시각 순으로 정렬한다")
    func mapsOnlyVisibleSorted() {
        let later = CalendarEvent(
            id: "later",
            title: "나중",
            startDate: now.addingTimeInterval(3600),
            endDate: now.addingTimeInterval(5400),
            attendees: [EventAttendee(name: "가"), EventAttendee(name: "나")],
            calendarTitle: "업무"
        )
        let sooner = CalendarEvent(
            id: "sooner",
            title: "먼저",
            startDate: now.addingTimeInterval(600),
            endDate: now.addingTimeInterval(1800),
            attendees: [EventAttendee(name: "가"), EventAttendee(name: "나")],
            calendarTitle: "업무"
        )
        let hidden = CalendarEvent(
            id: "hidden",
            title: "취소",
            startDate: now.addingTimeInterval(1200),
            endDate: now.addingTimeInterval(2400),
            status: .canceled,
            attendees: [EventAttendee(name: "가"), EventAttendee(name: "나")]
        )
        let rows = catalog.rows(from: [later, hidden, sooner], now: now)
        #expect(rows.map(\.id) == ["sooner", "later"])
        #expect(rows.map(\.title) == ["먼저", "나중"])
    }

    @Test("회의 링크가 없으면 행의 링크도 비운다")
    func mapsMissingConferenceLink() {
        let event = CalendarEvent(
            id: "no-link",
            title: "오프라인 회의",
            startDate: now.addingTimeInterval(600),
            endDate: now.addingTimeInterval(1800),
            attendees: [EventAttendee(name: "가")],
            calendarTitle: "개인"
        )
        let rows = catalog.rows(from: [event], now: now)
        #expect(rows.first?.conferenceURL == nil)
        #expect(rows.first?.calendarTitle == "개인")
    }

    @Test("예전 참석자 JSON에 응답 상태가 없어도 읽는다")
    func decodesAttendeeWithoutResponseStatus() throws {
        let json = Data(#"{"email":"a@example.com","isCurrentUser":false,"isOrganizer":true,"name":"김민수"}"#.utf8)
        let attendee = try JSONDecoder().decode(EventAttendee.self, from: json)
        #expect(attendee.name == "김민수")
        #expect(attendee.responseStatus == nil)
        #expect(!attendee.isDeclined)
    }
}
