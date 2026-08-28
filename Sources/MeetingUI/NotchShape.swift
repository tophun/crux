import SwiftUI

/// 화면 상단에서 노치처럼 흘러내리는 모양.
///
/// 위쪽 양 끝은 화면 상단 가장자리에서 안쪽으로 오목하게 이어지고(`topRadius`),
/// 아래쪽은 볼록한 연속 곡선으로 마무리한다(`bottomRadius`). 오목한 위 모서리 덕분에
/// 캡슐이 따로 떠 있는 사각형이 아니라 노치와 한 덩어리로 보인다.
/// 반지름은 `animatableData`로 보간해 커질 때 모양이 같이 움직인다.
public struct NotchShape: Shape {
    public var topRadius: CGFloat
    public var bottomRadius: CGFloat

    public init(topRadius: CGFloat = 0, bottomRadius: CGFloat = 16) {
        self.topRadius = topRadius
        self.bottomRadius = bottomRadius
    }

    public var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set {
            topRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    public func path(in rect: CGRect) -> Path {
        let flare = max(0, min(topRadius, rect.width / 2, rect.height))
        let body = rect.insetBy(dx: flare, dy: 0)
        let bottom = max(0, min(bottomRadius, body.width / 2, rect.height - flare))

        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        // 왼쪽 위: 화면 가장자리에서 몸통으로 오목하게 흘러내린다.
        path.addQuadCurve(
            to: CGPoint(x: body.minX, y: rect.minY + flare),
            control: CGPoint(x: body.minX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: body.minX, y: body.maxY - bottom))
        path.addArc(
            center: CGPoint(x: body.minX + bottom, y: body.maxY - bottom),
            radius: bottom, startAngle: .degrees(180), endAngle: .degrees(90), clockwise: true
        )
        path.addLine(to: CGPoint(x: body.maxX - bottom, y: body.maxY))
        path.addArc(
            center: CGPoint(x: body.maxX - bottom, y: body.maxY - bottom),
            radius: bottom, startAngle: .degrees(90), endAngle: .degrees(0), clockwise: true
        )
        path.addLine(to: CGPoint(x: body.maxX, y: rect.minY + flare))
        // 오른쪽 위: 몸통에서 화면 가장자리로 오목하게 이어진다.
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: body.maxX, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }
}
