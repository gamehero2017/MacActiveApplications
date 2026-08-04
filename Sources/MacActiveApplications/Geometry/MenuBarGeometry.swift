import AppKit

struct MenuBarSlot: Equatable {
    /// Full usable strip left of the notch (or fallback virtual slot).
    let availableFrame: NSRect
    /// Right edge X flush with the notch black area.
    let snapMaxX: CGFloat
    var barHeight: CGFloat { availableFrame.height }
    var screen: NSScreen?
}

enum MenuBarGeometry {
    /// Prefer the screen under the mouse; then a notched screen; then main/first.
    static func targetScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) {
            return screen
        }
        if let notched = NSScreen.screens.first(where: {
            if let area = $0.auxiliaryTopLeftArea { return area.width > 1 } else { return false }
        }) {
            return notched
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    static func slot(on screen: NSScreen? = targetScreen()) -> MenuBarSlot? {
        guard let screen else { return nil }

        if let left = screen.auxiliaryTopLeftArea, left.width > 1, left.height > 1 {
            let snapMaxX = notchSnapMaxX(leftArea: left, screen: screen)
            return MenuBarSlot(availableFrame: left, snapMaxX: snapMaxX, screen: screen)
        }

        // No-notch fallback: virtual slot occupying the left ~42% of the menu bar.
        let menuHeight = max(24, screen.frame.maxY - screen.visibleFrame.maxY)
        let slotWidth = screen.frame.width * 0.42
        let frame = NSRect(
            x: screen.frame.minX,
            y: screen.frame.maxY - menuHeight,
            width: slotWidth,
            height: menuHeight
        )
        return MenuBarSlot(availableFrame: frame, snapMaxX: frame.maxX, screen: screen)
    }

    /// Panel frame anchored flush to the notch left edge, growing leftward.
    static func panelFrame(width: CGFloat, in slot: MenuBarSlot) -> NSRect {
        let maxWidth = max(TaskbarStyle.collapsedWidth, slot.availableFrame.width - TaskbarStyle.edgeInset)
        let clampedWidth = min(max(width, TaskbarStyle.collapsedWidth), maxWidth)
        let height = slot.barHeight
        let x = slot.snapMaxX - clampedWidth
        let y = slot.availableFrame.minY
        return NSRect(x: x, y: y, width: clampedWidth, height: height)
    }

    /// Dynamic right-edge snap: AppKit safe trailing edge + height/scale compensation
    /// so the handle meets the visual notch across machines and resolutions.
    static func notchSnapMaxX(leftArea: NSRect, screen: NSScreen) -> CGFloat {
        let scale = max(screen.backingScaleFactor, 1)
        let raw = leftArea.height * TaskbarStyle.notchVisualCompensationRatio
        let compensation = (raw * scale).rounded() / scale

        var snap = leftArea.maxX + compensation + TaskbarStyle.handleTrailingExtension
        if let right = screen.auxiliaryTopRightArea, right.minX > leftArea.maxX {
            // Never cross into the camera housing / right menu-bar area.
            let notchLeading = right.minX
            let maxBridge = max(0, (notchLeading - leftArea.maxX) * 0.08)
            snap = min(snap, leftArea.maxX + maxBridge + TaskbarStyle.handleTrailingExtension)
            snap = min(snap, notchLeading)
        }
        return (snap * scale).rounded() / scale
    }
}
