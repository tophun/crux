import AppKit
import MeetingAudio
import MeetingCore
import SwiftUI

/// 첫 실행 안내(§11).
///
/// 권한이 없으면 기능이 조용히 죽는다 — 캘린더가 없으면 회의를 감지하지 못하고,
/// 마이크가 없으면 녹음 자체가 안 된다. 그래서 앱을 켤 때 무엇이 필요한지 먼저 보여 주고
/// 여기서 권한을 받는다. 자동으로 녹음을 시작하지는 않는다.
public struct OnboardingView: View {
    @Bindable var coordinator: MeetingSessionCoordinator
    @Bindable var installs: ModelInstallCenter
    /// 안내를 닫을 때 부른다.
    let onFinish: () -> Void

    public init(
        coordinator: MeetingSessionCoordinator,
        installs: ModelInstallCenter,
        onFinish: @escaping () -> Void
    ) {
        self.coordinator = coordinator
        self.installs = installs
        self.onFinish = onFinish
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            VStack(spacing: 0) {
                calendarRow
                Divider()
                microphoneRow
                Divider()
                systemAudioRow
                Divider()
                transcriptionModelRow
                Divider()
                languageModelRow
            }
            Divider()
            footer
        }
        .frame(width: 520)
        .task { await coordinator.refreshPermissions() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(AppIdentity.productName) 시작하기")
                .font(.title2.bold())
            Text("회의를 감지하고 녹음하려면 아래 권한과 두 개의 모델이 필요합니다. 권한 확인, 녹음, 전사, 회의록 생성은 모두 이 기기에서만 실행되며 오디오와 전사문은 외부로 전송하지 않습니다.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
    }

    private var calendarRow: some View {
        PermissionRow(
            symbol: "calendar",
            title: "캘린더",
            detail: "회의 시작 시각을 알아내 캡슐로 물어봅니다. 일정 제목과 참석자는 이 기기에만 저장됩니다.",
            state: PermissionRow.State(coordinator.calendarStatus),
            requirement: .required
        ) {
            Task { await coordinator.requestCalendarAccess() }
        } openSettings: {
            Self.openSettings("Privacy_Calendars")
        }
    }

    private var microphoneRow: some View {
        PermissionRow(
            symbol: "mic",
            title: "마이크",
            detail: "내 목소리를 녹음합니다. 없으면 회의록을 만들 수 없습니다.",
            state: PermissionRow.State(coordinator.microphoneStatus),
            requirement: .required
        ) {
            Task { await coordinator.requestRecordingPermissions() }
        } openSettings: {
            Self.openSettings("Privacy_Microphone")
        }
    }

    private var systemAudioRow: some View {
        PermissionRow(
            symbol: "speaker.wave.2",
            title: "화면 및 시스템 오디오 기록",
            detail: "상대방 목소리를 녹음합니다. 허용하지 않으면 내 마이크만 녹음합니다. 화면 영상은 저장하지 않습니다.",
            state: PermissionRow.State(coordinator.systemAudioStatus),
            requirement: .optional
        ) {
            Task { await coordinator.refreshSystemAudioPermission() }
        } openSettings: {
            Self.openSettings("Privacy_ScreenCapture")
        }
    }

    /// 기본 모델 두 가지. 없으면 처리가 실패하므로 여기서 받게 안내한다.
    /// 다른 모델은 설정 → 일반에서 나중에 고를 수 있다.
    private var transcriptionModelRow: some View {
        ModelInstallRow(
            symbol: "waveform.badge.magnifyingglass",
            title: "음성 인식 모델",
            detail: "녹음을 글로 옮깁니다. 네트워크는 지금 내려받을 때만 쓰고, 실행은 모두 이 기기에서 합니다.",
            choice: TranscriptionModelCatalog.choice(for: TranscriptionModelCatalog.defaultId),
            status: installs.transcription[TranscriptionModelCatalog.defaultId] ?? .notInstalled
        ) {
            installs.installTranscription(TranscriptionModelCatalog.defaultId)
        }
    }

    private var languageModelRow: some View {
        ModelInstallRow(
            symbol: "doc.text.below.ecg",
            title: "회의록 생성 모델",
            detail: "전사문에서 요약·결정·Action Item을 뽑아냅니다. 마찬가지로 이 기기에서만 실행됩니다.",
            choice: LanguageModelCatalog.choice(for: LanguageModelCatalog.defaultId),
            status: installs.language[LanguageModelCatalog.defaultId] ?? .notInstalled
        ) {
            installs.installLanguage(LanguageModelCatalog.defaultId)
        }
    }

    private var footer: some View {
        HStack {
            if remaining > 0 {
                Text("남은 준비 \(remaining)개")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Label("준비됐습니다", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            Spacer()
            Button("나중에 하기", action: onFinish)
            Button("시작하기", action: onFinish)
                .buttonStyle(.borderedProminent)
                .disabled(remaining > 0)
        }
        .padding(20)
    }

    /// 아직 남은 필수 권한과 기본 모델 수. 시스템 오디오는 선택이라 세지 않는다.
    private var remaining: Int {
        OnboardingGate.remainingRequired(
            calendarAuthorized: coordinator.calendarStatus == .authorized,
            microphoneGranted: coordinator.microphoneStatus == .granted,
            transcriptionModelInstalled: installs.selectedTranscriptionStatus().isInstalled,
            languageModelInstalled: installs.selectedLanguageStatus().isInstalled
        )
    }

    /// 시스템 설정의 해당 항목을 연다. 한 번 거부하면 앱에서 다시 물어볼 수 없기 때문이다.
    static func openSettings(_ anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}

/// 권한 한 줄. 상태에 따라 버튼이 달라진다.
struct PermissionRow: View {
    enum State {
        case notDetermined
        case granted
        case blocked

        init(_ status: CalendarAuthorizationStatus) {
            switch status {
            case .authorized: self = .granted
            case .notDetermined: self = .notDetermined
            case .denied, .restricted, .writeOnly: self = .blocked
            }
        }

        init(_ status: CapturePermissionState) {
            switch status {
            case .granted: self = .granted
            case .notDetermined: self = .notDetermined
            case .denied, .restricted: self = .blocked
            }
        }
    }

    enum Requirement {
        case required
        case optional
    }

    let symbol: String
    let title: String
    let detail: String
    let state: State
    let requirement: Requirement
    let request: () -> Void
    let openSettings: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .frame(width: 26)
                .foregroundStyle(state == .granted ? Color.green : .secondary)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(title).font(.headline)
                    if requirement == .optional {
                        Text("선택")
                            .font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                    }
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            action
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var action: some View {
        switch state {
        case .granted:
            Label("허용됨", systemImage: "checkmark.circle.fill")
                .labelStyle(.iconOnly)
                .font(.title3)
                .foregroundStyle(.green)
        case .notDetermined:
            Button("허용", action: request)
                .buttonStyle(.borderedProminent)
        case .blocked:
            // 한 번 거부하면 앱에서 다시 물어볼 수 없다. 시스템 설정으로 보낸다.
            Button("시스템 설정 열기", action: openSettings)
                .buttonStyle(.bordered)
        }
    }
}

/// 모델 설치 한 줄. 권한 줄과 같은 골격이고, 오른쪽에 설치 버튼이나 진행률이 온다.
struct ModelInstallRow: View {
    let symbol: String
    let title: String
    let detail: String
    let choice: ModelChoice?
    let status: ModelInstallCenter.Status
    let install: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .frame(width: 26)
                .foregroundStyle(status.isInstalled ? Color.green : .secondary)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(title).font(.headline)
                    Text("필수")
                        .font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                }
                Text(detailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if case let .installing(fraction) = status {
                    HStack(spacing: 8) {
                        ProgressView(value: fraction)
                        Text("\(Int((fraction * 100).rounded()))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 12)
            action
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var detailText: String {
        guard let choice else { return detail }
        return "\(choice.name) · \(detail) (내려받기 \(sizeText(choice.downloadSizeGB)))"
    }

    @ViewBuilder
    private var action: some View {
        switch status {
        case .installed:
            Label("설치됨", systemImage: "checkmark.circle.fill")
                .labelStyle(.titleAndIcon)
                .font(.caption)
                .foregroundStyle(.green)
        case .notInstalled:
            Button("내려받기", action: install)
                .buttonStyle(.borderedProminent)
        case .installing:
            Text("설치 중…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func sizeText(_ gigabytes: Double) -> String {
        gigabytes < 1
            ? "\(Int((gigabytes * 1000).rounded()))MB"
            : String(format: "%.1fGB", gigabytes)
    }
}

/// 온보딩을 담는 창.
///
/// SwiftUI `Window` 씬은 `openWindow` 액션이 있어야 열 수 있어 App 구조체에서 다루기 번거롭다.
/// 캡슐 창과 같은 방식으로 AppKit 창을 직접 만든다.
@MainActor
public final class OnboardingWindowController {
    private var window: NSWindow?

    public init() {}

    public var isVisible: Bool {
        window?.isVisible == true
    }

    public func show(
        coordinator: MeetingSessionCoordinator,
        installs: ModelInstallCenter,
        onFinish: @escaping () -> Void
    ) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(
            rootView: OnboardingView(coordinator: coordinator, installs: installs) { [weak self] in
                onFinish()
                self?.close()
            }
        )
        let window = NSWindow(contentViewController: hosting)
        window.title = "\(AppIdentity.productName) 시작하기"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func close() {
        window?.orderOut(nil)
    }
}
