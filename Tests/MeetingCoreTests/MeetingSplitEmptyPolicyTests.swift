@testable import MeetingCore
import Testing

@Suite("회의 목록·상세 Empty")
struct MeetingSplitEmptyPolicyTests {
    @Test("회의가 없으면 목록 Empty만 켠다")
    func listEmptyWhenNoMeetings() {
        #expect(MeetingSplitEmptyPolicy.showsListPlaceholder(meetingCount: 0))
        #expect(!MeetingSplitEmptyPolicy.showsDetailPlaceholder(hasDetail: false))
    }

    @Test("회의가 있어도 상세에는 선택 유도 Empty를 두지 않는다")
    func neverShowsDetailPlaceholder() {
        #expect(!MeetingSplitEmptyPolicy.showsDetailPlaceholder(hasDetail: false))
        #expect(!MeetingSplitEmptyPolicy.showsDetailPlaceholder(hasDetail: true))
    }

    @Test("회의가 하나 이상이면 목록 Empty는 끈다")
    func hidesListEmptyWhenMeetingsExist() {
        #expect(!MeetingSplitEmptyPolicy.showsListPlaceholder(meetingCount: 1))
        #expect(!MeetingSplitEmptyPolicy.showsListPlaceholder(meetingCount: 4))
    }
}
