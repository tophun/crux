import Foundation

/// 회의 한 건. 오디오 원본과 전사문, 생성된 회의록의 소유자다.
public struct Meeting: Identifiable, Hashable, Sendable, Codable {
    public var id: UUID
    public var title: String
    public var startedAt: Date
    public var endedAt: Date?
    public var status: MeetingStatus
    /// 회의 관련 파일이 저장된 로컬 디렉터리 (raw/, mixed/, exports/)
    public var storageDirectory: URL
    public var source: MeetingSource
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        title: String,
        startedAt: Date,
        endedAt: Date? = nil,
        status: MeetingStatus = .recorded,
        storageDirectory: URL,
        source: MeetingSource = .importedFile,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.status = status
        self.storageDirectory = storageDirectory
        self.source = source
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var duration: TimeInterval? {
        guard let endedAt else { return nil }
        return endedAt.timeIntervalSince(startedAt)
    }
}

/// 회의 처리 상태. 사용자에게 보이는 진행 상태이자 재처리 판단 기준이다.
public enum MeetingStatus: String, Codable, Sendable, CaseIterable {
    /// 녹음 중 (Phase 2)
    case recording
    /// 녹음 일시정지 (Phase 2)
    case paused
    /// 녹음/가져오기 완료, 처리 대기
    case recorded
    /// 음성 인식 진행 중
    case transcribing
    /// 회의록 생성 진행 중
    case analyzing
    /// 회의록 생성 완료
    case completed
    /// 처리 실패 — 원본과 중간 산출물은 보존되며 재처리 가능
    case failed

    public var isTerminal: Bool {
        self == .completed || self == .failed
    }

    public var displayName: String {
        switch self {
        case .recording: "녹음 중"
        case .paused: "일시정지"
        case .recorded: "처리 대기"
        case .transcribing: "음성 인식 중"
        case .analyzing: "회의록 생성 중"
        case .completed: "완료"
        case .failed: "실패"
        }
    }
}

public enum MeetingSource: String, Codable, Sendable {
    /// 로컬 오디오 파일을 가져온 회의 (Phase 1)
    case importedFile
    /// 앱이 직접 녹음한 회의 (Phase 2)
    case liveCapture
}
