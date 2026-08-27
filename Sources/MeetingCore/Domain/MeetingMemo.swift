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

    public var elapsedLabel: String {
        let total = Int(elapsed.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// 회의 저장 폴더의 `memos.json`에 메모를 보관한다. 스키마 마이그레이션 없이 파일 하나로 끝낸다.
public struct MeetingMemoStore: Sendable {
    public let fileURL: URL

    public init(storageDirectory: URL) {
        fileURL = storageDirectory.appendingPathComponent("memos.json")
    }

    public func load() -> [MeetingMemo] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([MeetingMemo].self, from: data)) ?? []
    }

    public func append(_ memo: MeetingMemo) throws -> [MeetingMemo] {
        var memos = load()
        memos.append(memo)
        try save(memos)
        return memos
    }

    public func save(_ memos: [MeetingMemo]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(memos).write(to: fileURL, options: .atomic)
    }
}
