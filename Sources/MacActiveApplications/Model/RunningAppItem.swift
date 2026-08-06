import AppKit

struct RunningAppItem: Identifiable, Equatable {
    let id: pid_t
    let bundleIdentifier: String?
    let localizedName: String
    let icon: NSImage
    let isActive: Bool
    /// 固定的 Apps / 启动板入口（非真实运行中进程）。
    let isAppsLauncher: Bool
    /// Dock 角标非空时显示未读红点（不展示数字）。
    let hasUnreadBadge: Bool
    /// Dock `AXStatusLabel` 原文；变化时触发跳动（如 1→2）。
    let unreadBadgeSignal: String?

    init(
        id: pid_t,
        bundleIdentifier: String?,
        localizedName: String,
        icon: NSImage,
        isActive: Bool,
        isAppsLauncher: Bool = false,
        hasUnreadBadge: Bool = false,
        unreadBadgeSignal: String? = nil
    ) {
        self.id = id
        self.bundleIdentifier = bundleIdentifier
        self.localizedName = localizedName
        self.icon = icon
        self.isActive = isActive
        self.isAppsLauncher = isAppsLauncher
        self.hasUnreadBadge = hasUnreadBadge
        self.unreadBadgeSignal = unreadBadgeSignal
    }
}
