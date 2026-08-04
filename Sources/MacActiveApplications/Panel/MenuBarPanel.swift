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

    init(store: RunningAppsStore, peekController: WindowPeekController) {
        self.store = store
        self.peekController = peekController

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
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true

        let root = TaskbarRootView(
            store: store,
            peekController: peekController,
            chrome: .constant(.expanded),
            barHeight: 24,
            onChromeChange: { _ in }
        )
        let hosting = NSHostingView(rootView: root)
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
        peekController.hide(immediate: true)
        rebindRoot()
        relayout(animated: true)
    }

    private func desiredWidth(in slot: MenuBarSlot) -> CGFloat {
        let content = TaskbarStyle.contentWidth(
            appCount: store.apps.count,
            barHeight: slot.barHeight,
            chrome: chrome == .expanded
        )
        let maxWidth = TaskbarStyle.maxExpandedWidth(slotWidth: slot.availableFrame.width)
        return min(content, maxWidth)
    }

    private func relayout(animated: Bool) {
        guard let slot = MenuBarGeometry.slot() else { return }
        self.slot = slot
        rebindRoot(barHeight: slot.barHeight)
        applyFrame(desiredWidth(in: slot), in: slot, animated: animated)
    }

    private func relayoutFrame(animated: Bool) {
        guard let slot = MenuBarGeometry.slot() else { return }
        self.slot = slot
        applyFrame(desiredWidth(in: slot), in: slot, animated: animated)
    }

    private func applyFrame(_ width: CGFloat, in slot: MenuBarSlot, animated: Bool) {
        let frame = MenuBarGeometry.panelFrame(width: width, in: slot)
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }

    private func rebindRoot(barHeight: CGFloat? = nil) {
        let height = barHeight ?? slot?.barHeight ?? 24
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
            }
        )
    }
}

struct TaskbarRootView: View {
    @ObservedObject var store: RunningAppsStore
    @ObservedObject var peekController: WindowPeekController
    @Binding var chrome: TaskbarChrome
    let barHeight: CGFloat
    let onChromeChange: (TaskbarChrome) -> Void

    var body: some View {
        TaskbarView(
            store: store,
            peekController: peekController,
            chrome: $chrome,
            barHeight: barHeight,
            onChromeChange: onChromeChange
        )
    }
}

final class MenuBarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}
