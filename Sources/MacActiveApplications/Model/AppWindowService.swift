import AppKit
import ApplicationServices
import CoreGraphics

struct AppWindowInfo: Identifiable, Equatable {
    let id: Int
    let title: String
    let isMinimized: Bool
    let isMaximized: Bool
    /// Nil when we only have CG metadata (captions / AX actions unavailable).
    let axElement: AXUIElement?

    var isActionable: Bool { axElement != nil }

    static func == (lhs: AppWindowInfo, rhs: AppWindowInfo) -> Bool {
        lhs.id == rhs.id
            && lhs.title == rhs.title
            && lhs.isMinimized == rhs.isMinimized
            && lhs.isMaximized == rhs.isMaximized
            && lhs.isActionable == rhs.isActionable
    }
}

@MainActor
enum AppWindowService {
    private struct FrameKey: Hashable {
        let pid: pid_t
        let windowNumber: Int
    }

    private static var savedFramesBeforeMaximize: [FrameKey: CGRect] = [:]
    private static var windowsCache: (pid: pid_t, at: Date, windows: [AppWindowInfo])?
    private static let windowsCacheTTL: TimeInterval = 0.25

    struct CGWindowRecord {
        let number: Int
        let name: String
        let width: CGFloat
        let height: CGFloat
        let ownerPID: pid_t
    }

    @discardableResult
    static func ensurePermission(prompt: Bool = true) -> Bool {
        if AXIsProcessTrusted() { return true }
        guard prompt else { return false }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func invalidateWindowsCache(for pid: pid_t? = nil) {
        if let pid {
            if windowsCache?.pid == pid { windowsCache = nil }
        } else {
            windowsCache = nil
        }
    }

    /// 清除已退出进程的最大化还原缓存，避免窗口号复用后误还原。
    static func pruneSavedFrames(livePIDs: Set<pid_t>) {
        savedFramesBeforeMaximize = savedFramesBeforeMaximize.filter { livePIDs.contains($0.key.pid) }
    }

    static func clearSavedFrames(for pid: pid_t) {
        savedFramesBeforeMaximize = savedFramesBeforeMaximize.filter { $0.key.pid != pid }
    }

    static func windows(for pid: pid_t, bypassCache: Bool = false) -> [AppWindowInfo] {
        if !bypassCache,
           let cache = windowsCache,
           cache.pid == pid,
           Date().timeIntervalSince(cache.at) < windowsCacheTTL {
            return cache.windows
        }
        let result = fetchWindows(for: pid)
        windowsCache = (pid, Date(), result)
        return result
    }

    /// Shared CG scan used by peek titles and on-screen checks.
    static func layer0Windows(ownerPID: pid_t? = nil, onScreenOnly: Bool = false) -> [CGWindowRecord] {
        var options: CGWindowListOption = [.excludeDesktopElements]
        options.insert(onScreenOnly ? .optionOnScreenOnly : .optionAll)
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        var records: [CGWindowRecord] = []
        for info in list {
            guard let owner = info[kCGWindowOwnerPID as String] as? pid_t else { continue }
            if let ownerPID, owner != ownerPID { continue }
            let layer = info[kCGWindowLayer as String] as? Int ?? 0
            guard layer == 0 else { continue }

            let name = (info[kCGWindowName as String] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let number = info[kCGWindowNumber as String] as? Int ?? records.count
            var width: CGFloat = 0
            var height: CGFloat = 0
            if let bounds = info[kCGWindowBounds as String] as? [String: Any] {
                width = cgFloatValue(bounds["Width"])
                height = cgFloatValue(bounds["Height"])
            }
            records.append(
                CGWindowRecord(
                    number: number,
                    name: name,
                    width: width,
                    height: height,
                    ownerPID: owner
                )
            )
        }
        return records
    }

    static func hasOnscreenWindows(pid: pid_t) -> Bool {
        // 略放宽阈值：小工具条也视为「有窗」，避免前台应用点图标却无法 hide。
        layer0Windows(ownerPID: pid, onScreenOnly: true).contains {
            ($0.width >= 16 && $0.height >= 16) || !$0.name.isEmpty
        }
    }

    private static func fetchWindows(for pid: pid_t) -> [AppWindowInfo] {
        let cgByNumber = Dictionary(
            uniqueKeysWithValues: layer0Windows(ownerPID: pid).map { ($0.number, $0) }
        )

        let appElement = AXUIElementCreateApplication(pid)
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value)

        // AX 失败，或成功但列表为空（Electron 等）：回退 CG 标题列表。
        guard result == .success,
              let windowList = value as? [AXUIElement],
              !windowList.isEmpty else {
            return windowsFromCG(cgByNumber)
        }

        var windows: [AppWindowInfo] = []
        for (fallbackIndex, window) in windowList.enumerated() {
            let role = stringAttribute(window, kAXRoleAttribute as String)
            if let role, role != kAXWindowRole as String { continue }

            let number = intAttribute(window, "AXWindowNumber") ?? fallbackIndex
            let axTitle = stringAttribute(window, kAXTitleAttribute as String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let cgTitle = cgByNumber[number]?.name
            let resolvedTitle: String
            if let axTitle, !axTitle.isEmpty {
                resolvedTitle = axTitle
            } else if let cgTitle, !cgTitle.isEmpty {
                resolvedTitle = cgTitle
            } else {
                resolvedTitle = "未命名窗口"
            }

            let minimized = boolAttribute(window, kAXMinimizedAttribute as String) ?? false
            let frame = windowFrame(window)
            let maximized = frame.map { isRoughlyMaximized($0) } ?? false

            windows.append(
                AppWindowInfo(
                    id: number,
                    title: resolvedTitle,
                    isMinimized: minimized,
                    isMaximized: maximized,
                    axElement: window
                )
            )
        }

        var seen = Set<Int>()
        let axWindows = windows.filter { seen.insert($0.id).inserted }
        // 过滤 role 后也可能为空，同样回退 CG。
        return axWindows.isEmpty ? windowsFromCG(cgByNumber) : axWindows
    }

    private static func windowsFromCG(_ cgByNumber: [Int: CGWindowRecord]) -> [AppWindowInfo] {
        cgByNumber.values
            .filter { !$0.name.isEmpty }
            .sorted { $0.number < $1.number }
            .map {
                AppWindowInfo(
                    id: $0.number,
                    title: $0.name,
                    isMinimized: false,
                    isMaximized: false,
                    axElement: nil
                )
            }
    }

    static func focus(window: AppWindowInfo, pid: pid_t) {
        ensurePermission(prompt: true)
        activateApp(pid: pid)
        guard let element = window.axElement else { return }
        deminiaturizeIfNeeded(element)
        raise(element)
    }

    static func minimize(window: AppWindowInfo, pid: pid_t) {
        guard let element = window.axElement else { return }
        ensurePermission(prompt: true)
        activateApp(pid: pid)
        _ = AXUIElementSetAttributeValue(
            element,
            kAXMinimizedAttribute as CFString,
            kCFBooleanTrue
        )
        invalidateWindowsCache(for: pid)
    }

    static func toggleMaximize(window: AppWindowInfo, pid: pid_t) {
        guard let element = window.axElement else { return }
        ensurePermission(prompt: true)
        activateApp(pid: pid)
        deminiaturizeIfNeeded(element)
        raise(element)

        let key = FrameKey(pid: pid, windowNumber: window.id)

        guard let current = windowFrame(element) else {
            _ = pressButton(element, attribute: kAXZoomButtonAttribute as String)
            invalidateWindowsCache(for: pid)
            return
        }

        if let saved = savedFramesBeforeMaximize[key], isRoughlyMaximized(current) {
            setWindowFrame(element, saved)
            savedFramesBeforeMaximize.removeValue(forKey: key)
            invalidateWindowsCache(for: pid)
            return
        }

        guard let screen = screenContaining(axFrame: current) else {
            _ = pressButton(element, attribute: kAXZoomButtonAttribute as String)
            invalidateWindowsCache(for: pid)
            return
        }

        savedFramesBeforeMaximize[key] = current
        setWindowFrame(element, cocoaRectToAX(screen.visibleFrame))
        invalidateWindowsCache(for: pid)
    }

    static func close(window: AppWindowInfo, pid: pid_t) {
        guard let element = window.axElement else { return }
        ensurePermission(prompt: true)
        activateApp(pid: pid)
        deminiaturizeIfNeeded(element)

        let key = FrameKey(pid: pid, windowNumber: window.id)
        if pressButton(element, attribute: kAXCloseButtonAttribute as String) {
            savedFramesBeforeMaximize.removeValue(forKey: key)
            invalidateWindowsCache(for: pid)
            return
        }

        _ = AXUIElementPerformAction(element, kAXCancelAction as CFString)
        savedFramesBeforeMaximize.removeValue(forKey: key)
        invalidateWindowsCache(for: pid)
    }

    // MARK: - Private helpers

    private static func activateApp(pid: pid_t) {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return }
        if app.isHidden { app.unhide() }
        app.activate(options: [.activateIgnoringOtherApps])
    }

    private static func deminiaturizeIfNeeded(_ element: AXUIElement) {
        if boolAttribute(element, kAXMinimizedAttribute as String) == true {
            _ = AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
    }

    private static func raise(_ element: AXUIElement) {
        _ = AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        _ = AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        _ = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    }

    @discardableResult
    private static func pressButton(_ window: AXUIElement, attribute: String) -> Bool {
        var button: AnyObject?
        guard AXUIElementCopyAttributeValue(window, attribute as CFString, &button) == .success,
              let buttonObject = button,
              CFGetTypeID(buttonObject) == AXUIElementGetTypeID() else {
            return false
        }
        let axButton = unsafeBitCast(buttonObject as CFTypeRef, to: AXUIElement.self)
        return AXUIElementPerformAction(axButton, kAXPressAction as CFString) == .success
    }

    private static func windowFrame(_ element: AXUIElement) -> CGRect? {
        var posRef: AnyObject?
        var sizeRef: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posValue = posRef,
              let sizeValue = sizeRef,
              CFGetTypeID(posValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            return nil
        }

        var origin = CGPoint.zero
        var size = CGSize.zero
        let posAX = unsafeBitCast(posValue as CFTypeRef, to: AXValue.self)
        let sizeAX = unsafeBitCast(sizeValue as CFTypeRef, to: AXValue.self)
        guard AXValueGetValue(posAX, .cgPoint, &origin),
              AXValueGetValue(sizeAX, .cgSize, &size) else {
            return nil
        }
        return CGRect(origin: origin, size: size)
    }

    private static func setWindowFrame(_ element: AXUIElement, _ rect: CGRect) {
        var origin = rect.origin
        var size = rect.size
        guard let pos = AXValueCreate(.cgPoint, &origin),
              let sz = AXValueCreate(.cgSize, &size) else { return }
        _ = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, pos)
        _ = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sz)
    }

    private static func cocoaRectToAX(_ cocoa: NSRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? cocoa.maxY
        return CGRect(
            x: cocoa.origin.x,
            y: primaryHeight - cocoa.origin.y - cocoa.height,
            width: cocoa.width,
            height: cocoa.height
        )
    }

    private static func axRectToCocoa(_ ax: CGRect) -> NSRect {
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? (ax.origin.y + ax.height)
        return NSRect(
            x: ax.origin.x,
            y: primaryHeight - ax.origin.y - ax.height,
            width: ax.width,
            height: ax.height
        )
    }

    private static func screenContaining(axFrame: CGRect) -> NSScreen? {
        let cocoa = axRectToCocoa(axFrame)
        return NSScreen.screens.first { $0.frame.intersects(cocoa) } ?? NSScreen.main
    }

    private static func isRoughlyMaximized(_ axFrame: CGRect) -> Bool {
        guard let screen = screenContaining(axFrame: axFrame) else { return false }
        let visible = cocoaRectToAX(screen.visibleFrame)
        let inset: CGFloat = 8
        return abs(axFrame.minX - visible.minX) <= inset
            && abs(axFrame.minY - visible.minY) <= inset
            && abs(axFrame.width - visible.width) <= inset * 2
            && abs(axFrame.height - visible.height) <= inset * 2
    }

    private static func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private static func boolAttribute(_ element: AXUIElement, _ name: String) -> Bool? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        if let number = value as? NSNumber { return number.boolValue }
        return nil
    }

    private static func intAttribute(_ element: AXUIElement, _ name: String) -> Int? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }

    private static func cgFloatValue(_ value: Any?) -> CGFloat {
        if let number = value as? CGFloat { return number }
        if let number = value as? Double { return CGFloat(number) }
        if let number = value as? NSNumber { return CGFloat(number.doubleValue) }
        return 0
    }
}
