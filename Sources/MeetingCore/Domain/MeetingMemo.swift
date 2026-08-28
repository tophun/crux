import Foundation

/// 녹음 중 사용자가 노치에서 남긴 짧은 메모. 녹음 경과 시각과 함께 저장한다.
public struct MeetingMemo: Identifiable, Hashable, Sendable, Codable {
    public var id: UUID
    public var createdAt: Date
    /// 녹음 시작 기준 경과 초. 전사문·근거 시각과 맞춰 볼 수 있다.
    public var elapsed: TimeInterval
    public var text: String

    public init(id: UUID = UUID(), createdAt: Date = Date(), elapsed: TimeInterval, text: String) {
        self.id = id
        self.createdAt = createdAt
        self.elapsed = elapsed
        self.text = text
    }

    /// 캡슐과 같은 m:ss / h:mm:ss 표기.
    public var elapsedLabel: String {
        CruxState.clock(elapsed)
    }
}
