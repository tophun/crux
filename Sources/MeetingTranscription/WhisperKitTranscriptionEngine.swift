import Foundation
import MeetingAudio
import MeetingCore
import WhisperKit

/// WhisperKit 기반 로컬 음성 인식 엔진(§6).
///
/// - 기본 모델은 large-v3 turbo다. 모델 파일 최초 다운로드에만 네트워크를 쓰고 그 외에는 로컬에서만 동작한다.
/// - 긴 파일은 `incremental` 로딩으로 메모리를 제한하고, VAD 기반으로 구간을 나눈다.
/// - 전사가 끝나면 `unload()`로 모델을 내려 LLM이 들어갈 자리를 만든다(§12).
public actor WhisperKitTranscriptionEngine: TranscriptionEngine {
    public struct Configuration: Sendable {
        /// WhisperKit 모델 이름. `openai_whisper-large-v3-v20240930_turbo`가 large-v3 turbo다.
        /// 메모리가 부족하면 `openai_whisper-large-v3-v20240930_626MB`(양자화)로 낮출 수 있다.
        public var model: String
        /// 설정에서 고른 모델을 알려 주는 함수. 있으면 `model`보다 우선한다.
        ///
        /// 로드할 때마다 물어보므로, 설정을 바꾸면 다음 처리부터 새 모델이 쓰인다.
        public var modelProvider: (@Sendable () -> String)?
        /// 모델 저장 폴더. 지정하면 오프라인에서 이 경로만 사용한다.
        public var modelFolder: String?
        /// 모델이 없을 때 다운로드를 허용할지. false면 완전 오프라인으로 동작한다.
        public var allowDownload: Bool
        /// 다운로드 캐시 위치
        public var downloadBase: URL?
        /// 단어 단위 타임스탬프 (가능한 경우)
        public var wordTimestamps: Bool
        /// 긴 파일 스트리밍 로딩 사용
        public var incrementalLoading: Bool
        /// Core ML 모델 사전 특화. 최대 메모리를 낮춘다.
        public var prewarm: Bool
        /// 인식 힌트. 회의에서 자주 쓰는 고유명사·약어를 넣으면 표기 정확도가 올라갈 수 있다.
        /// (예: "QA, 릴리즈, 스프린트").
        ///
        /// 주의: 프롬프트 토큰은 디코딩에 영향을 주어 **구간 분할이 거칠어질 수 있다.**
        /// 실제 검증에서 118초 오디오가 24구간 → 6구간으로 합쳐졌다. 기본값은 사용하지 않음(nil)이다.
        public var vocabularyHint: String?
        /// 이 길이를 넘는 구간은 문장 단위로 다시 나눈다. 근거 타임스탬프 정밀도를 지키기 위한 장치다.
        public var maxSegmentCharacters: Int

        public init(
            model: String = TranscriptionModelCatalog.defaultId,
            modelProvider: (@Sendable () -> String)? = nil,
            modelFolder: String? = nil,
            allowDownload: Bool = true,
            downloadBase: URL? = nil,
            wordTimestamps: Bool = true,
            incrementalLoading: Bool = true,
            prewarm: Bool = true,
            vocabularyHint: String? = nil,
            maxSegmentCharacters: Int = 90
        ) {
            self.model = model
            self.modelProvider = modelProvider
            self.modelFolder = modelFolder
            self.allowDownload = allowDownload
            self.downloadBase = downloadBase
            self.wordTimestamps = wordTimestamps
            self.incrementalLoading = incrementalLoading
            self.prewarm = prewarm
            self.vocabularyHint = vocabularyHint
            self.maxSegmentCharacters = maxSegmentCharacters
        }

        /// 기본 모델 저장 위치. 앱 데이터 디렉터리 안에 둔다.
        public static func defaultDownloadBase() -> URL {
            AppIdentity.dataDirectory().appendingPathComponent("models", isDirectory: true)
        }
    }

    public private(set) var configuration: Configuration
    private var whisperKit: WhisperKit?
    /// 지금 올라와 있는 모델 이름. 설정에서 다른 모델을 고르면 이 값과 달라진다.
    private var loadedModel: String?
    private let log: (@Sendable (String) -> Void)?
    /// 콜백이 알려 준 처리 창 번호. 진행 표시에 함께 쓴다.
    private var lastWindowId = 0

    public init(configuration: Configuration = Configuration(), log: (@Sendable (String) -> Void)? = nil) {
        self.configuration = configuration
        self.log = log
    }

    /// 지금 써야 할 모델 이름. 설정이 있으면 그쪽을 따른다.
    private var selectedModel: String {
        configuration.modelProvider?() ?? configuration.model
    }

    public func load() async throws {
        let model = selectedModel
        // 설정에서 모델을 바꿨으면 올라와 있던 것을 내리고 새로 올린다.
        // 로드는 각 단계 진입 때만 부르므로 처리 도중에 바뀌지 않는다.
        if whisperKit != nil, loadedModel != model {
            log?("음성 인식 모델 변경: \(loadedModel ?? "없음") → \(model)")
            await unload()
        }
        guard whisperKit == nil else { return }
        let started = Date()
        let config = WhisperKitConfig(
            model: model,
            downloadBase: configuration.downloadBase ?? Configuration.defaultDownloadBase(),
            modelFolder: configuration.modelFolder,
            verbose: false,
            logLevel: .error,
            prewarm: configuration.prewarm,
            load: true,
            download: configuration.allowDownload
        )
        do {
            whisperKit = try await WhisperKit(config)
            loadedModel = model
        } catch {
            throw TranscriptionEngineError.modelUnavailable(
                "\(model) 로드 실패: \(error.localizedDescription)"
            )
        }
        log?(String(format: "WhisperKit(%@) 로드 %.1fs", model, Date().timeIntervalSince(started)))
    }

    public func unload() async {
        guard let whisperKit else { return }
        await whisperKit.unloadModels()
        self.whisperKit = nil
        loadedModel = nil
        log?("WhisperKit 해제")
    }

    public func transcribe(
        audioURL: URL,
        meetingId: UUID,
        language: String,
        progress: (@Sendable (MeetingCore.TranscriptionProgress) -> Void)?
    ) async throws -> [TranscriptSegment] {
        let info = try AudioFileInspector.inspect(url: audioURL)
        try await load()
        guard let whisperKit else {
            throw TranscriptionEngineError.modelUnavailable("엔진이 로드되지 않음")
        }

        // 인식 힌트를 프롬프트 토큰으로 넣는다. 힌트가 없으면 기본 동작 그대로다.
        let promptTokens: [Int]? = configuration.vocabularyHint.flatMap { hint in
            guard let tokenizer = whisperKit.tokenizer else { return nil }
            let tokens = tokenizer.encode(text: " " + hint)
                .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
            return tokens.isEmpty ? nil : tokens
        }

        let options = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: language,
            temperatureFallbackCount: 2,
            usePrefillPrompt: true,
            detectLanguage: false,
            skipSpecialTokens: true,
            withoutTimestamps: false,
            wordTimestamps: configuration.wordTimestamps,
            promptTokens: promptTokens,
            // VAD 기반 분할. 긴 회의를 구간으로 잘라 처리한다(§6).
            chunkingStrategy: .vad
        )
        let audioInput = AudioInputOptions(
            channelMode: .sumChannels(nil),
            audioLoadingMode: configuration.incrementalLoading ? .incremental : .fullFile
        )

        lastWindowId = 0

        // WhisperKit의 Progress를 주기적으로 읽어 진행률을 보고한다.
        // 콜백이 주는 `timings.inputAudioSeconds`는 전사가 끝나야 채워져서 진행 표시에 쓸 수 없다.
        let estimator = TranscriptionProgressEstimator()
        let startedAt = Date()
        let monitor: Task<Void, Never>? = progress == nil ? nil : Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(400))
                guard let self else { return }
                let snapshot = await self.progressSnapshot()
                let fraction = estimator.fraction(
                    reported: snapshot.fraction,
                    elapsed: Date().timeIntervalSince(startedAt),
                    audioDuration: info.duration
                )
                progress?(
                    MeetingCore.TranscriptionProgress(
                        processedSeconds: fraction * info.duration,
                        totalSeconds: info.duration,
                        segmentCount: snapshot.windowId
                    )
                )
            }
        }

        let results = await whisperKit.transcribeWithResults(
            audioPaths: [audioURL.path],
            audioInputOptions: audioInput,
            decodeOptions: options,
            callback: { [weak self] progressUpdate in
                Task { await self?.noteWindow(progressUpdate.windowId) }
                return true
            }
        )
        monitor?.cancel()

        guard let first = results.first else { throw TranscriptionEngineError.emptyResult }
        let transcriptionResults: [TranscriptionResult]
        switch first {
        case .success(let value):
            transcriptionResults = value
        case .failure(let error):
            throw TranscriptionEngineError.audioFileUnreadable(
                audioURL,
                underlying: error.localizedDescription
            )
        }

        let segments = transcriptionResults
            .flatMap(\.segments)
            .sorted { $0.start < $1.start }
            .map { $0 }

        var result: [TranscriptSegment] = []
        for segment in segments {
            let text = segment.text
                .replacingOccurrences(of: "<|endoftext|>", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            result.append(
                TranscriptSegment(
                    meetingId: meetingId,
                    index: result.count,
                    startTime: TimeInterval(segment.start),
                    endTime: TimeInterval(segment.end),
                    speakerId: nil,
                    text: text,
                    confidence: Self.confidence(avgLogprob: segment.avgLogprob, noSpeechProb: segment.noSpeechProb),
                    sourceTrack: .mixed
                )
            )
        }

        // 긴 구간은 문장 단위로 다시 나눈다. 근거 타임스탬프가 뭉뚝해지는 것을 막는다.
        let segmenter = TranscriptSegmenter(maxCharacters: configuration.maxSegmentCharacters)
        result = segmenter.split(result)

        progress?(
            MeetingCore.TranscriptionProgress(
                processedSeconds: info.duration,
                totalSeconds: info.duration,
                segmentCount: result.count
            )
        )

        guard !result.isEmpty else { throw TranscriptionEngineError.emptyResult }
        return result
    }

    /// WhisperKit이 갱신하는 진행 정보를 읽는다.
    ///
    /// `progress`는 구간마다 자식 `Progress`를 붙이는 부모라서 `completedUnitCount`로는 진행이 보이지 않는다.
    /// 자식까지 반영된 값은 `fractionCompleted`에만 들어온다.
    func progressSnapshot() -> (fraction: Double, windowId: Int) {
        guard let whisperKit else { return (0, lastWindowId) }
        let fraction = whisperKit.progress.fractionCompleted
        guard fraction.isFinite else { return (0, lastWindowId) }
        return (min(1, max(0, fraction)), lastWindowId)
    }

    func noteWindow(_ windowId: Int) {
        lastWindowId = max(lastWindowId, windowId + 1)
    }

    /// Whisper의 평균 로그확률과 무음 확률을 0...1 신뢰도로 바꾼다.
    /// 낮은 값은 사고 모드 재검토 신호로 쓰인다(§8).
    static func confidence(avgLogprob: Float, noSpeechProb: Float) -> Double {
        let probability = exp(Double(avgLogprob))
        let speech = 1 - Double(noSpeechProb)
        return min(1, max(0, probability * speech))
    }
}
