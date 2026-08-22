import CoreGraphics
import Foundation

/// 노치와 캡슐을 한 덩어리로 붙이기 위한 화면 기하 정보.
///
/// Live Capsule은 메뉴바 아래에 떠 있는 창이 아니라 **화면 최상단에 붙어 노치와 이어지는 모양**이다.
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

    public var hasNotch: Bool { notchWidth > 0 && notchHeight > 0 }

    /// 캡슐의 접힌 높이. 노치가 있으면 노치와 같은 높이로 맞춰 한 덩어리로 보이게 한다.
    public var collapsedHeight: CGFloat {
        hasNotch ? max(notchHeight, 32) : 30
    }

    /// 창 원점(좌하단 기준). 화면 최상단에 붙이고 노치 중심에 맞춘다.
    public func windowOrigin(for size: CGSize) -> CGPoint {
        CGPoint(
            x: (notchCenterX - size.width / 2).rounded(),
            y: (screenFrame.maxY - size.height).rounded()
        )
    }

    /// 노치가 없는 화면(외장 모니터 등)에서는 상단 중앙에 같은 모양으로 붙인다.
    public static func withoutNotch(screenFrame: CGRect) -> NotchMetrics {
        NotchMetrics(screenFrame: screenFrame, notchHeight: 0, notchWidth: 0)
    }
}
