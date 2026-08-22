import SwiftUI

/// 위쪽은 각지고 아래쪽만 둥근 모양. 화면 상단에 붙었을 때 노치에서 자라난 것처럼 보인다.
public struct NotchShape: Shape {
    public var topRadius: CGFloat
    public var bottomRadius: CGFloat

    public init(topRadius: CGFloat = 0, bottomRadius: CGFloat = 18) {
        self.topRadius = topRadius
        self.bottomRadius = bottomRadius
    }

    public func path(in rect: CGRect) -> Path {
        let top = min(topRadius, rect.height / 2)
        let bottom = min(bottomRadius, rect.height / 2, rect.width / 2)

        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + top))
        if top > 0 {
            path.addQuadCurve(
                to: CGPoint(x: rect.minX + top, y: rect.minY),
                control: CGPoint(x: rect.minX, y: rect.minY)
            )
        }
        path.addLine(to: CGPoint(x: rect.maxX - top, y: rect.minY))
        if top > 0 {
            path.addQuadCurve(
                to: CGPoint(x: rect.maxX, y: rect.minY + top),
                control: CGPoint(x: rect.maxX, y: rect.minY)
            )
        }
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - bottom))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - bottom, y: rect.maxY),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX + bottom, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY - bottom),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        path.closeSubpath()
        return path
    }
}
