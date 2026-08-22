import MeetingCore
import QuartzCore
import SwiftUI

/// Live Capsule 본체(요구사항 3).
///
/// 화면 최상단에 붙어 **노치와 한 덩어리처럼** 보이도록 그린다.
/// - 위쪽 모서리는 각지게(화면 끝에 밀착), 아래쪽만 둥글게
/// - 노치가 있는 화면에서는 노치 폭만큼 비워 두고 좌우에 내용을 배치한다
/// - **좌측은 아이콘과 상태, 우측은 시간·진행률** 한 줄로 읽힌다
/// - **마우스를 올리면 캡슐이 커지면서** 동작 버튼이 나온다. 클릭하면 상세까지 펼쳐 고정된다
public struct LiveCapsuleView: View {
    let state: LiveCapsuleState
    let detailMessage: String?
    let metrics: NotchMetrics
    /// 마우스 오버로 커진 상태. 창이 크기를 다시 재야 하므로 밖에서 들고 있는다.
    let isHovering: Bool
    /// 클릭으로 고정한 상세 패널
    let isPinned: Bool
    let onHoverChange: (Bool) -> Void
    let onTogglePin: () -> Void

    let onPrimaryAction: () -> Void
    let onDismiss: () -> Void
    let onOpenPreview: () -> Void
    /// 녹음 중 호버 컨트롤: 일시정지/재개
    let onTogglePause: () -> Void
    /// 녹음 중 호버 컨트롤: 종료(회의록 생성 시작)
    let onStop: () -> Void
    /// 생성 중 호버 컨트롤: 회의록 생성 취소
    let onCancelProcessing: () -> Void

    public init(
        state: LiveCapsuleState,
        detailMessage: String? = nil,
        metrics: NotchMetrics,
        isHovering: Bool = false,
        isPinned: Bool = false,
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
        self.metrics = metrics
        self.isHovering = isHovering
        self.isPinned = isPinned
        self.onHoverChange = onHoverChange
        self.onTogglePin = onTogglePin
        self.onPrimaryAction = onPrimaryAction
        self.onDismiss = onDismiss
        self.onOpenPreview = onOpenPreview
        self.onTogglePause = onTogglePause
        self.onStop = onStop
        self.onCancelProcessing = onCancelProcessing
    }

    /// 커진 상태인지. 마우스를 올렸거나 상세를 고정했을 때다.
    private var isEnlarged: Bool {
        isHovering || isPinned
    }

    private var isPreviewReady: Bool {
        if case .previewReady = state {
            return true
        }
        return false
    }

    private var isFailed: Bool {
        if case .failed = state {
            return true
        }
        return false
    }

    /// 감지 확인 문구를 보여줄 상태인지. 녹음이 시작되면 지난 감지 문구는 더 보여주지 않는다.
    private var showsPromptMessage: Bool {
        switch state {
        case .imminent, .detected, .failed: true
        default: false
        }
    }

    /// 노치 좌우 내용 영역의 최소 폭.
    ///
    /// 노치를 가운데 두려면 양옆이 같은 폭이어야 한다. 내용보다 넉넉하면 빈 띠가 길어 보이므로
    /// 최소만 잡고 내용에 맞춰 늘어나게 한다.
    private var sideWidth: CGFloat {
        let base: CGFloat = metrics.hasNotch ? 76 : 104
        return isEnlarged ? base + 28 : base
    }

    /// 한쪽이 지나치게 길어지지 않게 막는다. 긴 회의 제목은 말줄임한다.
    /// 커진 상태에서는 상태 문구가 잘리지 않도록 넉넉히 잡는다.
    private var sideMaxWidth: CGFloat {
        isEnlarged ? 340 : 170
    }

    /// 막대 높이. 항상 노치와 같은 높이를 유지한다.
    ///
    /// 커질 때 높이까지 바꾸면 창이 위아래로 움직여 노치 상단이 잘려 보인다.
    /// 확장은 좌우 폭과 아래쪽(버튼 줄)으로만 한다.
    private var barHeight: CGFloat {
        metrics.collapsedHeight
    }

    private var horizontalPadding: CGFloat {
        isEnlarged ? 14 : 10
    }

    public var body: some View {
        VStack(spacing: 0) {
            capsuleBar
            if isEnlarged, !state.showsRecordingIndicator, !isPreviewReady, !isFailed,
               state.primaryActionTitle != nil {
                actionRow
            }
            if isPinned, state.isExpandable {
                detail
            }
        }
        .background(Color.black)
        .clipShape(NotchShape(topRadius: metrics.hasNotch ? 0 : 6, bottomRadius: isEnlarged ? 26 : 20))
        .foregroundStyle(.white)
        // 크기 변화는 창(NSPanel)이 같은 곡선으로 움직인다.
        // 여기서 레이아웃까지 애니메이션하면 두 움직임이 어긋나 덜컹거린다.
        .onHover { hovering in onHoverChange(hovering) }
        .onTapGesture { onTogglePin() }
    }

    /// 노치를 감싸는 한 줄. 왼쪽은 아이콘과 상태, 오른쪽은 시간이다.
    private var capsuleBar: some View {
        HStack(spacing: 0) {
            HStack(spacing: 7) {
                Spacer(minLength: 0)
                indicator
                Text(state.statusText)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    // 커진 상태에서는 문구 전체가 보이도록 줄이지 않는다.
                    .fixedSize(horizontal: isEnlarged, vertical: false)
            }
            .frame(minWidth: sideWidth, maxWidth: sideMaxWidth, alignment: .trailing)
            .padding(.leading, horizontalPadding)
            .padding(.trailing, metrics.hasNotch ? 8 : 6)

            if metrics.hasNotch {
                // 카메라·노치 영역. 아무것도 그리지 않는다.
                Color.clear.frame(width: metrics.notchWidth)
            }

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                if case let .generating(fraction, _) = state {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .frame(width: isEnlarged ? 66 : 46)
                        .tint(.white)
                }
                if let trailing = state.trailingText {
                    Text(trailing)
                        .font(.system(size: 12, weight: .semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()
                        .foregroundStyle(.white.opacity(0.9))
                }
                if isEnlarged, case .failed = state {
                    Button("다시 시도", action: onPrimaryAction)
                        .buttonStyle(CapsuleButtonStyle())
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .frame(width: 20, height: 20)
                            .background(.white.opacity(0.18), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help("닫기")
                }
                if isEnlarged, case .previewReady = state {
                    // 완료 상태의 동작은 아래 줄이 아니라 시간 자리 옆에 둔다.
                    Button("열기", action: onOpenPreview)
                        .buttonStyle(CapsuleButtonStyle())
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .frame(width: 20, height: 20)
                            .background(.white.opacity(0.18), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help("닫기")
                }
                if isEnlarged, case .generating = state {
                    // 퍼센트 옆에서 바로 생성을 취소할 수 있다.
                    Button(action: onCancelProcessing) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .frame(width: 20, height: 20)
                            .background(.white.opacity(0.18), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help("회의록 생성 취소")
                }
                if isEnlarged, case let .recording(_, paused) = state {
                    // 시간 위에 마우스를 올리면 일시정지·종료를 바로 할 수 있다.
                    Button(action: onTogglePause) {
                        Image(systemName: paused ? "play.fill" : "pause.fill")
                            .font(.system(size: 10, weight: .bold))
                            .frame(width: 20, height: 20)
                            .background(.white.opacity(0.18), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help(paused ? "재개" : "일시정지")
                    Button(action: onStop) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.red)
                            .frame(width: 20, height: 20)
                            .background(.white.opacity(0.18), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help("녹음 종료")
                }
                Spacer(minLength: 0)
            }
            .frame(minWidth: sideWidth, maxWidth: sideMaxWidth, alignment: .trailing)
            .padding(.leading, metrics.hasNotch ? 8 : 6)
            .padding(.trailing, horizontalPadding)
        }
        .frame(height: barHeight)
        .contentShape(Rectangle())
    }

    /// 커졌을 때만 보이는 버튼 줄. 접힌 상태에서는 정보만 남긴다.
    private var actionRow: some View {
        HStack(spacing: 8) {
            if let title = state.primaryActionTitle {
                Button(title, action: onPrimaryAction)
                    .buttonStyle(CapsuleButtonStyle())
            }
            if case .previewReady = state {
                Button("Preview 열기", action: onOpenPreview)
                    .buttonStyle(CapsuleButtonStyle())
            }
            Button(action: onDismiss) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .opacity(0.5)
            .padding(.leading, 2)
        }
        .padding(.horizontal, horizontalPadding + 2)
        .padding(.bottom, isPinned ? 4 : 8)
        .frame(maxWidth: .infinity)
        .transition(.opacity)
    }

    /// 녹음 중임을 명확하게 표시한다(§11 개인정보 UX).
    @ViewBuilder
    private var indicator: some View {
        switch state {
        case let .recording(_, paused):
            HStack(spacing: 5) {
                Circle()
                    .fill(paused ? Color.orange : Color.red)
                    .frame(width: 7, height: 7)
                Image(systemName: "waveform")
                    .font(.system(size: 11, weight: .medium))
                    .symbolEffect(.variableColor.iterative, options: paused ? .default : .repeating)
                    .foregroundStyle(.white.opacity(0.85))
            }
        case .generating:
            Image(systemName: "waveform")
                .font(.system(size: 11, weight: .medium))
                .symbolEffect(.variableColor.iterative, options: .repeating)
        default:
            if let symbol = state.symbolName {
                Image(systemName: symbol).font(.system(size: 11))
            }
        }
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().overlay(.white.opacity(0.15))
            if let detailMessage, showsPromptMessage {
                Text(detailMessage)
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
            }
            switch state {
            case let .detected(title, message):
                if let title {
                    Text(title).font(.system(size: 12, weight: .semibold))
                }
                Text(message).font(.system(size: 11)).opacity(0.85)
                Text("녹음은 이 기기에서만 저장되며 자동으로 시작하지 않습니다.")
                    .font(.system(size: 10)).opacity(0.6)
            case let .recording(elapsed, paused):
                Text("\(paused ? "일시정지" : "녹음 중") · \(LiveCapsuleState.clock(elapsed))")
                    .font(.system(size: 11))
                    .monospacedDigit()
                Text("마이크와 시스템 오디오는 로컬 파일로만 저장됩니다.")
                    .font(.system(size: 10)).opacity(0.6)
            case let .generating(_, message):
                Text(detailMessage ?? message)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            case let .previewReady(_, count):
                Text("액션 아이템 \(count)개를 검토할 수 있습니다.")
                    .font(.system(size: 11))
            case let .published(title, issueCount):
                if let title {
                    Text(title).font(.system(size: 12, weight: .semibold))
                }
                Text("Jira 이슈 \(issueCount)개 생성").font(.system(size: 11)).opacity(0.85)
            case let .failed(message):
                Text(message)
                    .font(.system(size: 11))
                    .opacity(0.85)
                    .fixedSize(horizontal: false, vertical: true)
            default:
                EmptyView()
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .frame(maxWidth: 360, alignment: .leading)
    }
}

struct CapsuleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.white.opacity(configuration.isPressed ? 0.3 : 0.18), in: Capsule())
            .foregroundStyle(.white)
    }
}

/// 캡슐이 커지고 줄어드는 움직임.
///
/// SwiftUI 내용과 창(NSPanel) 크기가 **같은 시간·같은 곡선**으로 움직여야 한 덩어리로 보인다.
/// 값이 어긋나면 내용이 먼저 자리를 잡고 창이 뒤늦게 따라오면서 덜컹거린다.
enum LiveCapsuleAnimation {
    static let duration: TimeInterval = 0.22

    /// SwiftUI 쪽 곡선. macOS 창 애니메이션과 같은 easeOut 느낌을 맞춘다.
    static var swiftUI: Animation {
        .easeOut(duration: duration)
    }

    /// AppKit 쪽 곡선.
    static var timingFunction: CAMediaTimingFunction {
        CAMediaTimingFunction(name: .easeOut)
    }
}
