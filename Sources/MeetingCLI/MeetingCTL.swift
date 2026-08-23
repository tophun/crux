import ArgumentParser
import Foundation
import MeetingAudio
import MeetingCalendar
import MeetingCore
import MeetingInference
import MeetingPersistence
import MeetingPipeline
import MeetingPublishing
import MeetingTranscription

/// 헤드리스 하네스. GUI 없이 전체 파이프라인을 실제 모델로 검증할 수 있게 한다.
@main
struct MeetingCTL: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "meetingctl",
        abstract: "온디바이스 회의록 파이프라인 CLI (모든 처리는 로컬에서 실행됩니다)",
        subcommands: [
            Run.self, Transcribe.self, Note.self, List.self, Show.self, Retry.self,
            Auth.self, CalendarCommand.self, Record.self, Preview.self, Publish.self,
            Delete.self, Retention.self, ModelsCommand.self
        ]
    )
}

struct CommonOptions: ParsableArguments {
    @Option(name: .long, help: "SQLite 파일 경로 (기본: 앱 데이터 디렉터리)")
    var db: String?

    @Option(name: .long, help: "WhisperKit 모델 이름")
    var whisperModel: String = WhisperKitTranscriptionEngine.Configuration().model

    @Option(name: .long, help: "MLX LLM 모델 식별자")
    var llmModel: String = Qwen3InferenceEngine.Configuration().modelId

    @Option(name: .long, help: "이미 내려받은 LLM 모델 디렉터리 (지정 시 네트워크 미사용)")
    var llmDirectory: String?

    @Option(name: .long, help: "인식 힌트 (회의에서 자주 쓰는 고유명사·약어를 쉼표로 구분)")
    var vocabulary: String?

    @Flag(name: .long, help: "모델 다운로드를 금지한다 (완전 오프라인 검증)")
    var offline: Bool = false

    @Flag(name: .long, help: "상세 로그 출력")
    var verbose: Bool = false

    func makeDatabase() throws -> AppDatabase {
        let url = db.map { URL(fileURLWithPath: $0) } ?? AppDatabase.defaultURL
        return try AppDatabase.open(at: url)
    }

    func makeCoordinator() -> ModelLifecycleCoordinator {
        let verbose = verbose
        let log: @Sendable (String) -> Void = { message in
            AppLog.shared.write(.model, message)
            if verbose {
                FileHandle.standardError.write(Data(("[model] " + message + "\n").utf8))
            }
        }
        var transcription = WhisperKitTranscriptionEngine.Configuration()
        transcription.model = whisperModel
        transcription.allowDownload = !offline
        transcription.vocabularyHint = vocabulary

        var inference = Qwen3InferenceEngine.Configuration()
        inference.modelId = llmModel
        inference.localDirectory = llmDirectory.map { URL(fileURLWithPath: $0) }

        return ModelLifecycleCoordinator(
            transcriptionEngine: WhisperKitTranscriptionEngine(configuration: transcription, log: log),
            languageModel: Qwen3InferenceEngine(configuration: inference, log: log),
            log: log
        )
    }

    func makePipeline(database: AppDatabase) -> MeetingProcessingPipeline {
        let verbose = verbose
        return MeetingProcessingPipeline(
            repository: MeetingRepository(database: database),
            jobs: ProcessingJobRepository(database: database),
            coordinator: makeCoordinator(),
            logSink: { message in
                AppLog.shared.write(.pipeline, message)
                if verbose {
                    FileHandle.standardError.write(Data(("[pipeline] " + message + "\n").utf8))
                }
            }
        )
    }
}

extension MeetingCTL {
    /// 로컬 오디오 파일 하나를 끝까지 처리한다 (Phase 1 완료 기준 검증용).
    struct Run: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "오디오 파일 → 전사 → 회의록 생성 → 저장")

        @OptionGroup var options: CommonOptions

        @Option(name: .long, help: "회의 오디오 파일 경로")
        var audio: String

        @Option(name: .long, help: "회의 제목")
        var title: String?

        @Option(name: .long, help: "회의록을 내보낼 디렉터리")
        var out: String?

        func run() async throws {
            let database = try options.makeDatabase()
            let repository = MeetingRepository(database: database)
            let importer = MeetingImporter(repository: repository)
            let imported = try importer.importAudio(
                at: URL(fileURLWithPath: audio),
                title: title
            )
            print("회의 생성: \(imported.meeting.id) (\(String(format: "%.1f", imported.track.duration))초)")

            let pipeline = options.makePipeline(database: database)
            let started = Date()
            let result = try await pipeline.process(meetingId: imported.meeting.id) { update in
                FileHandle.standardError.write(
                    Data("[\(Int(update.fraction * 100))%] \(update.message)\n".utf8)
                )
            }

            print("")
            print(MeetingNoteExporter.markdown(result.note, meeting: imported.meeting))
            print("")
            print("--- 처리 정보 ---")
            for metric in result.metrics {
                print(metric.description)
            }
            print(String(format: "총 소요 %.1f초", Date().timeIntervalSince(started)))
            print("구간 \(result.segments.count)개, 문제 \(result.problems.count)건")
            for problem in result.problems.prefix(15) {
                print("· \(problem)")
            }

            if let out {
                let directory = URL(fileURLWithPath: out)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let markdownURL = directory.appendingPathComponent("\(imported.meeting.id).md")
                let jsonURL = directory.appendingPathComponent("\(imported.meeting.id).json")
                try MeetingNoteExporter.markdown(result.note, meeting: imported.meeting)
                    .write(to: markdownURL, atomically: true, encoding: .utf8)
                try MeetingNoteExporter.json(result.note).write(to: jsonURL, options: .atomic)
                let transcriptURL = directory.appendingPathComponent("\(imported.meeting.id).transcript.txt")
                let transcript = result.segments.map {
                    "[\(TimeFormat.stamp($0.startTime))] \($0.text)"
                }.joined(separator: "\n")
                try transcript.write(to: transcriptURL, atomically: true, encoding: .utf8)
                print("내보냄: \(markdownURL.path), \(jsonURL.path), \(transcriptURL.path)")
            }
        }
    }

    /// 음성 인식만 수행한다.
    struct Transcribe: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "오디오 파일을 전사만 수행")

        @OptionGroup var options: CommonOptions

        @Option(name: .long) var audio: String

        func run() async throws {
            let verbose = options.verbose
            var configuration = WhisperKitTranscriptionEngine.Configuration()
            configuration.model = options.whisperModel
            configuration.allowDownload = !options.offline
            configuration.vocabularyHint = options.vocabulary
            let engine = WhisperKitTranscriptionEngine(configuration: configuration) { message in
                if verbose {
                    FileHandle.standardError.write(Data(("[whisper] " + message + "\n").utf8))
                }
            }
            let started = Date()
            let segments = try await engine.transcribe(
                audioURL: URL(fileURLWithPath: audio),
                meetingId: UUID(),
                language: "ko",
                progress: nil
            )
            await engine.unload()
            for segment in segments {
                let confidence = segment.confidence.map { String(format: " (%.2f)", $0) } ?? ""
                print("[\(TimeFormat.stamp(segment.startTime))-\(TimeFormat.stamp(segment.endTime))]\(confidence) \(segment.text)")
            }
            print(String(format: "구간 %d개, %.1f초 소요", segments.count, Date().timeIntervalSince(started)))
        }
    }

    /// 저장된 전사문으로 회의록만 다시 만든다 (LLM 단계만 검증).
    struct Note: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "저장된 전사문으로 회의록 재생성")

        @OptionGroup var options: CommonOptions

        @Option(name: .long, help: "회의 UUID") var meeting: String

        func run() async throws {
            guard let meetingId = UUID(uuidString: meeting) else {
                throw ValidationError("회의 UUID 형식이 아닙니다: \(meeting)")
            }
            let database = try options.makeDatabase()
            let repository = MeetingRepository(database: database)
            let segments = try repository.transcript(meetingId: meetingId)
            guard !segments.isEmpty else {
                throw ValidationError("저장된 전사문이 없습니다. 먼저 run 또는 transcribe를 실행하세요.")
            }
            guard let meetingRecord = try repository.meeting(id: meetingId) else {
                throw ValidationError("회의를 찾을 수 없습니다.")
            }

            var inference = Qwen3InferenceEngine.Configuration()
            inference.modelId = options.llmModel
            inference.localDirectory = options.llmDirectory.map { URL(fileURLWithPath: $0) }
            let verbose = options.verbose
            let model = Qwen3InferenceEngine(configuration: inference) { message in
                if verbose {
                    FileHandle.standardError.write(Data(("[llm] " + message + "\n").utf8))
                }
            }
            let pipeline = LocalInferencePipeline(model: model)
            let output = try await pipeline.generateNote(
                meetingId: meetingId,
                titleHint: meetingRecord.title,
                segments: segments,
                progress: { progress in
                    FileHandle.standardError.write(Data("\(progress)\n".utf8))
                }
            )
            await model.unload()
            try repository.updateRelevance(output.relevance)
            try repository.save(note: output.note)
            print(MeetingNoteExporter.markdown(output.note, meeting: meetingRecord))
            for problem in output.problems.prefix(15) {
                print("· \(problem)")
            }
        }
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "회의 목록")

        @OptionGroup var options: CommonOptions

        func run() throws {
            let database = try options.makeDatabase()
            let repository = MeetingRepository(database: database)
            for summary in try repository.summaries() {
                print(
                    "\(summary.meeting.id) | \(summary.meeting.status.displayName) | "
                        + "결정 \(summary.decisionCount) 액션 \(summary.actionItemCount) | \(summary.displayTitle)"
                )
            }
        }
    }

    struct Show: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "회의록 출력")

        @OptionGroup var options: CommonOptions

        @Option(name: .long) var meeting: String
        @Option(name: .long, help: "md 또는 json") var format: String = "md"

        func run() throws {
            guard let meetingId = UUID(uuidString: meeting) else {
                throw ValidationError("회의 UUID 형식이 아닙니다.")
            }
            let database = try options.makeDatabase()
            let repository = MeetingRepository(database: database)
            guard let note = try repository.note(meetingId: meetingId) else {
                throw ValidationError("저장된 회의록이 없습니다.")
            }
            if format == "json" {
                try print(MeetingNoteExporter.jsonString(note))
            } else {
                try print(MeetingNoteExporter.markdown(note, meeting: repository.meeting(id: meetingId)))
            }
        }
    }

    struct Retry: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "실패한 회의 재처리")

        @OptionGroup var options: CommonOptions

        @Option(name: .long) var meeting: String

        func run() async throws {
            guard let meetingId = UUID(uuidString: meeting) else {
                throw ValidationError("회의 UUID 형식이 아닙니다.")
            }
            let database = try options.makeDatabase()
            let pipeline = options.makePipeline(database: database)
            let result = try await pipeline.retry(meetingId: meetingId) { update in
                FileHandle.standardError.write(Data("[\(Int(update.fraction * 100))%] \(update.message)\n".utf8))
            }
            print(MeetingNoteExporter.markdown(result.note))
        }
    }
}

// MARK: - 요구사항 1·2·3·4: 캘린더 · 녹음 · 검토 · 게시

extension MeetingCTL {
    /// Atlassian 인증 정보 관리. 토큰은 명령 인자로 받지 않고 stdin으로만 받는다.
    struct Auth: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "auth",
            abstract: "Atlassian 인증 정보를 Keychain에 저장·확인·삭제 (토큰은 stdin으로만 입력)"
        )

        @Option(name: .long, help: "Atlassian 사이트 (예: your-team.atlassian.net)")
        var site: String?

        @Option(name: .long, help: "Atlassian 계정 이메일")
        var email: String?

        @Flag(name: .long, help: "저장된 인증 정보를 삭제한다")
        var delete: Bool = false

        @Flag(name: .long, help: "저장된 인증 정보로 연결을 확인한다")
        var verify: Bool = false

        func run() async throws {
            let store = KeychainCredentialStore()

            if delete {
                try store.delete()
                print("저장된 Atlassian 인증 정보를 삭제했습니다.")
                return
            }

            if let site, let email {
                FileHandle.standardError.write(Data("API 토큰을 입력하고 Enter를 누르세요 (화면에 표시되지 않도록 붙여넣기 후 바로 Enter): \n".utf8))
                guard let token = readLine(strippingNewline: true), !token.isEmpty else {
                    throw ValidationError("토큰이 입력되지 않았습니다.")
                }
                let credentials = AtlassianCredentials(site: site, email: email, apiToken: token)
                try store.save(credentials)
                print("저장했습니다: \(credentials.redactedDescription)")
            }

            guard let credentials = try ChainedCredentialStore().load() else {
                print("저장된 Atlassian 인증 정보가 없습니다. --site 와 --email 을 주고 다시 실행하세요.")
                return
            }
            print("현재 인증 정보: \(credentials.redactedDescription)")

            if verify {
                let client = AtlassianClient(credentials: credentials)
                let name = try await client.verifyConnection()
                print("연결 확인 완료: \(name)")
            }
        }
    }

    /// 캘린더 일정과 회의 감지 결과를 확인한다.
    struct CalendarCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "calendar",
            abstract: "캘린더 일정과 회의 감지 결과 확인 (EventKit, 네트워크 미사용)"
        )

        @OptionGroup var options: CommonOptions

        @Option(name: .long, help: "조회할 시간 범위(시간)")
        var hours: Int = 4

        func run() async throws {
            let provider = EventKitCalendarProvider()
            let status = provider.authorizationStatus()
            print("캘린더 권한: \(status.displayName)")
            if status != .authorized {
                let granted = try await provider.requestAccess()
                print("권한 요청 결과: \(granted ? "허용" : "거부")")
                guard granted else {
                    print("앱 번들(Info.plist의 NSCalendarsFullAccessUsageDescription)에서만 권한을 받을 수 있습니다.")
                    return
                }
            }

            let now = Date()
            let events = try await provider.events(
                from: now.addingTimeInterval(-3600),
                to: now.addingTimeInterval(Double(hours) * 3600)
            )
            let database = try options.makeDatabase()
            let repository = CalendarRepository(database: database)
            try repository.save(events: events)

            let policy = MeetingDetectionPolicy()
            let eligible = policy.eligibleEvents(events)
            print("일정 \(events.count)건, 회의록 대상 \(eligible.count)건")
            for event in eligible {
                let attendees = event.attendeeDisplayNames.joined(separator: ", ")
                print("- \(event.title) | \(event.startDate) | 참석자 \(event.attendees.count)명 (\(attendees))")
                if let url = event.conferenceURL {
                    print("  회의 링크: \(url.absoluteString)")
                }
            }

            let detector = ConferenceAppDetector()
            let apps = detector.detect()
            if !apps.isEmpty {
                print("실행 중인 회의 앱: " + apps.map { "\($0.appName)\($0.usesAudio ? "(마이크 사용 중)" : "")" }.joined(separator: ", "))
            }
            let verdict = try policy.decide(
                events: events,
                now: now,
                notifiedEventIds: repository.notifiedEventIds(),
                conferenceApps: apps
            )
            print("감지 결과: \(verdict)")
            if let message = policy.confirmationMessage(for: verdict) {
                print("캡슐 문구: \(message)")
            }
        }
    }

    /// 마이크·시스템 오디오를 녹음하고 회의록까지 생성한다.
    struct Record: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "녹음 후 회의록 생성 (마이크 + 가능하면 시스템 오디오)"
        )

        @OptionGroup var options: CommonOptions

        @Option(name: .long, help: "녹음 시간(초)")
        var seconds: Int = 30

        @Option(name: .long, help: "회의 제목")
        var title: String?

        @Flag(name: .long, help: "녹음만 하고 회의록은 만들지 않는다")
        var recordOnly: Bool = false

        func run() async throws {
            let database = try options.makeDatabase()
            let repository = MeetingRepository(database: database)
            let capture = MeetingAudioCapture(log: { message in
                FileHandle.standardError.write(Data(("[audio] " + message + "\n").utf8))
            })

            let micPermission = await capture.microphonePermission()
            print("마이크 권한: \(micPermission.displayName)")
            if micPermission != .granted {
                let result = await capture.requestPermissions()
                print("권한 요청 결과 — 마이크: \(result.microphone.displayName), 시스템 오디오: \(result.systemAudio.displayName)")
                guard result.microphone == .granted else {
                    throw ValidationError("마이크 권한이 없어 녹음할 수 없습니다.")
                }
            }

            let meetingId = UUID()
            let storage = MeetingStorage.forMeeting(id: meetingId)
            let meeting = Meeting(
                id: meetingId,
                title: title ?? "CLI 녹음 \(meetingId.uuidString.prefix(8))",
                startedAt: Date(),
                status: .recording,
                storageDirectory: storage.root,
                source: .liveCapture
            )
            try repository.save(meeting)

            try await capture.start(meetingId: meetingId, storage: storage)
            print("녹음 시작 — \(seconds)초")
            try await Task.sleep(for: .seconds(Double(seconds)))
            let tracks = try await capture.stop()
            let problems = await capture.problems
            for problem in problems {
                print("· \(problem)")
            }

            guard !tracks.isEmpty else { throw ValidationError("저장된 오디오가 없습니다.") }
            try repository.save(tracks: tracks)
            for track in tracks {
                print("\(track.kind.rawValue): \(track.fileURL.path) (\(String(format: "%.1f", track.duration))초)")
            }

            var updated = meeting
            updated.endedAt = Date()
            updated.status = .recorded
            try repository.save(updated)

            guard !recordOnly else { return }
            let pipeline = options.makePipeline(database: database)
            let result = try await pipeline.process(meetingId: meetingId) { update in
                FileHandle.standardError.write(Data("[\(Int(update.fraction * 100))%] \(update.message)\n".utf8))
            }
            print("")
            print(MeetingNoteExporter.markdown(result.note, meeting: updated))
            if let url = result.evidenceFileURL {
                print("근거 파일: \(url.path)")
            }
        }
    }

    /// 게시 전 검토 내용을 출력한다 (실제 전송 없음).
    struct Preview: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "게시할 내용과 품질 검증 결과를 출력 (전송하지 않음)"
        )

        @OptionGroup var options: CommonOptions

        @Option(name: .long) var meeting: String
        @Option(name: .long, help: "Confluence Space 키") var space: String
        @Option(name: .long, help: "Jira Project 키") var project: String
        @Option(name: .long, help: "기본 이슈 유형 (Task/Bug/Story)") var issueType: String = "Task"

        func run() throws {
            guard let meetingId = UUID(uuidString: meeting) else {
                throw ValidationError("회의 UUID 형식이 아닙니다.")
            }
            let database = try options.makeDatabase()
            let preparation = PublishPreparation(
                repository: MeetingRepository(database: database),
                calendar: CalendarRepository(database: database),
                publishRecords: PublishRecordRepository(database: database)
            )
            let prepared = try preparation.prepare(
                meetingId: meetingId,
                options: PublishBundleBuilder.Options(
                    spaceKey: space,
                    projectKey: project,
                    defaultIssueType: issueType
                )
            )

            print("=== 품질 검증 ===")
            if prepared.findings.isEmpty {
                print("문제 없음")
            }
            for finding in prepared.findings {
                print("[\(finding.severity.rawValue)] \(finding.message)")
            }
            print("게시 가능: \(prepared.canPublish ? "예" : "아니오")")
            if !prepared.alreadyPublished.isEmpty {
                print("이미 게시됨: " + prepared.alreadyPublished.map(\.url).joined(separator: ", "))
            }

            print("")
            print("=== 전송될 내용 ===")
            let publisher = MeetingPublisher(
                client: AtlassianClient(
                    credentials: AtlassianCredentials(
                        site: "example.atlassian.net",
                        email: "preview@example.com",
                        apiToken: ""
                    )
                )
            )
            do {
                try print(publisher.dryRun(bundle: prepared.bundle, evidence: prepared.evidence))
            } catch {
                print("검열 게이트에서 중단됨: \(error.localizedDescription)")
            }
            print("")
            print("=== 근거(로컬에만 보관) ===")
            for item in prepared.evidence.items {
                let stamps = item.evidence.map { TimeFormat.stamp($0.startTime) }.joined(separator: ", ")
                print("\(item.contentId) [\(item.kind)] \(item.content) — 근거 \(stamps.isEmpty ? "없음" : stamps)")
            }
        }
    }

    /// 사용자가 승인한 회의록을 실제로 게시한다.
    struct Publish: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "승인한 회의록을 Confluence에 게시하고 액션 아이템을 Jira 이슈로 만든다"
        )

        @OptionGroup var options: CommonOptions

        @Option(name: .long) var meeting: String
        @Option(name: .long, help: "Confluence Space 키") var space: String
        @Option(name: .long, help: "Jira Project 키") var project: String
        @Option(name: .long, help: "기본 이슈 유형 (Task/Bug/Story)") var issueType: String = "Task"
        @Flag(name: .long, help: "게시를 승인한다. 이 플래그 없이는 전송하지 않는다.")
        var yes: Bool = false

        func run() async throws {
            guard let meetingId = UUID(uuidString: meeting) else {
                throw ValidationError("회의 UUID 형식이 아닙니다.")
            }
            guard yes else {
                throw ValidationError("게시하려면 --yes 로 승인해야 합니다. 먼저 `preview`로 내용을 확인하세요.")
            }
            guard let credentials = try ChainedCredentialStore().load() else {
                throw ValidationError("Atlassian 인증 정보가 없습니다. `meetingctl auth --site ... --email ...` 로 등록하세요.")
            }

            let database = try options.makeDatabase()
            let preparation = PublishPreparation(
                repository: MeetingRepository(database: database),
                calendar: CalendarRepository(database: database),
                publishRecords: PublishRecordRepository(database: database)
            )
            let prepared = try preparation.prepare(
                meetingId: meetingId,
                options: PublishBundleBuilder.Options(
                    spaceKey: space,
                    projectKey: project,
                    defaultIssueType: issueType
                )
            )
            guard prepared.canPublish else {
                for finding in prepared.findings where finding.severity == .blocking {
                    print("[차단] \(finding.message)")
                }
                throw ValidationError("품질 검증을 통과하지 못해 게시하지 않았습니다.")
            }

            let verbose = options.verbose
            let client = AtlassianClient(credentials: credentials) { message in
                if verbose {
                    FileHandle.standardError.write(Data(("[atlassian] " + message + "\n").utf8))
                }
            }
            let publisher = MeetingPublisher(client: client) { message in
                FileHandle.standardError.write(Data(("[publish] " + message + "\n").utf8))
            }
            let outcome = try await publisher.publish(
                bundle: prepared.bundle,
                evidence: prepared.evidence,
                approved: true
            )
            try preparation.recordOutcome(outcome, meetingId: meetingId, spaceKey: space)

            print("Confluence: \(outcome.pageURL)")
            for issue in outcome.issues {
                print("Jira \(issue.key): \(issue.url)")
            }
            for problem in outcome.problems {
                print("· \(problem)")
            }
        }
    }
}

extension MeetingCTL {
    /// 회의 삭제. 오디오·전사문·회의록·근거 파일을 함께 지운다.
    struct Delete: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "회의를 삭제한다 (파일은 휴지통으로, 기록은 데이터베이스에서 삭제)"
        )

        @OptionGroup var options: CommonOptions

        @Option(name: .long, help: "회의 UUID") var meeting: String

        @Flag(name: .long, help: "파일은 남기고 데이터베이스 기록만 지운다")
        var keepFiles: Bool = false

        @Flag(name: .long, help: "확인 없이 삭제한다")
        var yes: Bool = false

        func run() throws {
            guard let meetingId = UUID(uuidString: meeting) else {
                throw ValidationError("회의 UUID 형식이 아닙니다.")
            }
            let database = try options.makeDatabase()
            let repository = MeetingRepository(database: database)
            guard let target = try repository.meeting(id: meetingId) else {
                throw ValidationError("회의를 찾을 수 없습니다: \(meeting)")
            }

            if !yes {
                print("‘\(target.title)’를 삭제합니다. 녹음 파일·전사문·회의록·근거가 모두 사라집니다.")
                print("계속하려면 --yes 를 붙여 다시 실행하세요.")
                return
            }

            let summary = try MeetingDeleter(repository: repository)
                .delete(meetingId: meetingId, removeFiles: !keepFiles)
            print("삭제 완료: \(summary.meetingTitle)")
            if summary.trashedItemCount > 0 {
                let megabytes = Double(summary.freedBytes) / 1_048_576
                print(String(format: "휴지통으로 보낸 항목 %d개 (%.1fMB)", summary.trashedItemCount, megabytes))
            }
            for kept in summary.keptExternalFiles {
                print("남겨 둔 원본 파일: \(kept.path)")
            }
        }
    }

    struct Retention: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "오디오 보관 상태를 보고, 기간이 지난 오디오를 정리한다 (전사문·회의록·근거는 유지)"
        )

        @OptionGroup var options: CommonOptions

        @Option(name: .long, help: "보관 기간: immediate | days7 | days30 | days90 | forever (기본 days30)")
        var policy: String = AudioRetentionPolicy.standard.retention.rawValue

        @Flag(name: .long, help: "실제로 정리한다. 없으면 대상만 보여 준다.")
        var sweep: Bool = false

        func run() throws {
            guard let retention = AudioRetention(rawValue: policy) else {
                throw ValidationError("보관 기간 값이 올바르지 않습니다: \(policy)")
            }
            let database = try options.makeDatabase()
            let repository = MeetingRepository(database: database)
            let rule = AudioRetentionPolicy(retention: retention)

            let service = AudioRetentionService(repository: repository, logSink: { print($0) })
            let usage = try repository.audioStorageUsage()
            let disk = try service.diskUsage()
            print("디스크의 오디오: \(ByteFormat.short(disk.bytes)) · 파일 \(disk.fileCount)개")
            print("회의 기록과 연결된 오디오: \(ByteFormat.short(usage.bytes)) · 파일 \(usage.trackCount)개")
            if disk.untrackedFileCount > 0 {
                print("기록이 없어 자동 정리되지 않는 파일: \(ByteFormat.short(disk.untrackedBytes)) · \(disk.untrackedFileCount)개")
            }
            print("보관 기간: \(retention.label) — \(retention.detail)")

            let candidates = try repository.audioRetentionCandidates()
            let expired = rule.expired(among: candidates, now: Date())
            let blocked = candidates.filter { !$0.isCompleted && $0.hasAudio }
            print("정리 대상 회의: \(expired.count)건")
            if !blocked.isEmpty {
                print("회의록이 없어 오디오를 남기는 회의: \(blocked.count)건")
            }

            guard sweep else {
                if !expired.isEmpty {
                    print("실제로 정리하려면 --sweep 를 붙이세요.")
                }
                return
            }
            let outcome = try service.sweep(policy: rule)
            print("정리 완료: 회의 \(outcome.meetingCount)건 · 파일 \(outcome.trashedFileCount)개 · \(ByteFormat.short(outcome.freedBytes)) 회수")
            for kept in outcome.keptExternalFiles {
                print("남겨 둔 원본 파일: \(kept.path)")
            }
        }
    }
}
