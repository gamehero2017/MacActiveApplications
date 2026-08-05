import AppKit
import ApplicationServices
import Foundation
import ServiceManagement

/// 任务栏偏好：Apps 显示、开机启动等。
@MainActor
final class TaskbarPreferences: ObservableObject {
    static let shared = TaskbarPreferences()

    private enum Keys {
        static let showAppsLauncher = "taskbar.showAppsLauncher"
    }

    /// 是否在任务栏显示 Apps / 启动板入口。
    @Published var showAppsLauncher: Bool {
        didSet {
            UserDefaults.standard.set(showAppsLauncher, forKey: Keys.showAppsLauncher)
        }
    }

    private init() {
        if UserDefaults.standard.object(forKey: Keys.showAppsLauncher) == nil {
            showAppsLauncher = true
        } else {
            showAppsLauncher = UserDefaults.standard.bool(forKey: Keys.showAppsLauncher)
        }
    }

    var versionLabel: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "版本 \(short) (\(build))"
    }

    var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    var accessibilityStatusLabel: String {
        if isAccessibilityTrusted {
            return "辅助功能：已授权"
        }
        return "辅助功能：未授权（点击打开设置）"
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
}
