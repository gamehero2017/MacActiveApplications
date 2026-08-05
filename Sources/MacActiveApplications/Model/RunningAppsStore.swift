import AppKit
import Carbon
import Combine

/// 任务栏展示的运行中应用列表。
/// 数据来源是 `NSWorkspace.runningApplications`（不是 Dock 界面）；
/// 另固定插入 Apps / 启动板入口（位于访达之后）。
@MainActor
final class RunningAppsStore: ObservableObject {
    @Published private(set) var apps: [RunningAppItem] = []

    private var observers: [NSObjectProtocol] = []
    /// 按 pid 缓存图标，避免 SwiftUI 每次刷新都重新取图。
    private var iconCache: [pid_t: NSImage] = [:]
    private var appsVisibilityTimer: Timer?
    private var refreshWorkItem: DispatchWorkItem?

    static let finderBundleID = "com.apple.finder"
    private static let launcherBundleIDs: Set<String> = [
        "com.apple.apps.launcher",
        "com.apple.launchpad.launcher"
    ]

    init() {
        refresh()
        startObserving()
        startAppsVisibilityPolling()
    }

    deinit {
        appsVisibilityTimer?.invalidate()
        let center = NSWorkspace.shared.notificationCenter
        for observer in observers {
            center.removeObserver(observer)
        }
    }

    /// 根据 workspace 进程列表重建 `apps`，并钉上 Apps 入口。
    func refresh() {
        let workspace = NSWorkspace.shared
        let front = workspace.frontmostApplication
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let selfBundle = Bundle.main.bundleIdentifier

        // 清理已退出进程的图标缓存与最大化帧缓存。
        let livePIDs = Set(workspace.runningApplications.map(\.processIdentifier))
        iconCache = iconCache.filter { livePIDs.contains($0.key) }
        AppWindowService.pruneSavedFrames(livePIDs: livePIDs)

        var running = workspace.runningApplications
            .filter { app in
                // `.regular` ≈ 普通 GUI 应用（排除 agent、UIElement 等辅助进程）。
                app.activationPolicy == .regular
                    && app.processIdentifier != selfPID
                    && app.bundleIdentifier != selfBundle
                    && !app.isTerminated
                    // 启动板由固定入口展示，不进普通列表。
                    && !Self.launcherBundleIDs.contains(app.bundleIdentifier ?? "")
                    // 隐藏名称形如 *Agent.app 的辅助包。
                    && !(app.bundleURL?.lastPathComponent.hasSuffix("Agent.app") ?? false)
            }
            .sorted { lhs, rhs in
                // 访达固定在最左侧。
                let lFinder = lhs.bundleIdentifier == Self.finderBundleID
                let rFinder = rhs.bundleIdentifier == Self.finderBundleID
                if lFinder != rFinder { return lFinder && !rFinder }
                return (lhs.localizedName ?? "").localizedCaseInsensitiveCompare(rhs.localizedName ?? "") == .orderedAscending
            }
            .map { app -> RunningAppItem in
                let pid = app.processIdentifier
                let icon: NSImage
                if let cached = iconCache[pid] {
                    icon = cached
                } else {
                    let fresh = app.icon ?? NSImage(size: NSSize(width: 32, height: 32))
                    iconCache[pid] = fresh
                    icon = fresh
                }
                return RunningAppItem(
                    id: pid,
                    bundleIdentifier: app.bundleIdentifier,
                    localizedName: app.localizedName ?? "App",
                    icon: icon,
                    isActive: pid == front?.processIdentifier
                )
            }

        // Apps / 启动板：固定在访达后面（无访达时置于最左）；可由偏好关闭。
        if TaskbarPreferences.shared.showAppsLauncher, SystemAppsLauncher.appURL != nil {
            let launcher = RunningAppItem(
                id: SystemAppsLauncher.sentinelPID,
                bundleIdentifier: "com.apple.apps.launcher",
                localizedName: SystemAppsLauncher.displayName,
                icon: SystemAppsLauncher.icon,
                isActive: SystemAppsLauncher.isVisible(),
                isAppsLauncher: true
            )
            if let finderIndex = running.firstIndex(where: { $0.bundleIdentifier == Self.finderBundleID }) {
                running.insert(launcher, at: finderIndex + 1)
            } else {
                running.insert(launcher, at: 0)
            }
        }

        apps = running
    }

    /// 任务栏图标点击：Apps 入口切换启动板；其它应用则前台/隐藏。
    func activateOrHide(pid: pid_t) {
        if pid == SystemAppsLauncher.sentinelPID {
            SystemAppsLauncher.toggle()
            scheduleRefresh(after: 0.15)
            return
        }

        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return }

        // 切换普通应用前先让出任务栏 key，保证目标窗口能接收键盘输入。
        TaskbarFocus.resignTaskbarKey()

        if app.isActive, AppWindowService.hasOnscreenWindows(pid: pid) {
            app.hide()
        } else {
            bringToForeground(app)
        }

        scheduleRefresh()
    }

    // MARK: - 右键菜单动作

    /// 显示到前台（不切换隐藏）。
    func showApp(pid: pid_t) {
        guard let app = runningApp(pid: pid) else { return }
        bringToForeground(app)
        scheduleRefresh()
    }

    /// 隐藏应用。
    func hideApp(pid: pid_t) {
        guard let app = runningApp(pid: pid) else { return }
        app.hide()
        scheduleRefresh()
    }

    /// 退出应用；若普通 terminate 无效则强制退出。
    func quitApp(pid: pid_t) {
        guard let app = runningApp(pid: pid) else { return }
        let targetPID = app.processIdentifier
        AppWindowService.clearSavedFrames(for: targetPID)

        if !app.terminate() {
            app.forceTerminate()
            scheduleRefresh(after: 0.2)
            return
        }

        scheduleRefresh(after: 0.2)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            if let still = NSRunningApplication(processIdentifier: targetPID), !still.isTerminated {
                still.forceTerminate()
            }
            self?.scheduleRefresh()
        }
    }

    /// 在访达中显示该应用的 .app 包。
    func revealInFinder(pid: pid_t) {
        guard let app = runningApp(pid: pid),
              let url = app.bundleURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// 访达专属：新建访达窗口。
    func newFinderWindow() {
        guard let finder = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == Self.finderBundleID
        }) else { return }

        bringToForeground(finder)

        var error: NSDictionary?
        let script = NSAppleScript(source: """
            tell application "Finder"
                make new Finder window
                activate
            end tell
            """)
        let result = script?.executeAndReturnError(&error)
        if result == nil || error != nil {
            // AppleScript 失败（如自动化未授权）时，至少打开用户主目录。
            NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory()))
        }
        scheduleRefresh()
    }

    private func runningApp(pid: pid_t) -> NSRunningApplication? {
        guard pid != SystemAppsLauncher.sentinelPID,
              let app = NSRunningApplication(processIdentifier: pid),
              !app.isTerminated else { return nil }
        return app
    }

    /// 合并短时间内的多次刷新请求，避免快速切换时排队全量重建。
    private func scheduleRefresh(after delay: TimeInterval = 0.08) {
        refreshWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.refresh()
        }
        refreshWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Dock 式恢复：取消隐藏 + reopen + 激活（避免再用 openApplication 导致重复开窗）。
    private func bringToForeground(_ app: NSRunningApplication) {
        if app.isHidden {
            app.unhide()
        }
        sendReopenAppleEvent(to: app)
        app.activate(options: [.activateIgnoringOtherApps])
    }

    /// 发送 `kAEReopenApplication`，请求目标应用重新打开（例如还原最小化窗口）。
    private func sendReopenAppleEvent(to app: NSRunningApplication) {
        let target = NSAppleEventDescriptor(processIdentifier: app.processIdentifier)
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEReopenApplication),
            targetDescriptor: target,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )

        var reply = AppleEvent()
        let status = AESendMessage(
            event.aeDesc,
            &reply,
            AESendMode(kAENoReply),
            500
        )
        if status == noErr, reply.descriptorType != typeNull {
            AEDisposeDesc(&reply)
        }
    }

    /// 事件驱动刷新：监听启动 / 退出 / 激活 / 失活；经防抖合并。
    private func startObserving() {
        let center = NSWorkspace.shared.notificationCenter
        let names: [NSNotification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didDeactivateApplicationNotification
        ]
        for name in names {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                Task { @MainActor in
                    if name == NSWorkspace.didTerminateApplicationNotification,
                       let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                        AppWindowService.clearSavedFrames(for: app.processIdentifier)
                    }
                    self?.scheduleRefresh(after: 0.05)
                }
            }
            observers.append(token)
        }
    }

    /// 启动板可由 Esc / 点击桌面关闭，workspace 通知不一定触发；轻量轮询指示点。
    private func startAppsVisibilityPolling() {
        let timer = Timer(timeInterval: 0.8, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard let index = self.apps.firstIndex(where: \.isAppsLauncher) else { return }
                let visible = SystemAppsLauncher.isVisible()
                guard self.apps[index].isActive != visible else { return }
                var next = self.apps
                let item = next[index]
                next[index] = RunningAppItem(
                    id: item.id,
                    bundleIdentifier: item.bundleIdentifier,
                    localizedName: item.localizedName,
                    icon: item.icon,
                    isActive: visible,
                    isAppsLauncher: true
                )
                self.apps = next
            }
        }
        timer.tolerance = 0.25
        RunLoop.main.add(timer, forMode: .common)
        appsVisibilityTimer = timer
    }
}
