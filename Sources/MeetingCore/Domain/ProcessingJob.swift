import Foundation

/// 처리 단계. 앱이 강제 종료돼도 어디서부터 재시작할지 알 수 있어야 한다.
public enum ProcessingStage: String, Codable, Sendable, CaseIterable {
    case prepareAudio
    case transcribe
    case extractFacts
    case reviewFacts
    case assembleNote
    case persistNote

    public var displayName: String {
        switch self {
        case .prepareAudio: "오디오 준비"
        case .transcribe: "음성 인식"
        case .extractFacts: "사실 추출"
        case .reviewFacts: "재검토"
        case .assembleNote: "회의록 생성"
        case .persistNote: "저장"
        }
    }

    /// 진행률 표시용 가중치 (합 1.0). 음성 인식이 가장 오래 걸린다.
    public var progressWeight: Double {
        switch self {
        case .prepareAudio: 0.02
        case .transcribe: 0.55
        case .extractFacts: 0.20
        case .reviewFacts: 0.13
        case .assembleNote: 0.08
        case .persistNote: 0.02
        }
    }
}

public enum ProcessingJobState: String, Codable, Sendable {
    case pending
    case running
    case succeeded
    case failed
    /// 앱 종료 등으로 중단됨 — 재처리 대상
    case interrupted
}

/// 재처리를 위해 단계별로 기록되는 작업. 실패 시 데이터 유실보다 재처리를 우선한다.
public struct ProcessingJob: Identifiable, Hashable, Sendable, Codable {
    public var id: UUID
    public var meetingId: UUID
    public var stage: ProcessingStage
    public var state: ProcessingJobState
    public var attempt: Int
    public var startedAt: Date?
    public var finishedAt: Date?
    public var errorMessage: String?
    /// 단계 산출물 위치나 재시작 힌트 (예: 완료된 윈도 인덱스)
    public var checkpoint: String?

    public init(
        id: UUID = UUID(),
        meetingId: UUID,
        stage: ProcessingStage,
        state: ProcessingJobState = .pending,
        attempt: Int = 0,
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        errorMessage: String? = nil,
        checkpoint: String? = nil
    ) {
        self.id = id
        self.meetingId = meetingId
        self.stage = stage
        self.state = state
        self.attempt = attempt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.errorMessage = errorMessage
        self.checkpoint = checkpoint
    }

    public var isRetryable: Bool {
        state == .failed || state == .interrupted
    }
}
