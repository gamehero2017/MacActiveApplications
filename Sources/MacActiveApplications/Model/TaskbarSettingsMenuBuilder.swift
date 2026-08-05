import AppKit
import ObjectiveC

/// 最左侧三条横线菜单（向下展开）。
@MainActor
enum TaskbarSettingsMenuBuilder {
    static func menu(store: RunningAppsStore, preferences: TaskbarPreferences) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        // 版本信息（不可点）
        if #available(macOS 14.0, *) {
            menu.addItem(.sectionHeader(title: preferences.versionLabel))
        } else {
            let version = NSMenuItem(title: preferences.versionLabel, action: nil, keyEquivalent: "")
            version.isEnabled = false
            menu.addItem(version)
        }

        menu.addItem(.separator())

        addItem(menu, title: preferences.accessibilityStatusLabel) {
            preferences.openAccessibilitySettings()
        }

        addToggle(
            menu,
            title: "显示 Apps",
            isOn: preferences.showAppsLauncher,
            enabled: SystemAppsLauncher.appURL != nil
        ) {
            preferences.showAppsLauncher.toggle()
            store.refresh()
        }

        addToggle(menu, title: "开机启动", isOn: preferences.isLaunchAtLoginEnabled) {
            _ = preferences.setLaunchAtLogin(!preferences.isLaunchAtLoginEnabled)
        }

        menu.addItem(.separator())

        addItem(menu, title: "退出任务栏") {
            NSApp.terminate(nil)
        }

        return menu
    }

    /// 菜单左边与任务栏左边对齐，贴在汉堡按钮下方展开。
    static func popUp(menu: NSMenu, from view: NSView) {
        guard let window = view.window,
              let content = window.contentView else { return }

        let buttonBottomInContent = view.convert(
            NSPoint(x: 0, y: view.bounds.minY),
            to: content
        )
        let anchorInContent = NSPoint(x: 0, y: buttonBottomInContent.y)

        TaskbarFocus.withTemporaryKey(for: window) {
            guard let event = NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: content.convert(anchorInContent, to: nil),
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            ) else {
                menu.popUp(positioning: nil, at: anchorInContent, in: content)
                return
            }
            NSMenu.popUpContextMenu(menu, with: event, for: content)
        }
    }

    private static func addToggle(
        _ menu: NSMenu,
        title: String,
        isOn: Bool,
        enabled: Bool = true,
        action: @escaping () -> Void
    ) {
        let item = NSMenuItem(title: title, action: #selector(MenuTarget.run(_:)), keyEquivalent: "")
        let target = MenuTarget(action: action)
        item.target = target
        item.state = isOn ? .on : .off
        item.isEnabled = enabled
        objc_setAssociatedObject(item, &AssociatedKeys.target, target, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        menu.addItem(item)
    }

    private static func addItem(_ menu: NSMenu, title: String, action: @escaping () -> Void) {
        let item = NSMenuItem(title: title, action: #selector(MenuTarget.run(_:)), keyEquivalent: "")
        let target = MenuTarget(action: action)
        item.target = target
        objc_setAssociatedObject(item, &AssociatedKeys.target, target, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        menu.addItem(item)
    }
}

private enum AssociatedKeys {
    static var target: UInt8 = 0
}

private final class MenuTarget: NSObject {
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
    }

    @objc func run(_ sender: Any?) {
        action()
    }
}
