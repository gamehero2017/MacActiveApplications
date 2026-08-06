import AppKit
import Combine
import QuartzCore
import SwiftUI

@MainActor
final class MenuBarPanelController: NSObject {
    private let panel: MenuBarPanel
    private let store: RunningAppsStore
    private let peekController: WindowPeekController
    private let hosting: NSHostingView<TaskbarRootView>

    private var chrome: TaskbarChrome = .expanded
    private var slot: MenuBarSlot?
    private var cancellables = Set<AnyCancellable>()

    private var screenObserver: NSObjectProtocol?
    private var spaceObserver: NSObjectProtocol?
    private var boundBarHeight: CGFloat?

    /// 相对刘海的向左偏移；拖拽中用 live 值，结束后写入偏好。
    private var trailingOffset: CGFloat = 0
    private var panelDragStartScreenX: CGFloat?
    private var panelDragStartOffset: CGFloat = 0
    private var lastPresentedFlush: Bool?

    init(store: RunningAppsStore, peekController: WindowPeekController) {
        self.store = store
        self.peekController = peekController
        self.chrome = TaskbarPreferences.shared.initialChromeExpanded ? .expanded : .collapsed
        self.trailingOffset = TaskbarPreferences.shared.panelTrailingOffset

        let panel = MenuBarPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        // stationary：触发角「显示桌面」/ Exposé 时不挪走本面板，否则随后把手动画会错位。
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true

        // 先挂占位根视图；super.init 后立刻用真实 Binding 替换。
        let hosting = NSHostingView(
            rootView: TaskbarRootView(
                store: store,
                peekController: peekController,
                chrome: .constant(.expanded),
                barHeight: 24,
                onChromeChange: { _ in },
                onPanelDragBegan: { _ in },
                onPanelDragMoved: { _ in },
                onPanelDragEnded: {},
                isFlushToNotch: true
            )
        )
        hosting.autoresizingMask = [.width, .height]
        hosting.focusRingType = .none

        self.panel = panel
        self.hosting = hosting

        super.init()

        panel.contentView = hosting
        rebindRoot()
        startObserving()
        relayout(animated: false)
        panel.orderFrontRegardless()
    }

    deinit {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        if let spaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver)
        }
    }

    func show() {
        relayout(animated: false)
        panel.orderFrontRegardless()
    }

    private func startObserving() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.relayout(animated: false)
            }
        }

        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.relayout(animated: false)
            }
        }

        store.$apps
            .map(\.count)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                // Width depends on icon count; highlight-only updates skip frame work.
                // SwiftUI refreshes icons via @ObservedObject without replacing rootView.
                self?.relayoutFrame(animated: true)
            }
            .store(in: &cancellables)
    }

    private func setChrome(_ next: TaskbarChrome) {
        guard chrome != next else { return }
        chrome = next
        TaskbarPreferences.shared.saveChromeExpanded(next == .expanded)
        peekController.hide(immediate: true)
        rebindRoot()
        // 贴刘海横向收起：瞬时落地（显示桌面兼容）；未贴刘海纵向收起：轻微动画。
        relayoutFrame(animated: !isFlushToNotch)
        panel.orderFrontRegardless()
    }

    /// 贴刘海（把手贴 notch）时横向收起；拖离后改为纵向向上收起。
    private var isFlushToNotch: Bool {
        trailingOffset <= TaskbarStyle.notchFlushTolerance
    }

    private func desiredWidth(in slot: MenuBarSlot) -> CGFloat {
        if chrome == .collapsed && !isFlushToNotch {
            // 向上收起：高度仍为细条，宽度仅约一个图标；右缘由 trailingOffset 保持。
            return TaskbarStyle.detachedCollapsedHandleWidth(forBarHeight: slot.barHeight)
        }
        let useExpandedWidth = chrome == .expanded
        let content = TaskbarStyle.contentWidth(
            appCount: store.apps.count,
            barHeight: slot.barHeight,
            chrome: useExpandedWidth
        )
        let maxWidth = TaskbarStyle.maxExpandedWidth(slotWidth: slot.availableFrame.width)
        return min(content, maxWidth)
    }

    private func desiredHeight(in slot: MenuBarSlot) -> CGFloat {
        if chrome == .collapsed && !isFlushToNotch {
            return TaskbarStyle.collapsedStripHeight
        }
        return slot.barHeight
    }

    private func relayout(animated: Bool) {
        guard let slot = MenuBarGeometry.slot() else { return }
        self.slot = slot
        // barHeight 未变时只改 frame，避免重置 SwiftUI hover / scroll 状态。
        if boundBarHeight != slot.barHeight {
            boundBarHeight = slot.barHeight
            rebindRoot(barHeight: slot.barHeight)
        } else {
            presentFlushIfNeeded()
        }
        applyFrame(desiredWidth(in: slot), in: slot, animated: animated)
    }

    private func relayoutFrame(animated: Bool) {
        guard let slot = MenuBarGeometry.slot() else { return }
        self.slot = slot
        presentFlushIfNeeded()
        applyFrame(desiredWidth(in: slot), in: slot, animated: animated)
    }

    private func applyFrame(_ width: CGFloat, in slot: MenuBarSlot, animated: Bool) {
        trailingOffset = MenuBarGeometry.clampedTrailingOffset(trailingOffset, width: width, in: slot)
        let height = desiredHeight(in: slot)
        let pinToTop = chrome == .collapsed && !isFlushToNotch
        let frame = MenuBarGeometry.panelFrame(
            width: width,
            height: height,
            in: slot,
            trailingOffset: trailingOffset,
            pinToTop: pinToTop
        )
        // 清掉可能被「显示桌面」打断的残留动画，防止目标 frame 与实际不同步。
        panel.animations = [:]

        if animated {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(frame, display: true)
            }, completionHandler: { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    if !self.panel.frame.equalTo(frame) {
                        self.panel.setFrame(frame, display: true)
                    }
                    self.panel.orderFrontRegardless()
                }
            })
        } else {
            panel.setFrame(frame, display: true)
            panel.orderFrontRegardless()
        }
    }

    // MARK: - 汉堡拖动整条任务栏

    private func beginPanelDrag(screenX: CGFloat) {
        peekController.hide(immediate: true)
        // 纵向收起时先展开再拖，避免拖条带错位。
        if chrome == .collapsed && !isFlushToNotch {
            chrome = .expanded
            TaskbarPreferences.shared.saveChromeExpanded(true)
            rebindRoot()
            if let slot {
                applyFrame(desiredWidth(in: slot), in: slot, animated: false)
            }
        }
        panelDragStartScreenX = screenX
        panelDragStartOffset = trailingOffset
    }

    private func updatePanelDrag(screenX: CGFloat) {
        guard let startX = panelDragStartScreenX, let slot else { return }
        // 鼠标右移 → 任务栏右移 → 减小相对刘海的向左偏移。
        let delta = screenX - startX
        let width = desiredWidth(in: slot)
        trailingOffset = MenuBarGeometry.clampedTrailingOffset(
            panelDragStartOffset - delta,
            width: width,
            in: slot
        )
        // 拖拽中不 rebind，避免命中层被重建打断拖动手势；松手后再切换箭头样式。
        applyFrame(width, in: slot, animated: false)
    }

    private func endPanelDrag() {
        panelDragStartScreenX = nil
        TaskbarPreferences.shared.savePanelTrailingOffset(trailingOffset)
        presentFlushIfNeeded()
    }

    private func presentFlushIfNeeded() {
        let flush = isFlushToNotch
        guard lastPresentedFlush != flush else { return }
        lastPresentedFlush = flush
        rebindRoot()
    }

    private func rebindRoot(barHeight: CGFloat? = nil) {
        let height = barHeight ?? slot?.barHeight ?? 24
        boundBarHeight = height
        let flush = isFlushToNotch
        lastPresentedFlush = flush
        hosting.rootView = TaskbarRootView(
            store: store,
            peekController: peekController,
            chrome: Binding(
                get: { [weak self] in self?.chrome ?? .expanded },
                set: { [weak self] in self?.setChrome($0) }
            ),
            barHeight: height,
            onChromeChange: { [weak self] next in
                self?.setChrome(next)
            },
            onPanelDragBegan: { [weak self] screenX in
                self?.beginPanelDrag(screenX: screenX)
            },
            onPanelDragMoved: { [weak self] screenX in
                self?.updatePanelDrag(screenX: screenX)
            },
            onPanelDragEnded: { [weak self] in
                self?.endPanelDrag()
            },
            isFlushToNotch: flush
        )
    }
}

struct TaskbarRootView: View {
    @ObservedObject var store: RunningAppsStore
    @ObservedObject var peekController: WindowPeekController
    @Binding var chrome: TaskbarChrome
    let barHeight: CGFloat
    let onChromeChange: (TaskbarChrome) -> Void
    let onPanelDragBegan: (CGFloat) -> Void
    let onPanelDragMoved: (CGFloat) -> Void
    let onPanelDragEnded: () -> Void
    let isFlushToNotch: Bool

    var body: some View {
        TaskbarView(
            store: store,
            peekController: peekController,
            chrome: $chrome,
            barHeight: barHeight,
            onChromeChange: onChromeChange,
            onPanelDragBegan: onPanelDragBegan,
            onPanelDragMoved: onPanelDragMoved,
            onPanelDragEnded: onPanelDragEnded,
            isFlushToNotch: isFlushToNotch
        )
    }
}

final class MenuBarPanel: NSPanel {
    /// 仅弹 `NSMenu` 时临时允许成为 key；平时必须为 false。
    /// 否则 Apps / 启动板开合后焦点常留在本面板，其它 App 会出现「点得开但无法输入」。
    var allowsKeyWhenNeeded = false

    override var canBecomeKey: Bool { allowsKeyWhenNeeded }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// 任务栏为 accessory + statusBar 面板：交互后主动让出键盘焦点。
@MainActor
enum TaskbarFocus {
    static func resignTaskbarKey() {
        for window in NSApp.windows {
            if let panel = window as? MenuBarPanel {
                panel.allowsKeyWhenNeeded = false
            }
            if window.isKeyWindow {
                window.resignKey()
            }
        }
        if NSApp.isActive {
            NSApp.deactivate()
        }
    }

    /// 弹出菜单前短暂允许 key，结束后立刻让出。
    static func withTemporaryKey(for window: NSWindow?, perform: () -> Void) {
        let panel = window as? MenuBarPanel
        panel?.allowsKeyWhenNeeded = true
        window?.makeKeyAndOrderFront(nil)
        perform()
        resignTaskbarKey()
    }
}
