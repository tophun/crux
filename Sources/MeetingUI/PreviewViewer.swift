import MeetingCore
import Observation
import SwiftUI

/// Preview Viewer 상태.
///
/// Preview와 실제 게시가 **같은 구조화 데이터**(`PublishBundle`)에서 렌더링된다.
/// 사용자가 이 화면에서 고친 내용이 그대로 게시된다.
@MainActor
@Observable
public final class PreviewViewerModel {
    public var bundle: PublishBundle
    public private(set) var evidence: EvidenceBundle
    public private(set) var findings: [MeetingQualityChecker.Finding]
    public private(set) var statusMessage: String?
    public private(set) var errorMessage: String?
    public private(set) var isPublishing = false
    public private(set) var publishedURLs: [String] = []
    /// 사용자가 게시를 승인했는지. 승인 없이는 아무것도 전송하지 않는다.
    public var approved = false
    /// Settings에서 Atlassian 계정을 연결했는지. 없으면 게시 버튼을 끈다.
    public var hasAtlassianCredentials: Bool
    /// Slack 채널 ID·이름 또는 DM. 보내기 직전에 한 번 더 확인한다.
    public var slackDestination = ""
    public var slackSendGate = SlackSendGate()
    public private(set) var isSendingSlack = false
    public private(set) var slackStatusMessage: String?
    public private(set) var slackErrorMessage: String?
    public private(set) var slackResult: String?

    /// 근거 확인 탭에서 녹음을 들을 수 있게 한다. 없으면 재생 UI를 숨긴다.
    public let playback: AudioPlaybackController?

    private let publishAction: @Sendable (PublishBundle, EvidenceBundle) async throws -> [String]
    private let slackSendAction: (@Sendable (PublishBundle, EvidenceBundle, String, Bool) async throws -> String)?
    private let revalidate: @MainActor (PublishBundle) -> [MeetingQualityChecker.Finding]

    public init(
        bundle: PublishBundle,
        evidence: EvidenceBundle,
        findings: [MeetingQualityChecker.Finding],
        playback: AudioPlaybackController? = nil,
        hasAtlassianCredentials: Bool = false,
        publishAction: @escaping @Sendable (PublishBundle, EvidenceBundle) async throws -> [String],
        slackSendAction: (@Sendable (PublishBundle, EvidenceBundle, String, Bool) async throws -> String)? = nil,
        revalidate: @escaping @MainActor (PublishBundle) -> [MeetingQualityChecker.Finding] = { _ in [] }
    ) {
        self.bundle = bundle
        self.evidence = evidence
        self.findings = findings
        self.playback = playback
        self.hasAtlassianCredentials = hasAtlassianCredentials
        self.publishAction = publishAction
        self.slackSendAction = slackSendAction
        self.revalidate = revalidate
    }

    public var canPublish: Bool {
        approved
            && !isPublishing
            && hasAtlassianCredentials
            && !findings.contains { $0.severity == .blocking }
    }

    public func refreshFindings() {
        let updated = revalidate(bundle)
        if !updated.isEmpty || !findings.isEmpty {
            findings = updated
        }
    }

    public var canRequestSlackSend: Bool {
        slackSendAction != nil
            && !isSendingSlack
            && !slackDestination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !bundle.includedIssues.isEmpty
    }

    public var isAwaitingSlackConfirmation: Bool {
        slackSendGate.awaitingConfirmation
    }

    /// 보내기 버튼. 확인 대화상자로 넘길 뿐이며 여기서는 전송하지 않는다.
    public func requestSlackSend() {
        var gate = slackSendGate
        if let reason = gate.begin(destination: slackDestination, actionCount: bundle.includedIssues.count) {
            slackStatusMessage = reason
            slackSendGate = gate
            return
        }
        let payload = SlackActionPayload.make(from: bundle, destination: slackDestination)
        let violations = PublishRedaction.audit(text: payload.messageText(), evidence: evidence)
        if !violations.isEmpty {
            gate.cancel()
            slackStatusMessage = "Slack 본문에 내보내면 안 되는 내용이 있습니다: \(PublishRedaction.describe(violations))"
            slackSendGate = gate
            return
        }
        slackStatusMessage = nil
        slackErrorMessage = nil
        slackSendGate = gate
    }

    public func cancelSlackSend() {
        var gate = slackSendGate
        gate.cancel()
        slackSendGate = gate
    }

    /// 확인 대화상자에서 승인한 뒤에만 전송한다.
    public func confirmSlackSend() {
        var gate = slackSendGate
        guard gate.confirm() else {
            slackSendGate = gate
            slackStatusMessage = "보내기 전에 한 번 더 확인해 주세요."
            return
        }
        slackSendGate = gate
        guard let slackSendAction else {
            slackStatusMessage = "Slack 전송을 사용할 수 없습니다."
            return
        }
        isSendingSlack = true
        slackErrorMessage = nil
        slackStatusMessage = "Slack으로 보내는 중…"
        let snapshot = bundle
        let evidenceSnapshot = evidence
        let destination = slackDestination

        Task { [slackSendAction] in
            do {
                let result = try await slackSendAction(snapshot, evidenceSnapshot, destination, true)
                await MainActor.run {
                    self.isSendingSlack = false
                    self.slackResult = result
                    self.slackStatusMessage = "Slack 전송 완료"
                }
            } catch {
                await MainActor.run {
                    self.isSendingSlack = false
                    self.slackErrorMessage = error.localizedDescription
                    self.slackStatusMessage = "Slack 전송 실패"
                }
            }
        }
    }

    public func publish() {
        guard canPublish else {
            if !hasAtlassianCredentials {
                statusMessage = "설정에서 Atlassian 계정을 연결해 주세요."
            } else {
                statusMessage = approved ? "게시를 막는 문제가 남아 있습니다." : "게시 전에 확인 체크가 필요합니다."
            }
            return
        }
        isPublishing = true
        errorMessage = nil
        statusMessage = "게시 중…"
        let snapshot = bundle
        let evidenceSnapshot = evidence

        Task { [publishAction] in
            do {
                let urls = try await publishAction(snapshot, evidenceSnapshot)
                await MainActor.run {
                    self.isPublishing = false
                    self.publishedURLs = urls
                    self.statusMessage = "게시 완료 (\(urls.count)개 링크)"
                }
            } catch {
                await MainActor.run {
                    self.isPublishing = false
                    self.errorMessage = error.localizedDescription
                    self.statusMessage = "게시 실패"
                }
            }
        }
    }
}

/// Preview Viewer 화면. 탭 구성: 회의록 / Jira 액션 아이템 / 근거 확인.
public struct PreviewViewerView: View {
    @Bindable var model: PreviewViewerModel
    @State private var tab: Tab = .note

    public init(model: PreviewViewerModel) {
        self.model = model
    }

    enum Tab: String, CaseIterable, Identifiable {
        case note, issues, evidence
        var id: String {
            rawValue
        }

        var title: String {
            switch self {
            case .note: "회의록"
            case .issues: "Jira 액션 아이템"
            case .evidence: "근거 확인"
            }
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { tab in Text(tab.title).tag(tab) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)
            Divider()

            switch tab {
            case .note: noteTab
            case .issues: issuesTab
            case .evidence: evidenceTab
            }

            Divider()
            footer
        }
        .frame(minWidth: 720, minHeight: 560)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("게시 전 검토")
                .font(.title3.bold())
            Text("AI 결과물은 여기서 확인·수정한 뒤에만 나갑니다. Slack에는 승인한 액션만 보내며, 전사문·오디오·근거 타임스탬프는 포함되지 않습니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                TextField("Confluence Space 키", text: $model.bundle.spaceKey)
                    .frame(width: 180)
                TextField("Jira Project 키", text: $model.bundle.projectKey)
                    .frame(width: 180)
                    .onChange(of: model.bundle.projectKey) { _, newValue in
                        for index in model.bundle.issues.indices {
                            model.bundle.issues[index].projectKey = newValue
                        }
                    }
                TextField("Slack 채널 또는 DM", text: $model.slackDestination)
                    .frame(width: 200)
                    .help("채널 ID·이름 또는 DM. 예: #eng, C0123, U0123")
            }
            .textFieldStyle(.roundedBorder)
        }
        .padding()
    }

    // MARK: - 회의록 탭

    private var noteTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                labeled("회의 제목") {
                    TextField("", text: $model.bundle.page.title).textFieldStyle(.roundedBorder)
                }
                labeled("날짜") {
                    Text(model.bundle.page.meetingDate).foregroundStyle(.secondary)
                }
                labeled("참석자") {
                    Text(
                        model.bundle.page.attendees.isEmpty
                            ? "캘린더 참석자 정보 없음"
                            : model.bundle.page.attendees.joined(separator: ", ")
                    )
                    .foregroundStyle(.secondary)
                }
                labeled("회의 요약") {
                    TextEditor(text: $model.bundle.page.summary)
                        .frame(minHeight: 90)
                        .font(.body)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                }
                labeled("주요 결정사항") {
                    VStack(spacing: 6) {
                        ForEach(model.bundle.page.decisions.indices, id: \.self) { index in
                            HStack {
                                TextField("", text: $model.bundle.page.decisions[index])
                                    .textFieldStyle(.roundedBorder)
                                Button {
                                    model.bundle.page.decisions.remove(at: index)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        if model.bundle.page.decisions.isEmpty {
                            Text("확정된 결정사항 없음").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                labeled("액션 아이템") {
                    VStack(spacing: 6) {
                        ForEach(model.bundle.page.actionItems.indices, id: \.self) { index in
                            HStack {
                                TextField("작업", text: $model.bundle.page.actionItems[index].task)
                                TextField("담당자", text: $model.bundle.page.actionItems[index].assignee)
                                    .frame(width: 120)
                                TextField("기한", text: $model.bundle.page.actionItems[index].dueDate)
                                    .frame(width: 160)
                            }
                            .textFieldStyle(.roundedBorder)
                        }
                    }
                }
                labeled("논의 내용") {
                    VStack(spacing: 6) {
                        ForEach(model.bundle.page.discussion.indices, id: \.self) { index in
                            HStack {
                                TextField("주제", text: $model.bundle.page.discussion[index].topic)
                                    .frame(width: 160)
                                TextField("내용", text: $model.bundle.page.discussion[index].detail)
                            }
                            .textFieldStyle(.roundedBorder)
                        }
                    }
                }
                labeled("리스크 및 미해결 질문") {
                    VStack(spacing: 6) {
                        ForEach(model.bundle.page.risks.indices, id: \.self) { index in
                            TextField("리스크", text: $model.bundle.page.risks[index])
                                .textFieldStyle(.roundedBorder)
                        }
                        ForEach(model.bundle.page.openQuestions.indices, id: \.self) { index in
                            TextField("미해결 질문", text: $model.bundle.page.openQuestions[index])
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                }
            }
            .padding()
        }
    }

    // MARK: - Jira 탭

    private var issuesTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("생성에 체크한 액션만 Jira와 Slack으로 나갑니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if model.bundle.issues.isEmpty {
                    Text("생성할 액션 아이템이 없습니다.").foregroundStyle(.secondary)
                }
                ForEach(model.bundle.issues.indices, id: \.self) { index in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Toggle("생성", isOn: $model.bundle.issues[index].include)
                                .toggleStyle(.checkbox)
                            TextField("제목", text: $model.bundle.issues[index].summary)
                                .textFieldStyle(.roundedBorder)
                        }
                        HStack {
                            Picker("유형", selection: $model.bundle.issues[index].issueTypeName) {
                                ForEach(JiraIssueDraft.selectableIssueTypes, id: \.self) { Text($0).tag($0) }
                            }
                            .frame(width: 150)
                            Picker(
                                "우선순위",
                                selection: Binding(
                                    get: { model.bundle.issues[index].priorityName ?? "지정 없음" },
                                    set: { model.bundle.issues[index].priorityName = $0 == "지정 없음" ? nil : $0 }
                                )
                            ) {
                                Text("지정 없음").tag("지정 없음")
                                ForEach(JiraIssueDraft.selectablePriorities, id: \.self) { Text($0).tag($0) }
                            }
                            .frame(width: 170)
                        }
                        HStack {
                            TextField(
                                "담당자 (이메일 또는 이름, 비우면 미지정)",
                                text: Binding(
                                    get: { model.bundle.issues[index].assigneeQuery ?? "" },
                                    set: { model.bundle.issues[index].assigneeQuery = $0.isEmpty ? nil : $0 }
                                )
                            )
                            TextField(
                                "기한 YYYY-MM-DD (비우면 미지정)",
                                text: Binding(
                                    get: { model.bundle.issues[index].dueDate ?? "" },
                                    set: { model.bundle.issues[index].dueDate = $0.isEmpty ? nil : $0 }
                                )
                            )
                            .frame(width: 200)
                        }
                        .textFieldStyle(.roundedBorder)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("상세 내용").font(.caption).foregroundStyle(.secondary)
                            ForEach(model.bundle.issues[index].detailParagraphs.indices, id: \.self) { paragraph in
                                TextField("", text: $model.bundle.issues[index].detailParagraphs[paragraph])
                                    .textFieldStyle(.roundedBorder)
                                    .font(.caption)
                            }
                        }
                        Text("프로젝트 \(model.bundle.issues[index].projectKey)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding()
        }
    }

    // MARK: - 근거 확인 탭

    private var evidenceTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("근거 타임스탬프와 원문은 이 화면에서만 확인합니다. 게시물에는 포함되지 않습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let playback = model.playback, playback.isLoaded {
                    AudioPlayerBar(playback: playback)
                }
                ForEach(model.evidence.items, id: \.contentId) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(item.contentId)
                                .font(.caption.monospaced())
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.quaternary, in: Capsule())
                            Text(item.kind).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(item.content)
                        if item.evidence.isEmpty {
                            Text("근거 없음 — \(UnresolvedMarker.needsConfirmation)")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        } else {
                            ForEach(Array(item.evidence.enumerated()), id: \.offset) { _, evidence in
                                HStack(alignment: .top, spacing: 4) {
                                    if let playback = model.playback, playback.isLoaded {
                                        Button {
                                            playback.seek(to: evidence.startTime)
                                        } label: {
                                            Label(TimeFormat.stamp(evidence.startTime), systemImage: "play.circle")
                                                .font(.caption.monospacedDigit())
                                        }
                                        .buttonStyle(.link)
                                        .help("이 지점부터 듣기")
                                    } else {
                                        Text(TimeFormat.stamp(evidence.startTime))
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }
                                    Text("“\(evidence.quote)”")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }
                    Divider()
                }
            }
            .padding()
        }
    }

    // MARK: - 하단

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.findings.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(model.findings.enumerated()), id: \.offset) { _, finding in
                        Label(
                            finding.message,
                            systemImage: finding.severity == .blocking
                                ? "exclamationmark.octagon.fill"
                                : "exclamationmark.triangle"
                        )
                        .font(.caption)
                        .foregroundStyle(finding.severity == .blocking ? .red : .orange)
                    }
                }
            }
            if !model.hasAtlassianCredentials {
                HStack {
                    Text("설정에서 Atlassian 계정을 연결해 주세요.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    SettingsLink {
                        Text("설정 열기")
                    }
                }
            }
            HStack {
                Toggle("검토를 마쳤고 이 내용으로 게시합니다", isOn: $model.approved)
                Spacer()
                if let message = model.errorMessage {
                    Text(message).font(.caption).foregroundStyle(.red)
                } else if let message = model.statusMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
                Button("Confluence·Jira 게시") { model.publish() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canPublish)
            }
            HStack {
                Button("Slack으로 액션 보내기") { model.requestSlackSend() }
                    .disabled(!model.canRequestSlackSend)
                Spacer()
                if let message = model.slackErrorMessage {
                    Text(message).font(.caption).foregroundStyle(.red)
                } else if let message = model.slackStatusMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }
            if !model.publishedURLs.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(model.publishedURLs, id: \.self) { url in
                        Text(url).font(.caption).textSelection(.enabled)
                    }
                }
            }
            if let result = model.slackResult {
                Text(result).font(.caption).textSelection(.enabled)
            }
        }
        .padding()
        .confirmationDialog(
            "승인한 액션을 Slack으로 보낼까요?",
            isPresented: slackConfirmationBinding,
            titleVisibility: .visible
        ) {
            Button("보내기") { model.confirmSlackSend() }
            Button("취소", role: .cancel) { model.cancelSlackSend() }
        } message: {
            Text(
                "액션 \(model.bundle.includedIssues.count)개만 \(model.slackDestination)에 보냅니다. 전사문·오디오·근거 타임스탬프는 포함되지 않습니다."
            )
        }
    }

    private var slackConfirmationBinding: Binding<Bool> {
        Binding(
            get: { model.isAwaitingSlackConfirmation },
            set: { if !$0 { model.cancelSlackSend() } }
        )
    }

    private func labeled(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            content()
        }
    }
}
