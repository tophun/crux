import AppKit
import MeetingCore
import SwiftUI

/// 회의 상세(§11). 요약·결정사항·액션아이템·리스크·미해결 질문·전사문·미리보기 탭.
///
/// 타임라인 탭은 두지 않는다. 각 항목의 근거 시각은 해당 탭에서 바로 누를 수 있고,
/// 시간순 나열은 전사문과 내용이 겹친다.
public struct MeetingDetailView: View {
    @Bindable var state: AppState

    public init(state: AppState) {
        self.state = state
    }

    public var body: some View {
        Group {
            if let detail = state.detail {
                VStack(alignment: .leading, spacing: 0) {
                    header(detail)
                    Divider()
                    content(detail)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .contentShape(Rectangle())
                .onTapGesture {
                    // 빈 곳을 누르면 제목 입력에서 커서를 뺀다(그때 제목이 저장된다).
                    // 버튼·입력 칸은 자기 탭을 먼저 가져가므로 이 처리에 영향을 받지 않는다.
                    NSApp.keyWindow?.makeFirstResponder(nil)
                }
            } else if MeetingSplitEmptyPolicy.showsDetailPlaceholder(hasDetail: false) {
                ContentUnavailableView("회의를 선택하세요", systemImage: "doc.text")
            } else {
                Color.clear
            }
        }
        .deleteConfirmation(state: state)
    }

    private func header(_ detail: MeetingDetail) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // 제목·날짜·상태는 카드 하나에 모아 보여 준다. 제목은 카드 안에서 바로 고칠 수 있다.
            AudioPlayerBar(
                playback: state.playback,
                recordedAt: detail.meeting.startedAt,
                titleView: AnyView(TitleField(state: state, detail: detail))
            )
            .padding(.vertical, 2)

            if state.isProcessing {
                HStack(spacing: 10) {
                    ProgressView(value: state.progress?.fraction ?? 0) {
                        Text(state.progress?.message ?? "준비 중").font(.caption)
                    }
                    Button("취소") { state.cancelProcessing() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }

            // 전역 상태 문구(삭제·저장 등)는 여기 두지 않는다. 다른 회의를 열어도 남아 문맥이 어긋난다.
            if let message = state.errorMessage {
                Text(message).font(.caption).foregroundStyle(.red)
            }

            if let hit = state.selectedSearchHit {
                SearchMatchBanner(hit: hit)
            }
        }
        .padding()
    }

    /// 툴바 우측 버튼. 공유는 시스템 공유 시트로 마크다운 텍스트를 보낸다.
    func actionButtons(_ detail: MeetingDetail) -> some View {
        HStack(spacing: 6) {
            ShareLink(item: MeetingNoteExporter.document(
                detail.note ?? MeetingNote(meetingId: detail.meeting.id),
                meeting: detail.meeting,
                attendees: detail.attendees
            )) {
                Image(systemName: "square.and.arrow.up").frame(width: 22, height: 18)
            }
            .help("공유")
            .accessibilityLabel("공유")
            .disabled(detail.note == nil)

            Menu {
                Button(regenerateTitle(detail), systemImage: "arrow.clockwise") {
                    if detail.meeting.status == .failed {
                        state.retry(meetingId: detail.meeting.id)
                    } else {
                        state.process(meetingId: detail.meeting.id, force: detail.note != nil)
                    }
                }
                .disabled(state.isProcessing)
                Divider()
                Button("회의 삭제…", systemImage: "trash", role: .destructive) {
                    state.requestDelete(meetingId: detail.meeting.id)
                }
            } label: {
                Image(systemName: "ellipsis").frame(width: 22, height: 18)
            }
            .help("더보기")
            .accessibilityLabel("더보기")
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.bordered)
        .controlSize(.large)
        .fixedSize()
        .imageScale(.medium)
    }

    /// 상황에 따라 달라지는 재생성 항목 이름.
    private func regenerateTitle(_ detail: MeetingDetail) -> String {
        if detail.meeting.status == .failed {
            return "다시 처리"
        }
        return detail.note == nil ? "회의록 생성" : "다시 생성"
    }

    @ViewBuilder
    private func content(_ detail: MeetingDetail) -> some View {
        switch state.detailTab {
        case .preview:
            VStack(alignment: .leading, spacing: 0) {
                if !detail.memos.isEmpty {
                    MemoListView(memos: detail.memos) { elapsed in
                        state.playback.seek(to: elapsed)
                    }
                    Divider()
                }
                MarkdownPreviewTab(state: state, detail: detail)
            }
        case .transcript:
            TranscriptTab(state: state, detail: detail)
        }
    }
}

struct SummaryTab: View {
    @Bindable var state: AppState
    let detail: MeetingDetail

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let note = detail.note {
                    EditableParagraph(
                        title: "요약",
                        text: note.summary,
                        placeholder: "요약이 없습니다."
                    ) { edited in
                        state.updateSummary(edited, meetingId: detail.meeting.id)
                    }
                    if !note.topics.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("주제").font(.headline)
                            ForEach(note.topics) { topic in
                                Text("· \(topic.title)\(topic.summary.isEmpty ? "" : " — \(topic.summary)")")
                                    .font(.callout)
                            }
                        }
                    }
                    GenerationSummaryView(summary: note.generation)
                } else {
                    Text("아직 회의록이 생성되지 않았습니다.").foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
    }
}

/// 처리 관측값. 내부 사고 내용은 포함하지 않는다.
struct GenerationSummaryView: View {
    let summary: GenerationSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("처리 정보").font(.headline)
            Text("구간 \(summary.windowCount)개 · 후보 \(summary.candidateCount)건 · 재검토 \(summary.thinkingReviewCount)건")
            Text("반복 통합 \(summary.mergedDuplicateCount)건 · 근거 미확인 제거 \(summary.evidenceRejectedCount)건")
            Text(
                "회의록 유지 \(summary.keptSegmentCount) / 요약 \(summary.condensedSegmentCount)"
                    + " / 제외 \(summary.excludedSegmentCount) / 보류 \(summary.uncertainSegmentCount) 구간"
            )
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

/// 결정사항. 확정과 제안을 나눠 보여 주고, 본문은 사용자가 고칠 수 있다.
///
/// 확정·제안 구분(`kind`)은 편집에서 바꾸지 않는다. 근거와 함께 모델이 판단한 값을 유지한다.
struct DecisionsTab: View {
    @Bindable var state: AppState
    let detail: MeetingDetail

    var body: some View {
        EditableTextList(
            title: "결정사항",
            items: (detail.note?.decisions ?? []).map {
                (text: DecisionDisplay.text(for: $0), evidence: $0.evidence)
            },
            segments: detail.segments,
            onSeek: { state.play(from: $0) },
            onSave: { edits in
                let merged = mergeEdits(edits, into: detail.note?.decisions ?? []) {
                    Decision(content: DecisionDisplay.stripped($0), kind: .decided)
                } update: { text, decision in
                    var updated = decision
                    updated.content = DecisionDisplay.stripped(text)
                    return updated
                }
                state.updateDecisions(merged, meetingId: detail.meeting.id)
            }
        )
    }
}

/// 회의 제목. 눌러서 바로 고칠 수 있다.
///
/// 입력 중에는 화면 값만 바뀌고, 엔터를 치거나 포커스를 잃을 때 저장한다.
/// 목록과 회의록 문서가 같은 제목을 쓰도록 회의와 회의록 제목을 함께 바꾼다.
struct TitleField: View {
    @Bindable var state: AppState
    let detail: MeetingDetail

    @State private var draft = ""
    @FocusState private var isFocused: Bool

    private var current: String {
        detail.note?.title.isEmpty == false ? detail.note!.title : detail.meeting.title
    }

    var body: some View {
        TextField("회의 제목", text: $draft)
            .textFieldStyle(.plain)
            .font(.title2.bold())
            .lineLimit(1)
            .focused($isFocused)
            .onSubmit { commit() }
            .onChange(of: isFocused) { _, focused in
                if !focused {
                    commit()
                }
            }
            .onAppear { draft = current }
            .onChange(of: detail.meeting.id) { _, _ in draft = current }
            .onChange(of: current) { _, newValue in
                // 다시 생성 등으로 제목이 바뀌면 입력 중이 아닐 때만 따라간다.
                if !isFocused {
                    draft = newValue
                }
            }
            .fixedSize(horizontal: false, vertical: true)
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            draft = current
            return
        }
        guard trimmed != current else { return }
        state.updateTitle(trimmed, meetingId: detail.meeting.id)
    }
}

/// 결정·액션의 원문 근거를 타임스탬프와 함께 보여준다(§2, §11).
///
/// 타임스탬프를 누르면 그 지점부터 녹음을 들을 수 있다.
struct EvidenceView: View {
    let evidence: [Evidence]
    let segments: [TranscriptSegment]
    var onSeek: ((TimeInterval) -> Void)?

    var body: some View {
        if evidence.isEmpty {
            Text("근거 없음 — \(UnresolvedMarker.needsConfirmation)")
                .font(.caption2)
                .foregroundStyle(.orange)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(evidence.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 4) {
                        if let onSeek {
                            Button {
                                onSeek(item.startTime)
                            } label: {
                                Label(TimeFormat.stamp(item.startTime), systemImage: "play.circle")
                                    .font(.caption2.monospacedDigit())
                            }
                            .buttonStyle(.link)
                            .help("이 지점부터 듣기")
                        } else {
                            Text(TimeFormat.stamp(item.startTime))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Text("“\(item.quote)”")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }
}

struct TranscriptTab: View {
    @Bindable var state: AppState
    let detail: MeetingDetail
    @State private var showExcluded = false
    @State private var filter = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("전사문 검색", text: $filter).textFieldStyle(.roundedBorder)
                Toggle("회의록에서 제외된 구간 보기", isOn: $showExcluded)
            }
            .padding(.horizontal).padding(.top, 8)

            let labels = detail.relevanceBySegment
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(detail.segments) { segment in
                        let label = labels[segment.id] ?? .uncertain
                        if showExcluded || label != .exclude,
                           filter.isEmpty || segment.text.localizedCaseInsensitiveContains(filter) {
                            let isPlayingSegment = state.playback.currentTime >= segment.startTime
                                && state.playback.currentTime < segment.endTime
                            HStack(alignment: .top, spacing: 8) {
                                Button {
                                    state.play(from: segment.startTime)
                                } label: {
                                    Text(TimeFormat.stamp(segment.startTime))
                                        .font(.caption.monospacedDigit())
                                        .frame(width: 52, alignment: .leading)
                                }
                                .buttonStyle(.link)
                                .help("이 구간부터 듣기")
                                Text(segment.text)
                                    .foregroundStyle(label == .exclude ? .secondary : .primary)
                                    .textSelection(.enabled)
                                Spacer()
                                Text(label.rawValue)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                            .padding(.horizontal, 4)
                            .background(
                                isPlayingSegment ? Color.accentColor.opacity(0.12) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 4)
                            )
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
        }
    }
}

/// 회의록을 마크다운 문서 형태로 미리 본다.
///
/// 내보내기와 **같은 문자열**을 그린다. 화면에서 본 것과 내보낸 파일이 달라지면 안 되기 때문이다.
/// 전사문은 회의록에 포함하지 않으므로 여기에도 나오지 않는다.
struct MarkdownPreviewTab: View {
    @Bindable var state: AppState
    let detail: MeetingDetail
    /// 원본 마크다운 보기. 붙여 넣어 쓸 때 필요하다.
    @State private var showsSource = false
    @State private var draft = ""

    /// 편집 상태는 AppState가 든다. 제목 칸이 같은 편집/저장 흐름을 따라야 하기 때문이다.
    private var isEditing: Bool {
        state.isEditingDocument
    }

    private var markdown: String? {
        guard let note = detail.note else { return nil }
        return MeetingNoteExporter.document(note, meeting: detail.meeting, attendees: detail.attendees)
    }

    var body: some View {
        if let markdown {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Picker("", selection: $showsSource) {
                        Text("Preview").tag(false)
                        Text("Markdown").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 180)
                    .disabled(isEditing)
                    Spacer()
                    if isEditing {
                        Button("취소") { state.isEditingDocument = false }
                            .buttonStyle(.bordered)
                        Button("저장") {
                            state.updateDocument(draft, meetingId: detail.meeting.id)
                            state.isEditingDocument = false
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Button {
                            draft = markdown
                            state.isEditingDocument = true
                        } label: {
                            Label("편집", systemImage: "pencil")
                        }
                        .buttonStyle(.bordered)
                        Button {
                            copy(markdown)
                        } label: {
                            Label("복사", systemImage: "doc.on.doc")
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                Divider()
                if isEditing {
                    // 서식 있는 화면을 직접 고칠 수는 없으므로 원본 마크다운을 편집한다.
                    TextEditor(text: $draft)
                        .font(.system(size: 12, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(12)
                } else {
                    ScrollView {
                        if showsSource {
                            Text(markdown)
                                .font(.system(size: 12, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding()
                        } else {
                            rendered(markdown)
                        }
                    }
                }
            }
            .onChange(of: detail.meeting.id) { _, _ in state.isEditingDocument = false }
        } else {
            ContentUnavailableView(
                "아직 회의록이 없습니다",
                systemImage: "doc.richtext",
                description: Text("회의록을 생성하면 여기에서 문서 형태로 볼 수 있습니다.")
            )
        }
    }

    /// 마크다운을 읽기 좋은 문서로 그린다.
    ///
    /// 본문 폭을 글 읽기에 적당한 640pt로 제한해 가운데 두고,
    /// 굵게·기울임 같은 줄 안 서식은 시스템 마크다운 해석(AttributedString)에 맡긴다.
    private func rendered(_ markdown: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(MarkdownBlockParser.parse(markdown)) { block in
                switch block {
                case let .heading(level, text):
                    inline(text)
                        .font(headingFont(level))
                        .padding(.top, level <= 1 ? 4 : 18)
                        .padding(.bottom, level <= 1 ? 10 : 6)
                case let .bullet(text):
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Circle()
                            .fill(.secondary)
                            .frame(width: 4, height: 4)
                            .padding(.top, 7)
                        inline(text)
                            .lineSpacing(3)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 3)
                case let .checklist(text, done):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: done ? "checkmark.square.fill" : "square")
                            .foregroundStyle(done ? Color.accentColor : .secondary)
                        inline(text)
                            .strikethrough(done, color: .secondary)
                            .lineSpacing(3)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 3)
                case let .paragraph(text):
                    inline(text)
                        .lineSpacing(4)
                        .textSelection(.enabled)
                        .padding(.vertical, 4)
                case let .table(headers, rows):
                    MarkdownTableView(headers: headers, rows: rows)
                        .padding(.vertical, 6)
                }
            }
        }
        // 카드와 같은 좌측 여백에서 시작하고, 본문 폭만 640으로 제한한다.
        .frame(maxWidth: 640, alignment: .leading)
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .system(size: 24, weight: .bold)
        case 2: .system(size: 18, weight: .semibold)
        default: .system(size: 15, weight: .semibold)
        }
    }

    /// 굵게(**)·기울임 같은 줄 안 서식을 살려서 그린다. 해석에 실패하면 그대로 보여 준다.
    private func inline(_ text: String) -> Text {
        if let attributed = try? AttributedString(markdown: text) {
            return Text(attributed)
        }
        return Text(text)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// 표. 머리글 아래에 선을 긋고 행 간격을 넉넉히 둔다. 가로가 좁으면 스크롤한다.
struct MarkdownTableView: View {
    let headers: [String]
    let rows: [[String]]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                if !headers.isEmpty {
                    GridRow {
                        ForEach(Array(headers.enumerated()), id: \.offset) { _, header in
                            Text(header)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Divider().gridCellUnsizedAxes(.horizontal)
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(cell)
                                .font(.system(size: 13))
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .padding(12)
            .background(Color(nsColor: .quaternarySystemFill), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

/// 창 툴바에 올리는 공유·더보기 버튼. 상세 화면의 버튼 로직을 그대로 쓴다.
public struct DetailToolbarButtons: View {
    @Bindable var state: AppState
    let detail: MeetingDetail

    public init(state: AppState, detail: MeetingDetail) {
        self.state = state
        self.detail = detail
    }

    public var body: some View {
        MeetingDetailView(state: state).actionButtons(detail)
    }
}

/// 목록에서 고른 검색 결과가 맞춘 문장. 검색을 지울 때까지 상세 위에 남겨 둔다.
struct SearchMatchBanner: View {
    let hit: MeetingSearch.Hit

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("검색 일치 · \(hit.field.displayName)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(hit.sentence)
                .font(.callout)
                .textSelection(.enabled)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("검색 일치, \(hit.field.displayName), \(hit.sentence)")
    }
}

/// 툴바 오른쪽 끝에 두는 검색칸. 시스템 검색칸과 같은 모양으로 그린다.
public struct ToolbarSearchField: View {
    @Bindable var state: AppState

    public init(state: AppState) {
        self.state = state
    }

    public var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            TextField("회의·전사문·액션아이템 검색", text: Binding(
                get: { state.searchText },
                set: { state.searchText = $0 }
            ))
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            if !state.searchText.isEmpty {
                Button {
                    state.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(width: 260)
        .background(Color(nsColor: .quaternarySystemFill), in: Capsule())
    }
}

/// 녹음 중 남긴 메모 목록. 시각을 누르면 그 위치부터 재생한다.
struct MemoListView: View {
    let memos: [MeetingMemo]
    let onSeek: (TimeInterval) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("회의 중 메모 · \(memos.count)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(memos) { memo in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Button(memo.elapsedLabel) { onSeek(memo.elapsed) }
                        .buttonStyle(.plain)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tint)
                    Text(memo.text).font(.callout)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
