import AppKit
import Carbon
import Combine
import CoreGraphics

@MainActor
final class RunningAppsStore: ObservableObject {
    @Published private(set) var apps: [RunningAppItem] = []

    private var observers: [NSObjectProtocol] = []
    private var iconCache: [pid_t: NSImage] = [:]

    init() {
        refresh()
        startObserving()
    }

    deinit {
        let center = NSWorkspace.shared.notificationCenter
        for observer in observers {
            center.removeObserver(observer)
        }
    }

    func refresh() {
        let workspace = NSWorkspace.shared
        let front = workspace.frontmostApplication
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let selfBundle = Bundle.main.bundleIdentifier
        let livePIDs = Set(workspace.runningApplications.map(\.processIdentifier))
        iconCache = iconCache.filter { livePIDs.contains($0.key) }

        apps = workspace.runningApplications
            .filter { app in
                app.activationPolicy == .regular
                    && app.processIdentifier != selfPID
                    && app.bundleIdentifier != selfBundle
                    && !app.isTerminated
                    && !(app.bundleURL?.lastPathComponent.hasSuffix("Agent.app") ?? false)
            }
            .sorted { lhs, rhs in
                (lhs.localizedName ?? "").localizedCaseInsensitiveCompare(rhs.localizedName ?? "") == .orderedAscending
            }
            .map { app in
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
    }

    func activateOrHide(pid: pid_t) {
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return }

        if app.isActive, AppWindowService.hasOnscreenWindows(pid: pid) {
            app.hide()
        } else {
            bringToForeground(app)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            self?.refresh()
        }
    }

    /// Dock-like restore: unhide + reopen + activate (avoid double-open via openApplication).
    private func bringToForeground(_ app: NSRunningApplication) {
        if app.isHidden {
            app.unhide()
        }
        sendReopenAppleEvent(to: app)
        app.activate(options: [.activateIgnoringOtherApps])
    }

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

    private func startObserving() {
        let center = NSWorkspace.shared.notificationCenter
        let names: [NSNotification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didDeactivateApplicationNotification
        ]
        for name in names {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.refresh()
                }
            }
            observers.append(token)
        }
    }
}
