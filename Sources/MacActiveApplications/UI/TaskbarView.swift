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
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: TaskbarStyle.iconSpacing) {
                        ForEach(store.apps) { app in
                            AppIconButton(
                                app: app,
                                size: TaskbarStyle.iconSize(forBarHeight: barHeight),
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

private struct HandleButton: View {
    let chrome: TaskbarChrome
    let barHeight: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: chrome == .collapsed ? "chevron.left" : "chevron.right")
                .font(.system(size: max(9, barHeight * 0.38), weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.85))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(FocuslessButtonStyle())
        .focusable(false)
        .help(chrome == .collapsed ? "展开任务栏" : "收起任务栏")
    }
}

private struct AppIconButton: View {
    let app: RunningAppItem
    let size: CGFloat
    @ObservedObject var peekController: WindowPeekController
    let action: () -> Void

    @State private var hovering = false
    @State private var anchorView: NSView?

    var body: some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Image(nsImage: app.icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size, height: size)
                Capsule()
                    .fill(app.isActive ? Color.white : Color.clear)
                    .frame(width: max(8, size * 0.45), height: 2)
            }
            .frame(width: size + TaskbarStyle.iconCellPadding, height: size + 4)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(hoverFill)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(FocuslessButtonStyle())
        .focusable(false)
        .help(app.localizedName)
        .background(AnchorCaptureView { anchorView = $0 })
        .onHover { isHovering in
            hovering = isHovering
            peekController.setIconHovering(isHovering)
            if isHovering {
                presentPeekIfNeeded()
            }
        }
    }

    private var hoverFill: Color {
        if hovering { return Color.white.opacity(0.20) }
        if app.isActive { return Color.white.opacity(0.14) }
        return Color.clear
    }

    private func presentPeekIfNeeded() {
        guard let anchorView,
              let window = anchorView.window else { return }
        let rectInWindow = anchorView.convert(anchorView.bounds, to: nil)
        let screenRect = window.convertToScreen(rectInWindow)
        peekController.show(
            pid: app.id,
            appName: app.localizedName,
            anchorScreenRect: screenRect
        )
    }
}

/// Captures the underlying AppKit view so we can place the peek panel in screen space.
private struct AnchorCaptureView: NSViewRepresentable {
    let onView: (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { onView(view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // View instance is stable; avoid re-entrant async callbacks on every SwiftUI pass.
    }
}
