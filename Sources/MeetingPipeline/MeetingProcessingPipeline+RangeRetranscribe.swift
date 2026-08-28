import Foundation
import MeetingAudio
import MeetingCore

/// 틀린 구간만 다시 전사한다. 본체 파일의 타입 길이를 넘지 않도록 분리했다.
public extension MeetingProcessingPipeline {
    /// 선택한 시간 구간만 다시 전사한다. 기본은 전사문만 바꾸고 회의록·근거 시각은 유지한다.
    ///
    /// Whisper에는 그 구간의 오디오만 넣는다. 나머지 구간의 id와 텍스트는 그대로 둔다.
    /// `reextractNotes`가 true여도 선택 구간과 겹치는 항목만 갈아 끼운다.
    /// 실패해도 회의 상태와 기존 전사·근거는 그대로 둔다.
    func retranscribeRange(
        meetingId: UUID,
        startTime: TimeInterval,
        endTime: TimeInterval,
        reextractNotes: Bool = false,
        onUpdate: (@Sendable (Update) -> Void)? = nil
    ) async throws -> Result {
        guard !isProcessing else { throw PipelineError.busy }
        isProcessing = true
        defer { isProcessing = false }
        lastReportedFraction = 0

        guard let meeting = try repository.meeting(id: meetingId) else {
            throw PipelineError.meetingNotFound(meetingId)
        }

        let requested = TimeRange(start: startTime, end: endTime)
        guard requested.isValid else { throw PipelineError.invalidTimeRange }

        let sink = logSink
        let recorder = StageMetricsRecorder(sink: { metric in sink?(metric.description) })
        let track = try resolveTrack(meetingId: meetingId)
        let range = requested.clamped(toDuration: track.duration)
        guard range.isValid else { throw PipelineError.invalidTimeRange }

        let existing = try repository.transcript(meetingId: meetingId)
        let existingRelevance = try repository.relevance(meetingId: meetingId)
        let existingNote = try repository.note(meetingId: meetingId) ?? MeetingNote(meetingId: meetingId)

        let clipURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("crux-retranscribe-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: clipURL) }

        do {
            return try await performRangeRetranscribe(
                RangeRetranscribeInput(
                    meeting: meeting,
                    audioURL: track.fileURL,
                    existing: existing,
                    existingRelevance: existingRelevance,
                    existingNote: existingNote,
                    range: range,
                    clipURL: clipURL,
                    reextractNotes: reextractNotes
                ),
                recorder: recorder,
                onUpdate: onUpdate
            )
        } catch {
            await coordinator.releaseAll()
            throw error
        }
    }
}

struct RangeRetranscribeInput: Sendable {
    var meeting: Meeting
    var audioURL: URL
    var existing: [TranscriptSegment]
    var existingRelevance: [RelevanceDecision]
    var existingNote: MeetingNote
    var range: TimeRange
    var clipURL: URL
    var reextractNotes: Bool
}

struct RangeNoteExtraction: Sendable {
    var note: MeetingNote
    var relevance: [RelevanceDecision]
    var problems: [String]
    var evidenceURL: URL?
}

extension MeetingProcessingPipeline {
    func performRangeRetranscribe(
        _ input: RangeRetranscribeInput,
        recorder: StageMetricsRecorder,
        onUpdate: (@Sendable (Update) -> Void)?
    ) async throws -> Result {
        emit(onUpdate, stage: .prepareAudio, fraction: 0.02, message: "선택 구간 오디오 준비")
        let clip = try await recorder.record(ProcessingStage.prepareAudio.rawValue) {
            try AudioRangeExtractor.extract(from: input.audioURL, range: input.range, to: input.clipURL)
        }
        logSink?(
            "선택 구간 \(TimeFormat.stamp(clip.range.start))–\(TimeFormat.stamp(clip.range.end))만 음성 인식"
        )

        let rawSegments = try await transcribeClip(
            url: input.clipURL,
            meetingId: input.meeting.id,
            recorder: recorder,
            onUpdate: onUpdate
        )
        let replacement = TranscriptRangePatcher.shifted(rawSegments, by: clip.range.start)
        let patched = TranscriptRangePatcher.patch(
            existing: input.existing,
            range: clip.range,
            replacement: replacement,
            meetingId: input.meeting.id
        )
        let keptRelevance = input.existingRelevance.filter { patched.keptIds.contains($0.segmentId) }
        try repository.save(segments: patched.segments, relevance: keptRelevance, meetingId: input.meeting.id)

        var problems: [String] = []
        var note = input.existingNote
        var relevance = keptRelevance
        var evidenceURL: URL?

        if input.reextractNotes {
            let extracted = try await extractRangeNotes(
                meeting: input.meeting,
                replacement: replacement,
                existingNote: input.existingNote,
                range: clip.range,
                keptRelevance: keptRelevance,
                recorder: recorder,
                onUpdate: onUpdate
            )
            note = extracted.note
            relevance = extracted.relevance
            problems = extracted.problems
            evidenceURL = extracted.evidenceURL
        } else {
            logSink?("회의록은 그대로 둡니다. 근거 타임스탬프를 유지합니다.")
            emit(onUpdate, stage: .persistNote, fraction: 1, message: "선택 구간 전사 저장")
        }

        let metrics = await recorder.all()
        for line in problems.prefix(20) {
            logSink?("문제: \(line)")
        }

        await coordinator.releaseAll()
        return Result(
            note: note,
            segments: patched.segments,
            relevance: relevance,
            problems: problems,
            metrics: metrics,
            evidenceFileURL: evidenceURL,
            skills: note.generation.skills ?? MeetingSkillTrace()
        )
    }

    /// 잘라 낸 오디오만 Whisper에 넣는다. 전체 작업 기록은 건드리지 않는다.
    func transcribeClip(
        url: URL,
        meetingId: UUID,
        recorder: StageMetricsRecorder,
        onUpdate: (@Sendable (Update) -> Void)?
    ) async throws -> [TranscriptSegment] {
        emit(onUpdate, stage: .transcribe, fraction: Self.fraction(upTo: .transcribe, within: 0), message: "선택 구간 음성 인식")
        let result = try await recorder.record(ProcessingStage.transcribe.rawValue) {
            try await coordinator.withTranscription { engine in
                try await engine.transcribe(
                    audioURL: url,
                    meetingId: meetingId,
                    language: language,
                    progress: { progress in
                        Task { [weak self] in
                            await self?.emit(
                                onUpdate,
                                stage: .transcribe,
                                fraction: Self.fraction(upTo: .transcribe, within: progress.fraction),
                                message: "선택 구간 인식 \(Int(progress.fraction * 100))%"
                            )
                        }
                    }
                )
            }
        }
        guard !result.isEmpty else { throw TranscriptionEngineError.emptyResult }
        emit(onUpdate, stage: .transcribe, fraction: Self.fraction(upTo: .transcribe, within: 1), message: "선택 구간 인식 완료")
        return result
    }

    /// 선택 구간의 새 전사만으로 항목을 뽑고, 바깥 항목·근거 시각은 유지한 채 저장한다.
    func extractRangeNotes(
        meeting: Meeting,
        replacement: [TranscriptSegment],
        existingNote: MeetingNote,
        range: TimeRange,
        keptRelevance: [RelevanceDecision],
        recorder: StageMetricsRecorder,
        onUpdate: (@Sendable (Update) -> Void)?
    ) async throws -> RangeNoteExtraction {
        emit(
            onUpdate,
            stage: .extractFacts,
            fraction: Self.fraction(upTo: .extractFacts, within: 0),
            message: "선택 구간 사실 추출"
        )
        let output = try await recorder.record(ProcessingStage.extractFacts.rawValue) {
            try await coordinator.withLanguageModel { model in
                let pipeline = LocalInferencePipeline(model: model, configuration: inferenceConfiguration)
                return try await pipeline.generateNote(
                    meetingId: meeting.id,
                    titleHint: meeting.title,
                    segments: replacement,
                    progress: { progress in
                        if case let .extracting(window, total) = progress {
                            Task { [weak self] in
                                await self?.emit(
                                    onUpdate,
                                    stage: .extractFacts,
                                    fraction: Self.fraction(
                                        upTo: .extractFacts,
                                        within: total > 0 ? Double(window) / Double(total) : 0
                                    ),
                                    message: "선택 구간 사실 추출 \(window)/\(total)"
                                )
                            }
                        }
                    }
                )
            }
        }
        let note = NoteRangeMerger.merge(existing: existingNote, incoming: output.note, range: range)
        let relevance = keptRelevance + output.relevance
        let evidenceURL = try evidenceStore.write(EvidenceBundle.make(from: note), for: meeting)
        try repository.updateRelevance(relevance)
        try repository.save(note: note)
        emit(onUpdate, stage: .persistNote, fraction: 1, message: "선택 구간 회의록 항목 저장")
        return RangeNoteExtraction(
            note: note,
            relevance: relevance,
            problems: output.problems,
            evidenceURL: evidenceURL
        )
    }

    /// 현재 위치의 합성(또는 유일한) 트랙을 고른다.
    func resolveTrack(meetingId: UUID) throws -> AudioTrack {
        let tracks = try repository.tracks(meetingId: meetingId)
        guard let selected = tracks.first(where: { $0.kind == .mixed }) ?? tracks.first else {
            throw PipelineError.audioTrackMissing(meetingId)
        }
        let resolved = Self.resolveAudioFile(for: selected, meetingId: meetingId)
        if resolved.fileURL != selected.fileURL {
            logSink?("오디오 경로를 현재 위치로 정정: \(resolved.fileURL.path)")
            try? repository.save(tracks: [resolved])
        }
        _ = try AudioFileInspector.inspect(url: resolved.fileURL)
        return resolved
    }
}
