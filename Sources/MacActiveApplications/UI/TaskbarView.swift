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
        HStack(spacing: 0) {
            if chrome == .expanded {
                // 汉堡菜单：仅展开时显示；收起后只留把手。
                SettingsMenuButton(barHeight: barHeight, store: store, peekController: peekController)
                    .frame(width: TaskbarStyle.settingsButtonWidth)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: TaskbarStyle.iconSpacing) {
                        ForEach(store.apps) { app in
                            AppIconButton(
                                app: app,
                                size: TaskbarStyle.iconSize(forBarHeight: barHeight),
                                store: store,
                                peekController: peekController
                            ) {
                                peekController.hide(immediate: true)
                                store.activateOrHide(pid: app.id)
                            }
                        }
                    }
                    .padding(.leading, TaskbarStyle.horizontalPadding)
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
    @ObservedObject var store: RunningAppsStore
    @ObservedObject var peekController: WindowPeekController
    @ObservedObject private var preferences = TaskbarPreferences.shared

    @State private var hovering = false

    var body: some View {
        ZStack {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: max(10, barHeight * 0.42), weight: .semibold))
                .foregroundStyle(Color.white.opacity(hovering ? 1 : 0.85))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(hovering ? Color.white.opacity(0.20) : Color.clear)
                )
                .allowsHitTesting(false)

            AppIconHitView(
                onView: { _ in },
                onLeftClick: {},
                onRightClick: { _, _ in },
                onHover: { hovering = $0 },
                onLeftClickWithEvent: { view, _ in
                    peekController.hide(immediate: true)
                    let menu = TaskbarSettingsMenuBuilder.menu(store: store, preferences: preferences)
                    TaskbarSettingsMenuBuilder.popUp(menu: menu, from: view)
                }
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .help("设置")
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
        .help(chrome == .collapsed ? "展开任务栏" : "收起任务栏")
    }
}

private struct AppIconButton: View {
    let app: RunningAppItem
    let size: CGFloat
    @ObservedObject var store: RunningAppsStore
    @ObservedObject var peekController: WindowPeekController
    let action: () -> Void

    @State private var hovering = false
    @State private var anchorView: NSView?

    private var cellWidth: CGFloat { size + TaskbarStyle.iconCellPadding }
    private var cellHeight: CGFloat { size + 4 }

    var body: some View {
        ZStack {
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
            .allowsHitTesting(false)

            // 透明命中层：左键激活、右键菜单（accessory 面板上比 SwiftUI Button 可靠）。
            AppIconHitView(
                onView: { anchorView = $0 },
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
                    if app.isAppsLauncher {
                        if !isHovering {
                            peekController.setIconHovering(false)
                        }
                        return
                    }
                    peekController.setIconHovering(isHovering)
                    if isHovering {
                        presentPeekIfNeeded()
                    }
                }
            )
        }
        .frame(width: cellWidth, height: cellHeight)
        .help(app.localizedName)
    }

    private var hoverFill: Color {
        if hovering { return Color.white.opacity(0.20) }
        if app.isActive { return Color.white.opacity(0.14) }
        return Color.clear
    }

    private func presentPeekIfNeeded() {
        guard !app.isAppsLauncher,
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

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onLeftClick: onLeftClick,
            onRightClick: onRightClick,
            onHover: onHover,
            onLeftClickWithEvent: onLeftClickWithEvent
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
        nsView.coordinator = context.coordinator
    }

    final class Coordinator {
        var onLeftClick: () -> Void
        var onRightClick: (NSView, NSEvent) -> Void
        var onHover: (Bool) -> Void
        var onLeftClickWithEvent: ((NSView, NSEvent) -> Void)?

        init(
            onLeftClick: @escaping () -> Void,
            onRightClick: @escaping (NSView, NSEvent) -> Void,
            onHover: @escaping (Bool) -> Void,
            onLeftClickWithEvent: ((NSView, NSEvent) -> Void)?
        ) {
            self.onLeftClick = onLeftClick
            self.onRightClick = onRightClick
            self.onHover = onHover
            self.onLeftClickWithEvent = onLeftClickWithEvent
        }
    }
}

private final class AppIconHitNSView: NSView {
    weak var coordinator: AppIconHitView.Coordinator?
    private var tracking: NSTrackingArea?

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
            options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect, .enabledDuringMouseDrag],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseDown(with event: NSEvent) {
        if let withEvent = coordinator?.onLeftClickWithEvent {
            withEvent(self, event)
        } else {
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
}
