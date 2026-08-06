import Foundation

/// UI 文案：跟随系统语言（`en` / `zh-Hans`），不做应用内切换。
///
/// 说明：SwiftPM 拷贝资源时会把 `zh-Hans.lproj` 变成 `zh-hans.lproj`，
/// `Bundle.preferredLocalizations` 无法匹配 `zh-Hans-CN`，会错误回退到 `en`。
/// 因此这里按系统首选语言自行解析 `.lproj`。
///
/// 不要使用 `Bundle.module`：SPM 生成的 accessor 只查 `.app` 根目录与编译机 `.build` 路径，
/// 安装到其它机器的 `/Applications` 后会直接 fatalError。
enum L10n {
    private static let table = "Localizable"
    private static let resourceBundleName = "MacActiveApplications_MacActiveApplications"

    private static let stringsBundle: Bundle = {
        resolveStringsBundle()
    }()

    private static func resolveStringsBundle() -> Bundle {
        let module = resolveResourceBundle()
        let available = module.localizations.filter { $0 != "Base" }
        let preferred = Locale.preferredLanguages

        for pref in preferred {
            if let code = matchLocalization(preferred: pref, available: available),
               let path = module.path(forResource: code, ofType: "lproj"),
               let bundle = Bundle(path: path) {
                return bundle
            }
        }

        if let path = module.path(forResource: "en", ofType: "lproj"),
           let bundle = Bundle(path: path) {
            return bundle
        }
        return module
    }

    /// 在 `.app` 常见布局与 `swift run` 产物旁查找 SPM 资源包。
    private static func resolveResourceBundle() -> Bundle {
        let name = "\(resourceBundleName).bundle"
        let main = Bundle.main.bundleURL

        var candidates: [URL] = [
            // 与 SPM Bundle.module 一致（.app 根目录）
            main.appendingPathComponent(name),
            // 打包脚本原先放在可执行文件旁
            main.appendingPathComponent("Contents/MacOS/\(name)"),
            // Apple 惯例
            main.appendingPathComponent("Contents/Resources/\(name)"),
        ]
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent(name))
        }
        // swift run / 未打包：可执行文件同目录
        if let exeDir = Bundle.main.executableURL?.deletingLastPathComponent() {
            candidates.append(exeDir.appendingPathComponent(name))
        }

        for url in candidates {
            if FileManager.default.fileExists(atPath: url.path),
               let bundle = Bundle(url: url) {
                return bundle
            }
        }

        // 不崩溃：退回 main（界面可能显示 key，但仍可运行）
        return Bundle.main
    }

    /// 将系统语言（如 `zh-Hans-CN`）匹配到包内 localization（如 `zh-hans`）。
    private static func matchLocalization(preferred: String, available: [String]) -> String? {
        let pref = normalize(preferred)

        // 精确 / 前缀匹配（忽略大小写）
        for avail in available {
            let a = normalize(avail)
            if pref == a || pref.hasPrefix(a + "-") || a.hasPrefix(pref + "-") {
                return avail
            }
        }

        // 中文：简体 / 繁体
        let prefIsHans = pref.hasPrefix("zh-hans") || pref.hasPrefix("zh-cn") || pref == "zh"
        let prefIsHant = pref.hasPrefix("zh-hant") || pref.hasPrefix("zh-tw") || pref.hasPrefix("zh-hk") || pref.hasPrefix("zh-mo")
        for avail in available {
            let a = normalize(avail)
            if prefIsHans, a.hasPrefix("zh-hans") || a == "zh-cn" || a == "zh" { return avail }
            if prefIsHant, a.hasPrefix("zh-hant") || a == "zh-tw" || a == "zh-hk" { return avail }
        }

        // 仅语言码，如 en-001 → en
        if let lang = pref.split(separator: "-").first.map(String.init) {
            for avail in available where normalize(avail) == lang || normalize(avail).hasPrefix(lang + "-") {
                return avail
            }
        }
        return nil
    }

    private static func normalize(_ code: String) -> String {
        code.lowercased().replacingOccurrences(of: "_", with: "-")
    }

    private static func tr(_ key: String) -> String {
        NSLocalizedString(key, tableName: table, bundle: stringsBundle, value: key, comment: "")
    }

    private static func trf(_ key: String, _ args: CVarArg...) -> String {
        String(format: tr(key), locale: .current, arguments: args)
    }

    // Settings menu
    static func version(short: String, build: String) -> String {
        trf("menu.version %@", "\(short) (\(build))")
    }

    static var accessibilityTrusted: String { tr("menu.accessibility_trusted") }
    static var accessibilityDenied: String { tr("menu.accessibility_denied") }
    static var showApps: String { tr("menu.show_apps") }
    static var showFinder: String { tr("menu.show_finder") }
    static var showWindowPeek: String { tr("menu.show_window_peek") }
    static var showUnreadBadgeDot: String { tr("menu.show_unread_badge_dot") }
    static var rememberChrome: String { tr("menu.remember_chrome") }
    static var launchAtLogin: String { tr("menu.launch_at_login") }
    static var quitTaskbar: String { tr("menu.quit_taskbar") }

    // Tooltips
    static var settings: String { tr("tooltip.settings") }
    static var expandTaskbar: String { tr("tooltip.expand") }
    static var collapseTaskbar: String { tr("tooltip.collapse") }

    // Context menu
    static var show: String { tr("context.show") }
    static var hide: String { tr("context.hide") }
    static var newFinderWindow: String { tr("context.new_finder_window") }
    static var revealInFinder: String { tr("context.reveal_in_finder") }
    static var quit: String { tr("context.quit") }

    // Windows / Peek
    static var untitledWindow: String { tr("window.untitled") }
    static func windowsOf(_ appName: String) -> String { trf("peek.windows_of %@", appName) }
    static var needsAccessibility: String { tr("peek.needs_accessibility") }
    static var minimize: String { tr("peek.minimize") }
    static var maximize: String { tr("peek.maximize") }
    static var restore: String { tr("peek.restore") }
    static var close: String { tr("peek.close") }
}
