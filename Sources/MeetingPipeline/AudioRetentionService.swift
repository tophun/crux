import Foundation
import MeetingCore
import MeetingPersistence

/// 오디오 보관 정책을 실제 파일에 적용한다(§11).
///
/// 안전 규칙 — `MeetingDeleter`와 같다.
/// - 파일은 **휴지통으로 보낸다**.
/// - 회의 저장 디렉터리 **안에 있는 파일만** 지운다. 사용자가 가져온 원본은 건드리지 않는다.
/// - 전사문·회의록·근거 파일은 어떤 경우에도 지우지 않는다.
public struct AudioRetentionService: Sendable {
    public struct Outcome: Hashable, Sendable {
        /// 휴지통으로 보낸 파일 수
        public var trashedFileCount: Int
        /// 회수한 용량
        public var freedBytes: Int64
        /// 정리한 회의 수
        public var meetingCount: Int
        /// 회의 디렉터리 밖이라 남겨 둔 파일 (가져온 원본 등)
        public var keptExternalFiles: [URL]

        public static let none = Outcome(trashedFileCount: 0, freedBytes: 0, meetingCount: 0, keptExternalFiles: [])

        public var isEmpty: Bool {
            trashedFileCount == 0 && keptExternalFiles.isEmpty
        }
    }

    private let repository: MeetingRepository
    private nonisolated(unsafe) let fileManager: FileManager
    private let logSink: (@Sendable (String) -> Void)?

    public init(
        repository: MeetingRepository,
        fileManager: FileManager = .default,
        logSink: (@Sendable (String) -> Void)? = nil
    ) {
        self.repository = repository
        self.fileManager = fileManager
        self.logSink = logSink
    }

    /// 회의록 생성에 성공한 직후 부른다. 실패한 회의에는 절대 부르지 않는다.
    @discardableResult
    public func applyAfterProcessing(meetingId: UUID, policy: AudioRetentionPolicy) throws -> Outcome {
        switch policy.actionAfterProcessing() {
        case .keep:
            .none
        case .discardRaw:
            try removeAudio(meetingId: meetingId, kinds: [.microphone, .system], reason: "원본 트랙 정리")
        case .discardAll:
            try removeAudio(meetingId: meetingId, kinds: Set(AudioTrackKind.allCases), reason: "보관 안 함 설정")
        }
    }

    /// 보관 기간이 지난 회의의 오디오를 지운다. 앱을 켤 때와 처리가 끝난 뒤에 부른다.
    @discardableResult
    public func sweep(policy: AudioRetentionPolicy, now: Date = Date()) throws -> Outcome {
        let candidates = try repository.audioRetentionCandidates()
        let expired = policy.expired(among: candidates, now: now)
        guard !expired.isEmpty else { return .none }

        var total = Outcome.none
        for meetingId in expired {
            let outcome = try removeAudio(
                meetingId: meetingId,
                kinds: Set(AudioTrackKind.allCases),
                reason: "보관 기간 \(policy.retention.label) 경과"
            )
            total.trashedFileCount += outcome.trashedFileCount
            total.freedBytes += outcome.freedBytes
            total.keptExternalFiles += outcome.keptExternalFiles
            if !outcome.isEmpty {
                total.meetingCount += 1
            }
        }
        if total.trashedFileCount > 0 {
            logSink?("오디오 정리: 회의 \(total.meetingCount)건, \(ByteFormat.short(total.freedBytes)) 회수")
        }
        return total
    }

    /// 지정한 종류의 트랙을 지운다. 회의 디렉터리 밖의 파일은 기록만 지우고 파일은 남긴다.
    private func removeAudio(meetingId: UUID, kinds: Set<AudioTrackKind>, reason: String) throws -> Outcome {
        guard let meeting = try repository.meeting(id: meetingId) else { return .none }
        let root = meeting.storageDirectory.standardizedFileURL
        let targets = try repository.tracks(meetingId: meetingId).filter { kinds.contains($0.kind) }
        guard !targets.isEmpty else { return .none }

        var trashed = 0
        var freed: Int64 = 0
        var kept: [URL] = []
        var removedIds: [UUID] = []

        for track in targets {
            let url = MeetingProcessingPipeline.resolveAudioFile(for: track, meetingId: meetingId).fileURL
                .standardizedFileURL
            guard fileManager.fileExists(atPath: url.path) else {
                removedIds.append(track.id)
                continue
            }
            guard MeetingDeleter.isInside(url, root: root) else {
                // 사용자가 가져온 원본이다. 파일도 기록도 그대로 둔다.
                kept.append(url)
                continue
            }
            freed += MeetingDeleter.size(of: url, fileManager: fileManager)
            if trash(url) {
                trashed += 1
            }
            removedIds.append(track.id)
        }

        try repository.deleteTrackRows(ids: removedIds)
        if trashed > 0 {
            logSink?("오디오 \(trashed)개 휴지통으로 이동 (\(reason), \(ByteFormat.short(freed)))")
        }
        return Outcome(
            trashedFileCount: trashed,
            freedBytes: freed,
            meetingCount: trashed > 0 ? 1 : 0,
            keptExternalFiles: kept
        )
    }

    /// 회의 저장 폴더에 실제로 들어 있는 오디오 용량.
    ///
    /// 데이터베이스 합계와 다를 수 있다. 기록이 없는 파일(폴더를 옮기다 남은 잔여물 등)도 디스크는 차지하므로
    /// 사용자에게는 실제 값을 보여 준다.
    public struct DiskUsage: Hashable, Sendable {
        public var fileCount: Int
        public var bytes: Int64
        /// 데이터베이스에 기록이 없는 파일. 어떤 보관 설정으로도 자동 정리되지 않는다.
        public var untrackedFileCount: Int
        public var untrackedBytes: Int64

        public static let empty = DiskUsage(fileCount: 0, bytes: 0, untrackedFileCount: 0, untrackedBytes: 0)
    }

    public func diskUsage(root: URL = AudioRetentionService.defaultMeetingsRoot) throws -> DiskUsage {
        let tracked = try Set(
            repository.audioRetentionCandidates()
                .flatMap { try repository.tracks(meetingId: $0.meetingId) }
                .map(\.fileURL.standardizedFileURL.path)
        )
        guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) else {
            return .empty
        }
        var usage = DiskUsage.empty
        let audioExtensions: Set = ["m4a", "caf", "aiff", "wav", "mp3", "aac"]
        while let url = enumerator.nextObject() as? URL {
            guard audioExtensions.contains(url.pathExtension.lowercased()) else { continue }
            let bytes = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            usage.fileCount += 1
            usage.bytes += bytes
            if !tracked.contains(url.standardizedFileURL.path) {
                usage.untrackedFileCount += 1
                usage.untrackedBytes += bytes
            }
        }
        return usage
    }

    /// 회의 파일이 모이는 기본 위치.
    public static var defaultMeetingsRoot: URL {
        AppIdentity.dataDirectory().appendingPathComponent("meetings", isDirectory: true)
    }

    private func trash(_ url: URL) -> Bool {
        do {
            try fileManager.trashItem(at: url, resultingItemURL: nil)
            return true
        } catch {
            return (try? fileManager.removeItem(at: url)) != nil
        }
    }
}

/// 용량을 사람이 읽는 문자열로 바꾼다.
public enum ByteFormat {
    public static func short(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB, .useKB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
