import AppKit
import ApplicationServices
import CoreGraphics
import Darwin

/// 系统「Apps / 启动板」入口（macOS 26+ 为 Apps.app，旧版为 Launchpad.app）。
@MainActor
enum SystemAppsLauncher {
    /// 任务栏里固定项使用的哨兵 pid（不会与真实进程冲突）。
    static let sentinelPID: pid_t = -1

    private static var cachedIcon: NSImage?
    private static var coreDockSend: ((CFString, Int) -> Void)?

    static var appURL: URL? {
        let candidates = [
            URL(fileURLWithPath: "/System/Applications/Apps.app"),
            URL(fileURLWithPath: "/System/Applications/Launchpad.app")
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static var displayName: String {
        guard let url = appURL,
              let bundle = Bundle(url: url) else { return "Apps" }
        return bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "Apps"
    }

    static var icon: NSImage {
        if let cachedIcon { return cachedIcon }
        let image: NSImage
        if let url = appURL {
            image = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            image = NSImage(size: NSSize(width: 32, height: 32))
        }
        cachedIcon = image
        return image
    }

    /// 与 Dock 相同：经 HIServices 的 `CoreDockSendNotification` 切换启动板。
    /// 若符号不可用，再回退到辅助功能点击 Dock 图标。
    static func toggle() {
        if sendCoreDockNotification("com.apple.launchpad.toggle") {
            return
        }
        AppWindowService.ensurePermission(prompt: true)
        clickDockAppsItem()
    }

    /// 粗略判断启动板是否正打开（用于底部指示点）。优先看 owner/name，少建 NSRunningApplication。
    static func isVisible() -> Bool {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        for window in info {
            let owner = (window[kCGWindowOwnerName as String] as? String) ?? ""
            let name = (window[kCGWindowName as String] as? String) ?? ""

            if owner == "Apps" || owner == "Launchpad" {
                return true
            }
            if owner == "Dock",
               name.localizedCaseInsensitiveContains("launchpad") || name == "Apps" {
                return true
            }

            // 少数版本窗口名不含关键字时，再查 bundle。
            if let ownerPID = window[kCGWindowOwnerPID as String] as? pid_t,
               let bundle = NSRunningApplication(processIdentifier: ownerPID)?.bundleIdentifier,
               bundle == "com.apple.apps.launcher" || bundle == "com.apple.launchpad.launcher" {
                return true
            }
        }
        return false
    }

    // MARK: - Private

    @discardableResult
    private static func sendCoreDockNotification(_ name: String) -> Bool {
        if coreDockSend == nil {
            typealias Fn = @convention(c) (CFString, Int) -> Void
            let path =
                "/System/Library/Frameworks/ApplicationServices.framework/Versions/A/Frameworks/HIServices.framework/Versions/A/HIServices"
            guard let handle = dlopen(path, RTLD_LAZY),
                  let symbol = dlsym(handle, "CoreDockSendNotification") else {
                return false
            }
            coreDockSend = unsafeBitCast(symbol, to: Fn.self)
        }
        guard let send = coreDockSend else { return false }
        send(name as CFString, 0)
        return true
    }

    private static func clickDockAppsItem() {
        let titles: Set<String> = [
            "Apps", "App", "Launchpad",
            "启动台", "启动板", "应用程序"
        ]
        guard let dock = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.dock"
        }) else { return }

        let appElement = AXUIElementCreateApplication(dock.processIdentifier)
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXChildrenAttribute as CFString, &children) == .success,
              let list = children as? [AXUIElement] else { return }

        for root in list {
            if clickDockItem(in: root, titles: titles) { return }
        }
    }

    private static func clickDockItem(in element: AXUIElement, titles: Set<String>) -> Bool {
        var roleValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue) == .success,
           let role = roleValue as? String,
           role == (kAXDockItemRole as String) || role == "AXApplicationDockItem" {
            var titleValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleValue) == .success,
               let title = titleValue as? String,
               titles.contains(title) {
                AXUIElementPerformAction(element, kAXPressAction as CFString)
                return true
            }
        }

        var childrenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue) == .success,
              let children = childrenValue as? [AXUIElement] else { return false }
        for child in children {
            if clickDockItem(in: child, titles: titles) { return true }
        }
        return false
    }
}
