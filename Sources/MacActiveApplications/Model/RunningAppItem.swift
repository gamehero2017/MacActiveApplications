import AppKit

struct RunningAppItem: Identifiable, Equatable {
    let id: pid_t
    let bundleIdentifier: String?
    let localizedName: String
    let icon: NSImage
    let isActive: Bool
}
