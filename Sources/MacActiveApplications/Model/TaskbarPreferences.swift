import AppKit
import ApplicationServices
import Foundation
import ServiceManagement

/// 任务栏偏好：访达 / Apps 显示、Peek、未读红点、展开状态、开机启动等。
@MainActor
final class TaskbarPreferences: ObservableObject {
    static let shared = TaskbarPreferences()

    private enum Keys {
        static let showAppsLauncher = "taskbar.showAppsLauncher"
        static let showFinder = "taskbar.showFinder"
        static let showWindowPeekOnHover = "taskbar.showWindowPeekOnHover"
        static let showUnreadBadgeDot = "taskbar.showUnreadBadgeDot"
        static let rememberChromeState = "taskbar.rememberChromeState"
        static let chromeExpanded = "taskbar.chromeExpanded"
        static let iconOrder = "taskbar.iconOrder"
        static let panelTrailingOffset = "taskbar.panelTrailingOffset"
    }

    /// 是否在任务栏显示 Apps / 启动板入口。
    @Published var showAppsLauncher: Bool {
        didSet { UserDefaults.standard.set(showAppsLauncher, forKey: Keys.showAppsLauncher) }
    }

    /// 是否在任务栏显示访达。
    @Published var showFinder: Bool {
        didSet { UserDefaults.standard.set(showFinder, forKey: Keys.showFinder) }
    }

    /// 悬停应用图标时是否弹出窗口标题栏列表。
    @Published var showWindowPeekOnHover: Bool {
        didSet { UserDefaults.standard.set(showWindowPeekOnHover, forKey: Keys.showWindowPeekOnHover) }
    }

    /// 是否根据 Dock 角标在任务栏显示未读红点；关闭后彻底停止轮询。
    @Published var showUnreadBadgeDot: Bool {
        didSet {
            UserDefaults.standard.set(showUnreadBadgeDot, forKey: Keys.showUnreadBadgeDot)
            DockBadgeMonitor.shared.syncWithPreference()
        }
    }

    /// 是否记住上次展开/收起；关闭则每次启动均为展开。
    @Published var rememberChromeState: Bool {
        didSet { UserDefaults.standard.set(rememberChromeState, forKey: Keys.rememberChromeState) }
    }

    /// 任务栏图标顺序（`bundleIdentifier` 列表）；空则使用默认排序。
    @Published private(set) var iconOrder: [String] {
        didSet { UserDefaults.standard.set(iconOrder, forKey: Keys.iconOrder) }
    }

    /// 任务栏相对刘海贴齐位置向左的偏移（pt）；0 表示把手贴刘海。
    @Published private(set) var panelTrailingOffset: CGFloat {
        didSet { UserDefaults.standard.set(Double(panelTrailingOffset), forKey: Keys.panelTrailingOffset) }
    }

    private init() {
        showAppsLauncher = Self.bool(Keys.showAppsLauncher, default: true)
        showFinder = Self.bool(Keys.showFinder, default: true)
        showWindowPeekOnHover = Self.bool(Keys.showWindowPeekOnHover, default: true)
        showUnreadBadgeDot = Self.bool(Keys.showUnreadBadgeDot, default: true)
        rememberChromeState = Self.bool(Keys.rememberChromeState, default: false)
        iconOrder = UserDefaults.standard.stringArray(forKey: Keys.iconOrder) ?? []
        if UserDefaults.standard.object(forKey: Keys.panelTrailingOffset) != nil {
            panelTrailingOffset = CGFloat(UserDefaults.standard.double(forKey: Keys.panelTrailingOffset))
        } else {
            panelTrailingOffset = 0
        }
    }

    func saveIconOrder(_ order: [String]) {
        guard order != iconOrder else { return }
        iconOrder = order
    }

    func savePanelTrailingOffset(_ offset: CGFloat) {
        let next = max(0, offset)
        guard abs(next - panelTrailingOffset) > 0.05 else { return }
        panelTrailingOffset = next
    }

    /// 启动时应使用的展开状态。
    var initialChromeExpanded: Bool {
        if rememberChromeState {
            return Self.bool(Keys.chromeExpanded, default: true)
        }
        return true
    }

    func saveChromeExpanded(_ expanded: Bool) {
        guard rememberChromeState else { return }
        UserDefaults.standard.set(expanded, forKey: Keys.chromeExpanded)
    }

    var versionLabel: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return L10n.version(short: short, build: build)
    }

    var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    var accessibilityStatusLabel: String {
        if isAccessibilityTrusted {
            return L10n.accessibilityTrusted
        }
        return L10n.accessibilityDenied
    }

    var isLaunchAtLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @discardableResult
    func setLaunchAtLogin(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            objectWillChange.send()
            return true
        } catch {
            // `swift run` / 非 .app 打包时常见失败，静默保持现状。
            NSLog("Launch at login failed: \(error.localizedDescription)")
            objectWillChange.send()
            return false
        }
    }

    func openAccessibilitySettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility"
        ]
        for string in candidates {
            if let url = URL(string: string), NSWorkspace.shared.open(url) {
                return
            }
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security") {
            NSWorkspace.shared.open(url)
        }
    }

    private static func bool(_ key: String, default defaultValue: Bool) -> Bool {
        if UserDefaults.standard.object(forKey: key) == nil {
            return defaultValue
        }
        return UserDefaults.standard.bool(forKey: key)
    }
}
