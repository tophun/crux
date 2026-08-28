import Foundation
import MeetingCore

/// 녹음 중 자막·초안 요약을 회의 폴더에 남겨, 종료 후 전체 파이프라인과 합친다.
///
/// 공식 전사문은 아니다. 파이프라인이 성공하면 이 파일은 지운다.
public enum LiveCaptionDraftStore {
    public static let fileName = "live-captions.json"

    public static func fileURL(in storageDirectory: URL) -> URL {
        storageDirectory.appendingPathComponent(fileName)
    }

    public static func write(_ state: LiveCaptionState, to storageDirectory: URL) throws {
        try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: fileURL(in: storageDirectory), options: .atomic)
    }

    public static func load(from storageDirectory: URL) -> LiveCaptionState? {
        guard let data = try? Data(contentsOf: fileURL(in: storageDirectory)) else { return nil }
        return try? JSONDecoder().decode(LiveCaptionState.self, from: data)
    }

    /// 전체 파이프라인이 공식 전사·회의록을 만든 뒤 초안을 걷는다.
    public static func remove(from storageDirectory: URL) {
        try? FileManager.default.removeItem(at: fileURL(in: storageDirectory))
    }
}
