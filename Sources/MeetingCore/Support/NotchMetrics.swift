import CoreGraphics
import Foundation

/// 노치와 캡슐을 한 덩어리로 붙이기 위한 화면 기하 정보.
///
/// Crux은 메뉴바 아래에 떠 있는 창이 아니라 **화면 최상단에 붙어 노치와 이어지는 모양**이다.
/// 그래서 `visibleFrame`(메뉴바 아래)이 아니라 `frame`(화면 전체)을 기준으로 위치를 잡는다.
public struct NotchMetrics: Equatable, Sendable {
    /// 화면 전체 영역 (메뉴바 포함)
    public var screenFrame: CGRect
    /// 노치 높이. 노치가 없으면 0.
    public var notchHeight: CGFloat
    /// 노치 폭. 노치가 없으면 0.
    public var notchWidth: CGFloat
    /// 노치 가로 중심 (화면 좌표). 노치가 없으면 화면 가운데.
    public var notchCenterX: CGFloat

    public init(screenFrame: CGRect, notchHeight: CGFloat, notchWidth: CGFloat, notchCenterX: CGFloat? = nil) {
        self.screenFrame = screenFrame
        self.notchHeight = max(0, notchHeight)
        self.notchWidth = max(0, notchWidth)
        self.notchCenterX = notchCenterX ?? screenFrame.midX
    }

    public var hasNotch: Bool {
        notchWidth > 0 && notchHeight > 0
    }

    /// 캡슐의 접힌 높이. 노치가 있으면 노치와 같은 높이로 맞춰 한 덩어리로 보이게 한다.
    public var collapsedHeight: CGFloat {
        hasNotch ? max(notchHeight, 32) : 30
    }

    /// 접힌 섬의 한쪽 날개. 문구 길이와 무관한 고정값이다.
    public static let compactWing: CGFloat = 96
    /// 펼친 섬의 한쪽 날개. 좌우가 항상 같다.
    public static let expandedWing: CGFloat = 144

    /// 접힌 섬 너비. 하드웨어 노치를 덮는 한 덩어리이고, 내용이 바뀌어도 변하지 않는다.
    public var compactWidth: CGFloat {
        hasNotch ? notchWidth + 2 * Self.compactWing : 280
    }

    /// 펼친 섬 너비. 노치 중심 기준으로 좌우가 같이 늘어나는 한 가지 크기만 쓴다.
    public var expandedWidth: CGFloat {
        hasNotch ? max(notchWidth + 2 * Self.expandedWing, 420) : 400
    }

    public func islandWidth(expanded: Bool) -> CGFloat {
        expanded ? expandedWidth : compactWidth
    }

    /// 창 원점(좌하단 기준). 화면 최상단에 붙이고 노치 중심에 맞춘다.
    ///
    /// `y`는 반올림하지 않는다. 반올림하면 접힐 때 화면 상단과 1px 틈이 생긴다.
    public func windowOrigin(for size: CGSize) -> CGPoint {
        windowFrame(for: size).origin
    }

    /// 상단을 고정한 채로 크기를 바꿀 때 쓰는 프레임.
    /// 접힘·펼침 애니메이션에서 검은 캡슐이 노치에서 떨어지지 않게 한다.
    public func windowFrame(for size: CGSize, keepingTopOf current: CGRect? = nil) -> CGRect {
        let top = current?.maxY ?? screenFrame.maxY
        return CGRect(
            x: (notchCenterX - size.width / 2).rounded(),
            y: top - size.height,
            width: size.width,
            height: size.height
        )
    }

    /// 노치가 없는 화면(외장 모니터 등)에서는 상단 중앙에 같은 모양으로 붙인다.
    public static func withoutNotch(screenFrame: CGRect) -> NotchMetrics {
        NotchMetrics(screenFrame: screenFrame, notchHeight: 0, notchWidth: 0)
    }
}
