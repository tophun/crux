import MeetingCore
import SwiftUI

/// 메뉴바 메뉴(§11 + 요구사항 3).
///
/// 메뉴에는 네 가지만 둔다 — 상태, 시작·종료, 창 열기, 설정.
/// 나머지 동작은 각자 제자리에 있다: 오디오 가져오기는 창 툴바에, 검토·게시는 캡슐에 있다.
/// 메뉴가 길어지면 정작 급할 때 눌러야 할 종료 버튼을 찾기 어려워진다.
public struct MenuBarContentView: View {
    @Bindable var state: AppState
    @Bindable var coordinator: MeetingSessionCoordinator
    @Bindable var installs: ModelInstallCenter
    let openWindow: () -> Void

    public init(
        state: AppState,
        coordinator: MeetingSessionCoordinator,
        installs: ModelInstallCenter,
        openWindow: @escaping () -> Void
    ) {
        self.state = state
        self.coordinator = coordinator
        self.installs = installs
        self.openWindow = openWindow
    }

    public var body: some View {
        Text(statusLine)
        Divider()
        recordingControls
        Divider()
        Button("\(AppIdentity.productName) 열기", action: openWindow)
        SettingsLink { Text("설정…") }
    }

    /// 녹음 중이면 종료, 아니면 시작. 두 가지만 둔다.
    @ViewBuilder
    private var recordingControls: some View {
        switch coordinator.capsule {
        case .recording:
            Button("회의 종료 후 회의록 생성") {
                Task { await coordinator.stopAndProcess() }
            }
        case .generating:
            // 작성 중에는 누를 것이 없다. 상태 줄에 진행 상황이 나온다.
            EmptyView()
        default:
            Button("회의록 시작") {
                Task { await coordinator.startMeeting() }
            }
            .disabled(!canStartRecording)
            .help(
                canStartRecording
                    ? "녹음을 시작합니다"
                    : "음성 인식·회의록 생성 모델을 먼저 내려받으세요"
            )
        }
    }

    private var canStartRecording: Bool {
        OnboardingGate.canStartRecording(
            microphoneGranted: coordinator.microphoneStatus == .granted,
            transcriptionModelInstalled: installs.selectedTranscriptionStatus().isInstalled,
            languageModelInstalled: installs.selectedLanguageStatus().isInstalled
        )
    }

    private var statusLine: String {
        if coordinator.capsule.isVisible {
            let trailing = coordinator.capsule.trailingText.map { " · \($0)" } ?? ""
            return coordinator.capsule.statusText + trailing
        }
        if state.isProcessing {
            return "처리 중…"
        }
        return "대기 중 · 회의 \(state.summaries.count)건"
    }
}
