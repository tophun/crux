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
/// Atlassian 계정은 Keychain에 저장한다. 사고 모드 같은 AI 내부 동작 설정은 두지 않는다(§11).
public struct SettingsView: View {
    let databaseURL: URL
    let modelDirectory: URL
    @Bindable var coordinator: MeetingSessionCoordinator
    @Bindable var storage: AudioStorageModel
    @Bindable var installs: ModelInstallCenter
    @Bindable var notifications: EventNotificationStore

    @State private var selection: Pane = .general
    @State private var atlassian: AtlassianSettingsModel

    public init(
        databaseURL: URL,
        modelDirectory: URL,
        coordinator: MeetingSessionCoordinator,
        storage: AudioStorageModel,
        installs: ModelInstallCenter,
        notifications: EventNotificationStore
    ) {
        self.databaseURL = databaseURL
        self.modelDirectory = modelDirectory
        self.coordinator = coordinator
        self.storage = storage
        self.installs = installs
        self.notifications = notifications
        _atlassian = State(initialValue: AtlassianSettingsModel(store: coordinator.credentialStore))
    }

    enum Pane: String, CaseIterable, Identifiable {
        case general
        case vocabulary
        case detection
        case permissions
        case audio
        case atlassian
        case privacy

        var id: String {
            rawValue
        }

        var title: String {
            switch self {
            case .general: "일반"
            case .vocabulary: "용어"
            case .detection: "회의 감지"
            case .permissions: "권한"
            case .audio: "오디오 보관"
            case .atlassian: "Atlassian"
            case .privacy: "개인정보 및 저장 위치"
            }
        }

        var symbol: String {
            switch self {
            case .general: "gearshape.fill"
            case .vocabulary: "character.book.closed.fill"
            case .detection: "calendar"
            case .permissions: "lock.fill"
            case .audio: "waveform"
            case .atlassian: "link"
            case .privacy: "hand.raised.fill"
            }
        }

        var color: Color {
            switch self {
            case .general: .gray
            case .vocabulary: .orange
            case .detection: .red
            case .permissions: .green
            case .audio: .purple
            case .atlassian: .orange
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
        .task {
            await coordinator.refreshPermissions()
            await notifications.refresh()
        }
    }

    @ViewBuilder
    private var detailForm: some View {
        switch selection {
        case .general: NotePane(installs: installs)
        case .vocabulary: VocabularyPane()
        case .detection: DetectionPane(notifications: notifications)
        case .permissions: PermissionsPane(coordinator: coordinator, notifications: notifications)
        case .audio: AudioPane(storage: storage)
        case .atlassian: AtlassianPane(model: atlassian, coordinator: coordinator)
        case .privacy: PrivacyPane(databaseURL: databaseURL, modelDirectory: modelDirectory)
        }
    }
}

// MARK: - 권한

private struct PermissionsPane: View {
    @Bindable var coordinator: MeetingSessionCoordinator
    @Bindable var notifications: EventNotificationStore

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
            notificationPermissionRow
        } footer: {
            Text("시스템 오디오는 시스템 설정 → 개인정보 보호 및 보안 → 화면 및 시스템 오디오 기록에서 허용합니다. 허용하지 않으면 마이크만 녹음합니다.")
        }
    }

    @ViewBuilder
    private var notificationPermissionRow: some View {
        if notifications.authorization == .denied {
            LabeledContent {
                Button("시스템 설정 열기") { notifications.openSystemSettings() }
            } label: {
                Text("알림")
                Text("일정 시작을 이 기기에 알립니다. 한 번 거부하면 시스템 설정에서만 다시 켤 수 있습니다.")
            }
        } else {
            PermissionStatusRow(
                title: "알림",
                detail: "일정 시작을 이 기기에 알립니다. Google 알림은 쓰지 않습니다.",
                status: notifications.authorization.displayName,
                isSatisfied: notifications.authorization == .authorized,
                action: { await notifications.requestAuthorization() }
            )
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
    @Bindable var notifications: EventNotificationStore
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
            Text("종일 일정, 취소된 일정, 참석을 거절한 일정은 항상 제외합니다. 일정에 알림이 있으면 그 시각부터, 없으면 시작 5분 전부터 캡슐이 뜨고, 한 일정에 두 번 묻지 않습니다.")
        }
        Section {
            Picker(selection: $notifications.leadMinutes) {
                ForEach(EventNotificationSettings.allowedLeadMinutes, id: \.self) { minutes in
                    Text("\(minutes)분 전").tag(minutes)
                }
            } label: {
                Text("일정 알림 기본 시각")
                Text("일정 상세에서 알림을 켜면 시작 이 시간 전에 이 기기로 알립니다.")
            }
        } header: {
            Text("일정 알림")
        } footer: {
            Text("이 기기 알림만 예약합니다. Google·캘린더 알림은 바꾸지 않습니다.")
        }
    }
}

// MARK: - 용어 (인식 힌트)

private struct VocabularyPane: View {
    @State private var isEnabled = VocabularyStore.standard.isEnabled
    @State private var terms = VocabularyStore.standard.terms
    @State private var draft = ""

    var body: some View {
        Section {
            Toggle(isOn: $isEnabled) {
                Text("인식 힌트 사용")
                Text("똑닥·사람·티켓 이름처럼 자주 깨지는 단어를 음성 인식에 알려 줍니다.")
            }
            .onChange(of: isEnabled) { _, newValue in
                VocabularyStore.standard.isEnabled = newValue
            }
        } footer: {
            Text("힌트는 구간 분할을 거칠게 만들 수 있어 기본값은 꺼져 있습니다. 끄면 지금처럼 힌트 없이 인식합니다. 켠 뒤의 다음 전사부터 적용됩니다.")
        }
        Section {
            HStack(spacing: 8) {
                TextField("용어 추가", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addTerm() }
                Button("추가") { addTerm() }
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if terms.isEmpty {
                Text("아직 용어가 없습니다.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(terms, id: \.self) { term in
                    LabeledContent {
                        Button {
                            removeTerm(term)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("이 용어 삭제")
                        .accessibilityLabel("\(term) 삭제")
                    } label: {
                        Text(term)
                    }
                }
            }
        } header: {
            Text("용어 목록")
        } footer: {
            Text("이 기기에만 저장됩니다. 목록은 꺼 둔 상태에서도 고칠 수 있습니다.")
        }
    }

    private func addTerm() {
        let added = VocabularyStore.standard.addTerm(draft)
        draft = ""
        if added {
            terms = VocabularyStore.standard.terms
        }
    }

    private func removeTerm(_ term: String) {
        VocabularyStore.standard.removeTerm(term)
        terms = VocabularyStore.standard.terms
    }
}

// MARK: - 일반 (문서 프롬프트 + 모델)

private struct NotePane: View {
    @Bindable var installs: ModelInstallCenter
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
                statusFor: { installs.transcription[$0] ?? .notInstalled },
                selection: $transcriptionModel
            )
            .onChange(of: transcriptionModel) { _, newValue in
                ModelPreferenceStore.transcriptionModel = newValue
            }
            ModelInstallHint(
                choice: TranscriptionModelCatalog.choice(for: transcriptionModel),
                status: installs.transcription[transcriptionModel] ?? .notInstalled
            ) {
                installs.installTranscription(transcriptionModel)
            }

            ModelPicker(
                title: "회의록 생성",
                choices: LanguageModelCatalog.all,
                statusFor: { installs.language[$0] ?? .notInstalled },
                selection: $languageModel
            )
            .onChange(of: languageModel) { _, newValue in
                ModelPreferenceStore.languageModel = newValue
            }
            ModelInstallHint(
                choice: LanguageModelCatalog.choice(for: languageModel),
                status: installs.language[languageModel] ?? .notInstalled
            ) {
                installs.installLanguage(languageModel)
            }

            if let error = installs.lastErrorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }
        } header: {
            Text("모델")
        } footer: {
            Text(
                "설치되지 않은 모델을 고르면 여기서 내려받게 됩니다. 미리 받지 않은 모델은 처리 중에 자동으로 내려받지만, 그만큼 기다려야 합니다. 모델 추론은 모두 이 기기에서 실행되며, 네트워크는 내려받을 때만 씁니다. 바꾼 모델은 다음 처리부터 쓰입니다."
            )
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

// MARK: - Atlassian

private struct AtlassianPane: View {
    @Bindable var model: AtlassianSettingsModel
    @Bindable var coordinator: MeetingSessionCoordinator

    var body: some View {
        Section {
            TextField(text: $model.site) {
                Text("사이트")
                Text("예: your-team.atlassian.net")
            }
            TextField(text: $model.email) {
                Text("이메일")
                Text("Atlassian 계정 이메일입니다.")
            }
            SecureField(text: $model.apiToken) {
                Text("API 토큰")
                Text("id.atlassian.com에서 발급한 토큰입니다. Keychain에만 저장합니다.")
            }
            LabeledContent {
                Text(model.isConnected ? "연결됨" : "연결되지 않음")
                    .foregroundStyle(model.isConnected ? .secondary : .primary)
            } label: {
                Text("상태")
                if let summary = model.connectedSummary {
                    Text(summary)
                } else {
                    Text("Confluence 업로드와 Jira 티켓 생성에 사용합니다.")
                }
            }
            LabeledContent {
                HStack(spacing: 10) {
                    Button("저장") {
                        model.save()
                        coordinator.refreshAtlassianCredentials()
                    }
                    .disabled(!model.canSave)
                    if model.isConnected {
                        Button("연결 해제") {
                            model.disconnect()
                            coordinator.refreshAtlassianCredentials()
                        }
                        Button("연결 확인") {
                            Task { await model.verify() }
                        }
                        .disabled(model.isVerifying)
                    }
                }
            } label: {
                Text("연결")
                if let message = model.statusMessage {
                    Text(message)
                } else if model.isConnected {
                    Text("토큰을 바꾸려면 다시 입력한 뒤 저장하세요.")
                }
            }
            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }
        } header: {
            Text("계정")
        } footer: {
            Text("API 토큰은 Keychain에만 저장하며 로그에 남기지 않습니다. 전체 녹취록과 음성 파일은 게시되지 않습니다.")
        }
        .onAppear { model.reload() }
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
            Label("네트워크는 모델 다운로드와 사용자가 승인한 Confluence·Jira·Slack 전송에만 사용합니다", systemImage: "arrow.down.circle")
        }
        Section("저장 위치") {
            PathRow(title: "데이터베이스", url: databaseURL)
            PathRow(title: "모델", url: modelDirectory)
        }
    }
}

/// 모델 고르기 한 줄. 고른 모델의 설명과 설치 여부를 아래에 붙인다.
///
/// 이 기기의 메모리로 감당할 수 없는 모델은 고를 수 없게 막되 목록에는 남긴다.
/// 감추면 왜 없는지 알 수 없고, 그대로 두면 처리 도중에 메모리가 터진다.
private struct ModelPicker: View {
    let title: String
    let choices: [ModelChoice]
    let statusFor: (String) -> ModelInstallCenter.Status
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
                Text("\(current.detail) · \(sizeText(current.downloadSizeGB))")
            }
        }
    }

    private func label(for choice: ModelChoice) -> String {
        var suffix = ""
        if !choice.fits() {
            suffix = " — 메모리 \(choice.minimumMemoryGB)GB 이상 필요"
        } else if statusFor(choice.id) == .notInstalled {
            suffix = " · 미설치"
        }
        return choice.name + suffix
    }

    private func sizeText(_ gigabytes: Double) -> String {
        gigabytes < 1
            ? "\(Int((gigabytes * 1000).rounded()))MB"
            : String(format: "%.1fGB", gigabytes)
    }
}

/// 고른 모델의 설치 상태 한 줄. 미설치면 내려받기 버튼, 받는 중이면 진행률을 보여 준다.
private struct ModelInstallHint: View {
    let choice: ModelChoice?
    let status: ModelInstallCenter.Status
    let install: () -> Void

    var body: some View {
        switch status {
        case .installed:
            LabeledContent {
                Label("설치됨", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
            } label: {
                Text("설치 상태")
                Text("네트워크 없이 바로 사용할 수 있습니다.")
            }
        case .notInstalled:
            LabeledContent {
                Button("내려받기…", action: install)
            } label: {
                Text("설치되지 않음")
                Text("지금 내려받지 않으면 처리 중에 자동으로 받습니다. (\(sizeText))")
            }
        case let .installing(fraction):
            LabeledContent {
                HStack(spacing: 8) {
                    ProgressView(value: fraction)
                        .frame(width: 140)
                    Text("\(Int((fraction * 100).rounded()))%")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            } label: {
                Text("내려받는 중")
                Text("창을 닫아도 계속됩니다. 완료 후 다시 열면 상태가 갱신됩니다.")
            }
        }
    }

    private var sizeText: String {
        guard let size = choice?.downloadSizeGB else { return "" }
        return size < 1
            ? "약 \(Int((size * 1000).rounded()))MB"
            : String(format: "약 %.1fGB", size)
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
