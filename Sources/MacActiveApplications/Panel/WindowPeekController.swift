import AppKit
import SwiftUI

@MainActor
final class WindowPeekController: ObservableObject {
    private var panel: MenuBarPanel?
    private var hosting: NSHostingView<WindowPeekListView>?
    private var hideWorkItem: DispatchWorkItem?
    private(set) var currentPID: pid_t?
    private var currentAppName: String = ""
    private var currentAnchor: NSRect = .zero

    private var iconHovering = false
    private var peekHovering = false

    func setIconHovering(_ hovering: Bool) {
        iconHovering = hovering
        reconcileHover()
    }

    func show(pid: pid_t, appName: String, anchorScreenRect: NSRect) {
        AppWindowService.ensurePermission(prompt: true)
        let windows = AppWindowService.windows(for: pid)
        // 有可见窗口即显示标题栏列表（含单窗口）；无窗口则不弹出。
        guard !windows.isEmpty else {
            cancelHide()
            peekHovering = false
            if currentPID != nil {
                currentPID = nil
                panel?.orderOut(nil)
            }
            return
        }

        iconHovering = true
        cancelHide()
        currentPID = pid
        currentAppName = appName
        currentAnchor = anchorScreenRect
        present(windows: windows, pid: pid, appName: appName, anchor: anchorScreenRect)
    }

    func cancelHide() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
    }

    func hide(immediate: Bool = true) {
        cancelHide()
        iconHovering = false
        peekHovering = false
        currentPID = nil
        panel?.orderOut(nil)
    }

    private func setPeekHovering(_ hovering: Bool) {
        peekHovering = hovering
        reconcileHover()
    }

    private func reconcileHover() {
        if iconHovering || peekHovering {
            cancelHide()
            return
        }
        cancelHide()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.iconHovering, !self.peekHovering else { return }
            self.hide(immediate: true)
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + TaskbarStyle.peekHideDelay, execute: work)
    }

    private func refreshList() {
        guard let pid = currentPID else { return }
        AppWindowService.invalidateWindowsCache(for: pid)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self, self.currentPID == pid else { return }
            let windows = AppWindowService.windows(for: pid, bypassCache: true)
            if windows.isEmpty {
                self.hide(immediate: true)
            } else {
                self.present(
                    windows: windows,
                    pid: pid,
                    appName: self.currentAppName,
                    anchor: self.currentAnchor
                )
            }
        }
    }

    private func present(windows: [AppWindowInfo], pid: pid_t, appName: String, anchor: NSRect) {
        let content = WindowPeekListView(
            appName: appName,
            windows: windows,
            onSelect: { [weak self] window in
                AppWindowService.focus(window: window, pid: pid)
                self?.hide(immediate: true)
            },
            onMinimize: { [weak self] window in
                AppWindowService.minimize(window: window, pid: pid)
                self?.refreshList()
            },
            onMaximize: { [weak self] window in
                AppWindowService.toggleMaximize(window: window, pid: pid)
                self?.refreshList()
            },
            onClose: { [weak self] window in
                AppWindowService.close(window: window, pid: pid)
                self?.refreshList()
            },
            onHoverChange: { [weak self] hovering in
                self?.setPeekHovering(hovering)
            }
        )

        let width = TaskbarStyle.peekPanelWidth(
            titles: windows.map { "[\(appName)] \($0.title)" }
        )
        let rowHeight: CGFloat = 26
        let shadowPad = TaskbarStyle.peekShadowPadding
        let bridge = TaskbarStyle.peekHoverBridgeHeight
        let cardHeight = CGFloat(windows.count) * rowHeight + 8
        // No top shadow pad — keeps the panel entirely below the menu bar / notch.
        let panelWidth = width + shadowPad * 2
        let panelHeight = bridge + cardHeight + shadowPad

        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        var x = anchor.midX - panelWidth / 2
        x = min(max(x, visible.minX + 6), visible.maxX - panelWidth - 6)
        // Flush under the icon: panel.maxY == anchor.minY (does not cover the menu bar).
        let y = anchor.minY - panelHeight

        let panel = self.panel ?? makePanel()
        panel.hasShadow = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.acceptsMouseMovedEvents = true

        if let hosting {
            hosting.rootView = content
        } else {
            let hosting = NSHostingView(rootView: content)
            hosting.focusRingType = .none
            panel.contentView = hosting
            self.hosting = hosting
        }

        panel.setFrame(NSRect(x: x, y: y, width: panelWidth, height: panelHeight), display: true)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    private func makePanel() -> MenuBarPanel {
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
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true
        return panel
    }
}

struct WindowPeekListView: View {
    let appName: String
    let windows: [AppWindowInfo]
    let onSelect: (AppWindowInfo) -> Void
    let onMinimize: (AppWindowInfo) -> Void
    let onMaximize: (AppWindowInfo) -> Void
    let onClose: (AppWindowInfo) -> Void
    let onHoverChange: (Bool) -> Void

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Hit strip only under the menu bar — does not draw over the notch.
            Color.clear
                .frame(height: TaskbarStyle.peekHoverBridgeHeight)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())

            VStack(spacing: 2) {
                ForEach(windows) { window in
                    TitleBarRow(
                        appName: appName,
                        window: window,
                        onSelect: { onSelect(window) },
                        onMinimize: { onMinimize(window) },
                        onMaximize: { onMaximize(window) },
                        onClose: { onClose(window) }
                    )
                }
            }
            .padding(4)
            .background(cardShape.fill(Color(nsColor: .windowBackgroundColor).opacity(0.96)))
            .clipShape(cardShape)
            .compositingGroup()
            .shadow(color: .black.opacity(0.28), radius: 8, y: 3)
            .padding(.horizontal, TaskbarStyle.peekShadowPadding)
            .padding(.bottom, TaskbarStyle.peekShadowPadding)
        }
        .background(PeekHoverTrackingView(onHoverChange: onHoverChange))
        .accessibilityLabel(L10n.windowsOf(appName))
    }
}

private struct PeekHoverTrackingView: NSViewRepresentable {
    let onHoverChange: (Bool) -> Void

    func makeNSView(context: Context) -> PeekHoverNSView {
        let view = PeekHoverNSView()
        view.onHoverChange = onHoverChange
        return view
    }

    func updateNSView(_ nsView: PeekHoverNSView, context: Context) {
        nsView.onHoverChange = onHoverChange
    }
}

private final class PeekHoverNSView: NSView {
    var onHoverChange: ((Bool) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        updateTrackingAreas()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        let options: NSTrackingArea.Options = [
            .activeAlways,
            .mouseEnteredAndExited,
            .inVisibleRect,
            .enabledDuringMouseDrag
        ]
        addTrackingArea(NSTrackingArea(rect: .zero, options: options, owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChange?(false)
    }
}

private struct TitleBarRow: View {
    let appName: String
    let window: AppWindowInfo
    let onSelect: () -> Void
    let onMinimize: () -> Void
    let onMaximize: () -> Void
    let onClose: () -> Void

    @State private var hovering = false

    private var displayTitle: String {
        "[\(appName)] \(window.title)"
    }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onSelect) {
                HStack(spacing: 6) {
                    Text(displayTitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if window.isMinimized {
                        Image(systemName: "minus.rectangle")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(FocuslessButtonStyle())
            .help(displayTitle)

            WindowsCaptionButtons(
                isMaximized: window.isMaximized,
                isEnabled: window.isActionable,
                onMinimize: onMinimize,
                onMaximize: onMaximize,
                onClose: onClose
            )
        }
        .frame(height: 24)
        .background(
            Rectangle()
                .fill(hovering ? Color.primary.opacity(0.08) : Color(nsColor: .controlBackgroundColor))
        )
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 0.5)
        }
        .onHover { hovering = $0 }
    }
}

private struct WindowsCaptionButtons: View {
    let isMaximized: Bool
    var isEnabled: Bool = true
    let onMinimize: () -> Void
    let onMaximize: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            CaptionButton(kind: .minimize, isEnabled: isEnabled, action: onMinimize) {
                Rectangle()
                    .frame(width: 8, height: 1.1)
            }
            CaptionButton(kind: .maximize, isMaximized: isMaximized, isEnabled: isEnabled, action: onMaximize) {
                if isMaximized {
                    ZStack(alignment: .topTrailing) {
                        RoundedRectangle(cornerRadius: 0.5)
                            .strokeBorder(lineWidth: 1)
                            .frame(width: 6, height: 6)
                            .offset(x: -2, y: 2)
                        RoundedRectangle(cornerRadius: 0.5)
                            .fill(Color(nsColor: .controlBackgroundColor))
                            .overlay(
                                RoundedRectangle(cornerRadius: 0.5)
                                    .strokeBorder(lineWidth: 1)
                            )
                            .frame(width: 6, height: 6)
                    }
                    .frame(width: 9, height: 9)
                } else {
                    RoundedRectangle(cornerRadius: 0.5)
                        .strokeBorder(lineWidth: 1.1)
                        .frame(width: 8, height: 8)
                }
            }
            CaptionButton(kind: .close, isEnabled: isEnabled, action: onClose) {
                ZStack {
                    Capsule().frame(width: 9, height: 1.1).rotationEffect(.degrees(45))
                    Capsule().frame(width: 9, height: 1.1).rotationEffect(.degrees(-45))
                }
                .frame(width: 9, height: 9)
            }
        }
        .opacity(isEnabled ? 1 : 0.35)
    }
}

private enum CaptionKind {
    case minimize, maximize, close
}

private struct CaptionButton<Icon: View>: View {
    let kind: CaptionKind
    var isMaximized: Bool = false
    var isEnabled: Bool = true
    let action: () -> Void
    @ViewBuilder let icon: () -> Icon

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Rectangle()
                    .fill(backgroundColor)
                icon()
                    .foregroundStyle(foregroundColor)
            }
            .frame(width: 22, height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(FocuslessButtonStyle())
        .disabled(!isEnabled)
        .onHover { hovering = $0 }
        .help(helpText)
    }

    private var backgroundColor: Color {
        guard isEnabled, hovering else { return .clear }
        switch kind {
        case .close:
            return Color(red: 0.91, green: 0.19, blue: 0.14)
        case .minimize, .maximize:
            return Color.primary.opacity(0.10)
        }
    }

    private var foregroundColor: Color {
        if kind == .close, hovering, isEnabled { return .white }
        return Color.primary.opacity(0.9)
    }

    private var helpText: String {
        guard isEnabled else { return L10n.needsAccessibility }
        switch kind {
        case .minimize: return L10n.minimize
        case .maximize: return isMaximized ? L10n.restore : L10n.maximize
        case .close: return L10n.close
        }
    }
}
