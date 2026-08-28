import Foundation
import MeetingCore

/// 녹음 중 Whisper 부분 결과로 자막과 초안 요약을 만든다.
///
/// - 전사 모델만 올린다. LLM은 올리지 않는다(16GB에서 동시 상주 금지).
/// - 한 조각이 실패해도 세션은 멈추지 않는다. 녹음을 끊지 않기 위해서다.
/// - 회의가 끝나기 전 요약은 항상 초안이다.
public actor LiveCaptionSession {
    public struct Configuration: Sendable {
        public var pollInterval: Duration
        public var summaryLimit: Int
        public var language: String

        public init(
            pollInterval: Duration = .seconds(2),
            summaryLimit: Int = 160,
            language: String = "ko"
        ) {
            self.pollInterval = pollInterval
            self.summaryLimit = summaryLimit
            self.language = language
        }
    }

    private let meetingId: UUID
    private let source: any LiveCaptionAudioProviding
    private let models: ModelLifecycleCoordinator
    private let configuration: Configuration
    private let onUpdate: (@Sendable (LiveCaptionState) -> Void)?
    private let log: (@Sendable (String) -> Void)?

    private var state = LiveCaptionState(isDraft: true, isActive: false)
    private var segments: [TranscriptSegment] = []
    private var running = false
    private var loop: Task<Void, Never>?

    public init(
        meetingId: UUID,
        source: any LiveCaptionAudioProviding,
        models: ModelLifecycleCoordinator,
        configuration: Configuration = Configuration(),
        onUpdate: (@Sendable (LiveCaptionState) -> Void)? = nil,
        log: (@Sendable (String) -> Void)? = nil
    ) {
        self.meetingId = meetingId
        self.source = source
        self.models = models
        self.configuration = configuration
        self.onUpdate = onUpdate
        self.log = log
    }

    public func currentState() -> LiveCaptionState {
        state
    }

    public func start() {
        guard loop == nil else { return }
        running = true
        state.isActive = true
        state.isDraft = true
        publish()
        loop = Task { [weak self] in
            await self?.runLoop()
        }
    }

    /// 루프를 멈추고 남은 조각을 한 번 더 전사한 뒤 초안 상태를 돌려준다.
    public func stop() async -> LiveCaptionState {
        running = false
        loop?.cancel()
        await loop?.value
        loop = nil
        let leftover = await source.finishCaptionChunks()
        for chunk in leftover {
            await transcribe(chunk)
        }
        state.isActive = false
        state.isDraft = true
        publish()
        return state
    }

    private func runLoop() async {
        while running, !Task.isCancelled {
            let chunks = await source.nextCaptionChunks()
            for chunk in chunks {
                guard running else { break }
                await transcribe(chunk)
            }
            try? await Task.sleep(for: configuration.pollInterval)
        }
    }

    private func transcribe(_ chunk: LiveAudioChunk) async {
        do {
            let raw = try await models.withTranscription { engine in
                try await engine.transcribe(
                    audioURL: chunk.url,
                    meetingId: meetingId,
                    language: configuration.language,
                    progress: nil
                )
            }
            append(raw, offset: chunk.startOffset)
        } catch is CancellationError {
            return
        } catch {
            // 자막 실패는 녹음을 멈추지 않는다.
            state.lastError = error.localizedDescription
            log?("실시간 자막 실패(녹음은 계속): \(error.localizedDescription)")
            publish()
        }
    }

    private func append(_ raw: [TranscriptSegment], offset: TimeInterval) {
        let cleaned = raw.compactMap { segment -> TranscriptSegment? in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return TranscriptSegment(
                meetingId: meetingId,
                index: 0,
                startTime: segment.startTime + offset,
                endTime: segment.endTime + offset,
                speakerId: nil,
                text: text,
                confidence: segment.confidence,
                sourceTrack: segment.sourceTrack
            )
        }
        guard !cleaned.isEmpty else { return }

        for var segment in cleaned {
            segment.index = segments.count
            segments.append(segment)
            state.lines.append(
                LiveCaptionLine(
                    id: segment.id,
                    startTime: segment.startTime,
                    endTime: segment.endTime,
                    text: segment.text
                )
            )
        }
        state.draftSummary = LiveDraftSummaryBuilder.make(
            from: state.lines,
            maxCharacters: configuration.summaryLimit
        )
        state.isDraft = true
        state.lastError = nil
        publish()
    }

    private func publish() {
        onUpdate?(state)
    }
}
