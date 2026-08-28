import AppKit
import MeetingCore
import SwiftUI

/// Crux을 담는 플로팅 창.
///
/// - 화면 **최상단(메뉴바 영역)** 에 붙여 노치와 이어지게 그린다. `visibleFrame`이 아니라 `frame` 기준이다.
/// - `NSPanel`의 `.nonactivatingPanel`을 써서 다른 앱의 포커스를 빼앗지 않는다.
/// - MacBook 내장 화면에서는 노치 중심, 외부 모니터에서는 현재 활성 화면 상단 중앙에 붙는다.
@MainActor
public final class CruxWindowController {
    private var panel: NSPanel?
    private var hosting: NSHostingView<AnyView>?
    /// 루트 뷰가 읽는 상태. 값을 바꾸면 SwiftUI가 정상 업데이트로 반영한다.
    private var model: CruxShelfModel?
    private var metrics: NotchMetrics?
    private var lastKindId: String?
    /// 셸프 표시 상태. 뷰가 아니라 창이 들고 있어야 새 크기를 계산할 수 있다.
    ///
    /// 호스팅 뷰는 창 크기에 맞춰 늘어나므로, 뷰 안에서 크기를 재면 늘 "지금 창 크기"만 나온다.
    /// 확장 여부를 여기서 바꾸고 `fittingSize`(이상적인 크기)를 다시 물어야 창이 커질 수 있다.
    private var expansionMode: CruxExpansionMode = Demo.startsInPreview ? .preview : .collapsed
    /// 창을 다시 그린 직후 hover-off를 무시하는 마감 시각.
    private var ignoreLeaveUntil: Date?
    /// 실제 이탈인지 다시 확인하는 접기 예약.
    private var collapseWorkItem: DispatchWorkItem?
    private var snapshotCounter = 0
    /// 셸프 밖 클릭을 감지하는 이벤트 모니터. 펼쳐져 있는 동안에만 설치한다.
    private var eventMonitors: [Any] = []
    /// 전환 스프링이 정착하기를 기다리는 중인지. 정착 시 창을 정확한 크기로 한 번 맞춘다.
    private var awaitingSettle = false
    private var settleWork: DispatchWorkItem?
    private var demoToggleTimer: Timer?

    /// 개발용 환경 변수. 한 번만 읽는다(`ProcessInfo.environment`는 호출마다 사전을 복사한다).
    private enum Demo {
        private static let env = ProcessInfo.processInfo.environment
        /// `CRUX_DEMO_HOVER=1`: 미리보기 상태로 시작한다.
        static let startsInPreview = env["CRUX_DEMO_HOVER"] == "1"
        /// `CRUX_DEMO_EXPANDED=1`: 마우스 없이 펼친 상태로 고정한다.
        static let forcesExpanded = env["CRUX_DEMO_EXPANDED"] != nil
        /// `CRUX_DEMO_TOGGLE=1`: 1.8초마다 펼침/접힘을 반복해 애니메이션을 확인한다.
        static let autoToggles = env["CRUX_DEMO_TOGGLE"] == "1"
        /// `CRUX_DEMO_SNAPSHOT_DIR`: 크기 변화가 끝난 뒤 캡슐 뷰를 PNG로 저장한다.
        static let snapshotDirectory = env["CRUX_DEMO_SNAPSHOT_DIR"]
    }

    /// 스프링(응답 0.38s)이 정착하고 스냅샷을 찍기까지 기다리는 시간.
    private static let snapshotDelay: TimeInterval = 0.9

    public init() {}

    public func show(
        state: CruxState,
        detailMessage: String? = nil,
        meetingTitle: String? = nil,
        memos: [MeetingMemo] = [],
        processingStage: ProcessingStage? = nil,
        liveCaptions: LiveCaptionState = LiveCaptionState(),
        onAddMemo: @escaping (String) -> Void = { _ in },
        onPrimaryAction: @escaping () -> Void,
        onDismiss: @escaping () -> Void,
        onOpenPreview: @escaping () -> Void,
        onTogglePause: @escaping () -> Void = {},
        onStop: @escaping () -> Void = {},
        onCancelProcessing: @escaping () -> Void = {}
    ) {
        guard state.isVisible else {
            hide()
            return
        }

        let metrics = NotchMetrics.from(screen: Self.activeScreen())
        self.metrics = metrics

        // 상태가 바뀌면 펼쳐 둔 상세는 접는다.
        let kindChanged = CapsuleHoverGate.shouldResetExpansionMode(previousKindId: lastKindId, nextKindId: state.kindId)
        if kindChanged {
            cancelCollapseCheck()
            expansionMode = .collapsed
            ignoreLeaveUntil = nil
        }
        lastKindId = state.kindId
        if Demo.forcesExpanded {
            expansionMode = .pinned
        }

        let firstShow = hosting == nil
        let model = model ?? makeHosting(state: state, metrics: metrics)
        model.state = state
        model.detailMessage = detailMessage
        model.meetingTitle = meetingTitle
        model.memos = memos
        model.processingStage = processingStage
        model.liveCaptions = liveCaptions
        model.metrics = metrics
        model.onAddMemo = onAddMemo
        model.onPrimaryAction = onPrimaryAction
        model.onDismiss = onDismiss
        model.onOpenPreview = onOpenPreview
        model.onTogglePause = onTogglePause
        model.onStop = onStop
        model.onCancelProcessing = onCancelProcessing

        if firstShow || kindChanged {
            transition(animated: false)
        } else {
            // 녹음 경과 시간처럼 매초 오는 갱신. 강제 레이아웃 대신, 셸프 크기가 실제로
            // 바뀌면(메모 추가 등) 정착 콜백이 창을 맞춘다.
            applyExpansion()
            awaitingSettle = true
        }
        panel?.orderFrontRegardless()
        debugSnapshot(tag: "shown")
        startDemoToggleIfNeeded()
    }

    /// 루트 뷰는 한 번만 만든다. 이후에는 모델 값만 바꾼다.
    ///
    /// `rootView`를 매번 새 값으로 대입하면 SwiftUI가 애니메이션 트랜잭션 없이 즉시 갈아 끼워
    /// 접힘/펼침 스프링이 전혀 돌지 않는다(영상 프레임으로 확인). 모델 변경은 정상적인
    /// SwiftUI 업데이트라 `withAnimation`이 그대로 실린다.
    private func makeHosting(state: CruxState, metrics: NotchMetrics) -> CruxShelfModel {
        let model = CruxShelfModel(state: state, metrics: metrics, expansionMode: expansionMode)
        model.onMemoFocusChange = { [weak self] focused in self?.setMemoEditing(focused) }
        model.onContentSizeChange = { [weak self] size in self?.followContentSize(size) }
        model.onHoverChange = { [weak self] hovering in self?.setHovering(hovering) }
        model.onTogglePin = { [weak self] in self?.togglePin() }
        self.model = model

        let hostingView = NSHostingView(rootView: AnyView(CruxShelfRoot(model: model)))
        // 창 크기는 우리가 정한다. `.preferredContentSize`가 들어가면 NSHostingView가
        // windowDidLayout에서 스스로 창을 리사이즈하려 들고, 그게 레이아웃 패스 안에서
        // setNeedsUpdateConstraints 예외(SIGABRT)로 터진다 — 녹음 종료 시 크래시의 원인.
        // `.intrinsicContentSize`만 남겨 fittingSize 보고는 유지하고 창 주도권은 뺏는다.
        hostingView.sizingOptions = [.intrinsicContentSize]
        hostingView.translatesAutoresizingMaskIntoConstraints = true
        hostingView.autoresizingMask = [.width, .height]
        hostingView.wantsLayer = true
        hostingView.layer?.masksToBounds = true
        hosting = hostingView

        // 호스팅 뷰를 contentView로 직접 쓰지 않고 평범한 컨테이너 아래에 둔다.
        // contentView인 NSHostingView는 창 크기와 결합되어 위와 같은 충돌을 일으킨다.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: metrics.collapsedHeight))
        container.wantsLayer = true
        container.autoresizesSubviews = true
        hostingView.frame = container.bounds
        container.addSubview(hostingView)

        let panel = KeyablePanel(
            contentRect: container.frame,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        // 메뉴바(24)보다 위에 그려야 노치 영역을 덮을 수 있다.
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        // 활성 앱이 아니어도 마우스 오버를 받아야 캡슐이 커진다.
        panel.acceptsMouseMovedEvents = true
        panel.ignoresMouseEvents = false
        panel.contentView = container
        self.panel = panel
        return model
    }

    private func startDemoToggleIfNeeded() {
        guard Demo.autoToggles, demoToggleTimer == nil else { return }
        demoToggleTimer = Timer.scheduledTimer(withTimeInterval: 1.8, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.togglePin() }
        }
    }

    public func hide() {
        cancelCollapseCheck()
        removeOutsideClickMonitors()
        expansionMode = .collapsed
        ignoreLeaveUntil = nil
        panel?.orderOut(nil)
    }

    public func close() {
        cancelCollapseCheck()
        removeOutsideClickMonitors()
        demoToggleTimer?.invalidate()
        panel?.close()
        panel = nil
        hosting = nil
        model = nil
    }

    // MARK: - 표시 상태 전이

    /// 메모를 입력하는 동안은 포인터가 나가도 접지 않는다. 입력이 끝나면 다시 호버 규칙을 따른다.
    private func setMemoEditing(_ editing: Bool) {
        if editing {
            cancelCollapseCheck()
            if expansionMode != .pinned {
                expansionMode = .pinned
                transition(animated: true)
            }
            panel?.makeKey()
        } else if expansionMode == .pinned, !isMouseInPanel() {
            collapseShelf(animated: true)
        }
    }

    private func setHovering(_ hovering: Bool) {
        if hovering {
            cancelCollapseCheck()
            applyHover(true)
            return
        }

        // 고정 상태는 포인터가 나가도 닫히지 않는다.
        guard expansionMode != .pinned else { return }

        // 창을 다시 그리면 onHover(false)가 바로 온다. 즉시 접지 않고 포인터 위치로 확인한다.
        scheduleCollapseCheck(now: Date())
    }

    private func applyHover(_ hovering: Bool) {
        let nextMode = expansionMode.handlingHover(hovering)
        guard expansionMode != nextMode else { return }
        expansionMode = nextMode
        ignoreLeaveUntil = CapsuleHoverGate.ignoreDeadline(after: Date())
        transition(animated: true)
        debugSnapshot(tag: hovering ? "hover" : "leave")
    }

    private func scheduleCollapseCheck(now: Date) {
        cancelCollapseCheck()
        let delay = CapsuleHoverGate.collapseCheckDelay(now: now, ignoreLeaveUntil: ignoreLeaveUntil)
        let work = DispatchWorkItem { [weak self] in
            self?.applyScheduledCollapse()
        }
        collapseWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func applyScheduledCollapse() {
        switch CapsuleHoverGate.collapseCheckResult(
            now: Date(),
            ignoreLeaveUntil: ignoreLeaveUntil,
            mouseInWindow: isMouseInPanel()
        ) {
        case .reschedule:
            scheduleCollapseCheck(now: Date())
        case .collapse:
            applyHover(false)
        }
    }

    private func cancelCollapseCheck() {
        collapseWorkItem?.cancel()
        collapseWorkItem = nil
    }

    private func isMouseInPanel() -> Bool {
        guard let panel else { return false }
        return panel.frame.contains(NSEvent.mouseLocation)
    }

    private func togglePin() {
        cancelCollapseCheck()
        expansionMode = expansionMode.togglingPin()
        ignoreLeaveUntil = CapsuleHoverGate.ignoreDeadline(after: Date())
        transition(animated: true)
        debugSnapshot(tag: expansionMode.isPinned ? "pinned" : "unpinned")
    }

    /// 셸프만 접는다. 회의 상태 머신의 `dismissed` 이벤트는 발생시키지 않으므로,
    /// 현재 회의의 감지·처리 상태와 다음 표시를 그대로 유지한다.
    private func collapseShelf(animated: Bool) {
        guard expansionMode != .collapsed else { return }
        cancelCollapseCheck()
        expansionMode = .collapsed
        ignoreLeaveUntil = nil
        transition(animated: animated)
        debugSnapshot(tag: "collapse")
    }

    // MARK: - 셸프 밖 클릭

    /// 셸프 밖을 클릭하면 미리보기·고정 상태 모두 접는다. 로컬 모니터는 현재 앱의
    /// 이벤트를, 글로벌 모니터는 다른 앱에 포커스가 있을 때의 이벤트를 받는다.
    /// 접힌 동안에는 할 일이 없으므로 펼쳐질 때만 설치하고 접히면 제거한다.
    private func installOutsideClickMonitor() {
        guard eventMonitors.isEmpty else { return }

        let local = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.collapseIfClickedOutside()
            return event
        }
        if let local {
            eventMonitors.append(local)
        }

        let global = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            self?.collapseIfClickedOutside()
        }
        if let global {
            eventMonitors.append(global)
        }
    }

    private func removeOutsideClickMonitors() {
        for monitor in eventMonitors {
            NSEvent.removeMonitor(monitor)
        }
        eventMonitors.removeAll()
    }

    private func collapseIfClickedOutside() {
        guard expansionMode != .collapsed, !isMouseInPanel() else { return }
        collapseShelf(animated: true)
    }

    /// 개발용. 크기 변화가 끝난 뒤 캡슐 뷰를 PNG로 저장한다.
    /// 화면 기록 권한 없이 실제 렌더 결과를 확인하기 위한 것이다. 배포 동작에는 영향이 없다.
    private func debugSnapshot(tag: String) {
        guard let dir = Demo.snapshotDirectory else { return }
        snapshotCounter += 1
        let index = snapshotCounter
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.snapshotDelay) { [weak self] in
            guard let self, let hosting, let panel else { return }
            let bounds = hosting.bounds
            guard let rep = hosting.bitmapImageRepForCachingDisplay(in: bounds) else { return }
            hosting.cacheDisplay(in: bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else { return }
            let size = "\(Int(panel.frame.width))x\(Int(panel.frame.height))"
            let url = URL(fileURLWithPath: dir).appendingPathComponent("\(index)-\(tag)-\(size).png")
            try? png.write(to: url)
        }
    }

    // MARK: - 창 크기

    /// 접힘/펼침 전환. 원칙은 하나다 — **창 프레임은 애니메이션이 도는 동안 절대 바뀌지 않는다.**
    /// 창(윈도우 서버)과 SwiftUI 스프링(렌더러)은 프레임 단위로 동기화할 수 없어서,
    /// 애니메이션 중에 창을 건드리면 반드시 어긋난 프레임(배경 비침·요소 이탈)이 생긴다.
    ///
    /// - 펼침: 창을 **먼저** 넉넉한 최대 프레임으로 키운 뒤 렌더한다. 스프링은 이미 커진 창 안에서만 돈다.
    /// - 접힘: 렌더로 스프링을 시작하고 창은 큰 채로 둔다. 셸프가 접힘 높이로 정착하면 그때 한 번 스냅한다.
    private func transition(animated: Bool) {
        guard let hosting else { return }
        settleWork?.cancel()
        if expansionMode.isExpanded {
            installOutsideClickMonitor()
        } else {
            removeOutsideClickMonitors()
        }

        if !animated {
            awaitingSettle = false
            applyExpansion()
            hosting.layoutSubtreeIfNeeded()
            setWindowSize(hosting.fittingSize)
            return
        }
        awaitingSettle = true
        if expansionMode.isExpanded {
            // 순서가 핵심: 창 확대 → 렌더. 반대로 하면 셸프가 32pt 창 안에서 자라다 창이 점프한다.
            setWindowSize(maxContentSize)
        }
        applyExpansion()
    }

    /// 접힘/펼침만 스프링으로 반영한다. 나머지 모델 값은 `show()`가 즉시 대입한다.
    private func applyExpansion() {
        guard let model, model.expansionMode != expansionMode else { return }
        withAnimation(CruxAnimation.swiftUI) {
            model.expansionMode = expansionMode
        }
    }

    /// 스프링이 도는 동안 셸프가 어떤 크기까지 커져도 잘리지 않을 넉넉한 창 크기.
    /// 투명이라 커도 보이지 않는다. 정확할 필요 없이 최대치만 넘으면 된다.
    private var maxContentSize: CGSize {
        let metrics = metrics ?? NotchMetrics.from(screen: Self.activeScreen())
        return CGSize(width: metrics.expandedWidth, height: 260)
    }

    /// 셸프의 실제 렌더 크기가 정착했을 때 창을 정확한 크기로 한 번 맞춘다.
    ///
    /// 이 콜백은 SwiftUI 레이아웃 도중 불린다. 여기서 `layoutSubtreeIfNeeded`나 `fittingSize`를
    /// 동기로 부르면 진행 중인 애니메이션 트랜잭션이 강제 완료돼 스프링이 사라진다(즉시 전환).
    /// 그래서 hosting view를 전혀 건드리지 않고, 크기 변화가 잠깐 멎으면 그때 창만 맞춘다.
    private func followContentSize(_ size: CGSize) {
        guard awaitingSettle else { return }
        settleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, awaitingSettle else { return }
            awaitingSettle = false
            setWindowSize(size)
        }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    /// 화면 최상단·노치 중심에 맞춰 창 크기를 정한다. 상단은 항상 화면 맨 위에 고정한다.
    private func setWindowSize(_ contentSize: CGSize) {
        guard let panel else { return }
        let metrics = metrics ?? NotchMetrics.from(screen: Self.activeScreen())
        var size = contentSize
        size.width = max(size.width, metrics.islandWidth(expanded: expansionMode.isExpanded))
        size.height = max(ceil(size.height), metrics.collapsedHeight)

        let frame = metrics.windowFrame(for: size)
        if abs(frame.height - panel.frame.height) < 0.5, frame.origin == panel.frame.origin,
           abs(frame.width - panel.frame.width) < 0.5 {
            return
        }
        panel.setFrame(frame, display: true)
    }

    /// 마우스가 있는 화면을 활성 화면으로 본다. 외부 모니터를 쓰는 경우를 위한 처리다.
    static func activeScreen() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) {
            return screen
        }
        return NSScreen.main ?? NSScreen.screens[0]
    }
}

/// 비활성화 패널이지만 메모 입력을 위해 키 창이 될 수 있어야 한다.
/// `canBecomeKey`가 false면 텍스트 필드가 포커스를 받지 못한다.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool {
        true
    }
}

/// 노치 셸프 루트 뷰가 읽는 상태. 창(CruxWindow)이 값을 바꾸고 SwiftUI가 애니메이션한다.
///
/// 콜백은 관찰 대상에서 뺀다. 매 `show()`마다 새 클로저가 대입되는데, 이를 관찰하면
/// 클로저 교체만으로도 루트 뷰가 전부 다시 그려진다.
@MainActor @Observable
final class CruxShelfModel {
    var state: CruxState
    var detailMessage: String?
    var meetingTitle: String?
    var memos: [MeetingMemo] = []
    var processingStage: ProcessingStage?
    var liveCaptions = LiveCaptionState()
    var metrics: NotchMetrics
    var expansionMode: CruxExpansionMode

    @ObservationIgnored var onAddMemo: (String) -> Void = { _ in }
    @ObservationIgnored var onMemoFocusChange: (Bool) -> Void = { _ in }
    @ObservationIgnored var onContentSizeChange: (CGSize) -> Void = { _ in }
    @ObservationIgnored var onHoverChange: (Bool) -> Void = { _ in }
    @ObservationIgnored var onTogglePin: () -> Void = {}
    @ObservationIgnored var onPrimaryAction: () -> Void = {}
    @ObservationIgnored var onDismiss: () -> Void = {}
    @ObservationIgnored var onOpenPreview: () -> Void = {}
    @ObservationIgnored var onTogglePause: () -> Void = {}
    @ObservationIgnored var onStop: () -> Void = {}
    @ObservationIgnored var onCancelProcessing: () -> Void = {}

    init(state: CruxState, metrics: NotchMetrics, expansionMode: CruxExpansionMode) {
        self.state = state
        self.metrics = metrics
        self.expansionMode = expansionMode
    }
}

/// 한 번만 만들어지는 루트. 모델이 바뀔 때마다 CruxView를 다시 그린다.
struct CruxShelfRoot: View {
    let model: CruxShelfModel

    var body: some View {
        CruxView(
            state: model.state,
            detailMessage: model.detailMessage,
            meetingTitle: model.meetingTitle,
            memos: model.memos,
            processingStage: model.processingStage,
            liveCaptions: model.liveCaptions,
            metrics: model.metrics,
            expansionMode: model.expansionMode,
            onAddMemo: model.onAddMemo,
            onMemoFocusChange: model.onMemoFocusChange,
            onContentSizeChange: model.onContentSizeChange,
            onHoverChange: model.onHoverChange,
            onTogglePin: model.onTogglePin,
            onPrimaryAction: model.onPrimaryAction,
            onDismiss: model.onDismiss,
            onOpenPreview: model.onOpenPreview,
            onTogglePause: model.onTogglePause,
            onStop: model.onStop,
            onCancelProcessing: model.onCancelProcessing
        )
    }
}
