import AppKit
import MeetingCore

extension NotchMetrics {
    /// 화면에서 노치 정보를 읽는다. macOS 12+의 `safeAreaInsets`와 `auxiliaryTopLeftArea`를 쓴다.
    public static func from(screen: NSScreen) -> NotchMetrics {
        let frame = screen.frame
        let topInset = screen.safeAreaInsets.top

        guard topInset > 0,
              let leftArea = screen.auxiliaryTopLeftArea,
              let rightArea = screen.auxiliaryTopRightArea
        else {
            return NotchMetrics(screenFrame: frame, notchHeight: topInset, notchWidth: 0)
        }

        let width = max(0, rightArea.minX - leftArea.maxX)
        let centerX = leftArea.maxX + width / 2
        return NotchMetrics(
            screenFrame: frame,
            notchHeight: topInset,
            notchWidth: width,
            notchCenterX: centerX
        )
    }
}
