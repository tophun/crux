import Foundation
import MeetingAudio
import MeetingCore
import MeetingPersistence

/// 로컬 오디오 파일을 회의로 가져온다 (Phase 1 수직 슬라이스의 입력).
public struct MeetingImporter: Sendable {
    private let repository: MeetingRepository
    private let baseDirectory: URL?
    nonisolated(unsafe) private let fileManager: FileManager

    public init(repository: MeetingRepository, baseDirectory: URL? = nil, fileManager: FileManager = .default) {
        self.repository = repository
        self.baseDirectory = baseDirectory
        self.fileManager = fileManager
    }

    /// - Parameter copyFile: true면 원본을 회의 디렉터리로 복사한다. false면 원본 경로를 그대로 참조한다.
    public func importAudio(
        at url: URL,
        title: String? = nil,
        startedAt: Date? = nil,
        copyFile: Bool = true
    ) throws -> (meeting: Meeting, track: AudioTrack) {
        let info = try AudioFileInspector.inspect(url: url, fileManager: fileManager)
        let meetingId = UUID()
        let storage = MeetingStorage.forMeeting(id: meetingId, base: baseDirectory, fileManager: fileManager)
        try storage.createDirectories()

        let destination: URL
        if copyFile {
            destination = storage.url(for: .mixed, extension: url.pathExtension.isEmpty ? "m4a" : url.pathExtension)
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.copyItem(at: url, to: destination)
        } else {
            destination = url
        }

        let started = startedAt ?? (try? fileManager.attributesOfItem(atPath: url.path)[.creationDate] as? Date)
            .flatMap { $0 } ?? Date()

        let meeting = Meeting(
            id: meetingId,
            title: title ?? url.deletingPathExtension().lastPathComponent,
            startedAt: started,
            endedAt: started.addingTimeInterval(info.duration),
            status: .recorded,
            storageDirectory: storage.root,
            source: .importedFile
        )
        let track = AudioTrack(
            meetingId: meetingId,
            kind: .mixed,
            fileURL: destination,
            duration: info.duration,
            sampleRate: info.sampleRate,
            channelCount: info.channelCount,
            byteSize: info.byteSize
        )

        try repository.save(meeting)
        try repository.save(tracks: [track])
        return (meeting, track)
    }
}
