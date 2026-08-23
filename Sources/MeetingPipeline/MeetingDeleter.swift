import Foundation
import MeetingAudio
import MeetingCore
import MeetingPersistence

/// 회의 삭제. 오디오·전사문·회의록·근거 파일을 함께 지운다.
///
/// 안전 규칙
/// - 파일은 **휴지통으로 보낸다**. 실수로 지워도 되돌릴 수 있게 한다.
/// - 회의 저장 디렉터리 **안에 있는 파일만** 지운다. 사용자가 가져온 원본 파일(복사하지 않고 참조만 한 경우)은 건드리지 않는다.
/// - 회의와 연결된 SwiftData 모델 행은 저장소가 함께 지운다.
public struct MeetingDeleter: Sendable {
    public struct Summary: Hashable, Sendable {
        public var meetingTitle: String
        /// 휴지통으로 보낸 파일·디렉터리 수
        public var trashedItemCount: Int
        /// 회의 디렉터리 밖에 있어 남겨 둔 파일 (사용자가 가져온 원본 등)
        public var keptExternalFiles: [URL]
        public var freedBytes: Int64
    }

    private let repository: MeetingRepository
    private let evidenceStore: EvidenceFileStore
    private nonisolated(unsafe) let fileManager: FileManager

    public init(
        repository: MeetingRepository,
        evidenceStore: EvidenceFileStore = EvidenceFileStore(),
        fileManager: FileManager = .default
    ) {
        self.repository = repository
        self.evidenceStore = evidenceStore
        self.fileManager = fileManager
    }

    /// - Parameter removeFiles: false면 데이터베이스 기록만 지우고 파일은 남긴다.
    @discardableResult
    public func delete(meetingId: UUID, removeFiles: Bool = true) throws -> Summary {
        guard let meeting = try repository.meeting(id: meetingId) else {
            throw PipelineError.meetingNotFound(meetingId)
        }

        var trashed = 0
        var kept: [URL] = []
        var freed: Int64 = 0

        if removeFiles {
            let storageRoot = meeting.storageDirectory.standardizedFileURL

            // 1. 회의 디렉터리 밖을 가리키는 트랙은 남긴다 (가져오기에서 복사하지 않은 원본).
            for track in try repository.tracks(meetingId: meetingId) {
                let url = track.fileURL.standardizedFileURL
                if !Self.isInside(url, root: storageRoot), fileManager.fileExists(atPath: url.path) {
                    kept.append(url)
                }
            }

            // 2. 근거 파일
            let evidenceURL = evidenceStore.url(for: meeting)
            if fileManager.fileExists(atPath: evidenceURL.path) {
                freed += Self.size(of: evidenceURL, fileManager: fileManager)
                if trash(evidenceURL) {
                    trashed += 1
                }
            }

            // 3. 회의 디렉터리 전체 (raw/, mixed/, exports/)
            if fileManager.fileExists(atPath: storageRoot.path) {
                freed += Self.size(of: storageRoot, fileManager: fileManager)
                if trash(storageRoot) {
                    trashed += 1
                }
            }
        }

        // 4. 데이터베이스 (transcript·note·decision·actionItem·job 등 연결 모델 포함)
        try repository.delete(meetingId: meetingId)

        return Summary(
            meetingTitle: meeting.title,
            trashedItemCount: trashed,
            keptExternalFiles: kept,
            freedBytes: freed
        )
    }

    /// 휴지통으로 보낸다. 실패하면 바로 삭제한다.
    private func trash(_ url: URL) -> Bool {
        do {
            try fileManager.trashItem(at: url, resultingItemURL: nil)
            return true
        } catch {
            return (try? fileManager.removeItem(at: url)) != nil
        }
    }

    /// 경로가 회의 디렉터리 안에 있는지. 밖이면 사용자 파일이므로 건드리지 않는다.
    static func isInside(_ url: URL, root: URL) -> Bool {
        let target = url.standardizedFileURL.path
        var rootPath = root.standardizedFileURL.path
        if !rootPath.hasSuffix("/") {
            rootPath += "/"
        }
        return target.hasPrefix(rootPath)
    }

    static func size(of url: URL, fileManager: FileManager) -> Int64 {
        var total: Int64 = 0
        if let values = try? url.resourceValues(forKeys: [.isDirectoryKey]), values.isDirectory == true {
            let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
            while let child = enumerator?.nextObject() as? URL {
                total += Int64((try? child.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        } else {
            total = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}
