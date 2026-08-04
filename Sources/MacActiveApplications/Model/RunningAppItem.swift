import AppKit

struct RunningAppItem: Identifiable, Equatable {
    let id: pid_t
    let bundleIdentifier: String?
    let localizedName: String
    let icon: NSImage
    let isActive: Bool
    /// 固定的 Apps / 启动板入口（非真实运行中进程）。
    let isAppsLauncher: Bool

    init(
        id: pid_t,
        bundleIdentifier: String?,
        localizedName: String,
        icon: NSImage,
        isActive: Bool,
        isAppsLauncher: Bool = false
    ) {
        self.id = id
        self.bundleIdentifier = bundleIdentifier
        self.localizedName = localizedName
        self.icon = icon
        self.isActive = isActive
        self.isAppsLauncher = isAppsLauncher
    }
}
