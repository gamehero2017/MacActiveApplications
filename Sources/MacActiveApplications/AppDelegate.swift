import AppKit

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panelController: MenuBarPanelController?
    private var store: RunningAppsStore?
    private var peekController: WindowPeekController?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 仅首次未授权时弹一次系统框；拒绝后不再每次启动打扰。
        AppWindowService.ensurePermission(prompt: true)

        let store = RunningAppsStore()
        let peekController = WindowPeekController()
        self.store = store
        self.peekController = peekController

        let controller = MenuBarPanelController(store: store, peekController: peekController)
        controller.show()
        self.panelController = controller
    }
}
