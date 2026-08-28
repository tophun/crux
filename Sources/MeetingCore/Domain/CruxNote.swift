import Foundation

/// 녹음 중 플로팅 노트의 제목+본문. 경과 시각 슬롯과 별도로 `crux-note.json`에 둔다.
public struct CruxNote: Hashable, Sendable, Codable {
    public var title: String
    public var body: String
    public var updatedAt: Date

    public init(title: String, body: String, updatedAt: Date = Date()) {
        self.title = title
        self.body = body
        self.updatedAt = updatedAt
    }

    /// 저장된 본문이 있으면 그대로 쓰고, 없으면 예전 경과 시각 메모를 읽기 쉬운 줄로 이어 붙인다.
    public static func seedBody(note: CruxNote?, memos: [MeetingMemo]) -> String {
        if let body = note?.body, !body.isEmpty {
            return body
        }
        return MeetingMemo.readableTranscript(memos)
    }
}
