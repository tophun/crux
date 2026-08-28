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
    /// 회의록 생성 중 현재 단계. 상세의 단계 체크리스트를 그린다.
    let processingStage: ProcessingStage?
    let metrics: NotchMetrics
    let expansionMode: CruxExpansionMode
    /// 상태별 문구·동작 매핑. 한 번만 만들어 두고 본문에서 여러 번 읽는다.
    let presentation: CruxPresentationModel
    let onHoverChange: (Bool) -> Void
    let onTogglePin: () -> Void
    let onPrimaryAction: () -> Void
    let onDismiss: () -> Void
    let onOpenPreview: () -> Void
    let onTogglePause: () -> Void
    let onStop: () -> Void
    let onCancelProcessing: () -> Void
    let onAddMemo: (String) -> Void
    /// 메모 입력 칸의 포커스 변화. 입력 중에는 창이 접히지 않아야 한다.
    let onMemoFocusChange: (Bool) -> Void
    /// 검은 셸프의 실제 렌더 크기. 창은 애니메이션 중에는 건드리지 않고, 크기 변화가 멎어
    /// 정착했을 때 이 값으로 한 번만 자신을 맞춘다.
    let onContentSizeChange: (CGSize) -> Void

    @State var memoDraft = ""
    @FocusState var memoFocused: Bool

    public init(
        state: CruxState,
        detailMessage: String? = nil,
        meetingTitle: String? = nil,
        memos: [MeetingMemo] = [],
        processingStage: ProcessingStage? = nil,
        metrics: NotchMetrics,
        expansionMode: CruxExpansionMode = .collapsed,
        onAddMemo: @escaping (String) -> Void = { _ in },
        onMemoFocusChange: @escaping (Bool) -> Void = { _ in },
        onContentSizeChange: @escaping (CGSize) -> Void = { _ in },
        onHoverChange: @escaping (Bool) -> Void = { _ in },
        onTogglePin: @escaping () -> Void = {},
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
        self.processingStage = processingStage
        self.metrics = metrics
        presentation = CruxPresentationModel(state: state, detailMessage: detailMessage)
        self.onAddMemo = onAddMemo
        self.onMemoFocusChange = onMemoFocusChange
        self.onContentSizeChange = onContentSizeChange
        self.expansionMode = expansionMode
        self.onHoverChange = onHoverChange
        self.onTogglePin = onTogglePin
        self.onPrimaryAction = onPrimaryAction
        self.onDismiss = onDismiss
        self.onOpenPreview = onOpenPreview
        self.onTogglePause = onTogglePause
        self.onStop = onStop
        self.onCancelProcessing = onCancelProcessing
    }

    private var isEnlarged: Bool {
        expansionMode.isExpanded
    }

    var barHeight: CGFloat {
        metrics.collapsedHeight
    }

    private var horizontalPadding: CGFloat {
        isEnlarged ? 16 : 8
    }

    /// 화면 상단과 캡슐을 잇는 오목한 곡선의 크기.
    private var topFlare: CGFloat {
        20
    }

    private var barWidth: CGFloat {
        metrics.islandWidth(expanded: isEnlarged)
    }

    /// 녹음 중에는 텍스트 버튼 대신 아이콘 버튼(일시정지·종료)만 둔다.
    private var showsTextButton: Bool {
        presentation.primaryAction != nil && !presentation.showsRecordingIndicator
    }

    /// 상세는 보조 문구가 있을 때만. 진행률이 있는 상태(생성 중)는 항상 문구도 같이 온다.
    private var showsDetail: Bool {
        isEnlarged && presentation.detailText != nil
    }

    /// 파형 색. 접힘·펼침 두 곳에서 같은 값을 쓴다.
    static let waveformTint = Color(red: 0.55, green: 0.62, blue: 1.0)

    public var body: some View {
        capsuleShape
            // 셸프의 실제 크기를 창에 알려 준다. 창은 스프링이 정착한 뒤 이 값으로 한 번 맞춘다.
            .onGeometryChange(for: CGSize.self, of: { $0.size }, action: onContentSizeChange)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .foregroundStyle(.white)
            .onHover { hovering in onHoverChange(hovering) }
            .onTapGesture { onTogglePin() }
    }

    /// 접힘↔펼침에서 내용을 갈아 끼우는 전환. 나가는 내용은 셸프가 줄기 전에 빨리 사라져야
    /// 접힌 바 안에 글자 고스트가 남지 않고, 들어오는 내용은 셸프가 어느 정도 자란 뒤 나타나야
    /// 옛 요소와 겹쳐 보이지 않는다. 다이나믹 아일랜드가 쓰는 비대칭 페이드다.
    private static var contentSwap: AnyTransition {
        .asymmetric(
            insertion: .opacity.animation(.easeIn(duration: 0.18).delay(0.08)),
            removal: .opacity.animation(.easeOut(duration: 0.10))
        )
    }

    /// 검은 노치 셸프 하나. 접힘·펼침을 한 덩어리로 스프링 변형한다.
    private var capsuleShape: some View {
        VStack(spacing: 0) {
            if isEnlarged, case let .recording(seconds, paused) = state {
                // 녹음 중 펼침은 바+상세 대신 미디어 플레이어형 3단 구조를 쓴다.
                recordingExpanded(seconds: seconds, paused: paused)
                    .transition(Self.contentSwap)
            } else {
                VStack(spacing: 0) {
                    capsuleBar
                    if showsDetail {
                        detail
                    }
                }
                .transition(Self.contentSwap)
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
                if let trailing = presentation.trailingText, !showsTextButton, presentation.progressFraction == nil {
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

    @ViewBuilder
    private var trailingControls: some View {
        if showsTextButton, let action = presentation.primaryAction {
            Button(action.title, action: textButtonAction)
                .buttonStyle(CapsuleButtonStyle())
                .accessibilityLabel(action.accessibilityLabel)
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
        if let progress = presentation.progressFraction {
            generatingDetail(progress: progress)
        } else {
            standardDetail
        }
    }

    /// 단계 체크리스트 한 줄의 상태.
    private enum StepStatus { case done, current, pending }

    /// 현재 단계를 기준으로 전 단계에 완료/진행/대기 표시를 붙인다. 단계 정보가 없으면 빈 배열.
    private var processingSteps: [(stage: ProcessingStage, status: StepStatus)] {
        guard let current = processingStage,
              let currentIndex = ProcessingStage.allCases.firstIndex(of: current) else { return [] }
        return ProcessingStage.allCases.enumerated().map { index, stage in
            (stage, index < currentIndex ? .done : (index == currentIndex ? .current : .pending))
        }
    }

    /// 회의록 생성 중 상세. 진행률 한 줄과 단계 체크리스트를 보여 준다.
    private func generatingDetail(progress: Double) -> some View {
        let steps = processingSteps
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
                    ForEach(steps, id: \.stage) { step in
                        HStack(spacing: 7) {
                            stepMarker(step.status)
                            Text(step.stage.displayName)
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
    private func stepMarker(_ status: StepStatus) -> some View {
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

/// 입력 레벨 파형. `levels`가 없으면 흉내 낸 움직임을 그린다(실제 오디오 레벨 연결 전 목업).
struct LevelWaveform: View {
    var barCount: Int = 5
    var color: Color = .white
    var levels: [Double]?

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2.5) {
                ForEach(0 ..< barCount, id: \.self) { index in
                    let level = levels?[safe: index] ?? Self.mockLevel(index: index, time: time)
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
            let time = context.date.timeIntervalSinceReferenceDate
            content.opacity(active ? 0.55 + 0.45 * (0.5 + 0.5 * sin(time * 3)) : 1)
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
        Color(red: 0.95, green: 0.40, blue: 0.55)
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

/// 노치 셸프의 접힘/펼침 스프링. 창은 애니메이션 중 움직이지 않고 정착 후 한 번 맞춘다.
enum CruxAnimation {
    /// 다이나믹 아일랜드에 가까운 스프링. damping을 높게 둬 과한 반동을 없앤다.
    static var swiftUI: Animation {
        .spring(response: 0.38, dampingFraction: 0.86)
    }
}
