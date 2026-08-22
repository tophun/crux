import Foundation
import MeetingAudio
import MeetingCore

/// 근거 파일(`{meetingId}.evidence.json`) 입출력.
///
/// 근거는 이 로컬 파일에만 둔다. Confluence·Jira로는 나가지 않는다(요구사항 7).
public struct EvidenceFileStore: Sendable {
    private let baseDirectory: URL?
    nonisolated(unsafe) private let fileManager: FileManager

    public init(baseDirectory: URL? = nil, fileManager: FileManager = .default) {
        self.baseDirectory = baseDirectory
        self.fileManager = fileManager
    }

    public func url(for meeting: Meeting) -> URL {
        let directory = baseDirectory ?? meeting.storageDirectory
        return directory.appendingPathComponent(EvidenceBundle.fileName(meetingId: meeting.id))
    }

    @discardableResult
    public func write(_ bundle: EvidenceBundle, for meeting: Meeting) throws -> URL {
        let destination = url(for: meeting)
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try bundle.encoded().write(to: destination, options: .atomic)
        return destination
    }

    public func read(for meeting: Meeting) throws -> EvidenceBundle? {
        let source = url(for: meeting)
        guard fileManager.fileExists(atPath: source.path) else { return nil }
        return try EvidenceBundle.decoded(from: try Data(contentsOf: source))
    }
}
