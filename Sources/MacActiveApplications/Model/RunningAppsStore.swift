import AppKit
import Carbon
import Combine

/// 任务栏展示的运行中应用列表。
/// 数据来源是 `NSWorkspace.runningApplications`（不是 Dock 界面）；
/// 另插入 Apps / 启动板入口；顺序优先使用用户拖拽记住的 `iconOrder`。
@MainActor
final class RunningAppsStore: ObservableObject {
    @Published private(set) var apps: [RunningAppItem] = []

    private var observers: [NSObjectProtocol] = []
    /// 按 pid 缓存图标，避免 SwiftUI 每次刷新都重新取图。
    private var iconCache: [pid_t: NSImage] = [:]
    private var appsVisibilityTimer: Timer?
    private var refreshWorkItem: DispatchWorkItem?
    /// 图标在窗口坐标系中的 frame，供拖拽排序计算落点。
    private var iconFramesInWindow: [pid_t: CGRect] = [:]
    /// Dock 角标：key → 角标文案；关红点偏好时为空。
    private var unreadBadgeLabels: [String: String] = [:]
    /// 正在拖拽的图标；刷新时跳过全量重建，并用于 UI 高亮。
    @Published private(set) var draggingPID: pid_t?
    /// 拖拽时鼠标的窗口坐标，供浮层图标跟随。
    @Published private(set) var dragLocationInWindow: NSPoint?
    /// 按下时鼠标相对图标中心的偏移（窗口坐标，AppKit Y 向上）。
    private(set) var dragGrabOffsetInWindow: CGSize = .zero
    private var dragStartIndex: Int?
    private var dragStartMouseX: CGFloat?
    private var dragStride: CGFloat = 30

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
        // 拖拽中跳过全量重建，避免打断排序手感；松手后再同步。
        if draggingPID != nil { return }

        let workspace = NSWorkspace.shared
        let front = workspace.frontmostApplication
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let selfBundle = Bundle.main.bundleIdentifier

        // 清理已退出进程的图标缓存与最大化帧缓存。
        let livePIDs = Set(workspace.runningApplications.map(\.processIdentifier))
        iconCache = iconCache.filter { livePIDs.contains($0.key) }
        iconFramesInWindow = iconFramesInWindow.filter { livePIDs.contains($0.key) || $0.key == SystemAppsLauncher.sentinelPID }
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
                    // 访达可由汉堡菜单关闭。
                    && (TaskbarPreferences.shared.showFinder
                        || app.bundleIdentifier != Self.finderBundleID)
                    // 隐藏名称形如 *Agent.app 的辅助包。
                    && !(app.bundleURL?.lastPathComponent.hasSuffix("Agent.app") ?? false)
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
                let name = app.localizedName ?? "App"
                let signal = Self.badgeSignal(
                    bundleIdentifier: app.bundleIdentifier,
                    localizedName: name,
                    labels: unreadBadgeLabels
                )
                return RunningAppItem(
                    id: pid,
                    bundleIdentifier: app.bundleIdentifier,
                    localizedName: name,
                    icon: icon,
                    isActive: pid == front?.processIdentifier,
                    hasUnreadBadge: signal != nil,
                    unreadBadgeSignal: signal
                )
            }

        // Apps / 启动板：可由偏好关闭；位置由 iconOrder 或默认规则决定。
        if TaskbarPreferences.shared.showAppsLauncher, SystemAppsLauncher.appURL != nil {
            let launcher = RunningAppItem(
                id: SystemAppsLauncher.sentinelPID,
                bundleIdentifier: "com.apple.apps.launcher",
                localizedName: SystemAppsLauncher.displayName,
                icon: SystemAppsLauncher.icon,
                isActive: SystemAppsLauncher.isVisible(),
                isAppsLauncher: true,
                hasUnreadBadge: false,
                unreadBadgeSignal: nil
            )
            running.append(launcher)
        }

        apps = Self.ordered(running, savedOrder: TaskbarPreferences.shared.iconOrder)
    }

    /// 由 `DockBadgeMonitor` 推送；映射未变则跳过。关闭红点时传入空字典。
    func applyUnreadBadges(_ labels: [String: String]) {
        guard labels != unreadBadgeLabels else { return }
        unreadBadgeLabels = labels
        guard !apps.isEmpty else { return }

        var next = apps
        var changed = false
        for index in next.indices {
            let item = next[index]
            let signal: String?
            if item.isAppsLauncher {
                signal = nil
            } else {
                signal = Self.badgeSignal(
                    bundleIdentifier: item.bundleIdentifier,
                    localizedName: item.localizedName,
                    labels: labels
                )
            }
            let hasBadge = signal != nil
            guard item.hasUnreadBadge != hasBadge || item.unreadBadgeSignal != signal else { continue }
            next[index] = RunningAppItem(
                id: item.id,
                bundleIdentifier: item.bundleIdentifier,
                localizedName: item.localizedName,
                icon: item.icon,
                isActive: item.isActive,
                isAppsLauncher: item.isAppsLauncher,
                hasUnreadBadge: hasBadge,
                unreadBadgeSignal: signal
            )
            changed = true
        }
        if changed {
            apps = next
        }
    }

    private static func badgeSignal(
        bundleIdentifier: String?,
        localizedName: String,
        labels: [String: String]
    ) -> String? {
        guard !labels.isEmpty else { return nil }
        if let bundleIdentifier, let signal = labels[bundleIdentifier] {
            return signal
        }
        if let signal = labels[localizedName] {
            return signal
        }
        for (key, signal) in labels where key.caseInsensitiveCompare(localizedName) == .orderedSame {
            return signal
        }
        return nil
    }

    // MARK: - 拖拽排序

    func reportIconFrame(pid: pid_t, frameInWindow: CGRect) {
        iconFramesInWindow[pid] = frameInWindow
    }

    func beginIconDrag(pid: pid_t, locationInWindow: NSPoint) {
        guard let index = apps.firstIndex(where: { $0.id == pid }) else { return }
        draggingPID = pid
        dragStartIndex = index
        dragStartMouseX = locationInWindow.x
        dragLocationInWindow = locationInWindow
        let width = iconFramesInWindow[pid]?.width ?? 28
        dragStride = max(16, width + TaskbarStyle.iconSpacing)
        if let frame = iconFramesInWindow[pid] {
            dragGrabOffsetInWindow = CGSize(
                width: locationInWindow.x - frame.midX,
                height: locationInWindow.y - frame.midY
            )
        } else {
            dragGrabOffsetInWindow = .zero
        }
    }

    /// 按按下时的序号 + 水平位移换算落点；越过半格时换位并立刻记住。
    func updateIconDrag(pid: pid_t, locationInWindow: NSPoint) {
        guard draggingPID == pid,
              let startIndex = dragStartIndex,
              let startX = dragStartMouseX,
              let from = apps.firstIndex(where: { $0.id == pid }) else { return }

        dragLocationInWindow = locationInWindow

        let shift = Int(((locationInWindow.x - startX) / dragStride).rounded())
        let target = min(max(0, startIndex + shift), apps.count - 1)
        guard target != from else { return }

        var next = apps
        let item = next.remove(at: from)
        next.insert(item, at: target)
        apps = next
        persistIconOrder()
    }

    func endIconDrag(pid: pid_t) {
        guard draggingPID == pid else { return }
        draggingPID = nil
        dragLocationInWindow = nil
        dragGrabOffsetInWindow = .zero
        dragStartIndex = nil
        dragStartMouseX = nil
        persistIconOrder()
        scheduleRefresh(after: 0.05)
    }

    private func persistIconOrder() {
        let keys = apps.compactMap(\.bundleIdentifier)
        TaskbarPreferences.shared.saveIconOrder(keys)
    }

    /// 有保存顺序：按 bundle id 排列，未知应用按默认规则接在末尾。
    /// 无保存顺序：访达 → Apps → 其余按名称。
    private static func ordered(_ items: [RunningAppItem], savedOrder: [String]) -> [RunningAppItem] {
        if savedOrder.isEmpty {
            return defaultOrdered(items)
        }

        var remaining = items
        var result: [RunningAppItem] = []
        result.reserveCapacity(items.count)

        for key in savedOrder {
            if let index = remaining.firstIndex(where: { $0.bundleIdentifier == key }) {
                result.append(remaining.remove(at: index))
            }
        }

        if !remaining.isEmpty {
            result.append(contentsOf: defaultOrdered(remaining))
        }
        return result
    }

    private static func defaultOrdered(_ items: [RunningAppItem]) -> [RunningAppItem] {
        items.sorted { lhs, rhs in
            let lFinder = lhs.bundleIdentifier == finderBundleID
            let rFinder = rhs.bundleIdentifier == finderBundleID
            if lFinder != rFinder { return lFinder && !rFinder }

            if lhs.isAppsLauncher != rhs.isAppsLauncher {
                return lhs.isAppsLauncher && !rhs.isAppsLauncher
            }

            return lhs.localizedName.localizedCaseInsensitiveCompare(rhs.localizedName) == .orderedAscending
        }
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
                    isAppsLauncher: true,
                    hasUnreadBadge: false,
                    unreadBadgeSignal: nil
                )
                self.apps = next
            }
        }
        timer.tolerance = 0.25
        RunLoop.main.add(timer, forMode: .common)
        appsVisibilityTimer = timer
    }
}
