import CoreGraphics
import Foundation
import AppKit

enum TaskbarStyle {
    static let settingsButtonWidth: CGFloat = 22
    static let handleWidth: CGFloat = 22
    /// 收起时只留把手。
    static let collapsedWidth: CGFloat = handleWidth
    static let horizontalPadding: CGFloat = 4
    static let iconSpacing: CGFloat = 2
    /// Keep a little air on the leading edge so the rounded corner doesn't clip system menus.
    static let edgeInset: CGFloat = 2
    /// Matches the menu-bar / notch capsule corner feel (bottom-leading only).
    static let leadingCornerRadius: CGFloat = 10
    /// Extra width per icon cell beyond the drawn icon (highlight padding).
    static let iconCellPadding: CGFloat = 2
    /// Grow the handle toward the notch (right) beyond the visual snap base.
    static let handleTrailingExtension: CGFloat = 3
    /// Fraction of menu-bar height used to bridge AppKit safe-area vs visual notch edge.
    /// Empirically ~0.125 ≈ +4pt on a 32pt bar (typical notched MacBook).
    static let notchVisualCompensationRatio: CGFloat = 0.125

    // Window peek (multi-window hover list)
    static let peekMinWidth: CGFloat = 240
    static let peekMaxWidth: CGFloat = 520
    static let peekTitleFontSize: CGFloat = 12
    static let peekCaptionClusterWidth: CGFloat = 66 // 3 × 22
    static let peekHorizontalChrome: CGFloat = 28 // list padding + title leading + slack
    /// Extra inset so the rounded SwiftUI shadow isn't clipped (sides + bottom only).
    static let peekShadowPadding: CGFloat = 12
    /// Thin hit strip under the menu bar (does not overlap the notch/menu bar).
    static let peekHoverBridgeHeight: CGFloat = 4
    /// Short grace period while the cursor travels from icon to peek.
    static let peekHideDelay: TimeInterval = 0.1

    static func iconSize(forBarHeight height: CGFloat) -> CGFloat {
        max(12, height - 6)
    }

    /// 最后一个图标与把手之间的空隙（半个图标宽），减轻贴边 hover 冲突。
    static func iconsHandleGap(forBarHeight height: CGFloat) -> CGFloat {
        iconSize(forBarHeight: height) / 2
    }

    static func leadingCornerRadius(forBarHeight height: CGFloat) -> CGFloat {
        min(leadingCornerRadius, height * 0.45)
    }

    /// Ideal width for the given icon count (before applying the slot max).
    /// 展开：`[汉堡][图标…][缝][把手]`；收起：仅把手。
    static func contentWidth(appCount: Int, barHeight: CGFloat, chrome: Bool) -> CGFloat {
        guard chrome else { return collapsedWidth }
        let icon = iconSize(forBarHeight: barHeight)
        let cell = icon + iconCellPadding
        let iconsWidth = CGFloat(appCount) * cell
            + CGFloat(max(0, appCount - 1)) * iconSpacing
        // 汉堡与把手之间：左侧 padding + 图标 + 与把手的半图标缝。
        let width = settingsButtonWidth
            + handleWidth
            + (appCount > 0 ? horizontalPadding + iconsWidth + iconsHandleGap(forBarHeight: barHeight) : 0)
        return max(collapsedWidth, width)
    }

    /// Cap expanded width to the usable menu-bar slot (minus leading inset).
    static func maxExpandedWidth(slotWidth: CGFloat) -> CGFloat {
        max(collapsedWidth, slotWidth - edgeInset)
    }

    /// Peek panel width from longest window title, clamped to [min, max].
    static func peekPanelWidth(titles: [String]) -> CGFloat {
        let font = NSFont.systemFont(ofSize: peekTitleFontSize, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let longest = titles
            .map { ceil(($0 as NSString).size(withAttributes: attributes).width) }
            .max() ?? 0
        let ideal = longest + peekCaptionClusterWidth + peekHorizontalChrome
        return min(peekMaxWidth, max(peekMinWidth, ideal))
    }
}
