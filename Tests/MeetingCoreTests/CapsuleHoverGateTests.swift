import Foundation
@testable import MeetingCore
import Testing

@Suite("캡슐 호버 접기")
struct CapsuleHoverGateTests {
    @Test("포인터가 창 안에 있으면 hover-off를 바로 적용하지 않는다")
    func defersWhenMouseStillInside() {
        let now = Date(timeIntervalSince1970: 1000)
        #expect(
            CapsuleHoverGate.shouldDeferHoverOff(
                now: now,
                ignoreLeaveUntil: nil,
                mouseInWindow: true
            )
        )
    }

    @Test("레이아웃이 바뀐 직후의 hover-off는 창 밖이어도 무시한다")
    func defersDuringIgnoreWindow() {
        let now = Date(timeIntervalSince1970: 1000)
        let until = now.addingTimeInterval(0.25)
        #expect(
            CapsuleHoverGate.shouldDeferHoverOff(
                now: now.addingTimeInterval(0.1),
                ignoreLeaveUntil: until,
                mouseInWindow: false
            )
        )
    }

    @Test("무시 구간이 끝나고 포인터가 창 밖이면 접을 수 있다")
    func acceptsLeaveAfterIgnore() {
        let now = Date(timeIntervalSince1970: 1000)
        let until = now.addingTimeInterval(0.25)
        #expect(
            !CapsuleHoverGate.shouldDeferHoverOff(
                now: until.addingTimeInterval(0.01),
                ignoreLeaveUntil: until,
                mouseInWindow: false
            )
        )
    }

    @Test("접기 확인은 무시 구간이 끝날 때까지 미룬다")
    func collapseCheckWaitsForIgnoreWindow() {
        let now = Date(timeIntervalSince1970: 1000)
        let until = now.addingTimeInterval(2)
        #expect(
            CapsuleHoverGate.collapseCheckDelay(now: now, ignoreLeaveUntil: until) == 2
        )
        #expect(
            CapsuleHoverGate.collapseCheckDelay(now: now, ignoreLeaveUntil: nil)
                == CapsuleHoverGate.collapseDelay
        )
    }

    @Test("예약된 접기는 포인터가 창 안에 있으면 실행하지 않는다")
    func delayedCollapseRequiresMouseLeft() {
        #expect(!CapsuleHoverGate.shouldCollapse(mouseInWindow: true))
        #expect(CapsuleHoverGate.shouldCollapse(mouseInWindow: false))
    }

    @Test("확장 직후 무시 마감 시각을 잡는다")
    func ignoreDeadlineAfterLayoutChange() {
        let now = Date(timeIntervalSince1970: 1000)
        #expect(
            CapsuleHoverGate.ignoreDeadline(after: now)
                == now.addingTimeInterval(CapsuleHoverGate.ignoreLeaveAfterLayoutChange)
        )
    }

    @Test("창 안에 있는 hover-off는 접지 않고 다시 확인한다")
    func reschedulesWhenStillInside() {
        let now = Date(timeIntervalSince1970: 1000)
        #expect(
            CapsuleHoverGate.collapseCheckResult(
                now: now,
                ignoreLeaveUntil: nil,
                mouseInWindow: true
            ) == .reschedule
        )
    }

    @Test("창 밖이고 무시 구간이 끝나면 접는다")
    func collapsesWhenMouseLeft() {
        let now = Date(timeIntervalSince1970: 1000)
        #expect(
            CapsuleHoverGate.collapseCheckResult(
                now: now,
                ignoreLeaveUntil: nil,
                mouseInWindow: false
            ) == .collapse
        )
    }
}
