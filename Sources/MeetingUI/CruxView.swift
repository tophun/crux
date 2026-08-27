import MeetingCore
import QuartzCore
import SwiftUI

/// Crux 본체.
///
/// 화면 최상단에 붙어 노치와 한 덩어리처럼 보인다.
/// 접힌 줄에는 짧은 상태만 두고, 마우스를 올리면 오른쪽 동작과 아래 안내가 나온다.
public struct CruxView: View {
    let state: CruxState
    let detailMessage: String?
    /// 녹음 중인 회의 제목. 없으면 상태 문구를 쓴다.
    let meetingTitle: String?
    /// 녹음 중 남긴 메모. 최근 것부터 두 개만 보여 준다.
    let memos: [MeetingMemo]
    let metrics: NotchMetrics
    let expansionMode: CruxExpansionMode
    let onHoverChange: (Bool) -> Void
    let onTogglePin: () -> Void
    /// 셸프만 접는 표시 동작. 회의 상태를 숨기는 `onDismiss`와 분리한다.
    let onCollapse: () -> Void
    /// 도메인 상태를 닫는 동작은 호출부가 명시적으로 필요할 때만 사용한다.
    let onPrimaryAction: () -> Void
    let onDismiss: () -> Void
    let onOpenPreview: () -> Void
    let onTogglePause: () -> Void
    let onStop: () -> Void
    let onCancelProcessing: () -> Void
    let onAddMemo: (String) -> Void
    /// 메모 입력 칸의 포커스 변화. 입력 중에는 창이 접히지 않아야 한다.
    let onMemoFocusChange: (Bool) -> Void
    /// 검은 셸프의 실제 렌더 크기. 창이 매 프레임 이 값을 따라가 애니메이션과 완전히 동기화된다.
    let onContentSizeChange: (CGSize) -> Void

    @State private var memoDraft = ""
    @FocusState private var memoFocused: Bool
    /// 접힘↔펼침에서 같은 요소가 순간이동 없이 이동(morph)하도록 잇는다.
    @Namespace private var morph

    public init(
        state: CruxState,
        detailMessage: String? = nil,
        meetingTitle: String? = nil,
        memos: [MeetingMemo] = [],
        metrics: NotchMetrics,
        expansionMode: CruxExpansionMode = .collapsed,
        onAddMemo: @escaping (String) -> Void = { _ in },
        onMemoFocusChange: @escaping (Bool) -> Void = { _ in },
        onContentSizeChange: @escaping (CGSize) -> Void = { _ in },
        onHoverChange: @escaping (Bool) -> Void = { _ in },
        onTogglePin: @escaping () -> Void = {},
        onCollapse: (() -> Void)? = nil,
        onPrimaryAction: @escaping () -> Void,
        onDismiss: @escaping () -> Void,
        onOpenPreview: @escaping () -> Void,
        onTogglePause: @escaping () -> Void = {},
        onStop: @escaping () -> Void = {},
        onCancelProcessing: @escaping () -> Void = {}
    ) {
        self.state = state
        self.detailMessage = detailMessage
        self.meetingTitle = meetingTitle
        self.memos = memos
        self.metrics = metrics
        self.onAddMemo = onAddMemo
        self.onMemoFocusChange = onMemoFocusChange
        self.onContentSizeChange = onContentSizeChange
        self.expansionMode = expansionMode
        self.onHoverChange = onHoverChange
        self.onTogglePin = onTogglePin
        self.onCollapse = onCollapse ?? onDismiss
        self.onPrimaryAction = onPrimaryAction
        self.onDismiss = onDismiss
        self.onOpenPreview = onOpenPreview
        self.onTogglePause = onTogglePause
        self.onStop = onStop
        self.onCancelProcessing = onCancelProcessing
    }

    /// 이전 호출부와의 호환성을 유지하면서 표시 상태는 하나의 값으로 정규화한다.
    public init(
        state: CruxState,
        detailMessage: String? = nil,
        metrics: NotchMetrics,
        isHovering: Bool = false,
        isPinned: Bool = false,
        onHoverChange: @escaping (Bool) -> Void = { _ in },
        onTogglePin: @escaping () -> Void = {},
        onCollapse: (() -> Void)? = nil,
        onPrimaryAction: @escaping () -> Void,
        onDismiss: @escaping () -> Void,
        onOpenPreview: @escaping () -> Void,
        onTogglePause: @escaping () -> Void = {},
        onStop: @escaping () -> Void = {},
        onCancelProcessing: @escaping () -> Void = {}
    ) {
        self.init(
            state: state,
            detailMessage: detailMessage,
            metrics: metrics,
            expansionMode: .resolve(isHovering: isHovering, isPinned: isPinned),
            onHoverChange: onHoverChange,
            onTogglePin: onTogglePin,
            onCollapse: onCollapse,
            onPrimaryAction: onPrimaryAction,
            onDismiss: onDismiss,
            onOpenPreview: onOpenPreview,
            onTogglePause: onTogglePause,
            onStop: onStop,
            onCancelProcessing: onCancelProcessing
        )
    }

    private var presentation: CruxPresentationModel {
        CruxPresentationModel(state: state, detailMessage: detailMessage)
    }

    private var isEnlarged: Bool {
        expansionMode.isExpanded
    }

    private var barHeight: CGFloat {
        metrics.collapsedHeight
    }

    private var horizontalPadding: CGFloat {
        isEnlarged ? 16 : 8
    }

    /// 화면 상단과 캡슐을 잇는 오목한 곡선의 크기.
    private var topFlare: CGFloat { 20 }

    private var barWidth: CGFloat {
        metrics.islandWidth(expanded: isEnlarged)
    }

    private var showsTextButton: Bool {
        presentation.primaryAction != nil && !isRecording
    }

    private var textButtonTitle: String? {
        presentation.primaryAction?.title
    }

    private var showsDetail: Bool {
        isEnlarged && hasDetailCopy
    }

    private var hasDetailCopy: Bool {
        presentation.detailText != nil || presentation.progressFraction != nil
    }

    private var isGenerating: Bool {
        if case .generating = state { return true }
        return false
    }

    private var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    public var body: some View {
        capsuleShape
            // 셸프의 실제 크기를 매 프레임 창에 알려 준다. 창은 이 값을 따라가므로
            // 창 프레임을 따로 애니메이션하지 않아도 내용과 완전히 같이 움직인다.
            .onGeometryChange(for: CGSize.self, of: { $0.size }, action: onContentSizeChange)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .foregroundStyle(.white)
            .onHover { hovering in onHoverChange(hovering) }
            .onTapGesture { onTogglePin() }
    }

    /// 검은 노치 셸프 하나. 접힘·펼침을 한 덩어리로 스프링 변형한다.
    private var capsuleShape: some View {
        VStack(spacing: 0) {
            if isEnlarged, case let .recording(seconds, paused) = state {
                // 녹음 중 펼침은 바+상세 대신 미디어 플레이어형 3단 구조를 쓴다.
                recordingExpanded(seconds: Int(seconds), paused: paused)
            } else {
                capsuleBar
                if showsDetail {
                    detail
                }
            }
        }
        // 위 모서리가 바깥으로 흘러내리는 만큼 내용은 안쪽으로 들인다.
        .padding(.horizontal, topFlare)
        // 창이 커지는 동안에도 내용은 항상 목표 너비로 그린다. 중간 너비에서 글이 줄바꿈되면
        // 높이가 잠깐 튀어 상하로 흔들려 보인다.
        .frame(width: barWidth, alignment: .top)
        .background(Color.black)
        .clipShape(NotchShape(topRadius: topFlare, bottomRadius: isEnlarged ? 20 : 14))
        // 접힘/펼침·상세·메모 변화를 모두 같은 스프링으로 묶는다.
        .animation(CruxAnimation.swiftUI, value: isEnlarged)
        .animation(CruxAnimation.swiftUI, value: showsDetail)
        .animation(CruxAnimation.swiftUI, value: memos.count)
    }

    /// 창이 지금 가진 너비를 반으로 나눠 좌우 날개를 항상 같게 둔다.
    /// 내용 폭으로 고정하면 창이 커지는 동안 오른쪽만 늘어난 것처럼 보인다.
    private var capsuleBar: some View {
        HStack(spacing: 0) {
            // 펼치면 왼쪽 끝으로, 접히면 노치 쪽으로 붙는다. 늘어난 만큼 함께 이동한다.
            leadingCluster
                .frame(maxWidth: .infinity, alignment: isEnlarged ? .leading : .trailing)
            Color.clear.frame(width: metrics.hasNotch ? metrics.notchWidth : 10)
            trailingCluster
                .frame(maxWidth: .infinity, alignment: isEnlarged ? .trailing : .leading)
        }
        // 너비는 바깥 프레임이 정한다. 여기서 최소 너비를 다시 걸면 곡선 여백을 넘쳐 나간다.
        .frame(maxWidth: .infinity)
        .frame(height: barHeight)
        .contentShape(Rectangle())
        // 상태는 한 번에 읽되, 확장 상태의 버튼은 VoiceOver에서 각각 조작할 수 있게 둔다.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(presentation.accessibilityLabel)
    }

    /// 접힌 상태는 글자를 두지 않는다. 왼쪽은 정체(회의 타일·상태 점), 오른쪽은 살아 있는 신호 하나.
    @ViewBuilder
    private var leadingCluster: some View {
        if isEnlarged {
            HStack(spacing: 6) {
                indicator
                Text(presentation.title ?? state.statusText)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.leading, horizontalPadding)
            .padding(.trailing, 8)
            .id(state.kindId)
        } else {
            compactLeading
                .padding(.leading, horizontalPadding)
                .padding(.trailing, 8)
                .id(state.kindId)
        }
    }

    @ViewBuilder
    private var trailingCluster: some View {
        if isEnlarged {
            HStack(spacing: 6) {
                // 펼친 상태에서 텍스트 버튼이 있으면 보조 문구는 뺀다. 같은 내용이 아래 상세에 있고,
                // 둘을 다 두면 날개 폭이 모자라 버튼 제목이 잘린다.
                if let trailing = presentation.trailingText, !(showsTextButton || isGenerating) {
                    Text(trailing)
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .foregroundStyle(.white.opacity(0.92))
                        .contentTransition(.numericText())
                }
                trailingControls
                    .transition(.opacity)
            }
            .padding(.leading, 8)
            .padding(.trailing, horizontalPadding)
            .id(state.kindId)
        } else {
            compactTrailing
                .padding(.leading, 8)
                .padding(.trailing, horizontalPadding)
                .id(state.kindId)
        }
    }

    // MARK: 녹음 중 펼침

    /// 헤더(타일·제목·경과·파형) → 메모 입력 → 컨트롤. 참고한 미디어 플레이어 구조에서
    /// 진행 바 대신 메모 칸을 둔다. 회의는 끝나는 시각보다 "지금 적어 둘 것"이 중요하다.
    private func recordingExpanded(seconds: Int, paused: Bool) -> some View {
        let title = meetingTitle ?? (paused ? "녹음 일시정지" : "녹음 중")
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(LinearGradient(
                        colors: [MeetingTint.color(for: title), MeetingTint.color(for: title).opacity(0.5)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
                    .frame(width: 40, height: 40)
                    .overlay {
                        Image(systemName: "person.2.fill")
                            .font(.system(size: 15, weight: .semibold))
                    }
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 13, weight: .bold))
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Circle()
                            .fill(paused ? Color.orange : Color.red)
                            .frame(width: 6, height: 6)
                            .matchedGeometryEffect(id: "rec.dot", in: morph)
                        Text(Self.clock(seconds))
                            .font(.system(size: 11, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(.white.opacity(0.7))
                        if !memos.isEmpty {
                            Text("· 메모 \(memos.count)")
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                    }
                }
                Spacer(minLength: 8)
                if paused {
                    Image(systemName: "pause.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.orange)
                } else {
                    // 실제 입력 레벨이 연결되기 전까지는 흉내 낸 파형이다.
                    LevelWaveform(barCount: 6, color: Color(red: 0.55, green: 0.62, blue: 1.0))
                        .matchedGeometryEffect(id: "rec.wave", in: morph)
                }
            }

            memoComposer

            HStack {
                controlButton(paused ? "play.fill" : "pause.fill", size: 16, help: paused ? "재개" : "일시정지", action: onTogglePause)
                controlButton("stop.fill", size: 15, help: "녹음 종료", tint: Color(red: 1, green: 0.35, blue: 0.35), action: onStop)
                Spacer()
                controlButton("macwindow", size: 14, help: "앱 열기", action: onOpenPreview)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 메모 입력 칸과 최근 메모 두 개. Return으로 저장하고 칸을 비운다.
    private var memoComposer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                TextField("메모를 적고 Return", text: $memoDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($memoFocused)
                    .onSubmit(submitMemo)
                if !memoDraft.isEmpty {
                    Button(action: submitMemo) {
                        Image(systemName: "arrow.turn.down.left")
                            .font(.system(size: 11, weight: .bold))
                            .frame(width: 20, height: 20)
                            .background(.white.opacity(0.18), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("메모 저장")
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(.white.opacity(memoFocused ? 0.14 : 0.08), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .onChange(of: memoFocused) { _, focused in onMemoFocusChange(focused) }

            ForEach(memos.suffix(2).reversed()) { memo in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(memo.elapsedLabel)
                        .font(.system(size: 10, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.45))
                    Text(memo.text)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                }
                .padding(.horizontal, 4)
            }
        }
    }

    private func submitMemo() {
        let text = memoDraft
        memoDraft = ""
        onAddMemo(text)
    }

    private func controlButton(
        _ systemName: String,
        size: CGFloat,
        help: String,
        tint: Color = .white,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    private static func clock(_ seconds: Int) -> String {
        let m = seconds / 60, s = seconds % 60
        return String(format: "%d:%02d", m, s)
    }

    // MARK: 접힌 상태

    @ViewBuilder
    private var compactLeading: some View {
        switch state {
        case let .recording(_, paused):
            Circle()
                .fill(paused ? Color.orange : Color.red)
                .frame(width: 8, height: 8)
                .matchedGeometryEffect(id: "rec.dot", in: morph)
                .modifier(PulseModifier(active: !paused))
        default:
            meetingTile
        }
    }

    @ViewBuilder
    private var compactTrailing: some View {
        switch state {
        case let .recording(_, paused):
            if paused {
                Image(systemName: "pause.fill")
                    .font(.system(size: 11, weight: .bold))
            } else {
                // 실제 입력 레벨이 연결되기 전까지는 흉내 낸 파형이다.
                LevelWaveform(barCount: 5, color: Color(red: 0.55, green: 0.62, blue: 1.0))
                    .matchedGeometryEffect(id: "rec.wave", in: morph)
            }
        case let .generating(fraction, _):
            ProgressRing(fraction: fraction)
        case let .imminent(_, minutes):
            Text("\(minutes)분")
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
        case let .previewReady(_, count):
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.green)
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .bold))
                        .monospacedDigit()
                        .padding(.horizontal, 5)
                        .frame(height: 15)
                        .background(.white.opacity(0.18), in: Capsule())
                }
            }
        case .published:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.orange)
        case .detected:
            Image(systemName: "record.circle")
                .font(.system(size: 12, weight: .semibold))
        case .hidden:
            EmptyView()
        }
    }

    /// 회의를 나타내는 작은 타일. 참고 UI의 앨범 아트 자리다. 지금은 제목 해시로 색을 정한다.
    private var meetingTile: some View {
        let color = MeetingTint.color(for: presentation.title ?? state.kindId)
        return RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(LinearGradient(colors: [color, color.opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: 20, height: 20)
            .overlay {
                Image(systemName: presentation.symbolName ?? "calendar")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.95))
            }
    }

    @ViewBuilder
    private var trailingControls: some View {
        if let title = textButtonTitle, showsTextButton {
            Button(title, action: textButtonAction)
                .buttonStyle(CapsuleButtonStyle())
                .accessibilityLabel(presentation.primaryAction?.accessibilityLabel ?? title)
        }
        switch state {
        case let .recording(_, paused):
            capsuleIconButton(paused ? "play.fill" : "pause.fill", help: paused ? "재개" : "일시정지", action: onTogglePause)
            capsuleIconButton("stop.fill", help: "녹음 종료", tint: .red, action: onStop)
        case .generating:
            capsuleIconButton("xmark", help: "회의록 생성 취소", action: onCancelProcessing)
        case .detected, .imminent, .previewReady, .failed, .published:
            // 셸프만 접는 게 아니라 캡슐 자체를 닫는다. 접기는 바깥 클릭·마우스 이탈이 담당한다.
            capsuleIconButton("xmark", help: "닫기", action: onDismiss)
        default:
            EmptyView()
        }
    }

    private var textButtonAction: () -> Void {
        switch presentation.primaryAction {
        case .review, .open:
            onOpenPreview
        default:
            onPrimaryAction
        }
    }

    @ViewBuilder
    private var indicator: some View {
        switch state {
        case let .recording(_, paused):
            Circle()
                .fill(paused ? Color.orange : Color.red)
                .frame(width: 7, height: 7)
        case .generating:
            Image(systemName: "waveform")
                .font(.system(size: 11, weight: .medium))
                .symbolEffect(.variableColor.iterative, options: .repeating)
        default:
            if let symbol = presentation.symbolName {
                Image(systemName: symbol).font(.system(size: 11))
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if case .generating = state, let progress = presentation.progressFraction {
            generatingDetail(progress: progress)
        } else {
            standardDetail
        }
    }

    /// 회의록 생성 중 상세. 진행률 한 줄과 단계 체크리스트를 보여 준다.
    private func generatingDetail(progress: Double) -> some View {
        let steps = ProcessingStepLine.parse(presentation.detailText)
        return VStack(alignment: .leading, spacing: 8) {
            Divider().overlay(.white.opacity(0.14))
            HStack(spacing: 8) {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(.white)
                Text("\(Int((progress * 100).rounded()))%")
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 34, alignment: .trailing)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("회의록 생성 진행률")
            .accessibilityValue("\(Int((progress * 100).rounded()))%")
            if steps.isEmpty, let detail = presentation.detailText {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.8))
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(steps) { step in
                        HStack(spacing: 7) {
                            stepMarker(step.status)
                            Text(step.title)
                                .font(.system(size: 11, weight: step.status == .current ? .semibold : .regular))
                                .foregroundStyle(.white.opacity(step.status == .pending ? 0.45 : 0.95))
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func stepMarker(_ status: ProcessingStepLine.Status) -> some View {
        switch status {
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.green)
        case .current:
            Image(systemName: "circle.dotted.circle")
                .font(.system(size: 11))
                .foregroundStyle(.white)
                .symbolEffect(.pulse, options: .repeating)
        case .pending:
            Circle()
                .strokeBorder(.white.opacity(0.3), lineWidth: 1)
                .frame(width: 11, height: 11)
        }
    }

    private var standardDetail: some View {
        VStack(alignment: .leading, spacing: 5) {
            Divider().overlay(.white.opacity(0.14))
            if let title = presentation.title {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let progress = presentation.progressFraction {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(.white)
                    .accessibilityLabel("회의록 생성 진행률")
                    .accessibilityValue("\(Int((progress * 100).rounded()))%")
            }
            if let detail = presentation.detailText {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            [presentation.title, presentation.detailText]
                .compactMap { $0 }
                .joined(separator: ". ")
        )
    }

    private func capsuleIconButton(
        _ systemName: String,
        help: String,
        tint: Color = .white,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)
                .background(.white.opacity(0.16), in: Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// 코디네이터가 만든 단계 체크리스트 문구("✓ 오디오 준비\n▸ 음성 인식\n· 사실 추출")를 행으로 푼다.
struct ProcessingStepLine: Identifiable, Equatable {
    enum Status { case done, current, pending }

    let id: Int
    let title: String
    let status: Status

    static func parse(_ text: String?) -> [ProcessingStepLine] {
        guard let text else { return [] }
        let lines = text.split(separator: "\n").map(String.init)
        var result: [ProcessingStepLine] = []
        for (index, line) in lines.enumerated() {
            let status: Status
            if line.hasPrefix("✓") { status = .done }
            else if line.hasPrefix("▸") { status = .current }
            else if line.hasPrefix("·") { status = .pending }
            else { return [] }
            let title = line.dropFirst().trimmingCharacters(in: .whitespaces)
            result.append(ProcessingStepLine(id: index, title: title, status: status))
        }
        return result
    }
}

/// 입력 레벨 파형. `levels`가 없으면 흉내 낸 움직임을 그린다(실제 오디오 레벨 연결 전 목업).
struct LevelWaveform: View {
    var barCount: Int = 5
    var color: Color = .white
    var levels: [Double]? = nil

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2.5) {
                ForEach(0..<barCount, id: \.self) { index in
                    let level = levels?[safe: index] ?? Self.mockLevel(index: index, time: t)
                    Capsule()
                        .fill(color)
                        .frame(width: 2.5, height: 4 + 10 * level)
                }
            }
            .frame(height: 14)
        }
        .accessibilityLabel("입력 레벨")
    }

    private static func mockLevel(index: Int, time: TimeInterval) -> Double {
        let phase = Double(index) * 1.3
        let value = 0.5 + 0.5 * sin(time * (2.4 + Double(index) * 0.35) + phase)
        return 0.15 + 0.85 * value * value
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// 얇은 원형 진행률.
struct ProgressRing: View {
    var fraction: Double

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.22), lineWidth: 2)
            Circle()
                .trim(from: 0, to: min(1, max(0, fraction)))
                .stroke(.white, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 14, height: 14)
        .animation(.easeInOut(duration: 0.3), value: fraction)
        .accessibilityLabel("회의록 생성 진행률")
        .accessibilityValue("\(Int((fraction * 100).rounded()))%")
    }
}

/// 녹음 점이 숨 쉬듯 깜박인다.
struct PulseModifier: ViewModifier {
    var active: Bool

    func body(content: Content) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !active)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            content.opacity(active ? 0.55 + 0.45 * (0.5 + 0.5 * sin(t * 3)) : 1)
        }
    }
}

/// 회의 타일 색. 캘린더 색이 연결되기 전까지 제목 해시로 정한다.
enum MeetingTint {
    static let palette: [Color] = [
        Color(red: 0.36, green: 0.55, blue: 1.0),
        Color(red: 0.62, green: 0.45, blue: 1.0),
        Color(red: 0.22, green: 0.72, blue: 0.55),
        Color(red: 1.0, green: 0.58, blue: 0.30),
        Color(red: 0.95, green: 0.40, blue: 0.55),
    ]

    static func color(for key: String) -> Color {
        var hash: UInt32 = 2_166_136_261
        for byte in key.utf8 {
            hash = (hash ^ UInt32(byte)) &* 16_777_619
        }
        return palette[Int(hash % UInt32(palette.count))]
    }
}

struct CapsuleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.white.opacity(configuration.isPressed ? 0.28 : 0.16), in: Capsule())
            .foregroundStyle(.white)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
    }
}

/// 노치 셸프와 창이 함께 쓰는 애니메이션. 셸프는 이 스프링으로 변형되고,
/// 창은 셸프의 실제 크기를 프레임마다 따라가므로 둘이 완전히 같이 움직인다.
enum CruxAnimation {
    /// 스프링 정착까지의 대략적 시간. 스냅샷 대기 등에만 쓴다(애니메이션 자체는 스프링이 구동).
    static let duration: TimeInterval = 0.6

    /// 다이나믹 아일랜드에 가까운 스프링. damping을 높게 둬 과한 반동을 없앤다.
    static var swiftUI: Animation {
        .spring(response: 0.38, dampingFraction: 0.86)
    }
}
