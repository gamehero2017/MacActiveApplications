import AppKit
import ApplicationServices

/// 从 Dock 读取 `AXStatusLabel`，驱动任务栏未读红点。
/// 关闭偏好时**彻底停表**；开启时轮询 + 大 tolerance。
/// 休眠 / 关屏 / 锁屏时暂停轮询（保留红点状态），唤醒 / 解锁后再开。
@MainActor
final class DockBadgeMonitor {
    static let shared = DockBadgeMonitor()

    private weak var store: RunningAppsStore?
    private var timer: Timer?
    /// key（bundle id / Dock 标题）→ 角标文案；文案变化可触发图标跳动。
    private(set) var badgeLabels: [String: String] = [:]
    /// 系统休眠 / 关屏 / 锁屏等原因；非空则不跑 Timer。
    private var pauseReasons: Set<PauseReason> = []
    private var didInstallSystemObservers = false
    private var workspaceObservers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []

    private static let pollInterval: TimeInterval = 1.0
    private static let pollTolerance: TimeInterval = 1.0

    private enum PauseReason: Hashable {
        case systemSleep
        case screensSleep
        case screenLock
    }

    private init() {}

    func attach(store: RunningAppsStore) {
        self.store = store
        installSystemObserversIfNeeded()
        syncWithPreference()
    }

    /// 偏好开关或启动时调用：关 → 停表并清红点；开 → 开始轮询（若未因休眠/锁屏暂停）。
    func syncWithPreference() {
        if TaskbarPreferences.shared.showUnreadBadgeDot {
            resumePollingIfAllowed()
        } else {
            stop(clearBadges: true)
        }
    }

    // MARK: - Timer

    private func resumePollingIfAllowed() {
        guard TaskbarPreferences.shared.showUnreadBadgeDot else {
            stop(clearBadges: true)
            return
        }
        guard pauseReasons.isEmpty else {
            invalidateTimer()
            return
        }
        guard timer == nil else {
            poll()
            return
        }
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.poll()
            }
        }
        timer.tolerance = Self.pollTolerance
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        poll()
    }

    private func pausePolling() {
        invalidateTimer()
    }

    private func stop(clearBadges: Bool) {
        invalidateTimer()
        guard clearBadges else { return }
        badgeLabels = [:]
        store?.applyUnreadBadges([:])
    }

    private func invalidateTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        guard TaskbarPreferences.shared.showUnreadBadgeDot else {
            stop(clearBadges: true)
            return
        }
        guard pauseReasons.isEmpty else { return }
        guard AXIsProcessTrusted() else {
            publish([:])
            return
        }

        publish(Self.readBadgeLabelsFromDock())
    }

    private func publish(_ labels: [String: String]) {
        guard labels != badgeLabels else { return }
        badgeLabels = labels
        store?.applyUnreadBadges(labels)
    }

    // MARK: - 休眠 / 关屏 / 锁屏

    private func installSystemObserversIfNeeded() {
        guard !didInstallSystemObservers else { return }
        didInstallSystemObservers = true

        let workspace = NSWorkspace.shared.notificationCenter
        workspaceObservers = [
            workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.beginPause(.systemSleep) }
            },
            workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.endPause(.systemSleep) }
            },
            workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.beginPause(.screensSleep) }
            },
            workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.endPause(.screensSleep) }
            }
        ]

        let distributed = DistributedNotificationCenter.default()
        distributedObservers = [
            distributed.addObserver(
                forName: Notification.Name("com.apple.screenIsLocked"),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.beginPause(.screenLock) }
            },
            distributed.addObserver(
                forName: Notification.Name("com.apple.screenIsUnlocked"),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.endPause(.screenLock) }
            }
        ]
    }

    private func beginPause(_ reason: PauseReason) {
        let inserted = pauseReasons.insert(reason).inserted
        guard inserted else { return }
        pausePolling()
    }

    private func endPause(_ reason: PauseReason) {
        guard pauseReasons.remove(reason) != nil else { return }
        resumePollingIfAllowed()
    }

    // MARK: - Dock AX

    private static func readBadgeLabelsFromDock() -> [String: String] {
        guard let dock = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.dock"
        }) else { return [:] }

        let appElement = AXUIElementCreateApplication(dock.processIdentifier)
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let roots = childrenRef as? [AXUIElement] else { return [:] }

        var labels: [String: String] = [:]
        for root in roots {
            collectBadgedItems(in: root, into: &labels)
        }
        return labels
    }

    private static func collectBadgedItems(in element: AXUIElement, into labels: inout [String: String]) {
        var roleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success,
           let role = roleRef as? String,
           role == (kAXDockItemRole as String) || role == "AXApplicationDockItem" {
            if let status = statusLabel(element) {
                if let bundleID = bundleIdentifier(forDockItem: element) {
                    labels[bundleID] = status
                }
                if let title = stringAttribute(element, kAXTitleAttribute as String), !title.isEmpty {
                    labels[title] = status
                }
            }
        }

        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return }
        for child in children {
            collectBadgedItems(in: child, into: &labels)
        }
    }

    private static func statusLabel(_ element: AXUIElement) -> String? {
        guard let label = stringAttribute(element, "AXStatusLabel") else { return nil }
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func bundleIdentifier(forDockItem element: AXUIElement) -> String? {
        if let urlString = stringAttribute(element, kAXURLAttribute as String),
           let url = URL(string: urlString) {
            let path = url.path
            if let bundle = Bundle(path: path),
               let id = bundle.bundleIdentifier {
                return id
            }
            if path.hasSuffix(".app") || path.contains(".app/") {
                let appPath = path.components(separatedBy: ".app").first.map { $0 + ".app" } ?? path
                if let id = Bundle(path: appPath)?.bundleIdentifier {
                    return id
                }
            }
        }
        return nil
    }

    private static func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let string = value as? String else { return nil }
        return string
    }
}
