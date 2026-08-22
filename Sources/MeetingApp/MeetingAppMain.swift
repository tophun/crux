import AppKit
import MeetingAudio
import MeetingCalendar
import MeetingCore
import MeetingInference
import MeetingPersistence
import MeetingPipeline
import MeetingPublishing
import MeetingTranscription
import MeetingUI
import SwiftUI
import UniformTypeIdentifiers

/// 앱 조립 지점. 여기서만 무거운 엔진과 외부 연동 구현을 알고, 나머지 모듈은 프로토콜만 본다.
@main
struct CruxApp: App {
    @State private var state: AppState
    @State private var coordinator: MeetingSessionCoordinator
    /// 오디오 보관 설정과 사용량
    @State private var storage: AudioStorageModel
    @State private var installs: ModelInstallCenter
    /// 이번 실행에서 온보딩을 닫았는지. "나중에 하기"를 누르면 다시 띄우지 않는다.
    @State private var dismissedOnboarding = false
    private let onboarding = OnboardingWindowController()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    private let databaseURL: URL

    init() {
        let databaseURL = AppDatabase.defaultURL
        self.databaseURL = databaseURL

        let database: AppDatabase
        do {
            database = try AppDatabase.open(at: databaseURL)
        } catch {
            fatalError("데이터베이스를 열 수 없습니다: \(error.localizedDescription)")
        }

        let repository = MeetingRepository(database: database)
        let jobs = ProcessingJobRepository(database: database)
        let calendarRepository = CalendarRepository(database: database)
        let publishRecords = PublishRecordRepository(database: database)

        // 설정에서 고른 모델이 다음 처리부터 바로 쓰이도록, 로드할 때마다 저장소를 읽는다.
        let transcriptionConfiguration = WhisperKitTranscriptionEngine.Configuration(
            modelProvider: { ModelPreferenceStore.transcriptionModel }
        )
        let inferenceConfiguration = Qwen3InferenceEngine.Configuration(
            modelProvider: { ModelPreferenceStore.languageModel }
        )

        let log = AppLog.shared
        let coordinatorLog: @Sendable (String) -> Void = log.sink(.model)
        let modelLifecycle = ModelLifecycleCoordinator(
            transcriptionEngine: WhisperKitTranscriptionEngine(configuration: transcriptionConfiguration),
            languageModel: Qwen3InferenceEngine(configuration: inferenceConfiguration),
            log: coordinatorLog
        )
        let pipeline = MeetingProcessingPipeline(
            repository: repository,
            jobs: jobs,
            coordinator: modelLifecycle,
            // 설정 화면에서 바꾼 보관 기간이 다음 처리부터 바로 적용되도록 그때그때 읽는다.
            retention: { AudioRetentionStore.policy },
            documentPrompt: { DocumentPromptStore.prompt },
            logSink: log.sink(.pipeline)
        )
        let preparation = PublishPreparation(
            repository: repository,
            calendar: calendarRepository,
            publishRecords: publishRecords
        )

        let playback = AudioPlaybackController()
        _storage = State(initialValue: AudioStorageModel(repository: repository))

        // 모델 설치 관리. 카탈로그의 모든 선택지를 미리 만들어 두고
        // 설정·온보딩·메뉴바가 같은 인스턴스를 바라보게 한다.
        let transcriptionInstallers: [String: any ModelInstalling] = Dictionary(
            uniqueKeysWithValues: TranscriptionModelCatalog.all.map { choice in
                (choice.id, WhisperModelInstaller(modelVariant: choice.id))
            }
        )
        let languageInstallers: [String: any ModelInstalling] = Dictionary(
            uniqueKeysWithValues: LanguageModelCatalog.all.map { choice in
                (choice.id, MLXModelInstaller(modelId: choice.id))
            }
        )
        _installs = State(
            initialValue: ModelInstallCenter(
                transcriptionInstallers: transcriptionInstallers,
                languageInstallers: languageInstallers
            )
        )
        let installs = _installs.wrappedValue

        _state = State(
            initialValue: AppState(
                repository: repository,
                jobs: jobs,
                pipeline: pipeline,
                importer: MeetingImporter(repository: repository),
                deleter: MeetingDeleter(repository: repository),
                calendar: calendarRepository,
                playback: playback
            )
        )
        _coordinator = State(
            initialValue: MeetingSessionCoordinator(
                calendarProvider: EventKitCalendarProvider(),
                calendarRepository: calendarRepository,
                capture: MeetingAudioCapture(log: log.sink(.audio)),
                repository: repository,
                pipeline: pipeline,
                preparation: preparation,
                playback: playback,
                // 모델이 없으면 녹음해도 처리가 실패하므로 시작 자체를 막는다.
                // startMeeting이 메인 액터에서만 부르므로 assumeIsolated가 안전하다.
                recordingGate: {
                    let ready = MainActor.assumeIsolated { installs.readyForCapture }
                    return ready
                        ? nil
                        : "음성 인식·회의록 생성 모델이 아직 설치되지 않았습니다. 설정 → 일반에서 모델을 내려받은 뒤 시작하세요."
                },
                log: log.sink(.session)
            )
        )
    }

    var body: some Scene {
        Window(AppIdentity.productName, id: "main") {
            NavigationSplitView {
                MeetingListView(state: state)
                    .frame(minWidth: 280)
                    .toolbar {
                        // 기록: 녹음하기 또는 불러오기. 메뉴바의 "회의록 시작"과 같은 조건으로 잠근다.
                        ToolbarItem(placement: .automatic) {
                            Menu {
                                Button("녹음하기", systemImage: "record.circle") {
                                    Task { await coordinator.startMeeting() }
                                }
                                .disabled(
                                    coordinator.microphoneStatus != .granted
                                        || coordinator.capsule.showsRecordingIndicator
                                        || state.isProcessing
                                )
                                Button("불러오기", systemImage: "square.and.arrow.down") {
                                    importAudio()
                                }
                                .disabled(state.isProcessing)
                            } label: {
                                Label("기록", systemImage: "square.and.pencil")
                            }
                        }
                    }
            } detail: {
                MeetingDetailView(state: state)
                    .frame(minWidth: 560, minHeight: 480)
                    // 상세 열의 툴바. 유연한 공백(ToolbarSpacer)이 버튼 묶음을 오른쪽 끝으로 민다.
                    // 검색은 .searchable이 별도 그룹으로 그 오른쪽에 놓인다.
                    // 왼쪽: 미리보기 / 전사문 전환 (문서 아이콘 / 대사 아이콘)
                    .toolbar {
                        ToolbarItemGroup(placement: .navigation) {
                            Picker("보기", selection: $state.detailTab) {
                                Text("회의록").tag(DetailTab.preview)
                                Text("전사문").tag(DetailTab.transcript)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                        }
                    }
                    .modifier(TrailingToolbarButtons(state: state))
                    .searchable(
                        text: Binding(
                            get: { state.searchText },
                            set: { state.searchText = $0 }
                        ),
                        placement: .toolbar,
                        prompt: "회의·전사문·액션아이템 검색"
                    )
            }
            // 제목 문구는 화면에 그리지 않는다. 창 제목은 남아 메뉴의 "열기"가 창을 찾는다.
            .navigationTitle(AppIdentity.productName)
            .task {
                delegate.attach(coordinator: coordinator)
                // 녹음·처리 결과를 회의 목록과 상세 화면에 즉시 반영한다.
                coordinator.onMeetingsChanged = { meetingId in
                    state.reload()
                    if let meetingId {
                        state.selectedMeetingId = meetingId
                    }
                    state.loadDetail()
                }
                await coordinator.refreshPermissions()
                // 권한이 없으면 무엇이 필요한지 먼저 보여 준다. 없는 채로 두면 기능이 조용히 죽는다.
                presentOnboardingIfNeeded()
                coordinator.startMonitoring()
                AppLog.shared.write(.session, "앱 시작 · 로그: \(AppLog.defaultURL.path)")
                // 보관 기간이 지난 오디오를 정리한다. 전사문·회의록·근거는 건드리지 않는다.
                storage.sweepAtLaunch(log: AppLog.shared.sink(.session))
            }
        }
        // 메모 앱처럼 제목 줄을 없애고 머리줄이 그 자리를 쓴다.
        .windowStyle(.hiddenTitleBar)

        Window("게시 전 검토", id: "preview") {
            if let model = coordinator.previewModel {
                PreviewViewerView(model: model)
            } else {
                ContentUnavailableView(
                    "검토할 회의록이 없습니다",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("회의록 생성이 끝나면 Crux에서 열 수 있습니다.")
                )
                .frame(width: 480, height: 260)
            }
        }

        MenuBarExtra {
            MenuBarContentView(
                state: state,
                coordinator: coordinator,
                installs: installs,
                openWindow: { Self.activateWindow(titled: AppIdentity.productName) }
            )
        } label: {
            Image(systemName: menuBarSymbol)
        }

        Settings {
            SettingsView(
                databaseURL: databaseURL,
                modelDirectory: AppIdentity.dataDirectory().appendingPathComponent("models"),
                coordinator: coordinator,
                storage: storage,
                installs: installs
            )
        }
    }

    private var menuBarSymbol: String {
        switch coordinator.capsule {
        case .recording: "record.circle"
        case .generating: "waveform.circle.fill"
        case .previewReady: "doc.badge.ellipsis"
        default: state.isProcessing ? "waveform.circle.fill" : "waveform.circle"
        }
    }

    static func activateWindow(titled title: String) {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.title == title {
            window.makeKeyAndOrderFront(nil)
            return
        }
        // 아직 열리지 않은 창은 메뉴에서 다시 열도록 첫 창을 올린다.
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
    }

    /// 필수 권한(캘린더·마이크)이 없으면 안내 창을 띄운다.
    @MainActor
    private func presentOnboardingIfNeeded() {
        guard !dismissedOnboarding else { return }
        guard OnboardingGate.shouldPresent(
            calendarAuthorized: coordinator.calendarStatus == .authorized,
            microphoneGranted: coordinator.microphoneStatus == .granted
        ) else { return }
        onboarding.show(coordinator: coordinator, installs: installs) { dismissedOnboarding = true }
    }

    private func importAudio() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio, .mpeg4Audio, .wav, .mp3, .aiff]
        panel.message = "회의 오디오 파일을 선택하세요. 파일은 이 기기에서만 처리됩니다."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        state.importAndProcess(url: url)
    }
}

/// Crux 창을 관리한다. 상태가 바뀔 때마다 캡슐을 갱신한다.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let capsuleWindow = CruxWindowController()
    private var coordinator: MeetingSessionCoordinator?
    private var syncTask: Task<Void, Never>?
    private var lastState: CruxState = .hidden

    func attach(coordinator: MeetingSessionCoordinator) {
        guard self.coordinator == nil else { return }
        self.coordinator = coordinator
        syncTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.sync()
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
    }

    private func sync() {
        guard let coordinator else { return }
        let state = coordinator.capsule
        guard state != lastState else { return }
        lastState = state

        capsuleWindow.show(
            state: state,
            detailMessage: coordinator.detailMessage,
            onPrimaryAction: { [weak self] in self?.handlePrimaryAction(state) },
            onDismiss: {
                // 녹음 중 닫기는 "숨김"이 아니라 녹음 취소다. 숨기기만 하면 녹음이 계속 돈다.
                if state.showsRecordingIndicator {
                    Task { await coordinator.cancelRecording() }
                } else {
                    coordinator.dismissCapsule()
                }
            },
            onOpenPreview: {
                CruxApp.activateWindow(titled: "게시 전 검토")
            },
            onTogglePause: { Task { await coordinator.togglePause() } },
            onStop: { Task { await coordinator.stopAndProcess() } },
            onCancelProcessing: { coordinator.cancelProcessing() }
        )
    }

    private func handlePrimaryAction(_ state: CruxState) {
        guard let coordinator else { return }
        switch state {
        case .detected, .imminent:
            Task { await coordinator.startMeeting() }
        case let .recording(_, paused):
            if paused {
                Task { await coordinator.togglePause() }
            } else {
                Task { await coordinator.stopAndProcess() }
            }
        case .previewReady:
            CruxApp.activateWindow(titled: "게시 전 검토")
        case .published:
            CruxApp.activateWindow(titled: "게시 전 검토")
        case .failed:
            Task { await coordinator.pollOnce() }
        case .generating, .hidden:
            break
        }
    }

    func applicationWillTerminate(_: Notification) {
        syncTask?.cancel()
        capsuleWindow.close()
    }
}

/// 공유·더보기 묶음을 툴바 오른쪽 끝에 붙인다.
///
/// 배포 대상은 macOS 15지만 유연한 툴바 공백(ToolbarSpacer)은 26부터라 실행 시점에 가른다.
/// 26 미만에서는 밀어낼 방법이 없어 그냥 놓는다(왼쪽에 보일 수 있다).
private struct TrailingToolbarButtons: ViewModifier {
    @Bindable var state: AppState

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.toolbar {
                ToolbarSpacer(.flexible)
                ToolbarItemGroup {
                    if let detail = state.detail {
                        DetailToolbarButtons(state: state, detail: detail)
                    }
                }
            }
        } else {
            content.toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    if let detail = state.detail {
                        DetailToolbarButtons(state: state, detail: detail)
                    }
                }
            }
        }
    }
}
