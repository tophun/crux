import AppKit
import MeetingCore
import SwiftUI

/// 설정 화면. 시스템 설정처럼 왼쪽 목록에서 항목을 고르고 오른쪽에 내용을 보여 준다.
///
/// 시스템 설정과 같은 구성 규칙을 따른다.
/// - 설명 문구는 별도 줄이 아니라 **조작 항목의 보조 문구**(라벨의 두 번째 `Text`)로 붙인다.
/// - 어느 항목에도 속하지 않는 안내는 그룹 **아래(footer)** 에 둔다.
/// - 사이드바는 고정 폭이며 접기 버튼이 없다.
///
/// 첫 버전에는 Atlassian(게시) 설정을 두지 않는다. 사고 모드 같은 AI 내부 동작 설정도 없다(§11).
public struct SettingsView: View {
    let databaseURL: URL
    let modelDirectory: URL
    @Bindable var coordinator: MeetingSessionCoordinator
    @Bindable var storage: AudioStorageModel

    @State private var selection: Pane = .general

    public init(
        databaseURL: URL,
        modelDirectory: URL,
        coordinator: MeetingSessionCoordinator,
        storage: AudioStorageModel
    ) {
        self.databaseURL = databaseURL
        self.modelDirectory = modelDirectory
        self.coordinator = coordinator
        self.storage = storage
    }

    enum Pane: String, CaseIterable, Identifiable {
        case general
        case detection
        case permissions
        case audio
        case privacy

        var id: String {
            rawValue
        }

        var title: String {
            switch self {
            case .general: "일반"
            case .detection: "회의 감지"
            case .permissions: "권한"
            case .audio: "오디오 보관"
            case .privacy: "개인정보 및 저장 위치"
            }
        }

        var symbol: String {
            switch self {
            case .general: "gearshape.fill"
            case .detection: "calendar"
            case .permissions: "lock.fill"
            case .audio: "waveform"
            case .privacy: "hand.raised.fill"
            }
        }

        var color: Color {
            switch self {
            case .general: .gray
            case .detection: .red
            case .permissions: .green
            case .audio: .purple
            case .privacy: .blue
            }
        }
    }

    public var body: some View {
        // 사이드바는 항상 보인다. 접기 버튼도, 폭 조절도 두지 않는다(시스템 설정과 같다).
        NavigationSplitView(columnVisibility: .constant(.all)) {
            List(Pane.allCases, selection: $selection) { pane in
                Label {
                    Text(pane.title)
                } icon: {
                    Image(systemName: pane.symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(pane.color, in: RoundedRectangle(cornerRadius: 5.5))
                }
                .tag(pane)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(215)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            // 시스템 설정과 같은 표준 스타일. 상자·여백을 직접 그리지 않는다.
            Form {
                detailForm
            }
            .formStyle(.grouped)
            .navigationTitle(selection.title)
        }
        // 시스템 설정과 비슷한 크기로 열린다. 사이드바 215 + 내용 500.
        .frame(minWidth: 715, idealWidth: 715, minHeight: 560, idealHeight: 640)
        .task { await coordinator.refreshPermissions() }
    }

    @ViewBuilder
    private var detailForm: some View {
        switch selection {
        case .general: NotePane()
        case .detection: DetectionPane()
        case .permissions: PermissionsPane(coordinator: coordinator)
        case .audio: AudioPane(storage: storage)
        case .privacy: PrivacyPane(databaseURL: databaseURL, modelDirectory: modelDirectory)
        }
    }
}

// MARK: - 권한

private struct PermissionsPane: View {
    @Bindable var coordinator: MeetingSessionCoordinator

    var body: some View {
        Section {
            PermissionStatusRow(
                title: "캘린더",
                detail: "회의 일정을 읽어 시작을 감지하고 제목·참석자를 채웁니다.",
                status: coordinator.calendarStatus.displayName,
                isSatisfied: coordinator.calendarStatus == .authorized,
                action: { await coordinator.requestCalendarAccess() }
            )
            PermissionStatusRow(
                title: "마이크",
                detail: "회의 음성을 이 기기에서 녹음합니다.",
                status: coordinator.microphoneStatus.displayName,
                isSatisfied: coordinator.microphoneStatus == .granted,
                action: { await coordinator.requestRecordingPermissions() }
            )
            PermissionStatusRow(
                title: "시스템 오디오",
                detail: "화상회의 앱에서 나오는 상대방 목소리를 함께 녹음합니다. 선택 사항입니다.",
                status: coordinator.systemAudioStatus.displayName,
                isSatisfied: coordinator.systemAudioStatus == .granted,
                action: { await coordinator.requestSystemAudioPermission() }
            )
        } footer: {
            Text("시스템 오디오는 시스템 설정 → 개인정보 보호 및 보안 → 화면 및 시스템 오디오 기록에서 허용합니다. 허용하지 않으면 마이크만 녹음합니다.")
        }
    }
}

/// 권한 한 줄. 왼쪽에 이름과 설명, 오른쪽에 상태와 허용 버튼을 둔다.
private struct PermissionStatusRow: View {
    let title: String
    let detail: String
    let status: String
    let isSatisfied: Bool
    let action: () async -> Void

    var body: some View {
        LabeledContent {
            HStack(spacing: 10) {
                Text(status)
                    .foregroundStyle(isSatisfied ? .secondary : .primary)
                if !isSatisfied {
                    Button("허용…") { Task { await action() } }
                }
            }
        } label: {
            Text(title)
            Text(detail)
        }
    }
}

// MARK: - 회의 감지

private struct DetectionPane: View {
    @State private var includesSoloEvents = MeetingDetectionSettings.includesSoloEvents

    var body: some View {
        Section {
            Toggle(isOn: $includesSoloEvents) {
                Text("참석자가 없는 일정도 회의로 감지")
                Text("기본값은 참석자가 2명 이상인 일정만 감지합니다. 혼자 만든 일정으로 시험하거나 참석자를 초대하지 않는다면 켜세요.")
            }
            .onChange(of: includesSoloEvents) { _, newValue in
                MeetingDetectionSettings.includesSoloEvents = newValue
            }
        } footer: {
            Text("종일 일정과 취소된 일정은 항상 제외합니다. 일정에 알림이 있으면 그 시각부터, 없으면 시작 5분 전부터 캡슐이 뜨고, 한 일정에 두 번 묻지 않습니다.")
        }
    }
}

// MARK: - 일반 (문서 프롬프트 + 모델)

private struct NotePane: View {
    @State private var documentPrompt = DocumentPromptStore.prompt
    @State private var transcriptionModel = ModelPreferenceStore.transcriptionModel
    @State private var languageModel = ModelPreferenceStore.languageModel

    var body: some View {
        Section {
            TextEditor(text: $documentPrompt)
                .font(.body)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 110)
                .padding(.horizontal, 5)
                .padding(.vertical, 4)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color(nsColor: .separatorColor))
                )
                .onChange(of: documentPrompt) { _, newValue in
                    DocumentPromptStore.prompt = newValue
                }
        } header: {
            Text("문서 구성 프롬프트")
        } footer: {
            Text("비워 두면 기본 구성(날짜·참여자·요약·논의·Action Item)을 씁니다. 입력하면 검증된 내용만으로 문서를 이 지시대로 다시 구성하며, 없는 사실은 만들지 않습니다. 다음 생성부터 적용됩니다.")
        }
        Section {
            ModelPicker(
                title: "음성 인식",
                choices: TranscriptionModelCatalog.all,
                selection: $transcriptionModel
            )
            .onChange(of: transcriptionModel) { _, newValue in
                ModelPreferenceStore.transcriptionModel = newValue
            }
            ModelPicker(
                title: "회의록 생성",
                choices: LanguageModelCatalog.all,
                selection: $languageModel
            )
            .onChange(of: languageModel) { _, newValue in
                ModelPreferenceStore.languageModel = newValue
            }
        } header: {
            Text("모델")
        } footer: {
            Text("바꾼 모델은 다음 처리부터 쓰입니다. 처음 쓰는 모델은 실행 중에 내려받으므로 그만큼 오래 걸립니다. 모델 추론은 모두 이 기기에서 실행되며, 네트워크는 내려받을 때만 씁니다.")
        }
    }
}

// MARK: - 오디오 보관

private struct AudioPane: View {
    @Bindable var storage: AudioStorageModel

    var body: some View {
        Section {
            LabeledContent {
                Text(storage.usageText).foregroundStyle(.secondary)
            } label: {
                Text("현재 사용량")
                if let untracked = storage.untrackedText {
                    Text(untracked)
                }
            }
            Picker(selection: $storage.retention) {
                ForEach(AudioRetention.allCases, id: \.self) { option in
                    Text(option.label).tag(option)
                }
            } label: {
                Text("보관 기간")
                Text(storage.retention.detail)
            }
            Toggle(isOn: $storage.discardRawAfterProcessing) {
                Text("회의록을 만든 뒤 원본 트랙 정리")
                Text("마이크·시스템 원본을 지우고 합성본만 남깁니다. 재생과 재처리는 합성본으로 그대로 됩니다.")
            }
            .disabled(storage.retention == .immediate)
            LabeledContent {
                HStack(spacing: 10) {
                    Button("지금 정리") { storage.sweepNow() }
                    Button("사용량 새로 고침") { storage.refresh() }
                }
            } label: {
                Text("정리")
                if let message = storage.statusMessage {
                    Text(message)
                }
            }
        } footer: {
            Text("지운 오디오는 휴지통으로 갑니다. 전사문·회의록·근거는 이 설정과 관계없이 계속 보관합니다.")
        }
    }
}

// MARK: - 개인정보 및 저장 위치

private struct PrivacyPane: View {
    let databaseURL: URL
    let modelDirectory: URL

    var body: some View {
        Section("개인정보") {
            Label("회의 오디오·전사문·회의록은 이 기기에만 저장됩니다", systemImage: "lock.laptopcomputer")
            Label("전체 녹취록과 음성 파일은 외부로 전송하지 않습니다", systemImage: "network.slash")
            Label("네트워크는 모델 다운로드에만 사용합니다", systemImage: "arrow.down.circle")
        }
        Section("저장 위치") {
            PathRow(title: "데이터베이스", url: databaseURL)
            PathRow(title: "모델", url: modelDirectory)
        }
    }
}

/// 모델 고르기 한 줄. 고른 모델의 설명과 내려받을 크기를 아래에 붙인다.
///
/// 이 기기의 메모리로 감당할 수 없는 모델은 고를 수 없게 막되 목록에는 남긴다.
/// 감추면 왜 없는지 알 수 없고, 그대로 두면 처리 도중에 메모리가 터진다.
private struct ModelPicker: View {
    let title: String
    let choices: [ModelChoice]
    @Binding var selection: String

    private var current: ModelChoice? {
        choices.first { $0.id == selection }
    }

    var body: some View {
        Picker(selection: $selection) {
            ForEach(choices) { choice in
                Text(label(for: choice))
                    .tag(choice.id)
                    .disabled(!choice.fits())
            }
        } label: {
            Text(title)
            if let current {
                Text("\(current.detail) 내려받기 \(sizeText(current.downloadSizeGB))")
            }
        }
    }

    private func label(for choice: ModelChoice) -> String {
        choice.fits()
            ? choice.name
            : "\(choice.name) — 메모리 \(choice.minimumMemoryGB)GB 이상 필요"
    }

    private func sizeText(_ gigabytes: Double) -> String {
        gigabytes < 1
            ? "\(Int((gigabytes * 1000).rounded()))MB"
            : String(format: "%.1fGB", gigabytes)
    }
}

/// 경로 한 줄. 우측 버튼으로 Finder에서 바로 연다.
private struct PathRow: View {
    let title: String
    let url: URL

    var body: some View {
        LabeledContent {
            Button {
                // 파일이면 Finder에서 선택해 보여 주고, 폴더면 그 폴더를 연다.
                if url.hasDirectoryPath || (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    NSWorkspace.shared.open(url)
                } else {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            } label: {
                Image(systemName: "arrow.up.forward.square")
            }
            .buttonStyle(.borderless)
            .help("Finder에서 열기")
            .accessibilityLabel("\(title) Finder에서 열기")
        } label: {
            Text(title)
            Text(url.path)
        }
        .textSelection(.enabled)
    }
}
