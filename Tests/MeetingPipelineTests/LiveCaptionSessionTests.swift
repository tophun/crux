import Foundation
@testable import MeetingAudio
@testable import MeetingCore
@testable import MeetingPersistence
@testable import MeetingPipeline
import Testing

actor FakeLiveAudioSource: LiveCaptionAudioProviding {
    private var chunks: [LiveAudioChunk]
    private var finished: [LiveAudioChunk]

    init(chunks: [LiveAudioChunk], finished: [LiveAudioChunk] = []) {
        self.chunks = chunks
        self.finished = finished
    }

    func nextCaptionChunks() async -> [LiveAudioChunk] {
        let next = chunks
        chunks = []
        return next
    }

    func finishCaptionChunks() async -> [LiveAudioChunk] {
        let leftover = finished
        finished = []
        return leftover
    }
}

@Suite("녹음 중 실시간 자막")
struct LiveCaptionSessionTests {
    @Test("가짜 엔진의 부분 결과로 지연 자막과 초안 요약을 만든다")
    func showsDelayedCaptionsFromFakeEngine() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("live-caption-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let audio = try TestAudio.makeSilentFile(directory: directory)
        let meetingId = UUID()
        let source = FakeLiveAudioSource(chunks: [
            LiveAudioChunk(url: audio, startOffset: 0, duration: 8),
            LiveAudioChunk(url: audio, startOffset: 8, duration: 8)
        ])
        let monitor = ModelResidencyMonitor()
        let engine = FakeTranscriptionEngine(monitor: monitor) { id in
            [
                TranscriptSegment(
                    meetingId: id, index: 0, startTime: 0, endTime: 4,
                    text: "배포는 수요일입니다.", confidence: 0.9
                )
            ]
        }
        let models = ModelLifecycleCoordinator(
            transcriptionEngine: engine,
            languageModel: ScriptedLanguageModel(monitor: monitor, responder: TestScripts.responder)
        )
        let session = LiveCaptionSession(
            meetingId: meetingId,
            source: source,
            models: models,
            configuration: LiveCaptionSession.Configuration(pollInterval: .milliseconds(20), summaryLimit: 80)
        )

        await session.start()
        try await Task.sleep(for: .milliseconds(120))
        let state = await session.stop()

        #expect(state.lines.count == 2)
        #expect(state.lines[0].startTime == 0)
        #expect(state.lines[1].startTime == 8)
        #expect(state.lines.allSatisfy { $0.text == "배포는 수요일입니다." })
        #expect(state.isDraft)
        #expect(state.draftSummary?.contains("배포는 수요일입니다.") == true)
        #expect(!state.isActive)
        #expect(await engine.callCount() == 2)

        let snapshot = await monitor.snapshot()
        #expect(!snapshot.violated)
        #expect(snapshot.events.contains("transcription.load"))
        #expect(!snapshot.events.contains("language.load"))
    }

    @Test("자막이 실패해도 세션은 멈추지 않고 다음 조각을 계속 전사한다")
    func captionFailureDoesNotStopSession() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("live-caption-fail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let audio = try TestAudio.makeSilentFile(directory: directory)
        let meetingId = UUID()
        let source = FakeLiveAudioSource(chunks: [
            LiveAudioChunk(url: audio, startOffset: 0, duration: 8),
            LiveAudioChunk(url: audio, startOffset: 8, duration: 8)
        ])

        let counter = CallCounter()
        let engine = FakeTranscriptionEngine { id in
            let call = counter.next()
            if call == 1 {
                throw TranscriptionEngineError.modelUnavailable("부분 결과 실패")
            }
            return [
                TranscriptSegment(
                    meetingId: id, index: 0, startTime: 0, endTime: 3,
                    text: "이어서 진행합니다.", confidence: 0.8
                )
            ]
        }
        let models = ModelLifecycleCoordinator(
            transcriptionEngine: engine,
            languageModel: ScriptedLanguageModel(responder: TestScripts.responder)
        )
        let session = LiveCaptionSession(
            meetingId: meetingId,
            source: source,
            models: models,
            configuration: LiveCaptionSession.Configuration(pollInterval: .milliseconds(20))
        )

        await session.start()
        try await Task.sleep(for: .milliseconds(150))
        let state = await session.stop()

        #expect(state.lines.count == 1)
        #expect(state.lines[0].text == "이어서 진행합니다.")
        #expect(state.isDraft)
        #expect(await engine.callCount() == 2)
    }

    @Test("초안이 있어도 전체 파이프라인은 전사를 다시 하고 초안 파일을 걷는다")
    func fullPipelineMergesAndReplacesDraft() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("live-caption-merge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try AppDatabase.inMemory()
        let repository = MeetingRepository(database: database)
        let jobs = ProcessingJobRepository(database: database)
        let audio = try TestAudio.makeSilentFile(directory: directory)
        let importer = MeetingImporter(repository: repository, baseDirectory: directory)
        let meeting = try importer.importAudio(at: audio, title: "초안 합치기").meeting

        let draft = LiveCaptionState(
            lines: [LiveCaptionLine(startTime: 0, endTime: 4, text: "녹음 중 초안 자막")],
            draftSummary: "녹음 중 초안 자막",
            isDraft: true
        )
        try LiveCaptionDraftStore.write(draft, to: meeting.storageDirectory)
        #expect(LiveCaptionDraftStore.load(from: meeting.storageDirectory)?.draftSummary == "녹음 중 초안 자막")

        let engine = FakeTranscriptionEngine { TestScripts.segments(meetingId: $0) }
        let pipeline = MeetingProcessingPipeline(
            repository: repository,
            jobs: jobs,
            coordinator: ModelLifecycleCoordinator(
                transcriptionEngine: engine,
                languageModel: ScriptedLanguageModel(responder: TestScripts.responder)
            )
        )
        let result = try await pipeline.process(meetingId: meeting.id)

        #expect(await engine.callCount() == 1)
        #expect(result.segments.contains(where: { $0.text.contains("결제 모듈") }))
        #expect(!result.segments.contains(where: { $0.text.contains("녹음 중 초안 자막") }))
        #expect(LiveCaptionDraftStore.load(from: meeting.storageDirectory) == nil)
    }
}

final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}
