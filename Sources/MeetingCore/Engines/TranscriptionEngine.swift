import Foundation

/// 전사 진행 상황. UI 진행률 표시에 사용한다.
public struct TranscriptionProgress: Hashable, Sendable {
    public var processedSeconds: TimeInterval
    public var totalSeconds: TimeInterval
    public var segmentCount: Int

    public init(processedSeconds: TimeInterval, totalSeconds: TimeInterval, segmentCount: Int) {
        self.processedSeconds = processedSeconds
        self.totalSeconds = totalSeconds
        self.segmentCount = segmentCount
    }

    public var fraction: Double {
        guard totalSeconds > 0 else { return 0 }
        return min(1, max(0, processedSeconds / totalSeconds))
    }
}

/// 음성 인식 추상화. 구현은 교체 가능하며 오디오를 외부로 전송하지 않는다.
public protocol TranscriptionEngine: Sendable {
    /// 오디오 파일을 전사한다.
    /// - Parameters:
    ///   - audioURL: 로컬 오디오 파일
    ///   - meetingId: 결과 세그먼트에 부여할 회의 식별자
    ///   - language: 인식 언어 (기본 한국어)
    ///   - progress: 진행 콜백
    func transcribe(
        audioURL: URL,
        meetingId: UUID,
        language: String,
        progress: (@Sendable (TranscriptionProgress) -> Void)?
    ) async throws -> [TranscriptSegment]

    func load() async throws

    /// 전사 완료 후 모델 메모리를 해제한다.
    func unload() async
}

extension TranscriptionEngine {
    public func transcribe(
        audioURL: URL,
        meetingId: UUID
    ) async throws -> [TranscriptSegment] {
        try await transcribe(audioURL: audioURL, meetingId: meetingId, language: "ko", progress: nil)
    }

    public func load() async throws {}
    public func unload() async {}
}

public enum TranscriptionEngineError: Error, LocalizedError, Sendable {
    case audioFileMissing(URL)
    case audioFileUnreadable(URL, underlying: String)
    case modelUnavailable(String)
    case emptyResult

    public var errorDescription: String? {
        switch self {
        case .audioFileMissing(let url):
            "오디오 파일을 찾을 수 없습니다: \(url.path)"
        case .audioFileUnreadable(let url, let underlying):
            "오디오 파일을 읽을 수 없습니다: \(url.lastPathComponent) (\(underlying))"
        case .modelUnavailable(let message):
            "음성 인식 모델을 사용할 수 없습니다: \(message)"
        case .emptyResult:
            "음성 인식 결과가 비어 있습니다."
        }
    }
}
