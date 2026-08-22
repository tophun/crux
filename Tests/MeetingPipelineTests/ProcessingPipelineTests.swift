import AVFoundation
import Foundation
@testable import MeetingAudio
@testable import MeetingCore
@testable import MeetingPersistence
@testable import MeetingPipeline
import Testing

@Suite("회의 처리 파이프라인")
struct ProcessingPipelineTests {
    struct Harness {
        var database: AppDatabase
        var repository: MeetingRepository
        var jobs: ProcessingJobRepository
        var directory: URL
    }

    func makeHarness() throws -> Harness {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("meeting-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try AppDatabase.inMemory()
        return Harness(
            database: database,
            repository: MeetingRepository(database: database),
            jobs: ProcessingJobRepository(database: database),
            directory: directory
        )
    }

    func importMeeting(_ harness: Harness, corrupt: Bool = false) throws -> Meeting {
        let audio = corrupt
            ? try TestAudio.makeCorruptFile(directory: harness.directory)
            : try TestAudio.makeSilentFile(directory: harness.directory)
        let importer = MeetingImporter(repository: harness.repository, baseDirectory: harness.directory)
        if corrupt {
            // 손상 파일은 가져오기 단계에서 걸러지므로 회의를 직접 만들어 파이프라인 단계를 검증한다.
            let meeting = Meeting(
                title: "손상 회의",
                startedAt: Date(),
                storageDirectory: harness.directory
            )
            try harness.repository.save(meeting)
            try harness.repository.save(tracks: [
                AudioTrack(
                    meetingId: meeting.id,
                    kind: .mixed,
                    fileURL: audio,
                    duration: 60,
                    sampleRate: 16000,
                    channelCount: 1,
                    byteSize: 100
                )
            ])
            return meeting
        }
        return try importer.importAudio(at: audio, title: "테스트 회의").meeting
    }

    func makePipeline(
        _ harness: Harness,
        transcription: FakeTranscriptionEngine,
        model: ScriptedLanguageModel = ScriptedLanguageModel(responder: TestScripts.responder)
    ) -> MeetingProcessingPipeline {
        MeetingProcessingPipeline(
            repository: harness.repository,
            jobs: harness.jobs,
            coordinator: ModelLifecycleCoordinator(transcriptionEngine: transcription, languageModel: model)
        )
    }

    @Test("오디오 파일에서 회의록까지 생성하고 저장한다")
    func endToEndWithFakes() async throws {
        let harness = try makeHarness()
        let meeting = try importMeeting(harness)
        let engine = FakeTranscriptionEngine { TestScripts.segments(meetingId: $0) }
        let pipeline = makePipeline(harness, transcription: engine)

        let collector = FractionCollector()
        let result = try await pipeline.process(meetingId: meeting.id) { update in
            collector.append(update.fraction)
        }
        let fractions = collector.values()

        #expect(result.note.decisions.count == 1)
        #expect(result.note.decisions[0].kind == .decided)
        #expect(result.note.actionItems[0].assignee == "홍길동")
        // 근거 타임스탬프가 실제 전사 구간에 연결된다.
        #expect(result.note.actionItems[0].evidence.first?.startTime == 16)

        // 저장 확인
        #expect(try harness.repository.note(meetingId: meeting.id)?.decisions.count == 1)
        #expect(try harness.repository.meeting(id: meeting.id)?.status == .completed)
        #expect(try harness.repository.transcript(meetingId: meeting.id).count == 3)

        // 사담 판정이 함께 저장된다.
        let relevance = try harness.repository.relevance(meetingId: meeting.id)
        #expect(relevance.contains { $0.label == .exclude })

        // 모든 단계가 성공으로 기록된다.
        let jobs = try harness.jobs.jobs(meetingId: meeting.id)
        #expect(jobs.count == ProcessingStage.allCases.count)
        #expect(jobs.allSatisfy { $0.state == .succeeded })

        // 진행률은 단조 증가한다.
        #expect(fractions == fractions.sorted())
        #expect(fractions.last ?? 0 > 0.9)

        // 단계별 시간·메모리가 기록된다.
        #expect(result.metrics.contains { $0.stage == ProcessingStage.transcribe.rawValue })
        #expect(result.metrics.allSatisfy { $0.residentBytes > 0 })
    }

    @Test("전사 실패는 작업을 실패로 기록하고 재처리로 복구된다")
    func retryAfterTranscriptionFailure() async throws {
        let harness = try makeHarness()
        let meeting = try importMeeting(harness)

        let failing = FakeTranscriptionEngine(
            failure: TranscriptionEngineError.modelUnavailable("테스트 실패")
        ) { TestScripts.segments(meetingId: $0) }
        let failingPipeline = makePipeline(harness, transcription: failing)

        await #expect(throws: (any Error).self) {
            _ = try await failingPipeline.process(meetingId: meeting.id)
        }
        #expect(try harness.repository.meeting(id: meeting.id)?.status == .failed)
        let failedJob = try harness.jobs.job(meetingId: meeting.id, stage: .transcribe)
        #expect(failedJob?.state == .failed)
        #expect(failedJob?.errorMessage != nil)
        #expect(try harness.jobs.meetingsNeedingRetry().contains(meeting.id))
        // 원본 오디오는 남아 있어 재처리가 가능하다.
        #expect(try harness.repository.tracks(meetingId: meeting.id).count == 1)

        // 재처리
        let working = FakeTranscriptionEngine { TestScripts.segments(meetingId: $0) }
        let pipeline = makePipeline(harness, transcription: working)
        let result = try await pipeline.retry(meetingId: meeting.id)
        #expect(result.note.decisions.count == 1)
        #expect(try harness.repository.meeting(id: meeting.id)?.status == .completed)
        let retriedJob = try harness.jobs.job(meetingId: meeting.id, stage: .transcribe)
        #expect(retriedJob?.state == .succeeded)
        #expect((retriedJob?.attempt ?? 0) >= 2)
    }

    @Test("앱이 강제 종료된 뒤에는 전사문을 재사용해 회의록만 다시 만든다")
    func resumesFromExistingTranscript() async throws {
        let harness = try makeHarness()
        let meeting = try importMeeting(harness)
        // 전사까지 끝난 상태를 재현한다.
        try harness.repository.save(segments: TestScripts.segments(meetingId: meeting.id), meetingId: meeting.id)
        try harness.jobs.upsert(
            ProcessingJob(meetingId: meeting.id, stage: .transcribe, state: .interrupted, attempt: 1)
        )

        let engine = FakeTranscriptionEngine { TestScripts.segments(meetingId: $0) }
        let pipeline = makePipeline(harness, transcription: engine)
        let result = try await pipeline.process(meetingId: meeting.id)

        #expect(await engine.callCount() == 0, "전사를 다시 수행했다")
        #expect(result.note.decisions.count == 1)
        #expect(result.segments.count == 3)
    }

    @Test("손상된 오디오는 준비 단계에서 걸러진다")
    func failsFastOnCorruptAudio() async throws {
        let harness = try makeHarness()
        let meeting = try importMeeting(harness, corrupt: true)
        let engine = FakeTranscriptionEngine { TestScripts.segments(meetingId: $0) }
        let pipeline = makePipeline(harness, transcription: engine)

        await #expect(throws: (any Error).self) {
            _ = try await pipeline.process(meetingId: meeting.id)
        }
        #expect(await engine.callCount() == 0)
        #expect(try harness.jobs.job(meetingId: meeting.id, stage: .prepareAudio)?.state == .failed)
        #expect(try harness.repository.meeting(id: meeting.id)?.status == .failed)
    }

    @Test("처리 중에도 두 모델이 동시에 상주하지 않는다")
    func modelsNeverCoResidentDuringProcessing() async throws {
        let harness = try makeHarness()
        let meeting = try importMeeting(harness)
        let monitor = ModelResidencyMonitor()
        let pipeline = MeetingProcessingPipeline(
            repository: harness.repository,
            jobs: harness.jobs,
            coordinator: ModelLifecycleCoordinator(
                transcriptionEngine: FakeTranscriptionEngine(monitor: monitor) {
                    TestScripts.segments(meetingId: $0)
                },
                languageModel: ScriptedLanguageModel(monitor: monitor, responder: TestScripts.responder)
            )
        )
        _ = try await pipeline.process(meetingId: meeting.id)
        let snapshot = await monitor.snapshot()
        #expect(!snapshot.violated, "\(snapshot.events)")
        // 처리가 끝나면 모델이 모두 내려간다.
        #expect(snapshot.events.last == "language.unload")
    }

    @Test("존재하지 않는 회의는 오류로 처리한다")
    func rejectsUnknownMeeting() async throws {
        let harness = try makeHarness()
        let pipeline = makePipeline(
            harness,
            transcription: FakeTranscriptionEngine { TestScripts.segments(meetingId: $0) }
        )
        await #expect(throws: PipelineError.self) {
            _ = try await pipeline.process(meetingId: UUID())
        }
    }

    @Test("가져오기는 오디오를 회의 디렉터리로 복사하고 메타데이터만 DB에 저장한다")
    func importCopiesAudio() throws {
        let harness = try makeHarness()
        let audio = try TestAudio.makeSilentFile(directory: harness.directory)
        let importer = MeetingImporter(repository: harness.repository, baseDirectory: harness.directory)
        let imported = try importer.importAudio(at: audio, title: "복사 테스트")

        #expect(imported.track.fileURL != audio)
        #expect(FileManager.default.fileExists(atPath: imported.track.fileURL.path))
        #expect(imported.track.duration > 0.9)
        #expect(imported.track.byteSize > 0)
        // DB에는 경로만 저장된다.
        let stored = try harness.repository.tracks(meetingId: imported.meeting.id)
        #expect(stored.count == 1)
        #expect(stored[0].fileURL.path.contains(imported.meeting.id.uuidString))
    }
}

@Suite("오디오 합성")
struct AudioMixerTests {
    @Test("두 트랙을 하나의 mixed 파일로 합친다")
    func mixesTwoTracks() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mixer-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let microphone = try TestAudio.makeSilentFile(seconds: 1.0, directory: directory)
        let system = try TestAudio.makeSilentFile(seconds: 1.5, directory: directory)
        let output = directory.appendingPathComponent("meeting.m4a")

        let info = try await AudioMixer.mix(inputs: [microphone, system], output: output)
        #expect(FileManager.default.fileExists(atPath: output.path))
        #expect(info.duration > 1.0)
        // 원본 트랙은 지우지 않는다.
        #expect(FileManager.default.fileExists(atPath: microphone.path))
        #expect(FileManager.default.fileExists(atPath: system.path))
    }

    @Test("트랙이 하나면 그대로 복사한다")
    func copiesSingleTrack() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mixer-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let microphone = try TestAudio.makeSilentFile(seconds: 1.0, directory: directory)
        let output = directory.appendingPathComponent("meeting.caf")

        let info = try await AudioMixer.mix(inputs: [microphone], output: output)
        #expect(info.duration > 0.9)
        #expect(FileManager.default.fileExists(atPath: output.path))
    }

    @Test("합성 결과는 16kHz 모노로 인코딩된다 — 보관 용량을 줄인다")
    func encodesAtLowBitrate() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mixer-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let microphone = try TestAudio.makeSilentFile(seconds: 2.0, directory: directory)
        let system = try TestAudio.makeSilentFile(seconds: 2.0, directory: directory)
        let output = directory.appendingPathComponent("meeting.m4a")

        _ = try await AudioMixer.mix(inputs: [microphone, system], output: output)

        let asset = AVURLAsset(url: output)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let track = try #require(tracks.first)
        let descriptions = try await track.load(.formatDescriptions)
        let description = try #require(descriptions.first)
        let basic = try #require(CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee)
        #expect(basic.mSampleRate == 16000)
        #expect(basic.mChannelsPerFrame == 1)
    }

    @Test("합칠 파일이 없으면 오류를 던진다")
    func failsWithoutInputs() async {
        await #expect(throws: (any Error).self) {
            _ = try await AudioMixer.mix(
                inputs: [URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID().uuidString).m4a")],
                output: URL(fileURLWithPath: NSTemporaryDirectory() + "/out.m4a")
            )
        }
    }
}

@Suite("동시 처리 차단")
struct ConcurrentProcessingTests {
    @Test("두 회의를 동시에 처리하지 않는다 — 모델이 동시에 올라가는 것을 막는다")
    func rejectsConcurrentProcessing() async throws {
        let harness = try ProcessingPipelineTests().makeHarness()
        let first = try ProcessingPipelineTests().importMeeting(harness)
        let second = try ProcessingPipelineTests().importMeeting(harness)

        let monitor = ModelResidencyMonitor()
        let pipeline = MeetingProcessingPipeline(
            repository: harness.repository,
            jobs: harness.jobs,
            coordinator: ModelLifecycleCoordinator(
                transcriptionEngine: FakeTranscriptionEngine(
                    monitor: monitor,
                    delay: .milliseconds(300)
                ) { TestScripts.segments(meetingId: $0) },
                languageModel: ScriptedLanguageModel(monitor: monitor, responder: TestScripts.responder)
            )
        )

        async let firstResult = pipeline.process(meetingId: first.id)
        // 첫 처리가 전사 단계에 머무는 동안 두 번째를 시도한다.
        try await Task.sleep(for: .milliseconds(60))
        await #expect(throws: PipelineError.self) {
            _ = try await pipeline.process(meetingId: second.id)
        }

        let result = try await firstResult
        #expect(result.note.decisions.count == 1)
        let snapshot = await monitor.snapshot()
        #expect(!snapshot.violated, "\(snapshot.events)")

        // 첫 처리가 끝난 뒤에는 두 번째도 처리된다.
        let secondResult = try await pipeline.process(meetingId: second.id)
        #expect(secondResult.note.decisions.count == 1)
    }
}

@Suite("오디오 경로 자가 복구")
struct AudioPathHealingTests {
    @Test("데이터 폴더가 옮겨져 경로가 어긋나도 현재 위치에서 파일을 찾는다")
    func healsMovedPath() throws {
        let meetingId = UUID()
        let storage = MeetingStorage.forMeeting(id: meetingId)
        try storage.createDirectories()
        defer { try? FileManager.default.removeItem(at: storage.root) }

        let realURL = storage.url(for: .mixed, extension: "m4a")
        try Data("audio".utf8).write(to: realURL)

        // DB에 남아 있는 옛 경로
        let stale = AudioTrack(
            meetingId: meetingId,
            kind: .mixed,
            fileURL: URL(fileURLWithPath: "/Users/nobody/Old Location/meetings/\(meetingId)/mixed/meeting.m4a"),
            duration: 30,
            sampleRate: 48000,
            channelCount: 1,
            byteSize: 5
        )
        let resolved = MeetingProcessingPipeline.resolveAudioFile(for: stale, meetingId: meetingId)
        #expect(resolved.fileURL == realURL)
        #expect(resolved.id == stale.id)
    }

    @Test("파일이 실제로 없으면 원래 경로를 그대로 둔다")
    func keepsPathWhenFileMissing() {
        let meetingId = UUID()
        let missing = AudioTrack(
            meetingId: meetingId,
            kind: .mixed,
            fileURL: URL(fileURLWithPath: "/tmp/definitely-missing-\(meetingId).m4a"),
            duration: 1,
            sampleRate: 48000,
            channelCount: 1,
            byteSize: 1
        )
        let resolved = MeetingProcessingPipeline.resolveAudioFile(for: missing, meetingId: meetingId)
        #expect(resolved.fileURL == missing.fileURL)
    }
}

@Suite("회의 삭제")
struct MeetingDeleterTests {
    struct Harness {
        var repository: MeetingRepository
        var deleter: MeetingDeleter
        var directory: URL
    }

    func makeHarness() throws -> Harness {
        let database = try AppDatabase.inMemory()
        let repository = MeetingRepository(database: database)
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("delete-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return Harness(
            repository: repository,
            deleter: MeetingDeleter(repository: repository),
            directory: directory
        )
    }

    /// 녹음까지 끝난 회의 한 건을 만든다.
    func makeMeeting(_ harness: Harness, copyAudioIntoStorage: Bool = true) throws -> (Meeting, URL) {
        let meetingId = UUID()
        let storage = MeetingStorage.forMeeting(id: meetingId, base: harness.directory)
        try storage.createDirectories()

        let audioURL: URL = if copyAudioIntoStorage {
            storage.url(for: .mixed, extension: "m4a")
        } else {
            // 사용자가 가져온 원본을 복사하지 않고 참조만 한 경우
            harness.directory.appendingPathComponent("사용자원본.m4a")
        }
        try Data("audio".utf8).write(to: audioURL)

        let meeting = Meeting(
            id: meetingId,
            title: "삭제 테스트 회의",
            startedAt: Date(),
            status: .completed,
            storageDirectory: storage.root
        )
        try harness.repository.save(meeting)
        try harness.repository.save(tracks: [
            AudioTrack(
                meetingId: meetingId, kind: .mixed, fileURL: audioURL,
                duration: 30, sampleRate: 48000, channelCount: 1, byteSize: 5
            )
        ])
        let segments = [
            TranscriptSegment(
                meetingId: meetingId, index: 0, startTime: 0, endTime: 5,
                text: "배포일을 3월 12일로 확정합니다.", confidence: 0.9
            )
        ]
        try harness.repository.save(segments: segments, meetingId: meetingId)

        var note = MeetingNote(meetingId: meetingId, title: "삭제 테스트 회의", summary: "요약")
        note.decisions = [Decision(content: "배포일 확정", kind: .decided, confidence: 0.9)]
        try harness.repository.save(note: note)

        // 근거 파일
        let evidenceStore = EvidenceFileStore()
        try evidenceStore.write(EvidenceBundle.make(from: note), for: meeting)

        return (meeting, audioURL)
    }

    @Test("회의를 지우면 오디오·전사문·회의록·근거 파일이 모두 사라진다")
    func deletesEverything() throws {
        let harness = try makeHarness()
        let (meeting, audioURL) = try makeMeeting(harness)
        let evidenceURL = EvidenceFileStore().url(for: meeting)
        #expect(FileManager.default.fileExists(atPath: evidenceURL.path))

        let summary = try harness.deleter.delete(meetingId: meeting.id)

        #expect(summary.meetingTitle == "삭제 테스트 회의")
        #expect(summary.trashedItemCount >= 1)
        #expect(summary.keptExternalFiles.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: audioURL.path))
        #expect(!FileManager.default.fileExists(atPath: meeting.storageDirectory.path))
        #expect(try harness.repository.meeting(id: meeting.id) == nil)
        #expect(try harness.repository.transcript(meetingId: meeting.id).isEmpty)
        #expect(try harness.repository.note(meetingId: meeting.id) == nil)
        #expect(try harness.repository.tracks(meetingId: meeting.id).isEmpty)
    }

    @Test("가져오기만 한 사용자 원본 파일은 지우지 않는다")
    func keepsExternalOriginal() throws {
        let harness = try makeHarness()
        let (meeting, externalURL) = try makeMeeting(harness, copyAudioIntoStorage: false)

        let summary = try harness.deleter.delete(meetingId: meeting.id)

        #expect(summary.keptExternalFiles.contains(externalURL.standardizedFileURL))
        #expect(FileManager.default.fileExists(atPath: externalURL.path), "사용자 원본이 삭제됐다")
        #expect(try harness.repository.meeting(id: meeting.id) == nil)
    }

    @Test("파일을 남기고 기록만 지울 수 있다")
    func canKeepFiles() throws {
        let harness = try makeHarness()
        let (meeting, audioURL) = try makeMeeting(harness)

        _ = try harness.deleter.delete(meetingId: meeting.id, removeFiles: false)

        #expect(FileManager.default.fileExists(atPath: audioURL.path))
        #expect(try harness.repository.meeting(id: meeting.id) == nil)
    }

    @Test("없는 회의를 지우려 하면 오류를 낸다")
    func rejectsUnknownMeeting() throws {
        let harness = try makeHarness()
        #expect(throws: PipelineError.self) {
            try harness.deleter.delete(meetingId: UUID())
        }
    }

    @Test("회의 디렉터리 안팎을 정확히 구분한다")
    func distinguishesInsideAndOutside() {
        let root = URL(fileURLWithPath: "/Users/me/Library/Application Support/Crux/meetings/abc")
        #expect(MeetingDeleter.isInside(root.appendingPathComponent("raw/microphone.m4a"), root: root))
        #expect(!MeetingDeleter.isInside(URL(fileURLWithPath: "/Users/me/Desktop/회의.m4a"), root: root))
        // 접두어만 같은 다른 디렉터리를 안쪽으로 착각하면 안 된다.
        #expect(!MeetingDeleter.isInside(URL(fileURLWithPath: "\(root.path)-backup/x.m4a"), root: root))
    }
}
