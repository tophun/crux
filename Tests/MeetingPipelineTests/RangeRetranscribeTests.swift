import AVFoundation
import Foundation
@testable import MeetingAudio
@testable import MeetingCore
@testable import MeetingPersistence
@testable import MeetingPipeline
import Testing

@Suite("선택 구간 다시 전사")
struct RangeRetranscribeTests {
    let pipelineTests = ProcessingPipelineTests()

    func seedMeeting(_ harness: ProcessingPipelineTests.Harness, seconds: Double = 3) throws -> (
        meeting: Meeting,
        first: TranscriptSegment,
        middle: TranscriptSegment,
        last: TranscriptSegment,
        note: MeetingNote
    ) {
        let audio = try TestAudio.makeSilentFile(seconds: seconds, directory: harness.directory)
        let importer = MeetingImporter(repository: harness.repository, baseDirectory: harness.directory)
        let imported = try importer.importAudio(at: audio, title: "구간 재전사 회의")
        let meeting = imported.meeting
        try harness.repository.updateStatus(.completed, meetingId: meeting.id)

        let first = TranscriptSegment(
            meetingId: meeting.id, index: 0, startTime: 0, endTime: 1,
            text: "첫 구간 원문", confidence: 0.9
        )
        let middle = TranscriptSegment(
            meetingId: meeting.id, index: 1, startTime: 1, endTime: 2,
            text: "중간 구간 원문", confidence: 0.9
        )
        let last = TranscriptSegment(
            meetingId: meeting.id, index: 2, startTime: 2, endTime: 3,
            text: "마지막 구간 원문", confidence: 0.9
        )
        try harness.repository.save(segments: [first, middle, last], meetingId: meeting.id)

        let firstEvidence = Evidence(
            segmentId: first.id.uuidString, startTime: 0.2, endTime: 0.8, quote: "첫 구간 원문"
        )
        let middleEvidence = Evidence(
            segmentId: middle.id.uuidString, startTime: 1.2, endTime: 1.8, quote: "중간 구간 원문"
        )
        let lastEvidence = Evidence(
            segmentId: last.id.uuidString, startTime: 2.2, endTime: 2.8, quote: "마지막 구간 원문"
        )
        var note = MeetingNote(meetingId: meeting.id, title: "구간 재전사 회의", summary: "요약")
        note.decisions = [
            Decision(content: "첫 결정", kind: .decided, evidence: [firstEvidence], confidence: 0.9)
        ]
        note.actionItems = [
            ActionItem(task: "중간 액션", evidence: [middleEvidence], confidence: 0.9)
        ]
        note.risks = [
            RiskItem(content: "마지막 리스크", evidence: [lastEvidence], confidence: 0.7)
        ]
        try harness.repository.save(note: note)
        return (meeting, first, middle, last, note)
    }

    @Test("한 구간만 다시 돌려도 다른 구간과 기존 근거 시각이 깨지지 않는다")
    func retranscribeDoesNotClobberOtherRanges() async throws {
        let harness = try pipelineTests.makeHarness()
        let seeded = try seedMeeting(harness)
        let engine = FakeTranscriptionEngine { meetingId in
            [
                TranscriptSegment(
                    meetingId: meetingId, index: 0, startTime: 0, endTime: 1,
                    text: "중간 구간 수정됨", confidence: 0.95
                )
            ]
        }
        let model = ScriptedLanguageModel(responder: TestScripts.responder)
        let pipeline = pipelineTests.makePipeline(harness, transcription: engine, model: model)

        let result = try await pipeline.retranscribeRange(
            meetingId: seeded.meeting.id,
            startTime: 1,
            endTime: 2
        )

        #expect(await engine.callCount() == 1)
        #expect(await model.callCount() == 0, "기본은 전사만 해야 한다")

        let stored = try harness.repository.transcript(meetingId: seeded.meeting.id)
        #expect(stored.count == 3)
        #expect(stored[0].id == seeded.first.id)
        #expect(stored[0].text == "첫 구간 원문")
        #expect(stored[0].startTime == 0)
        #expect(stored[2].id == seeded.last.id)
        #expect(stored[2].text == "마지막 구간 원문")
        #expect(stored[2].startTime == 2)
        #expect(stored[1].text == "중간 구간 수정됨")
        #expect(stored[1].id != seeded.middle.id)
        #expect(stored[1].startTime == 1)
        #expect(stored[1].endTime == 2)

        let note = try #require(harness.repository.note(meetingId: seeded.meeting.id))
        #expect(note.decisions[0].evidence[0].startTime == 0.2)
        #expect(note.decisions[0].evidence[0].endTime == 0.8)
        #expect(note.actionItems[0].evidence[0].startTime == 1.2)
        #expect(note.actionItems[0].evidence[0].endTime == 1.8)
        #expect(note.risks[0].evidence[0].startTime == 2.2)
        #expect(note.summary == "요약")
        #expect(try harness.repository.meeting(id: seeded.meeting.id)?.status == .completed)
        #expect(result.note.decisions[0].evidence[0].startTime == 0.2)
    }

    @Test("Whisper에는 선택 구간의 오디오만 넣는다")
    func sendsOnlySelectedRangeAudio() async throws {
        let harness = try pipelineTests.makeHarness()
        let seeded = try seedMeeting(harness)
        let engine = FakeTranscriptionEngine { meetingId in
            [
                TranscriptSegment(
                    meetingId: meetingId, index: 0, startTime: 0, endTime: 1,
                    text: "중간 구간 수정됨", confidence: 0.9
                )
            ]
        }
        let pipeline = pipelineTests.makePipeline(harness, transcription: engine)

        _ = try await pipeline.retranscribeRange(
            meetingId: seeded.meeting.id,
            startTime: 1,
            endTime: 2
        )

        let urls = await engine.recordedURLs()
        let clip = try #require(urls.first)
        let duration = try #require(await engine.recordedDurations().first)
        #expect(duration > 0.7)
        #expect(duration < 1.4)
        let original = try #require(try harness.repository.tracks(meetingId: seeded.meeting.id).first)
        #expect(clip != original.fileURL)
        #expect(clip.lastPathComponent.contains("crux-retranscribe"))
    }

    @Test("전사 실패는 다른 구간과 근거를 덮어쓰지 않는다")
    func failureLeavesExistingTranscript() async throws {
        let harness = try pipelineTests.makeHarness()
        let seeded = try seedMeeting(harness)
        let engine = FakeTranscriptionEngine(
            failure: TranscriptionEngineError.modelUnavailable("구간 실패")
        ) { TestScripts.segments(meetingId: $0) }
        let pipeline = pipelineTests.makePipeline(harness, transcription: engine)

        await #expect(throws: (any Error).self) {
            _ = try await pipeline.retranscribeRange(
                meetingId: seeded.meeting.id,
                startTime: 1,
                endTime: 2
            )
        }

        let stored = try harness.repository.transcript(meetingId: seeded.meeting.id)
        #expect(stored.map(\.id) == [seeded.first.id, seeded.middle.id, seeded.last.id])
        #expect(stored[1].text == "중간 구간 원문")
        let note = try #require(harness.repository.note(meetingId: seeded.meeting.id))
        #expect(note.actionItems[0].evidence[0].startTime == 1.2)
        #expect(try harness.repository.meeting(id: seeded.meeting.id)?.status == .completed)
    }

    @Test("옵션으로 그 구간 항목만 다시 뽑아도 바깥 근거는 남는다")
    func optionalNotesReextractKeepsOutsideEvidence() async throws {
        let harness = try pipelineTests.makeHarness()
        let seeded = try seedMeeting(harness)
        let engine = FakeTranscriptionEngine { meetingId in
            [
                TranscriptSegment(
                    meetingId: meetingId, index: 0, startTime: 0, endTime: 1,
                    text: "결제 모듈 배포는 3월 12일 수요일로 확정합니다.", confidence: 0.95
                )
            ]
        }
        let model = ScriptedLanguageModel(responder: TestScripts.responder)
        let pipeline = pipelineTests.makePipeline(harness, transcription: engine, model: model)

        let result = try await pipeline.retranscribeRange(
            meetingId: seeded.meeting.id,
            startTime: 1,
            endTime: 2,
            reextractNotes: true
        )

        #expect(await model.callCount() > 0)
        #expect(result.note.decisions.contains { $0.evidence.contains { $0.startTime == 0.2 } })
        #expect(result.note.risks[0].evidence[0].startTime == 2.2)
        #expect(result.note.summary == "요약")
        #expect(result.note.title == "구간 재전사 회의")
    }

    @Test("구간 재전사 중에도 두 모델이 동시에 상주하지 않는다")
    func modelsNeverCoResidentDuringRangeRetranscribe() async throws {
        let harness = try pipelineTests.makeHarness()
        let seeded = try seedMeeting(harness)
        let monitor = ModelResidencyMonitor()
        let pipeline = MeetingProcessingPipeline(
            repository: harness.repository,
            jobs: harness.jobs,
            coordinator: ModelLifecycleCoordinator(
                transcriptionEngine: FakeTranscriptionEngine(monitor: monitor) { meetingId in
                    [
                        TranscriptSegment(
                            meetingId: meetingId, index: 0, startTime: 0, endTime: 1,
                            text: "결제 모듈 배포는 3월 12일 수요일로 확정합니다.", confidence: 0.9
                        )
                    ]
                },
                languageModel: ScriptedLanguageModel(monitor: monitor, responder: TestScripts.responder)
            )
        )

        _ = try await pipeline.retranscribeRange(
            meetingId: seeded.meeting.id,
            startTime: 1,
            endTime: 2,
            reextractNotes: true
        )
        let snapshot = await monitor.snapshot()
        #expect(!snapshot.violated, "\(snapshot.events)")
        #expect(snapshot.events.contains("transcription.unload"))
        #expect(snapshot.events.last == "language.unload")
    }

    @Test("잘못된 구간은 거절한다")
    func rejectsInvalidRange() async throws {
        let harness = try pipelineTests.makeHarness()
        let seeded = try seedMeeting(harness)
        let pipeline = pipelineTests.makePipeline(
            harness,
            transcription: FakeTranscriptionEngine { TestScripts.segments(meetingId: $0) }
        )
        await #expect(throws: PipelineError.self) {
            _ = try await pipeline.retranscribeRange(
                meetingId: seeded.meeting.id,
                startTime: 2,
                endTime: 1
            )
        }
        #expect(try harness.repository.transcript(meetingId: seeded.meeting.id).count == 3)
    }
}

@Suite("오디오 구간 추출")
struct AudioRangeExtractorTests {
    @Test("원본에서 선택 구간만 잘라 내고 원본은 남긴다")
    func extractsOnlySelectedRange() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clip-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = try TestAudio.makeSilentFile(seconds: 3.0, directory: directory)
        let output = directory.appendingPathComponent("clip.caf")

        let clip = try AudioRangeExtractor.extract(
            from: source,
            range: TimeRange(start: 1, end: 2),
            to: output
        )
        #expect(clip.info.duration > 0.7)
        #expect(clip.info.duration < 1.4)
        #expect(clip.range.start == 1)
        #expect(clip.range.end == 2)
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(FileManager.default.fileExists(atPath: output.path))
    }
}
