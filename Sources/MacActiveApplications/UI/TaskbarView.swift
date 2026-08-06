import SwiftUI
import AppKit

enum TaskbarChrome: Equatable {
    case collapsed
    case expanded
}

struct TaskbarView: View {
    @ObservedObject var store: RunningAppsStore
    @ObservedObject var peekController: WindowPeekController
    @Binding var chrome: TaskbarChrome
    let barHeight: CGFloat
    let onChromeChange: (TaskbarChrome) -> Void

    private var shape: TaskbarOutlineShape {
        TaskbarOutlineShape(
            topLeadingRadius: 0,
            bottomLeadingRadius: TaskbarStyle.leadingCornerRadius(forBarHeight: barHeight)
        )
    }

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                if chrome == .expanded {
                    // 汉堡菜单：仅展开时显示；收起后只留把手。
                    SettingsMenuButton(
                        barHeight: barHeight,
                        chrome: chrome,
                        store: store,
                        peekController: peekController
                    )
                        .frame(width: TaskbarStyle.settingsButtonWidth)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: TaskbarStyle.iconSpacing) {
                            ForEach(store.apps) { app in
                                AppIconButton(
                                    app: app,
                                    size: TaskbarStyle.iconSize(forBarHeight: barHeight),
                                    store: store,
                                    peekController: peekController,
                                    isDragging: store.draggingPID == app.id
                                ) {
                                    peekController.hide(immediate: true)
                                    store.activateOrHide(pid: app.id)
                                }
                            }
                        }
                        .padding(.leading, TaskbarStyle.horizontalPadding)
                        .padding(.trailing, TaskbarStyle.iconsHandleGap(forBarHeight: barHeight))
                        .animation(nil, value: store.apps.map(\.id))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                HandleButton(chrome: chrome, barHeight: barHeight) {
                    peekController.hide(immediate: true)
                    let next: TaskbarChrome = chrome == .collapsed ? .expanded : .collapsed
                    onChromeChange(next)
                }
                .frame(width: TaskbarStyle.handleWidth)
            }

            // 拖拽浮层：盖在任务栏最上层，跟随光标（保留按下时的抓取点）。
            if chrome == .expanded,
               let pid = store.draggingPID,
               let app = store.apps.first(where: { $0.id == pid }),
               let location = store.dragLocationInWindow {
                DragFollowIcon(
                    app: app,
                    size: TaskbarStyle.iconSize(forBarHeight: barHeight),
                    isActive: app.isActive,
                    locationInWindow: location,
                    grabOffsetInWindow: store.dragGrabOffsetInWindow
                )
                .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(shape.fill(Color.black))
        .clipShape(shape)
        .ignoresSafeArea()
    }
}

/// Trailing corners always square. Leading corners configurable.
struct TaskbarOutlineShape: Shape {
    var topLeadingRadius: CGFloat
    var bottomLeadingRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let maxR = min(rect.height / 2, rect.width / 2)
        let topR = min(max(0, topLeadingRadius), maxR)
        let bottomR = min(max(0, bottomLeadingRadius), maxR)
        var path = Path()

        path.move(to: CGPoint(x: rect.minX + topR, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + bottomR, y: rect.maxY))
        if bottomR > 0 {
            path.addQuadCurve(
                to: CGPoint(x: rect.minX, y: rect.maxY - bottomR),
                control: CGPoint(x: rect.minX, y: rect.maxY)
            )
        } else {
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        }
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + topR))
        if topR > 0 {
            path.addQuadCurve(
                to: CGPoint(x: rect.minX + topR, y: rect.minY),
                control: CGPoint(x: rect.minX, y: rect.minY)
            )
        } else {
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        }
        path.closeSubpath()
        return path
    }
}

struct FocuslessButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.65 : 1)
    }
}

private struct SettingsMenuButton: View {
    let barHeight: CGFloat
    let chrome: TaskbarChrome
    @ObservedObject var store: RunningAppsStore
    @ObservedObject var peekController: WindowPeekController
    @ObservedObject private var preferences = TaskbarPreferences.shared

    @State private var hovering = false
    /// 菜单打开时三条横线旋转成 X。
    @State private var menuOpen = false

    private var iconSize: CGFloat { max(10, barHeight * 0.42) }

    var body: some View {
        ZStack {
            HamburgerToXIcon(
                isOpen: menuOpen,
                size: iconSize,
                color: Color.white.opacity(hovering || menuOpen ? 1 : 0.85)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(hovering || menuOpen ? Color.white.opacity(0.20) : Color.clear)
            )
            .allowsHitTesting(false)

            AppIconHitView(
                onView: { _ in },
                onLeftClick: {},
                onRightClick: { _, _ in },
                onHover: { hovering = $0 },
                onLeftClickWithEvent: { view, _ in
                    peekController.hide(immediate: true)
                    let menu = TaskbarSettingsMenuBuilder.menu(
                        store: store,
                        preferences: preferences,
                        peekController: peekController,
                        chromeExpanded: chrome == .expanded
                    )
                    // 先播旋转，再阻塞式弹出菜单；关闭后转回汉堡。
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                        menuOpen = true
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                        TaskbarSettingsMenuBuilder.popUp(menu: menu, from: view)
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                            menuOpen = false
                        }
                    }
                }
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .help(L10n.settings)
    }
}

/// 三条横线 ↔ X（上下两线旋转交叉，中线淡出）。
private struct HamburgerToXIcon: View {
    let isOpen: Bool
    let size: CGFloat
    let color: Color

    var body: some View {
        let lineHeight = max(1.5, size * 0.14)
        let lineWidth = size * 1.15
        let spacing = size * 0.32

        ZStack {
            Capsule()
                .fill(color)
                .frame(width: lineWidth, height: lineHeight)
                .offset(y: isOpen ? 0 : -spacing)
                .rotationEffect(.degrees(isOpen ? 45 : 0))

            Capsule()
                .fill(color)
                .frame(width: lineWidth, height: lineHeight)
                .opacity(isOpen ? 0 : 1)
                .scaleEffect(x: isOpen ? 0.2 : 1, y: 1, anchor: .center)

            Capsule()
                .fill(color)
                .frame(width: lineWidth, height: lineHeight)
                .offset(y: isOpen ? 0 : spacing)
                .rotationEffect(.degrees(isOpen ? -45 : 0))
        }
        .frame(width: size * 1.2, height: size * 1.2)
        .animation(.spring(response: 0.32, dampingFraction: 0.78), value: isOpen)
    }
}

private struct HandleButton: View {
    let chrome: TaskbarChrome
    let barHeight: CGFloat
    let action: () -> Void

    var body: some View {
        ZStack {
            Image(systemName: chrome == .collapsed ? "chevron.left" : "chevron.right")
                .font(.system(size: max(9, barHeight * 0.38), weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.85))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)

            AppIconHitView(
                onView: { _ in },
                onLeftClick: action,
                onRightClick: { _, _ in },
                onHover: { _ in }
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .help(chrome == .collapsed ? L10n.expandTaskbar : L10n.collapseTaskbar)
    }
}

/// 拖拽中跟随光标的浮层图标（窗口坐标 → 任务栏本地坐标）。
private struct DragFollowIcon: View {
    let app: RunningAppItem
    let size: CGFloat
    let isActive: Bool
    let locationInWindow: NSPoint
    let grabOffsetInWindow: CGSize

    @State private var probeView: NSView?

    private var cellWidth: CGFloat { size + TaskbarStyle.iconCellPadding }
    private var cellHeight: CGFloat { size + 4 }

    var body: some View {
        GeometryReader { geo in
            let center = iconCenter(in: geo)
            iconContent
                .position(x: center.x, y: center.y)
        }
        .background(WindowPointProbe { probeView = $0 })
    }

    private var iconContent: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 1) {
                Image(nsImage: app.icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size, height: size)
                Capsule()
                    .fill(isActive ? Color.white : Color.clear)
                    .frame(width: max(8, size * 0.45), height: 2)
            }
            .frame(width: cellWidth, height: cellHeight)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.white.opacity(0.28))
            )

            if app.hasUnreadBadge {
                UnreadBadgeDot(iconSize: size)
                    .padding(.top, 1)
                    .padding(.trailing, 1)
            }
        }
        .scaleEffect(1.12)
        .shadow(color: .black.opacity(0.55), radius: 8, y: 3)
    }

    private func iconCenter(in geo: GeometryProxy) -> CGPoint {
        guard let probeView else {
            return CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        let mouse = probeView.convert(locationInWindow, from: nil)
        // grabOffset：鼠标相对图标中心；AppKit Y 向上，SwiftUI Y 向下。
        let midX = mouse.x - grabOffsetInWindow.width
        let midY = geo.size.height - (mouse.y - grabOffsetInWindow.height)
        return CGPoint(x: midX, y: midY)
    }
}

private struct WindowPointProbe: NSViewRepresentable {
    let onView: (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { onView(view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { onView(nsView) }
    }
}

private struct UnreadBadgeDot: View {
    let iconSize: CGFloat

    var body: some View {
        let side = TaskbarStyle.unreadBadgeDotSize(forIconSize: iconSize)
        Circle()
            .fill(Color(red: 1, green: 0.23, blue: 0.19))
            .frame(width: side, height: side)
            .overlay(
                Circle()
                    .strokeBorder(Color.black.opacity(0.25), lineWidth: 0.5)
            )
    }
}

private struct AppIconButton: View {
    let app: RunningAppItem
    let size: CGFloat
    @ObservedObject var store: RunningAppsStore
    @ObservedObject var peekController: WindowPeekController
    @ObservedObject private var preferences = TaskbarPreferences.shared
    let isDragging: Bool
    let action: () -> Void

    @State private var hovering = false
    @State private var anchorView: NSView?
    @State private var bounceOffset: CGFloat = 0
    @State private var bounceTask: Task<Void, Never>?

    private var cellWidth: CGFloat { size + TaskbarStyle.iconCellPadding }
    private var cellHeight: CGFloat { size + 4 }

    var body: some View {
        ZStack {
            ZStack(alignment: .topTrailing) {
                VStack(spacing: 1) {
                    Image(nsImage: app.icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: size, height: size)
                    Capsule()
                        .fill(app.isActive ? Color.white : Color.clear)
                        .frame(width: max(8, size * 0.45), height: 2)
                }
                .frame(width: cellWidth, height: cellHeight)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(hoverFill)
                )

                if app.hasUnreadBadge && !isDragging {
                    UnreadBadgeDot(iconSize: size)
                        .padding(.top, 1)
                        .padding(.trailing, 1)
                }
            }
            .offset(y: isDragging ? 0 : bounceOffset)
            // 拖拽中列表内只留淡占位，实体由图层浮层绘制。
            .opacity(isDragging ? 0.22 : 1)
            .allowsHitTesting(false)

            // 透明命中层：左键激活 / 拖拽排序、右键菜单。
            AppIconHitView(
                onView: { view in
                    anchorView = view
                    reportFrame(from: view)
                },
                onLeftClick: {
                    action()
                },
                onRightClick: { view, event in
                    peekController.hide(immediate: true)
                    guard let menu = AppContextMenuBuilder.menu(for: app, store: store) else { return }
                    presentContextMenu(menu, from: view, event: event)
                },
                onHover: { isHovering in
                    hovering = isHovering
                    if store.draggingPID != nil { return }
                    if app.isAppsLauncher {
                        if !isHovering {
                            peekController.setIconHovering(false)
                        }
                        return
                    }
                    guard preferences.showWindowPeekOnHover else {
                        if !isHovering {
                            peekController.setIconHovering(false)
                        } else {
                            peekController.hide(immediate: true)
                        }
                        return
                    }
                    peekController.setIconHovering(isHovering)
                    if isHovering {
                        presentPeekIfNeeded()
                    }
                },
                onDragBegan: { view, event in
                    peekController.hide(immediate: true)
                    reportFrame(from: view)
                    store.beginIconDrag(pid: app.id, locationInWindow: event.locationInWindow)
                },
                onDragMoved: { view, event in
                    reportFrame(from: view)
                    store.updateIconDrag(pid: app.id, locationInWindow: event.locationInWindow)
                },
                onDragEnded: { _, _ in
                    store.endIconDrag(pid: app.id)
                }
            )
        }
        .frame(width: cellWidth, height: cellHeight)
        .help(app.localizedName)
        .onChange(of: app.unreadBadgeSignal) { newSignal in
            if newSignal != nil {
                playAttentionBounce()
            } else {
                stopBounce()
            }
        }
        .onChange(of: isDragging) { dragging in
            if dragging {
                stopBounce()
            }
        }
    }

    private var hoverFill: Color {
        if isDragging { return Color.white.opacity(0.10) }
        if hovering { return Color.white.opacity(0.20) }
        if app.isActive { return Color.white.opacity(0.14) }
        return Color.clear
    }

    /// 类似 Dock 提醒：向上连弹几下。
    private func playAttentionBounce() {
        guard !isDragging else { return }
        bounceTask?.cancel()
        let amplitude = min(5, max(3, size * 0.2))
        bounceTask = Task { @MainActor in
            bounceOffset = 0
            for _ in 0..<3 {
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.11)) {
                    bounceOffset = -amplitude
                }
                try? await Task.sleep(nanoseconds: 110_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(.easeIn(duration: 0.11)) {
                    bounceOffset = 0
                }
                try? await Task.sleep(nanoseconds: 110_000_000)
            }
        }
    }

    private func stopBounce() {
        bounceTask?.cancel()
        bounceTask = nil
        bounceOffset = 0
    }

    private func reportFrame(from view: NSView) {
        let frameInWindow = view.convert(view.bounds, to: nil)
        store.reportIconFrame(pid: app.id, frameInWindow: frameInWindow)
    }

    private func presentPeekIfNeeded() {
        guard !app.isAppsLauncher,
              store.draggingPID == nil,
              let anchorView,
              let window = anchorView.window else { return }
        let rectInWindow = anchorView.convert(anchorView.bounds, to: nil)
        let screenRect = window.convertToScreen(rectInWindow)
        peekController.show(
            pid: app.id,
            appName: app.localizedName,
            anchorScreenRect: screenRect
        )
    }

    private func presentContextMenu(_ menu: NSMenu, from view: NSView, event: NSEvent) {
        // 非激活面板上 popUpContextMenu 常失败，改用显式坐标弹出；结束后立刻让出 key。
        let location = view.convert(event.locationInWindow, from: nil)
        let point = NSPoint(x: location.x, y: location.y - 2)
        TaskbarFocus.withTemporaryKey(for: view.window) {
            menu.popUp(positioning: nil, at: point, in: view)
        }
    }
}

/// 图标命中层：接收鼠标事件并回调。
private struct AppIconHitView: NSViewRepresentable {
    let onView: (NSView) -> Void
    let onLeftClick: () -> Void
    let onRightClick: (NSView, NSEvent) -> Void
    let onHover: (Bool) -> Void
    var onLeftClickWithEvent: ((NSView, NSEvent) -> Void)? = nil
    var onDragBegan: ((NSView, NSEvent) -> Void)? = nil
    var onDragMoved: ((NSView, NSEvent) -> Void)? = nil
    var onDragEnded: ((NSView, NSEvent) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onLeftClick: onLeftClick,
            onRightClick: onRightClick,
            onHover: onHover,
            onLeftClickWithEvent: onLeftClickWithEvent,
            onDragBegan: onDragBegan,
            onDragMoved: onDragMoved,
            onDragEnded: onDragEnded
        )
    }

    func makeNSView(context: Context) -> AppIconHitNSView {
        let view = AppIconHitNSView()
        view.coordinator = context.coordinator
        DispatchQueue.main.async { onView(view) }
        return view
    }

    func updateNSView(_ nsView: AppIconHitNSView, context: Context) {
        context.coordinator.onLeftClick = onLeftClick
        context.coordinator.onRightClick = onRightClick
        context.coordinator.onHover = onHover
        context.coordinator.onLeftClickWithEvent = onLeftClickWithEvent
        context.coordinator.onDragBegan = onDragBegan
        context.coordinator.onDragMoved = onDragMoved
        context.coordinator.onDragEnded = onDragEnded
        nsView.coordinator = context.coordinator
        DispatchQueue.main.async { onView(nsView) }
    }

    final class Coordinator {
        var onLeftClick: () -> Void
        var onRightClick: (NSView, NSEvent) -> Void
        var onHover: (Bool) -> Void
        var onLeftClickWithEvent: ((NSView, NSEvent) -> Void)?
        var onDragBegan: ((NSView, NSEvent) -> Void)?
        var onDragMoved: ((NSView, NSEvent) -> Void)?
        var onDragEnded: ((NSView, NSEvent) -> Void)?

        init(
            onLeftClick: @escaping () -> Void,
            onRightClick: @escaping (NSView, NSEvent) -> Void,
            onHover: @escaping (Bool) -> Void,
            onLeftClickWithEvent: ((NSView, NSEvent) -> Void)?,
            onDragBegan: ((NSView, NSEvent) -> Void)?,
            onDragMoved: ((NSView, NSEvent) -> Void)?,
            onDragEnded: ((NSView, NSEvent) -> Void)?
        ) {
            self.onLeftClick = onLeftClick
            self.onRightClick = onRightClick
            self.onHover = onHover
            self.onLeftClickWithEvent = onLeftClickWithEvent
            self.onDragBegan = onDragBegan
            self.onDragMoved = onDragMoved
            self.onDragEnded = onDragEnded
        }
    }
}

private final class AppIconHitNSView: NSView {
    weak var coordinator: AppIconHitView.Coordinator?
    private var tracking: NSTrackingArea?
    private var mouseDownLocationInWindow: NSPoint?
    private var isDragging = false
    /// 与 `NSCursor.push` 配对，避免重复 push / 漏 pop。
    private var didPushDragCursor = false
    private static let dragThreshold: CGFloat = 4

    override var isFlipped: Bool { false }
    /// 不抢第一响应者，避免任务栏点击后键盘焦点留在空白命中层。
    override var acceptsFirstResponder: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking {
            removeTrackingArea(tracking)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [
                .activeAlways,
                .mouseEnteredAndExited,
                .cursorUpdate,
                .inVisibleRect,
                .enabledDuringMouseDrag
            ],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func cursorUpdate(with event: NSEvent) {
        if isDragging {
            NSCursor.closedHand.set()
        } else {
            super.cursorUpdate(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        // 汉堡菜单等：仍立即响应带 event 的左键。
        if let withEvent = coordinator?.onLeftClickWithEvent {
            withEvent(self, event)
            return
        }

        mouseDownLocationInWindow = event.locationInWindow
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard coordinator?.onLeftClickWithEvent == nil,
              let start = mouseDownLocationInWindow else { return }

        if !isDragging {
            let dx = event.locationInWindow.x - start.x
            let dy = event.locationInWindow.y - start.y
            guard hypot(dx, dy) >= Self.dragThreshold else { return }
            isDragging = true
            beginDragCursor()
            coordinator?.onDragBegan?(self, event)
        }

        if isDragging {
            // 非激活面板上系统常改回箭头，拖拽中持续压回小手。
            NSCursor.closedHand.set()
            coordinator?.onDragMoved?(self, event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            endDragCursor()
            mouseDownLocationInWindow = nil
            isDragging = false
        }

        guard coordinator?.onLeftClickWithEvent == nil else { return }

        if isDragging {
            coordinator?.onDragEnded?(self, event)
        } else if mouseDownLocationInWindow != nil {
            coordinator?.onLeftClick()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        coordinator?.onRightClick(self, event)
    }

    override func mouseEntered(with event: NSEvent) {
        coordinator?.onHover(true)
    }

    override func mouseExited(with event: NSEvent) {
        coordinator?.onHover(false)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// `nonactivatingPanel` 下未激活应用时 `set()` 会被忽略；拖拽时短暂激活并 push 光标。
    private func beginDragCursor() {
        guard !didPushDragCursor else {
            NSCursor.closedHand.set()
            return
        }
        didPushDragCursor = true
        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }
        NSCursor.closedHand.push()
    }

    private func endDragCursor() {
        guard didPushDragCursor else { return }
        didPushDragCursor = false
        NSCursor.pop()
        // 与菜单弹层一致：结束后让出焦点，避免挡住其它 App 键盘输入。
        TaskbarFocus.resignTaskbarKey()
    }
}
