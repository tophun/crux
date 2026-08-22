import Foundation
import MeetingAudio
import MeetingCore
import MeetingPersistence

/// 회의 처리 전체 흐름.
///
///     오디오 파일 → 로컬 전사 → (음성 인식 모델 해제) → 로컬 LLM 회의록 생성 → 저장
///
/// 각 단계는 `ProcessingJob`으로 기록되므로 앱이 죽어도 재처리할 수 있다(§13, §15).
public actor MeetingProcessingPipeline {
    public struct Update: Sendable {
        public var stage: ProcessingStage
        /// 전체 진행률 0...1
        public var fraction: Double
        public var message: String
    }

    public struct Result: Sendable {
        public var note: MeetingNote
        public var segments: [TranscriptSegment]
        public var relevance: [RelevanceDecision]
        public var problems: [String]
        public var metrics: [StageMetric]
        /// 근거 파일 경로 ({meetingId}.evidence.json)
        public var evidenceFileURL: URL?
        public var skills: MeetingSkillTrace
    }

    private let repository: MeetingRepository
    private let jobs: ProcessingJobRepository
    private let coordinator: ModelLifecycleCoordinator
    private let inferenceConfiguration: LocalInferencePipeline.Configuration
    private let language: String
    private let logSink: (@Sendable (String) -> Void)?
    private let editor: KoreanMeetingEditor
    private let evidenceStore: EvidenceFileStore
    /// 회의록 문서 구성 프롬프트. 설정에서 바꾼 값이 다음 처리에 바로 반영되도록 클로저로 받는다.
    private let documentPrompt: @Sendable () -> String
    /// 오디오 보관 정책을 그때그때 읽어 온다. 설정 화면에서 바꾼 값이 바로 반영되도록 클로저로 받는다.
    private let retention: @Sendable () -> AudioRetentionPolicy
    /// 마지막으로 보고한 진행률. 단계가 겹쳐도 UI 진행률이 뒤로 가지 않게 한다.
    private var lastReportedFraction: Double = 0
    /// 처리 중 여부. 두 회의가 동시에 처리되면 모델 수명 관리가 깨지므로 한 번에 하나만 돌린다(§12).
    private var isProcessing = false

    public init(
        repository: MeetingRepository,
        jobs: ProcessingJobRepository,
        coordinator: ModelLifecycleCoordinator,
        inferenceConfiguration: LocalInferencePipeline.Configuration = .init(),
        language: String = "ko",
        editor: KoreanMeetingEditor = KoreanMeetingEditor(),
        evidenceStore: EvidenceFileStore = EvidenceFileStore(),
        retention: @escaping @Sendable () -> AudioRetentionPolicy = { .standard },
        documentPrompt: @escaping @Sendable () -> String = { "" },
        logSink: (@Sendable (String) -> Void)? = nil
    ) {
        self.repository = repository
        self.jobs = jobs
        self.coordinator = coordinator
        self.inferenceConfiguration = inferenceConfiguration
        self.language = language
        self.editor = editor
        self.evidenceStore = evidenceStore
        self.retention = retention
        self.documentPrompt = documentPrompt
        self.logSink = logSink
    }

    /// 진행률을 단조 증가하도록 보정해서 내보낸다.
    private func emit(
        _ onUpdate: (@Sendable (Update) -> Void)?,
        stage: ProcessingStage,
        fraction: Double,
        message: String
    ) {
        guard let onUpdate else { return }
        lastReportedFraction = max(lastReportedFraction, min(1, max(0, fraction)))
        onUpdate(Update(stage: stage, fraction: lastReportedFraction, message: message))
    }

    /// 회의 하나를 처리한다. 이미 완료된 단계는 다시 하지 않는다(재처리 지원).
    public func process(
        meetingId: UUID,
        force: Bool = false,
        onUpdate: (@Sendable (Update) -> Void)? = nil
    ) async throws -> Result {
        guard !isProcessing else { throw PipelineError.busy }
        isProcessing = true
        defer { isProcessing = false }
        lastReportedFraction = 0

        guard let meeting = try repository.meeting(id: meetingId) else {
            throw PipelineError.meetingNotFound(meetingId)
        }

        let sink = logSink
        let recorder = StageMetricsRecorder(sink: { metric in sink?(metric.description) })
        var problems: [String] = []

        // MARK: 1. 오디오 준비

        let track = try await runStage(.prepareAudio, meetingId: meetingId, recorder: recorder, onUpdate: onUpdate) {
            let tracks = try repository.tracks(meetingId: meetingId)
            guard let selected = tracks.first(where: { $0.kind == .mixed }) ?? tracks.first else {
                throw PipelineError.audioTrackMissing(meetingId)
            }
            // 저장 위치가 바뀐 경우(데이터 폴더 이동·복원 등) 현재 위치에서 같은 파일을 찾아 경로를 고친다.
            let resolved = Self.resolveAudioFile(for: selected, meetingId: meetingId)
            if resolved.fileURL != selected.fileURL {
                logSink?("오디오 경로를 현재 위치로 정정: \(resolved.fileURL.path)")
                try? repository.save(tracks: [resolved])
            }
            // 손상 파일은 여기서 걸러 이후 단계를 낭비하지 않는다.
            _ = try AudioFileInspector.inspect(url: resolved.fileURL)
            return resolved
        }

        // MARK: 2. 음성 인식

        var segments = force ? [] : try repository.transcript(meetingId: meetingId)
        if segments.isEmpty {
            try repository.updateStatus(.transcribing, meetingId: meetingId)
            segments = try await runStage(.transcribe, meetingId: meetingId, recorder: recorder, onUpdate: onUpdate) {
                let total = track.duration
                let result = try await coordinator.withTranscription { engine in
                    try await engine.transcribe(
                        audioURL: track.fileURL,
                        meetingId: meetingId,
                        language: language,
                        progress: { progress in
                            Task { [weak self] in
                                await self?.emit(
                                    onUpdate,
                                    stage: .transcribe,
                                    fraction: Self.fraction(upTo: .transcribe, within: progress.fraction),
                                    message: "음성 인식 \(Int(progress.fraction * 100))% (\(progress.segmentCount)개 구간)"
                                )
                            }
                        }
                    )
                }
                guard !result.isEmpty else { throw TranscriptionEngineError.emptyResult }
                _ = total
                try repository.save(segments: result, meetingId: meetingId)
                return result
            }
        } else {
            logSink?("전사문이 이미 있어 음성 인식을 건너뜁니다 (\(segments.count)개 구간)")
        }

        // MARK: 3~5. 회의록 생성 (사실 추출 → 재검토 → 최종 종합)

        try repository.updateStatus(.analyzing, meetingId: meetingId)
        let editor = editor
        let output = try await runStage(.extractFacts, meetingId: meetingId, recorder: recorder, onUpdate: onUpdate) {
            try await coordinator.withLanguageModel { model in
                let pipeline = LocalInferencePipeline(model: model, configuration: inferenceConfiguration)
                var result = try await pipeline.generateNote(
                    meetingId: meetingId,
                    titleHint: meeting.title,
                    segments: segments,
                    progress: { progress in
                        switch progress {
                        case let .extracting(window, total):
                            Task { [weak self] in
                                await self?.emit(
                                    onUpdate,
                                    stage: .extractFacts,
                                    fraction: Self.fraction(
                                        upTo: .extractFacts,
                                        within: total > 0 ? Double(window) / Double(total) : 0
                                    ),
                                    message: "사실 추출 \(window)/\(total) 구간"
                                )
                            }
                        case let .reviewing(item, total):
                            Task { [weak self] in
                                await self?.emit(
                                    onUpdate,
                                    stage: .reviewFacts,
                                    fraction: Self.fraction(
                                        upTo: .reviewFacts,
                                        within: total > 0 ? Double(item) / Double(total) : 0
                                    ),
                                    message: "재검토 \(item)/\(total) 항목"
                                )
                            }
                        case .assembling:
                            Task { [weak self] in
                                await self?.emit(
                                    onUpdate,
                                    stage: .assembleNote,
                                    fraction: Self.fraction(upTo: .assembleNote, within: 0.5),
                                    message: "회의록 정리 중"
                                )
                            }
                        }
                    }
                )
                // korean-meeting-editor — LLM이 올라와 있는 동안 윤문까지 마친다.
                let (edited, report) = await editor.edit(note: result.note, model: model)
                result.note = edited
                result.note.generation.koreanEditor = report
                result.problems += report.warnings.map { "[윤문] \($0)" }

                // 사용자 문서 프롬프트가 있으면 검증된 내용만으로 문서를 다시 구성한다.
                // 실패해도 회의록 생성은 성공으로 남기고 기본 구성을 쓴다.
                let prompt = documentPrompt()
                if DocumentComposer.isUsable(prompt: prompt) {
                    do {
                        result.note.customDocument = try await DocumentComposer.compose(
                            note: result.note,
                            meeting: meeting,
                            userPrompt: prompt,
                            model: model
                        )
                    } catch {
                        result.problems.append("[문서 구성] 실패해 기본 구성을 사용: \(error.localizedDescription)")
                    }
                }
                return result
            }
        }
        problems += output.problems

        // 재검토·종합 단계도 성공으로 기록한다 (한 번의 LLM 세션에서 함께 수행됨).
        try markSucceeded(.reviewFacts, meetingId: meetingId)
        try markSucceeded(.assembleNote, meetingId: meetingId)

        // MARK: 6. 저장 — 회의록은 DB, 근거는 로컬 파일로 분리한다(요구사항 7).

        var note = output.note
        var trace = MeetingSkillTrace()
        trace.record(
            MeetingSkillRun(
                skill: .factExtractor,
                succeeded: note.generation.candidateCount > 0,
                itemCount: note.generation.candidateCount
            )
        )
        trace.record(
            MeetingSkillRun(
                skill: .cleaner,
                succeeded: true,
                itemCount: note.generation.excludedSegmentCount + note.generation.condensedSegmentCount
            )
        )
        trace.record(
            MeetingSkillRun(skill: .actionItemExtractor, succeeded: true, itemCount: note.actionItems.count)
        )
        if let report = note.generation.koreanEditor {
            trace.record(
                MeetingSkillRun(
                    skill: .koreanEditor,
                    succeeded: report.rolledBackFieldCount == 0,
                    itemCount: report.editedFieldCount,
                    notes: report.warnings
                )
            )
        }
        note.generation.skills = trace

        let evidenceBundle = EvidenceBundle.make(from: note)
        var evidenceURL: URL?
        let store = evidenceStore
        try await runStage(.persistNote, meetingId: meetingId, recorder: recorder, onUpdate: onUpdate) {
            try repository.updateRelevance(output.relevance)
            try repository.save(note: note)
            evidenceURL = try store.write(evidenceBundle, for: meeting)
            try repository.updateStatus(.completed, meetingId: meetingId)
        }

        await coordinator.releaseAll()

        // 회의록이 저장된 뒤에만 오디오를 정리한다. 실패한 회의의 오디오는 재시도의 유일한 수단이므로 남긴다(§11).
        applyRetention(meetingId: meetingId)

        let metrics = await recorder.all()
        for line in problems.prefix(20) {
            logSink?("문제: \(line)")
        }

        return Result(
            note: note,
            segments: segments,
            relevance: output.relevance,
            problems: problems,
            metrics: metrics,
            evidenceFileURL: evidenceURL,
            skills: trace
        )
    }

    /// 보관 정책에 따라 오디오를 정리한다. 실패해도 처리 결과에는 영향을 주지 않는다.
    private func applyRetention(meetingId: UUID) {
        let policy = retention()
        let service = AudioRetentionService(repository: repository, logSink: logSink)
        do {
            _ = try service.applyAfterProcessing(meetingId: meetingId, policy: policy)
            _ = try service.sweep(policy: policy)
        } catch {
            logSink?("오디오 정리 실패(회의록은 저장됨): \(error.localizedDescription)")
        }
    }

    /// 실패·중단된 회의를 다시 처리한다. 전사문이 남아 있으면 음성 인식을 건너뛴다.
    public func retry(
        meetingId: UUID,
        onUpdate: (@Sendable (Update) -> Void)? = nil
    ) async throws -> Result {
        try jobs.resetForRetry(meetingId: meetingId)
        return try await process(meetingId: meetingId, onUpdate: onUpdate)
    }

    // MARK: - 단계 실행

    private func runStage<T: Sendable>(
        _ stage: ProcessingStage,
        meetingId: UUID,
        recorder: StageMetricsRecorder,
        onUpdate: (@Sendable (Update) -> Void)?,
        _ body: sending () async throws -> T
    ) async throws -> T {
        // 사용자가 취소하면 다음 단계로 넘어가지 않는다. 이미 끝난 단계의 결과는 그대로 남는다.
        try Task.checkCancellation()

        let existing = try jobs.job(meetingId: meetingId, stage: stage)
        var job = existing ?? ProcessingJob(meetingId: meetingId, stage: stage)
        job.state = .running
        job.attempt = (existing?.attempt ?? 0) + 1
        job.startedAt = Date()
        job.errorMessage = nil
        try jobs.upsert(job)

        emit(onUpdate, stage: stage, fraction: Self.fraction(upTo: stage, within: 0), message: stage.displayName + " 시작")

        do {
            let value = try await recorder.record(stage.rawValue, body)
            job.state = .succeeded
            job.finishedAt = Date()
            try jobs.upsert(job)
            emit(onUpdate, stage: stage, fraction: Self.fraction(upTo: stage, within: 1), message: stage.displayName + " 완료")
            return value
        } catch {
            job.state = .failed
            job.finishedAt = Date()
            job.errorMessage = error.localizedDescription
            try? jobs.upsert(job)
            try? repository.updateStatus(.failed, meetingId: meetingId)
            logSink?("\(stage.displayName) 실패: \(error.localizedDescription)")
            throw error
        }
    }

    private func markSucceeded(_ stage: ProcessingStage, meetingId: UUID) throws {
        var job = try jobs.job(meetingId: meetingId, stage: stage)
            ?? ProcessingJob(meetingId: meetingId, stage: stage)
        job.state = .succeeded
        job.attempt = max(1, job.attempt)
        job.startedAt = job.startedAt ?? Date()
        job.finishedAt = Date()
        try jobs.upsert(job)
    }

    /// 기록된 경로에 파일이 없으면 현재 저장 위치에서 같은 회의의 파일을 찾는다.
    ///
    /// 데이터 폴더를 옮기거나 백업에서 복원하면 DB에 남은 절대 경로가 어긋난다.
    /// 원본이 남아 있는데 재처리가 막히는 것을 방지한다.
    public static func resolveAudioFile(for track: AudioTrack, meetingId: UUID) -> AudioTrack {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: track.fileURL.path) { return track }

        let storage = MeetingStorage.forMeeting(id: meetingId)
        let candidates = [
            storage.url(for: track.kind, extension: track.fileURL.pathExtension),
            storage.mixedDirectory.appendingPathComponent(track.fileURL.lastPathComponent),
            storage.rawDirectory.appendingPathComponent(track.fileURL.lastPathComponent)
        ]
        guard let found = candidates.first(where: { fileManager.fileExists(atPath: $0.path) }) else {
            return track
        }
        var updated = track
        updated.fileURL = found
        return updated
    }

    /// 단계 가중치를 누적해 전체 진행률을 만든다.
    static func fraction(upTo stage: ProcessingStage, within: Double) -> Double {
        var accumulated = 0.0
        for candidate in ProcessingStage.allCases {
            if candidate == stage {
                return min(1, accumulated + candidate.progressWeight * min(1, max(0, within)))
            }
            accumulated += candidate.progressWeight
        }
        return min(1, accumulated)
    }
}

public enum PipelineError: Error, LocalizedError, Sendable {
    case meetingNotFound(UUID)
    case audioTrackMissing(UUID)
    /// 다른 회의를 처리하는 중이다. 모델을 동시에 두 개 올리지 않기 위해 거부한다.
    case busy

    public var errorDescription: String? {
        switch self {
        case let .meetingNotFound(id): "회의를 찾을 수 없습니다: \(id)"
        case let .audioTrackMissing(id): "회의에 연결된 오디오 파일이 없습니다: \(id)"
        case .busy: "다른 회의를 처리하는 중입니다. 끝난 뒤에 다시 시도하세요."
        }
    }
}
