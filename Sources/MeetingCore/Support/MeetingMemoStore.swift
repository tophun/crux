import Foundation

/// 회의 저장 폴더의 `memos.json`에 메모를 보관한다. 스키마 마이그레이션 없이 파일 하나로 끝낸다.
///
/// 호출자가 메모 배열을 들고 있으므로 저장은 전체 배열을 덮어쓴다. 매번 파일을 다시 읽지 않는다.
public struct MeetingMemoStore: Sendable {
    private let fileURL: URL

    public init(storageDirectory: URL) {
        fileURL = storageDirectory.appendingPathComponent("memos.json")
    }

    public func load() -> [MeetingMemo] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([MeetingMemo].self, from: data)) ?? []
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
