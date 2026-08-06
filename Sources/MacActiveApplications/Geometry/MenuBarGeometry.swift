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

    /// Panel frame: trailing edge inset from notch snap by `trailingOffset` (0 = flush).
    /// - Parameters:
    ///   - height: panel height; when vertically collapsed use a thin strip and pin to the top of the slot.
    ///   - pinToTop: if true, align to `availableFrame.maxY` (向上收起后留顶边条带).
    static func panelFrame(
        width: CGFloat,
        height: CGFloat? = nil,
        in slot: MenuBarSlot,
        trailingOffset: CGFloat = 0,
        pinToTop: Bool = false
    ) -> NSRect {
        let maxWidth = max(TaskbarStyle.collapsedWidth, slot.availableFrame.width - TaskbarStyle.edgeInset)
        let clampedWidth = min(max(width, TaskbarStyle.collapsedWidth), maxWidth)
        let fullHeight = slot.barHeight
        let clampedHeight = min(max(height ?? fullHeight, TaskbarStyle.collapsedStripHeight), fullHeight)
        let offset = clampedTrailingOffset(trailingOffset, width: clampedWidth, in: slot)
        let x = slot.snapMaxX - clampedWidth - offset
        let y: CGFloat
        if pinToTop {
            y = slot.availableFrame.maxY - clampedHeight
        } else {
            y = slot.availableFrame.minY
        }
        return NSRect(x: x, y: y, width: clampedWidth, height: clampedHeight)
    }

    /// How far left the panel’s trailing edge may sit from `snapMaxX`.
    static func maxTrailingOffset(width: CGFloat, in slot: MenuBarSlot) -> CGFloat {
        let maxWidth = max(TaskbarStyle.collapsedWidth, slot.availableFrame.width - TaskbarStyle.edgeInset)
        let clampedWidth = min(max(width, TaskbarStyle.collapsedWidth), maxWidth)
        return max(0, slot.snapMaxX - clampedWidth - slot.availableFrame.minX - TaskbarStyle.edgeInset)
    }

    static func clampedTrailingOffset(_ offset: CGFloat, width: CGFloat, in slot: MenuBarSlot) -> CGFloat {
        min(max(0, offset), maxTrailingOffset(width: width, in: slot))
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
