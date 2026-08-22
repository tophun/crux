import Foundation

/// 오디오 트랙의 출처. 온라인 회의에서는 마이크와 시스템 오디오를 분리 보존한다.
public enum AudioTrackKind: String, Codable, Sendable, CaseIterable {
    case microphone
    case system
    /// 전사에 사용하는 합성 트랙
    case mixed
}

/// 오디오 파일 메타데이터. 오디오 바이트는 DB에 넣지 않고 파일 경로만 저장한다.
public struct AudioTrack: Identifiable, Hashable, Sendable, Codable {
    public var id: UUID
    public var meetingId: UUID
    public var kind: AudioTrackKind
    public var fileURL: URL
    public var duration: TimeInterval
    public var sampleRate: Double
    public var channelCount: Int
    public var byteSize: Int64
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        meetingId: UUID,
        kind: AudioTrackKind,
        fileURL: URL,
        duration: TimeInterval,
        sampleRate: Double,
        channelCount: Int,
        byteSize: Int64,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.meetingId = meetingId
        self.kind = kind
        self.fileURL = fileURL
        self.duration = duration
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.byteSize = byteSize
        self.createdAt = createdAt
    }
}

/// 긴 오디오를 메모리에 한 번에 올리지 않기 위한 처리 단위.
public struct AudioSegment: Identifiable, Hashable, Sendable, Codable {
    public var id: UUID
    public var trackId: UUID
    public var index: Int
    public var startTime: TimeInterval
    public var endTime: TimeInterval
    /// 분할 파일을 따로 만든 경우의 경로. 원본에서 구간만 읽는 경우 nil.
    public var fileURL: URL?

    public init(
        id: UUID = UUID(),
        trackId: UUID,
        index: Int,
        startTime: TimeInterval,
        endTime: TimeInterval,
        fileURL: URL? = nil
    ) {
        self.id = id
        self.trackId = trackId
        self.index = index
        self.startTime = startTime
        self.endTime = endTime
        self.fileURL = fileURL
    }

    public var duration: TimeInterval { max(0, endTime - startTime) }
}

public extension AudioTrack {
    /// 재생에 쓸 트랙을 고른다. 합성본 → 마이크 → 시스템 오디오 순이다.
    static func preferredForPlayback(_ tracks: [AudioTrack]) -> AudioTrack? {
        let order: [AudioTrackKind] = [.mixed, .microphone, .system]
        for kind in order {
            if let track = tracks.first(where: { $0.kind == kind }) { return track }
        }
        return tracks.first
    }

    var displayName: String {
        switch kind {
        case .mixed: "전체(합성)"
        case .microphone: "마이크"
        case .system: "시스템 오디오"
        }
    }
}
