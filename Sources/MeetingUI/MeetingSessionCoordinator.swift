import Foundation
import MeetingAudio
import MeetingCalendar
import MeetingCore
import MeetingPersistence
import MeetingPipeline
import MeetingPublishing
import Observation

/// 캘린더 감지 → Crux → 녹음 → 회의록 생성 → Preview → 게시를 잇는 조정자.
///
/// 기본 동작은 자동 녹음이 아니라 사용자 확인이다. 감지는 캡슐에 제안만 띄운다.
@MainActor
@Observable
public final class MeetingSessionCoordinator {
    public private(set) var capsule: CruxState = .hidden
    public private(set) var detailMessage: String?
    public private(set) var previewModel: PreviewViewerModel?
    public private(set) var lastError: String?
    /// 캘린더 권한 상태 (설정 화면 표시용)
    public private(set) var calendarStatus: CalendarAuthorizationStatus = .notDetermined
    public private(set) var microphoneStatus: CapturePermissionState = .notDetermined
    public private(set) var systemAudioStatus: CapturePermissionState = .notDetermined
    public private(set) var activeMeetingId: UUID?
    /// 녹음 중인 회의 제목. 노치 펼침 헤더에 쓴다.
    public private(set) var activeMeetingTitle: String?
    /// 녹음 중 노치에서 남긴 메모. 회의 저장 폴더의 memos.json과 같은 내용이다.
    public private(set) var memos: [MeetingMemo] = []
    private var memoStore: MeetingMemoStore?

    /// 회의 목록이 바뀌었을 때 알린다. 앱이 회의 목록·상세 화면을 새로 고치는 데 쓴다.
    /// (녹음 시작, 처리 완료, 처리 실패 시점)
    public var onMeetingsChanged: (@MainActor (UUID?) -> Void)?

    /// 게시 대상 기본값. 사용자가 Preview에서 바꿀 수 있다.
    public var defaultSpaceKey: String {
        didSet { UserDefaults.standard.set(defaultSpaceKey, forKey: "publish.spaceKey") }
    }

    public var defaultProjectKey: String {
        didSet { UserDefaults.standard.set(defaultProjectKey, forKey: "publish.projectKey") }
    }

    private var machine = CruxMachine()
    private let calendarProvider: any CalendarProvider
    private let calendarRepository: CalendarRepository
    private let detector: ConferenceAppDetector
    private var policy: MeetingDetectionPolicy
    /// 같은 진단을 15초마다 반복해서 남기지 않기 위한 직전 값.
    private var lastDiagnostic: String?
    private var lastDiagnosticAt: Date?
    private let capture: MeetingAudioCapture
    private let repository: MeetingRepository
    private let pipeline: MeetingProcessingPipeline
    private let preparation: PublishPreparation
    private let credentialStore: any AtlassianCredentialStore
    /// 검토 화면에서 녹음을 들을 수 있게 공유하는 재생 컨트롤러
    private let playback: AudioPlaybackController
    private let log: (@Sendable (String) -> Void)?
    /// 녹음 시작 전 마지막 관문. 막는 이유를 반환하고, 통과면 nil을 반환한다.
    /// 모델 미설치 같은 "지금 시작하면 처리가 실패하는" 상태를 잡는다.
    private let recordingGate: (@Sendable () -> String?)?

    private var pollingTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    /// 진행 중인 회의록 생성을 취소하는 손잡이. 캡슐의 취소 버튼이 부른다.
    private var processingCancel: (() -> Void)?
    /// 사용자가 캡슐에서 취소를 눌렀는지. 파이프라인이 `CancellationError`가 아닌
    /// 다른 오류(네트워크 취소 등)로 끝나도 실패로 보여 주지 않기 위해 따로 기억한다.
    private var processingCancelRequested = false

    public init(
        calendarProvider: any CalendarProvider,
        calendarRepository: CalendarRepository,
        capture: MeetingAudioCapture,
        repository: MeetingRepository,
        pipeline: MeetingProcessingPipeline,
        preparation: PublishPreparation,
        credentialStore: any AtlassianCredentialStore = ChainedCredentialStore(),
        playback: AudioPlaybackController? = nil,
        detector: ConferenceAppDetector = ConferenceAppDetector(),
        policy: MeetingDetectionPolicy = MeetingDetectionPolicy(),
        recordingGate: (@Sendable () -> String?)? = nil,
        log: (@Sendable (String) -> Void)? = nil
    ) {
        self.calendarProvider = calendarProvider
        self.calendarRepository = calendarRepository
        self.capture = capture
        self.repository = repository
        self.pipeline = pipeline
        self.preparation = preparation
        self.credentialStore = credentialStore
        self.playback = playback ?? AudioPlaybackController()
        self.detector = detector
        self.policy = policy
        self.recordingGate = recordingGate
        self.log = log
        defaultSpaceKey = UserDefaults.standard.string(forKey: "publish.spaceKey") ?? ""
        defaultProjectKey = UserDefaults.standard.string(forKey: "publish.projectKey") ?? ""
    }

    // MARK: - 권한

    /// 감지 루프에서 주기적으로 부르는 가벼운 확인. 권한 창을 띄우는 API는 호출하지 않는다.
    public func refreshPermissions() async {
        calendarStatus = calendarProvider.authorizationStatus()
        microphoneStatus = await capture.microphonePermission()
    }

    /// 시스템 오디오(화면 기록) 권한 확인. ScreenCaptureKit은 조회 API가 없어 실제 조회로 확인해야 하고,
    /// 그 호출이 권한 창을 띄울 수 있다. 그래서 주기적으로 부르지 않고 사용자 동작에서만 확인한다.
    public func refreshSystemAudioPermission() async {
        systemAudioStatus = await capture.systemAudioPermission()
    }

    /// 설정·온보딩의 '허용' 버튼용. 아직 정해지지 않았으면 시스템 대화상자를 띄운다.
    public func requestSystemAudioPermission() async {
        systemAudioStatus = await capture.requestSystemAudioPermission()
    }

    public func requestCalendarAccess() async {
        _ = try? await calendarProvider.requestAccess()
        calendarStatus = calendarProvider.authorizationStatus()
    }

    public func requestRecordingPermissions() async {
        let result = await capture.requestPermissions()
        microphoneStatus = result.microphone
        systemAudioStatus = result.systemAudio
    }

    // MARK: - 감지 루프

    /// 감지 루프를 돈다.
    ///
    /// 15초 간격인 이유: 일정 알림을 1분 전으로 걸어 두는 경우가 많은데,
    /// 30초 간격이면 캡슐이 시작 30초 전에야 뜰 수 있다. 캘린더 읽기는 로컬이라 비용이 작다.
    public func startMonitoring(interval: TimeInterval = 15) {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce()
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    public func stopMonitoring() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    public func pollOnce() async {
        await refreshPermissions()
        // 설정에서 감지 기준을 바꿨을 수 있으므로 매번 읽는다.
        policy.configuration.minimumAttendees = MeetingDetectionSettings.minimumAttendees

        guard calendarStatus.canReadEvents || !detector.detect().isEmpty else {
            diagnose("캘린더 권한이 없고 실행 중인 회의 앱도 없어 감지를 건너뜁니다. (권한: \(calendarStatus.displayName))")
            return
        }

        var events: [CalendarEvent] = []
        if calendarStatus.canReadEvents {
            let now = Date()
            events = await (try? calendarProvider.events(
                from: now.addingTimeInterval(-3600),
                to: now.addingTimeInterval(7200)
            )) ?? []
            // 캘린더 메타데이터는 로컬에만 저장한다.
            try? calendarRepository.save(events: events)
        }

        let notified = (try? calendarRepository.notifiedEventIds()) ?? []
        let verdict = policy.decide(
            events: events,
            now: Date(),
            notifiedEventIds: notified,
            conferenceApps: detector.detect()
        )
        report(events: events, notified: notified, verdict: verdict)

        let message = policy.confirmationMessage(for: verdict)
        capsule = machine.apply(.detection(verdict, message: message))
        // 녹음·처리 중에는 감지 문구를 덮지 않는다. 캡슐에 지난 감지 문구가 남는 문제를 막는다.
        switch capsule {
        case .imminent, .detected:
            detailMessage = message
        case .hidden:
            detailMessage = nil
        default:
            break
        }
    }

    /// 왜 캡슐이 떴는지·안 떴는지 로그로 남긴다. 같은 내용은 반복하지 않는다.
    private func report(
        events: [CalendarEvent],
        notified: Set<String>,
        verdict: MeetingDetectionPolicy.Verdict
    ) {
        // 권한 상태를 항상 남긴다. 이게 빠지면 "일정 0건"이 권한 문제인지 일정이 없는 것인지 알 수 없다.
        var parts: [String] = ["캘린더 \(calendarStatus.displayName)", "일정 \(events.count)건"]
        let eligible = policy.eligibleEvents(events)
        parts.append("대상 \(eligible.count)건")
        for event in eligible.prefix(3) {
            let lead = Int(policy.leadTime(for: event) / 60)
            let source = event.earliestAlarmLeadTime == nil ? "기본" : "일정 알림"
            parts.append("\(event.title): \(lead)분 전부터(\(source))")
        }

        for (event, reason) in policy.exclusions(events).prefix(5) {
            parts.append("제외: \(event.title) — \(reason.displayName)")
        }
        let alreadyAsked = eligible.filter { notified.contains($0.id) }
        if !alreadyAsked.isEmpty {
            parts.append("이미 물어본 일정 \(alreadyAsked.count)건")
        }
        switch verdict {
        case .idle: parts.append("판정: 표시할 것 없음")
        case let .imminent(event, seconds):
            parts.append("판정: \(event.title) \(Int(seconds / 60))분 전")
        case let .started(event, reason):
            parts.append("판정: \(event.title) 시작됨(\(reason.rawValue))")
        case let .unscheduled(appName):
            parts.append("판정: 일정 없이 \(appName) 실행 중")
        }
        diagnose(parts.joined(separator: " · "))
    }

    /// 같은 내용은 반복하지 않되, 루프가 살아 있는지 알 수 있게 5분마다 한 번은 남긴다.
    private func diagnose(_ message: String, now: Date = Date()) {
        if message == lastDiagnostic, let last = lastDiagnosticAt, now.timeIntervalSince(last) < 300 {
            return
        }
        lastDiagnostic = message
        lastDiagnosticAt = now
        log?("감지 " + message)
    }

    // MARK: - 회의록 시작·종료

    /// 사용자가 "회의록 시작"을 눌렀을 때. 자동으로 시작하지 않는다.
    public func startMeeting() async {
        lastError = nil
        // 모델 미설치 같은 상태에서는 녹음해도 처리가 실패하므로 시작 전에 막는다.
        if let recordingGate, let reason = recordingGate() {
            lastError = reason
            capsule = machine.apply(.failed(message: reason))
            log?("녹음 시작 거부: \(reason)")
            return
        }
        let event = machine.activeEvent
        if let event {
            try? calendarRepository.markNotified(eventId: event.id, at: Date())
        }

        let meetingId = UUID()
        let storage = MeetingStorage.forMeeting(id: meetingId)
        let meeting = Meeting(
            id: meetingId,
            title: event?.title ?? "회의 \(Self.timestampTitle())",
            startedAt: Date(),
            status: .recording,
            storageDirectory: storage.root,
            source: .liveCapture
        )

        do {
            try repository.save(meeting)
            if let event {
                try calendarRepository.link(meetingId: meetingId, eventId: event.id)
            }
            try await capture.start(meetingId: meetingId, storage: storage)
            activeMeetingId = meetingId
            activeMeetingTitle = meeting.title
            memoStore = MeetingMemoStore(storageDirectory: storage.root)
            memos = []
            capsule = machine.apply(.userStartedMeeting)
            startTicking()
            log?("녹음 시작: \(meeting.title)")
            onMeetingsChanged?(meetingId)
            let problems = await capture.problems
            if !problems.isEmpty {
                detailMessage = problems.joined(separator: "\n")
            }
        } catch {
            lastError = error.localizedDescription
            capsule = machine.apply(.failed(message: error.localizedDescription))
            try? repository.updateStatus(.failed, meetingId: meetingId)
        }
    }

    public func togglePause() async {
        do {
            if case let .recording(_, paused) = capsule {
                if paused {
                    try await capture.resume()
                    capsule = machine.apply(.recordingResumed)
                } else {
                    try await capture.pause()
                    capsule = machine.apply(.recordingPaused)
                }
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// 녹음을 끝내고 회의록 생성까지 진행한다.
    public func stopAndProcess() async {
        stopTicking()
        guard let meetingId = activeMeetingId else {
            // 회의 식별자를 잃은 상태에서도 캡슐이 "녹음 중"으로 남지 않게 정리한다.
            log?("종료 요청을 받았지만 진행 중인 회의가 없어 상태만 정리합니다.")
            _ = try? await capture.stop()
            capsule = machine.apply(.reset)
            return
        }
        activeMeetingId = nil
        activeMeetingTitle = nil
        memoStore = nil
        capsule = machine.apply(.recordingStopped)
        log?("녹음 종료 요청: \(meetingId)")

        do {
            let tracks = try await capture.stop()
            guard !tracks.isEmpty else {
                throw CaptureError.mixFailed("저장된 오디오가 없습니다.")
            }
            try repository.save(tracks: tracks)
            log?("트랙 저장 \(tracks.count)개: \(tracks.map(\.kind.rawValue).joined(separator: ", "))")
            // 목록이 계속 "녹음 중"으로 보이지 않도록 즉시 상태를 바꾸고 새로 고친다.
            try? repository.updateStatus(.transcribing, meetingId: meetingId)
            onMeetingsChanged?(meetingId)
            if let mixed = tracks.first(where: { $0.kind == .mixed }) ?? tracks.first {
                var meeting = try repository.meeting(id: meetingId)
                meeting?.endedAt = Date()
                if let meeting {
                    try repository.save(meeting)
                }
                log?("녹음 종료: \(String(format: "%.1f", mixed.duration))초")
            }

            var lastStage: ProcessingStage?
            let task = Task { try await self.pipeline.process(meetingId: meetingId) { [weak self] update in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    capsule = machine.apply(
                        .processingProgress(fraction: update.fraction, message: update.message)
                    )
                    // 단계가 바뀌면 목록의 상태 표시도 따라가게 한다.
                    if lastStage != update.stage {
                        lastStage = update.stage
                        onMeetingsChanged?(nil)
                    }
                    // 캡슐 상세에 어떤 단계가 끝났고 무엇이 남았는지 보여 준다.
                    detailMessage = Self.stageChecklist(current: update.stage)
                }
            } }
            processingCancelRequested = false
            processingCancel = { [weak self] in
                self?.processingCancelRequested = true
                task.cancel()
            }
            defer { processingCancel = nil }
            let result = try await task.value
            detailMessage = nil
            capsule = machine.apply(
                .previewReady(meetingId: meetingId, actionItemCount: result.note.actionItems.count)
            )
            log?("회의록 생성 완료: 결정 \(result.note.decisions.count)건, 액션 \(result.note.actionItems.count)건")
            preparePreview(meetingId: meetingId)
            onMeetingsChanged?(meetingId)
        } catch where error is CancellationError || processingCancelRequested {
            // 사용자가 직접 취소한 경우다. 오류가 아니므로 실패 메시지를 띄우지 않는다.
            processingCancelRequested = false
            detailMessage = nil
            try? repository.updateStatus(.recorded, meetingId: meetingId)
            capsule = machine.apply(.reset)
            log?("회의록 생성 취소: \(meetingId) — 녹음은 보관, 상세 화면에서 다시 생성할 수 있습니다.")
            onMeetingsChanged?(meetingId)
        } catch {
            lastError = error.localizedDescription
            detailMessage = nil
            log?("녹음 종료·처리 실패: \(error.localizedDescription)")
            try? repository.updateStatus(.failed, meetingId: meetingId)
            capsule = machine.apply(.failed(message: error.localizedDescription))
            onMeetingsChanged?(meetingId)
        }
    }

    /// 녹음 중 메모를 남긴다. 빈 문자열은 무시하고, 녹음 경과 시각을 함께 기록한다.
    public func addMemo(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let memoStore else { return }
        var elapsed: TimeInterval = 0
        if case let .recording(seconds, _) = capsule { elapsed = seconds }
        let memo = MeetingMemo(elapsed: elapsed, text: trimmed)
        do {
            memos = try memoStore.append(memo)
        } catch {
            lastError = error.localizedDescription
            log?("메모 저장 실패: \(error.localizedDescription)")
        }
    }

    /// 회의록 생성을 취소한다. 캡슐의 취소 버튼에서 부른다.
    public func cancelProcessing() {
        processingCancel?()
    }

    /// 파이프라인 단계 체크리스트 문구. 캡슐 상세에 보여 준다.
    public static func stageChecklist(current: ProcessingStage) -> String {
        let all = ProcessingStage.allCases
        guard let currentIndex = all.firstIndex(of: current) else { return current.displayName }
        return all.enumerated().map { index, stage in
            let marker = index < currentIndex ? "✓" : (index == currentIndex ? "▸" : "·")
            return "\(marker) \(stage.displayName)"
        }.joined(separator: "\n")
    }

    public func dismissCapsule() {
        capsule = machine.apply(.dismissed)
        detailMessage = nil
    }

    /// 녹음 중 캡슐을 닫으면 녹음을 취소한다. 오디오와 회의 기록을 남기지 않는다.
    public func cancelRecording() async {
        stopTicking()
        guard let meetingId = activeMeetingId else {
            capsule = machine.apply(.dismissed)
            detailMessage = nil
            return
        }
        activeMeetingId = nil
        activeMeetingTitle = nil
        memoStore = nil
        _ = try? await capture.stop()
        if let meeting = try? repository.meeting(id: meetingId) {
            try? FileManager.default.trashItem(at: meeting.storageDirectory, resultingItemURL: nil)
        }
        try? repository.delete(meetingId: meetingId)
        capsule = machine.apply(.dismissed)
        detailMessage = nil
        log?("녹음 취소: \(meetingId) — 오디오는 휴지통, 회의 기록은 삭제")
        onMeetingsChanged?(nil)
    }

    // MARK: - Preview · 게시

    public func preparePreview(meetingId: UUID) {
        do {
            let prepared = try preparation.prepare(
                meetingId: meetingId,
                options: PublishBundleBuilder.Options(
                    spaceKey: defaultSpaceKey,
                    projectKey: defaultProjectKey
                )
            )
            let preparation = preparation
            let credentialStore = credentialStore
            // 근거를 들어 보며 검토할 수 있도록 이 회의의 오디오를 준비한다.
            let tracks = (try? repository.tracks(meetingId: meetingId)) ?? []
            playback.prepare(tracks: tracks)
            previewModel = PreviewViewerModel(
                bundle: prepared.bundle,
                evidence: prepared.evidence,
                findings: prepared.findings,
                playback: playback,
                publishAction: { [weak self] bundle, evidence in
                    guard let credentials = try credentialStore.load() else {
                        throw PublishError.missingCredentials("설정에서 Atlassian 계정을 연결해 주세요.")
                    }
                    let publisher = MeetingPublisher(client: AtlassianClient(credentials: credentials))
                    let outcome = try await publisher.publish(bundle: bundle, evidence: evidence, approved: true)
                    try preparation.recordOutcome(outcome, meetingId: meetingId, spaceKey: bundle.spaceKey)
                    // 게시 결과를 캡슐에 반영한다: "Confluence 게시 · Jira 이슈 N개 생성"
                    await MainActor.run { [weak self] in
                        self?.applyPublished(title: outcome.pageTitle, issueCount: outcome.issues.count)
                    }
                    return [outcome.pageURL] + outcome.issues.map(\.url)
                },
                revalidate: { bundle in
                    MeetingQualityChecker().check(note: prepared.note, bundle: bundle, evidence: prepared.evidence)
                }
            )
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// 게시 결과를 캡슐 상태에 반영한다.
    public func applyPublished(title: String?, issueCount: Int) {
        capsule = machine.apply(.published(confluencePageTitle: title, jiraIssueCount: issueCount))
    }

    // MARK: - 내부

    private func startTicking() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                let elapsed = await capture.elapsed
                await MainActor.run {
                    self.capsule = self.machine.apply(.recordingTicked(elapsed: elapsed))
                }
            }
        }
    }

    private func stopTicking() {
        tickTask?.cancel()
        tickTask = nil
    }

    static func timestampTitle() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        // 파일명으로도 쓰이므로 콜론을 피한다(macOS에서 콜론은 경로 구분자).
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        return formatter.string(from: Date())
    }
}
