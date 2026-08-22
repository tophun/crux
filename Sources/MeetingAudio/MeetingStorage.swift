import Foundation
import MeetingCore

/// 회의별 로컬 파일 배치(§5).
///
///     meeting/
///       raw/
///         microphone.m4a
///         system.m4a
///       mixed/
///         meeting.m4a
///       exports/
///
/// 원본 오디오는 데이터베이스에 넣지 않고 이 디렉터리에만 둔다.
public struct MeetingStorage: Sendable {
    public let root: URL
    /// FileManager는 Sendable이 아니지만 파일 조작에 스레드 안전하게 쓰인다.
    private nonisolated(unsafe) let fileManager: FileManager

    public init(root: URL, fileManager: FileManager = .default) {
        self.root = root
        self.fileManager = fileManager
    }

    public static func forMeeting(id: UUID, base: URL? = nil, fileManager: FileManager = .default) -> MeetingStorage {
        let baseURL = base ?? AppIdentity.dataDirectory(fileManager: fileManager)
            .appendingPathComponent("meetings", isDirectory: true)
        return MeetingStorage(
            root: baseURL.appendingPathComponent(id.uuidString, isDirectory: true),
            fileManager: fileManager
        )
    }

    public var rawDirectory: URL {
        root.appendingPathComponent("raw", isDirectory: true)
    }

    public var mixedDirectory: URL {
        root.appendingPathComponent("mixed", isDirectory: true)
    }

    public var exportsDirectory: URL {
        root.appendingPathComponent("exports", isDirectory: true)
    }

    public func url(for kind: AudioTrackKind, extension pathExtension: String) -> URL {
        switch kind {
        case .microphone: rawDirectory.appendingPathComponent("microphone").appendingPathExtension(pathExtension)
        case .system: rawDirectory.appendingPathComponent("system").appendingPathExtension(pathExtension)
        case .mixed: mixedDirectory.appendingPathComponent("meeting").appendingPathExtension(pathExtension)
        }
    }

    public func createDirectories() throws {
        for directory in [rawDirectory, mixedDirectory, exportsDirectory] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    /// 원본 오디오만 삭제한다. 회의록과 전사문은 남는다(§11).
    @discardableResult
    public func deleteAudio() throws -> Int {
        var removed = 0
        for directory in [rawDirectory, mixedDirectory] {
            guard let contents = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
                continue
            }
            for url in contents {
                try fileManager.removeItem(at: url)
                removed += 1
            }
        }
        return removed
    }
}
