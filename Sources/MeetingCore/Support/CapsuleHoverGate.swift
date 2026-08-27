import Foundation

/// 노치 캡슐 호버로 창이 커질 때 SwiftUI `onHover`가 leave/enter를 반복하는 것을 막는다.
///
/// 창을 다시 그리거나 크기를 바꾸면 히트 영역이 잠깐 어긋나 hover-off가 온다.
/// 그 신호를 바로 접기에 쓰지 않고, 포인터가 창 밖에 있을 때만 접는다.
public enum CapsuleHoverGate {
    /// 첫 렌더처럼 이전 상태가 없을 때는 개발용 초기 미리보기 모드를 유지한다.
    /// 이전 상태가 있고 단계가 바뀐 경우에만 펼친 셸프를 접는다.
    public static func shouldResetExpansionMode(previousKindId: String?, nextKindId: String) -> Bool {
        guard let previousKindId else { return false }
        return previousKindId != nextKindId
    }

    /// 실제 이탈로 보고 접기 전에 기다리는 시간.
    public static let collapseDelay: TimeInterval = 0.28
    /// 레이아웃이 바뀐 직후 hover-off를 무시하는 시간.
    ///
    /// 창이 커지는 애니메이션보다 짧으면, 확장 중에 온 leave로 바로 접혀 깜빡인다.
    public static let ignoreLeaveAfterLayoutChange: TimeInterval = 0.45

    /// hover-off를 즉시 접기로 쓰면 안 되는 경우.
    public static func shouldDeferHoverOff(
        now: Date,
        ignoreLeaveUntil: Date?,
        mouseInWindow: Bool
    ) -> Bool {
        if mouseInWindow {
            return true
        }
        if let ignoreLeaveUntil, now < ignoreLeaveUntil {
            return true
        }
        return false
    }

    /// 접기 확인을 실행할 때까지의 대기. 무시 구간이 더 길면 그 끝까지 기다린다.
    public static func collapseCheckDelay(now: Date, ignoreLeaveUntil: Date?) -> TimeInterval {
        let remainingIgnore = ignoreLeaveUntil.map { max(0, $0.timeIntervalSince(now)) } ?? 0
        return max(collapseDelay, remainingIgnore)
    }

    /// 예약된 접기를 실행할지. 포인터가 창 안에 있으면 접지 않는다.
    public static func shouldCollapse(mouseInWindow: Bool) -> Bool {
        !mouseInWindow
    }

    /// 호버 이벤트를 셸프의 단일 표시 상태로 변환한다.
    public static func mode(afterHover hovering: Bool, current: CruxExpansionMode) -> CruxExpansionMode {
        current.handlingHover(hovering)
    }

    /// 캡슐 본체를 클릭했을 때 고정을 토글한다.
    public static func mode(afterPinToggle current: CruxExpansionMode) -> CruxExpansionMode {
        current.togglingPin()
    }

    /// 외부 클릭이나 상태 종료처럼 명시적으로 닫아야 할 때 쓴다.
    public static func mode(afterExternalClick current: CruxExpansionMode) -> CruxExpansionMode {
        guard current != .collapsed else { return .collapsed }
        return .collapsed
    }

    /// hover-off 확인 결과. 창 안에 있으면 접지 않고 다시 본다.
    ///
    /// SwiftUI는 뷰를 다시 그리면서 leave를 한 번만 보낼 수 있다.
    /// 그때 접기를 건너뛰고 끝내면, 포인터가 나가도 캡슐이 열린 채로 남는다.
    public static func collapseCheckResult(
        now: Date,
        ignoreLeaveUntil: Date?,
        mouseInWindow: Bool
    ) -> CapsuleHoverCollapseCheck {
        if shouldDeferHoverOff(now: now, ignoreLeaveUntil: ignoreLeaveUntil, mouseInWindow: mouseInWindow) {
            return .reschedule
        }
        return .collapse
    }

    public static func ignoreDeadline(after now: Date) -> Date {
        now.addingTimeInterval(ignoreLeaveAfterLayoutChange)
    }
}

public enum CapsuleHoverCollapseCheck: Equatable, Sendable {
    case collapse
    case reschedule
}
