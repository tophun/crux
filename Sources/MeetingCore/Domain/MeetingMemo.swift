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

    /// 예전 시각 슬롯 메모를 노트 본문 초깃값으로 보여 주기 위한 읽기 전용 텍스트.
    /// `memos.json`은 바꾸지 않는다.
    public static func readableTranscript(_ memos: [MeetingMemo]) -> String {
        memos.map { "\($0.elapsedLabel)  \($0.text)" }.joined(separator: "\n")
    }
}
