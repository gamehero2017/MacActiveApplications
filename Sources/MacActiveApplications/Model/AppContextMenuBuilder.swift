import AppKit
import ObjectiveC

/// 按应用组装任务栏右键菜单（Apps / 启动板不提供菜单）。
@MainActor
enum AppContextMenuBuilder {
    static func menu(
        for app: RunningAppItem,
        store: RunningAppsStore
    ) -> NSMenu? {
        guard !app.isAppsLauncher else { return nil }

        let menu = NSMenu()
        menu.autoenablesItems = false

        addItem(menu, title: "显示") {
            store.showApp(pid: app.id)
        }
        addItem(menu, title: "隐藏") {
            store.hideApp(pid: app.id)
        }

        if app.bundleIdentifier == RunningAppsStore.finderBundleID {
            menu.addItem(.separator())
            addItem(menu, title: "新建访达窗口") {
                store.newFinderWindow()
            }
        }

        menu.addItem(.separator())
        addItem(menu, title: "在访达中显示") {
            store.revealInFinder(pid: app.id)
        }
        menu.addItem(.separator())
        addItem(menu, title: "退出") {
            store.quitApp(pid: app.id)
        }

        return menu
    }

    private static func addItem(_ menu: NSMenu, title: String, action: @escaping () -> Void) {
        let item = NSMenuItem(title: title, action: #selector(AppContextMenuTarget.run(_:)), keyEquivalent: "")
        let target = AppContextMenuTarget(action: action)
        item.target = target
        // Retain target for the menu item lifetime.
        objc_setAssociatedObject(item, &AssociatedKeys.target, target, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        menu.addItem(item)
    }
}

private enum AssociatedKeys {
    static var target: UInt8 = 0
}

private final class AppContextMenuTarget: NSObject {
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
    }

    @objc func run(_ sender: Any?) {
        action()
    }
}
