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
    /// 개발용. `CRUX_DEMO_HOVER=1`이면 미리보기 상태로 시작한다. 합성 포인터 이벤트가 막힌 환경에서
    /// 펼친 레이아웃을 스냅샷으로 확인하기 위한 것이다.
    private var expansionMode: CruxExpansionMode =
        ProcessInfo.processInfo.environment["CRUX_DEMO_HOVER"] == "1" ? .preview : .collapsed
    /// 창을 다시 그린 직후 hover-off를 무시하는 마감 시각.
    private var ignoreLeaveUntil: Date?
    /// 실제 이탈인지 다시 확인하는 접기 예약.
    private var collapseWorkItem: DispatchWorkItem?
    /// 다시 그릴 때 필요한 마지막 입력값.
    private var render: (() -> Void)?
    private var snapshotCounter = 0
    private var eventMonitors: [Any] = []
    /// 전환 스프링이 정착하기를 기다리는 중인지. 정착 시 창을 정확한 크기로 한 번 맞춘다.
    private var awaitingSettle = false
    private var settleWork: DispatchWorkItem?
    private var lastContentSize: CGSize?
    /// 개발용 자동 토글 타이머. `CRUX_DEMO_TOGGLE=1`일 때만 돈다.
    private var demoToggleTimer: Timer?

    public init() {}

    public func show(
        state: CruxState,
        detailMessage: String? = nil,
        meetingTitle: String? = nil,
        memos: [MeetingMemo] = [],
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

        let screen = Self.activeScreen()
        let metrics = NotchMetrics.from(screen: screen)
        self.metrics = metrics

        // 상태가 바뀌면 펼쳐 둔 상세는 접는다.
        if CapsuleHoverGate.shouldResetExpansionMode(previousKindId: lastKindId, nextKindId: state.kindId) {
            cancelCollapseCheck()
            expansionMode = .collapsed
            ignoreLeaveUntil = nil
        }
        lastKindId = state.kindId
        // 개발용. `CRUX_DEMO_EXPANDED=1`이면 마우스 없이도 펼친 상태로 고정해 레이아웃을 확인한다.
        if ProcessInfo.processInfo.environment["CRUX_DEMO_EXPANDED"] != nil {
            expansionMode = .pinned
        }

        // 루트 뷰는 한 번만 만든다. 이후에는 모델 값만 바꾼다.
        // `rootView`를 매번 새 값으로 대입하면 SwiftUI가 애니메이션 트랜잭션 없이 즉시 갈아 끼워
        // 접힘/펼침 스프링이 전혀 돌지 않는다(영상 프레임으로 확인). 모델 변경은 정상적인
        // SwiftUI 업데이트라 `withAnimation`이 그대로 실린다.
        if hosting == nil {
            let model = CruxShelfModel(
                state: state,
                metrics: metrics,
                expansionMode: expansionMode
            )
            model.onMemoFocusChange = { [weak self] focused in self?.setMemoEditing(focused) }
            model.onContentSizeChange = { [weak self] size in self?.followContentSize(size) }
            model.onHoverChange = { [weak self] hovering in self?.setHovering(hovering) }
            model.onTogglePin = { [weak self] in self?.togglePin() }
            model.onCollapse = { [weak self] in self?.collapseShelf(animated: true) }
            self.model = model

            let hostingView = NSHostingView(rootView: AnyView(CruxShelfRoot(model: model)))
            hostingView.translatesAutoresizingMaskIntoConstraints = true
            hostingView.wantsLayer = true
            hostingView.layer?.masksToBounds = true
            hosting = hostingView

            let panel = KeyablePanel(
                contentRect: NSRect(x: 0, y: 0, width: 420, height: metrics.collapsedHeight),
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
            panel.contentView = hostingView
            self.panel = panel
            installOutsideClickMonitor()
        }

        render = { [weak self] in
            guard let self, let model = self.model else { return }
            model.state = state
            model.detailMessage = detailMessage
            model.meetingTitle = meetingTitle
            model.memos = memos
            model.metrics = metrics
            model.onAddMemo = onAddMemo
            model.onPrimaryAction = onPrimaryAction
            model.onDismiss = onDismiss
            model.onOpenPreview = onOpenPreview
            model.onTogglePause = onTogglePause
            model.onStop = onStop
            model.onCancelProcessing = onCancelProcessing
            // 접힘/펼침만 스프링으로. 나머지 값 변화는 즉시 반영한다.
            if model.expansionMode != self.expansionMode {
                withAnimation(CruxAnimation.swiftUI) {
                    model.expansionMode = self.expansionMode
                }
            }
        }

        transition(animated: false)
        panel?.orderFrontRegardless()
        debugSnapshot(tag: "shown")
        startDemoToggleIfNeeded()
    }

    /// 개발용. `CRUX_DEMO_TOGGLE=1`이면 마우스 없이 1.8초마다 펼침/접힘을 반복해
    /// 애니메이션을 눈·영상으로 확인할 수 있게 한다. 배포 동작에는 영향이 없다.
    private func startDemoToggleIfNeeded() {
        guard ProcessInfo.processInfo.environment["CRUX_DEMO_TOGGLE"] == "1",
              demoToggleTimer == nil else { return }
        demoToggleTimer = Timer.scheduledTimer(withTimeInterval: 1.8, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.togglePin() }
        }
    }

    public func hide() {
        cancelCollapseCheck()
        expansionMode = .collapsed
        ignoreLeaveUntil = nil
        panel?.orderOut(nil)
    }

    public func close() {
        cancelCollapseCheck()
        removeOutsideClickMonitors()
        panel?.close()
        panel = nil
        hosting = nil
        model = nil
    }

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
        let nextMode = CapsuleHoverGate.mode(afterHover: hovering, current: expansionMode)
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
        expansionMode = CapsuleHoverGate.mode(afterPinToggle: expansionMode)
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

    /// 셸프 밖을 클릭하면 미리보기·고정 상태 모두 접는다. 로컬 모니터는 현재 앱의
    /// 이벤트를, 글로벌 모니터는 다른 앱에 포커스가 있을 때의 이벤트를 받는다.
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

    /// 개발용. `CRUX_DEMO_SNAPSHOT_DIR`가 있으면 크기 변화가 끝난 뒤 캡슐 뷰를 PNG로 저장한다.
    /// 화면 기록 권한 없이 실제 렌더 결과를 확인하기 위한 것이다. 배포 동작에는 영향이 없다.
    private func debugSnapshot(tag: String) {
        guard let dir = ProcessInfo.processInfo.environment["CRUX_DEMO_SNAPSHOT_DIR"] else { return }
        snapshotCounter += 1
        let index = snapshotCounter
        DispatchQueue.main.asyncAfter(deadline: .now() + CruxAnimation.duration + 0.3) { [weak self] in
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

    /// 지금 내용에 맞는 크기로 창을 맞춘다.
    ///
    /// 접힘/펼침 전환. 원칙은 하나다 — **창 프레임은 애니메이션이 도는 동안 절대 바뀌지 않는다.**
    /// 창(윈도우 서버)과 SwiftUI 스프링(렌더러)은 프레임 단위로 동기화할 수 없어서,
    /// 애니메이션 중에 창을 건드리면 반드시 어긋난 프레임(배경 비침·요소 이탈)이 생긴다.
    ///
    /// - 펼침: 창을 **먼저** 넉넉한 최대 프레임으로 키운 뒤 렌더한다. 스프링은 이미 커진 창 안에서만 돈다.
    /// - 접힘: 렌더로 스프링을 시작하고 창은 큰 채로 둔다. 셸프가 접힘 높이로 정착하면 그때 한 번 스냅한다.
    private func transition(animated: Bool) {
        guard let hosting else { return }
        if !animated {
            awaitingSettle = false
            render?()
            hosting.layoutSubtreeIfNeeded()
            setWindowSize(hosting.fittingSize)
            return
        }
        settleWork?.cancel()
        if expansionMode.isExpanded {
            // 순서가 핵심: 창 확대 → 렌더. 반대로 하면 셸프가 32pt 창 안에서 자라다 창이 점프한다.
            awaitingSettle = true
            setWindowSize(maxContentSize)
            render?()
        } else {
            awaitingSettle = true
            render?()
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
        lastContentSize = size
        guard awaitingSettle else { return }
        settleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.awaitingSettle, let size = self.lastContentSize else { return }
            self.awaitingSettle = false
            self.setWindowSize(size)
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

    /// 처음 띄울 때 등 애니메이션 없이 위치만 다시 잡을 때 쓴다.
    public func reposition(animated: Bool = false, contentSize _: CGSize? = nil) {
        transition(animated: animated)
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
    override var canBecomeKey: Bool { true }
}

/// 노치 셸프 루트 뷰가 읽는 상태. 창(CruxWindow)이 값을 바꾸고 SwiftUI가 애니메이션한다.
@MainActor @Observable
final class CruxShelfModel {
    var state: CruxState
    var detailMessage: String?
    var meetingTitle: String?
    var memos: [MeetingMemo] = []
    var metrics: NotchMetrics
    var expansionMode: CruxExpansionMode

    var onAddMemo: (String) -> Void = { _ in }
    var onMemoFocusChange: (Bool) -> Void = { _ in }
    var onContentSizeChange: (CGSize) -> Void = { _ in }
    var onHoverChange: (Bool) -> Void = { _ in }
    var onTogglePin: () -> Void = {}
    var onCollapse: () -> Void = {}
    var onPrimaryAction: () -> Void = {}
    var onDismiss: () -> Void = {}
    var onOpenPreview: () -> Void = {}
    var onTogglePause: () -> Void = {}
    var onStop: () -> Void = {}
    var onCancelProcessing: () -> Void = {}

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
            metrics: model.metrics,
            expansionMode: model.expansionMode,
            onAddMemo: model.onAddMemo,
            onMemoFocusChange: model.onMemoFocusChange,
            onContentSizeChange: model.onContentSizeChange,
            onHoverChange: model.onHoverChange,
            onTogglePin: model.onTogglePin,
            onCollapse: model.onCollapse,
            onPrimaryAction: model.onPrimaryAction,
            onDismiss: model.onDismiss,
            onOpenPreview: model.onOpenPreview,
            onTogglePause: model.onTogglePause,
            onStop: model.onStop,
            onCancelProcessing: model.onCancelProcessing
        )
    }
}
