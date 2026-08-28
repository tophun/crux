import Foundation

/// 회의 저장 폴더의 `memos.json`(경과 시각 슬롯)과 `crux-note.json`(제목+본문)을 보관한다.
///
/// 호출자가 값을 들고 있으므로 저장은 파일을 덮어쓴다. 매번 파일을 다시 읽지 않는다.
/// 예전 `memos.json`은 지우지 않는다. 상세 화면과 노트 초깃값에서 그대로 읽는다.
public struct MeetingMemoStore: Sendable {
    private let fileURL: URL
    private let noteURL: URL

    public init(storageDirectory: URL) {
        fileURL = storageDirectory.appendingPathComponent("memos.json")
        noteURL = storageDirectory.appendingPathComponent("crux-note.json")
    }

    public func load() -> [MeetingMemo] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([MeetingMemo].self, from: data)) ?? []
    }

    public func save(_ memos: [MeetingMemo]) throws {
        try writeJSON(memos, to: fileURL)
    }

    public func loadNote() -> CruxNote? {
        guard let data = try? Data(contentsOf: noteURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CruxNote.self, from: data)
    }

    public func saveNote(_ note: CruxNote) throws {
        try writeJSON(note, to: noteURL)
    }

    private func writeJSON(_ value: some Encodable, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}
