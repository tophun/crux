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
    /// 접히는 동안 셸프 크기를 창이 따라가는 중인지. 펼칠 때는 false(창을 즉시 최종 크기로).
    private var followsContentSize = false
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

        render = { [weak self] in
            guard let self else { return }
            let view = AnyView(
                CruxView(
                    state: state,
                    detailMessage: detailMessage,
                    meetingTitle: meetingTitle,
                    memos: memos,
                    metrics: metrics,
                    expansionMode: expansionMode,
                    onAddMemo: onAddMemo,
                    onMemoFocusChange: { [weak self] focused in
                        self?.setMemoEditing(focused)
                    },
                    onContentSizeChange: { [weak self] size in
                        self?.followContentSize(size)
                    },
                    onHoverChange: { [weak self] hovering in
                        self?.setHovering(hovering)
                    },
                    onTogglePin: { [weak self] in
                        self?.togglePin()
                    },
                    onCollapse: { [weak self] in
                        self?.collapseShelf(animated: true)
                    },
                    onPrimaryAction: onPrimaryAction,
                    onDismiss: onDismiss,
                    onOpenPreview: onOpenPreview,
                    onTogglePause: onTogglePause,
                    onStop: onStop,
                    onCancelProcessing: onCancelProcessing
                )
            )
            hosting?.rootView = view
        }

        if hosting != nil {
            render?()
        } else {
            let hostingView = NSHostingView(rootView: AnyView(EmptyView()))
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
            render?()
        }

        resize(animated: false)
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
    }

    /// 메모를 입력하는 동안은 포인터가 나가도 접지 않는다. 입력이 끝나면 다시 호버 규칙을 따른다.
    private func setMemoEditing(_ editing: Bool) {
        if editing {
            cancelCollapseCheck()
            if expansionMode != .pinned {
                expansionMode = .pinned
                render?()
                resize(animated: true)
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
        render?()
        resize(animated: true)
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
        render?()
        resize(animated: true)
        debugSnapshot(tag: expansionMode.isPinned ? "pinned" : "unpinned")
    }

    /// 셸프만 접는다. 회의 상태 머신의 `dismissed` 이벤트는 발생시키지 않으므로,
    /// 현재 회의의 감지·처리 상태와 다음 표시를 그대로 유지한다.
    private func collapseShelf(animated: Bool) {
        guard expansionMode != .collapsed else { return }
        cancelCollapseCheck()
        expansionMode = .collapsed
        ignoreLeaveUntil = nil
        render?()
        resize(animated: animated)
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
    /// 접힘/펼침 전환. 창 크기는 두 방향을 다르게 다뤄야 자연스럽다.
    ///
    /// - 펼침: 최종 크기로 창을 **즉시** 키운다. 창이 먼저 커져 있으면 안에서 스프링으로
    ///   자라나는 검은 셸프가 잘리지 않는다.
    /// - 접힘: 창을 미리 줄이지 않는다. 대신 셸프가 스프링으로 줄어드는 실제 크기를
    ///   `followContentSize`로 매 프레임 받아 창이 그대로 따라간다. 창이 항상 내용보다
    ///   크거나 같아 배경이 비치지 않고, 지연 스냅도 없다.
    private func resize(animated: Bool) {
        guard let hosting else { return }
        if !animated {
            followsContentSize = false
            hosting.layoutSubtreeIfNeeded()
            setWindowSize(hosting.fittingSize)
            return
        }
        if expansionMode.isExpanded {
            followsContentSize = false
            hosting.layoutSubtreeIfNeeded()
            setWindowSize(hosting.fittingSize) // 최종 펼침 크기로 즉시
        } else {
            followsContentSize = true // 셸프가 줄어드는 걸 창이 따라간다
        }
    }

    /// 셸프의 실제 렌더 크기를 창에 반영한다. 접히는 동안에만 창을 따라 줄인다.
    private func followContentSize(_ size: CGSize) {
        guard followsContentSize else { return }
        let metrics = metrics ?? NotchMetrics.from(screen: Self.activeScreen())
        setWindowSize(size)
        if size.height <= metrics.collapsedHeight + 0.5 {
            followsContentSize = false
        }
    }

    /// 화면 최상단·노치 중심에 맞춰 창 크기를 정한다. 상단은 항상 화면 맨 위에 고정한다.
    private func setWindowSize(_ contentSize: CGSize) {
        guard let panel else { return }
        let metrics = metrics ?? NotchMetrics.from(screen: Self.activeScreen())
        var size = contentSize
        size.width = metrics.islandWidth(expanded: expansionMode.isExpanded)
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
        resize(animated: animated)
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
