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
    /// 마우스 오버로 커진 상태. 뷰가 아니라 창이 들고 있어야 새 크기를 계산할 수 있다.
    ///
    /// 호스팅 뷰는 창 크기에 맞춰 늘어나므로, 뷰 안에서 크기를 재면 늘 "지금 창 크기"만 나온다.
    /// 확장 여부를 여기서 바꾸고 `fittingSize`(이상적인 크기)를 다시 물어야 창이 커질 수 있다.
    private var isHovering = false
    private var isPinned = false
    /// 창을 다시 그린 직후 hover-off를 무시하는 마감 시각.
    private var ignoreLeaveUntil: Date?
    /// 실제 이탈인지 다시 확인하는 접기 예약.
    private var collapseWorkItem: DispatchWorkItem?
    /// 다시 그릴 때 필요한 마지막 입력값.
    private var render: (() -> Void)?

    public init() {}

    public func show(
        state: CruxState,
        detailMessage: String? = nil,
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
        if state.kindId != lastKindId {
            lastKindId = state.kindId
            isPinned = false
        }

        render = { [weak self] in
            guard let self else { return }
            let view = AnyView(
                CruxView(
                    state: state,
                    detailMessage: detailMessage,
                    metrics: metrics,
                    isHovering: isHovering,
                    isPinned: isPinned,
                    onHoverChange: { [weak self] hovering in
                        self?.setHovering(hovering)
                    },
                    onTogglePin: { [weak self] in
                        self?.togglePin()
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
            hosting = hostingView

            let panel = NSPanel(
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
            render?()
        }

        resize(animated: false)
        panel?.orderFrontRegardless()
    }

    public func hide() {
        cancelCollapseCheck()
        panel?.orderOut(nil)
    }

    public func close() {
        cancelCollapseCheck()
        panel?.close()
        panel = nil
        hosting = nil
    }

    private func setHovering(_ hovering: Bool) {
        if hovering {
            cancelCollapseCheck()
            applyHover(true)
            return
        }

        // 창을 다시 그리면 onHover(false)가 바로 온다. 즉시 접지 않고 포인터 위치로 확인한다.
        scheduleCollapseCheck(now: Date())
    }

    private func applyHover(_ hovering: Bool) {
        guard isHovering != hovering else { return }
        isHovering = hovering
        ignoreLeaveUntil = CapsuleHoverGate.ignoreDeadline(after: Date())
        render?()
        resize(animated: true)
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
        isPinned.toggle()
        render?()
        resize(animated: true)
    }

    /// 지금 내용에 맞는 크기로 창을 맞춘다.
    ///
    /// `fittingSize`는 창 크기와 무관한 "이상적인 크기"라 확장 후에도 제대로 나온다.
    /// 레이아웃이 반영된 뒤에 읽어야 하므로 먼저 `layoutSubtreeIfNeeded`를 부른다.
    private func resize(animated: Bool) {
        guard let hosting else { return }
        hosting.layoutSubtreeIfNeeded()
        reposition(animated: animated, contentSize: hosting.fittingSize)
    }

    /// 화면 최상단, 노치 중심에 맞춰 배치한다.
    ///
    /// - Parameter animated: 크기가 바뀌는 경우 부드럽게 움직인다. 처음 띄울 때는 애니메이션하지 않는다.
    public func reposition(animated: Bool = false, contentSize: CGSize? = nil) {
        guard let panel, let hosting else { return }
        let metrics = metrics ?? NotchMetrics.from(screen: Self.activeScreen())

        var size = contentSize ?? hosting.fittingSize
        // 노치가 있는 화면에서는 최소한 노치를 덮을 만큼 넓혀 한 덩어리로 보이게 한다.
        size.width = max(size.width, metrics.notchWidth + 56)
        size.height = max(size.height, metrics.collapsedHeight)

        let origin = metrics.windowOrigin(for: size)
        let frame = NSRect(x: origin.x, y: origin.y, width: size.width, height: size.height)
        guard frame != panel.frame else { return }

        guard animated else {
            panel.setFrame(frame, display: true)
            return
        }
        // 창과 내용이 같은 곡선으로 움직여야 한 덩어리처럼 보인다.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = CruxAnimation.duration
            context.timingFunction = CruxAnimation.timingFunction
            context.allowsImplicitAnimation = true
            panel.animator().setFrame(frame, display: true)
        }
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
