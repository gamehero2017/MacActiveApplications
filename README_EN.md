# Mac Active Applications

A Windows-style taskbar for macOS, docked to the **left of the notch**. It covers the left portion of the menu bar, lists running apps, and supports switch / restore, hover window actions, context menus, and a system Apps (formerly Launchpad) entry.

[中文说明](README.md)

## Features

- Snaps to the **left** of the notch; height matches the menu bar; expanded by default
- Width scales with the number of running apps (with a maximum)
- Handle click collapses / expands (no auto-expand on hover)
- Icon order: Finder → Apps (Launchpad) → other running apps (sorted by name)
- Single-click icon: bring to front; if already frontmost with visible windows, hide (Windows taskbar semantics)
- Minimized or window-closed-but-still-running apps can be restored on click (Dock-like reopen)
- **Apps / Launchpad** pinned entry (after Finder): click toggles open/close like the Dock; no context menu, no hover peek
- Hover any app that has visible windows: title list (`[App Name] Window Title`, including single-window apps)
  - Click a title to focus the window
  - Minimize / maximize (restorable) / close (requires Accessibility)
- **Right-click app icons** (except Apps):
  - Common: Show, Hide, Reveal in Finder, Quit
  - Finder extra: New Finder Window
- **Hamburger menu** (leftmost, expanded only; icon rotates to an X while open):
  - Version (non-interactive)
  - Accessibility status (opens System Settings; system prompt at most once)
  - Show Apps (toggle)
  - Show window list on hover (toggle)
  - Remember expanded / collapsed (toggle)
  - Launch at Login (toggle; works reliably when running as a `.app`)
  - Quit Taskbar
- Menu-bar utility form: no Dock icon (`LSUIElement` / `.accessory`)
- UI strings follow the system language (Simplified Chinese / English)

## Requirements

- macOS 13+ (Apps entry on macOS 26+ uses `/System/Applications/Apps.app`; older systems fall back to Launchpad.app)
- Xcode / Swift 5.9+ (command-line tools are enough)
- **Accessibility** permission: required for window lists and window button actions
- **UI language**: follows the system language (Simplified Chinese / English); no in-app language switch

## Quick start

```bash
cd MacActiveApplications
swift run
```

Or open in Xcode:

```bash
open Package.swift
```

Select scheme `MacActiveApplications`, destination My Mac, then Run.

## How to quit

This tool has no Dock icon. You can:

- Open the hamburger menu → **Quit Taskbar**
- If started with `swift run` in a terminal: `Ctrl + C`
- Or: `killall MacActiveApplications`

## Package a DMG

```bash
./scripts/package-dmg.sh
```

Outputs:

- `dist/MacActiveApplications.app`
- `dist/MacActiveApplications-<version>.dmg` (version from `CFBundleShortVersionString` in `Resources/Info.plist`)

Install: open the DMG and drag the app to Applications. On first launch, enable it under:

**System Settings → Privacy & Security → Accessibility**

## Project layout

```text
Sources/MacActiveApplications/
  AppDelegate.swift                 # Entry point
  Geometry/MenuBarGeometry.swift    # Notch snap & menu-bar geometry
  Model/
    RunningAppsStore.swift          # Running apps, activation, context actions
    RunningAppItem.swift
    AppWindowService.swift          # Window enum / min / max / close (Accessibility)
    SystemAppsLauncher.swift        # Apps / Launchpad toggle (CoreDockSendNotification)
    AppContextMenuBuilder.swift     # App icon context menu
    TaskbarPreferences.swift        # Settings preferences (UserDefaults / login item)
    TaskbarSettingsMenuBuilder.swift # Hamburger NSMenu
  L10n.swift                        # Localized strings (follows system language)
  Resources/
    en.lproj/Localizable.strings
    zh-Hans.lproj/Localizable.strings
  Panel/
    MenuBarPanel.swift              # Taskbar panel
    WindowPeekController.swift      # Hover title-list overlay (“Peek”)
  UI/
    TaskbarView.swift               # Icons / handle / hit targets / menus
    TaskbarStyle.swift              # Size & style constants
Resources/
  Info.plist
  AppIcon.icns                      # Packaging icon
  AppIcon.icon/                     # Icon Composer source (optional)
scripts/
  package-dmg.sh                    # Release build → .app → DMG
docs/
  更新说明.md                       # Changelog (Chinese)
```

## Common tuning

In `UI/TaskbarStyle.swift`:

| Constant | Meaning |
|----------|---------|
| `handleWidth` / `collapsedWidth` | Collapsed handle width |
| `settingsButtonWidth` | Hamburger button width |
| `handleTrailingExtension` | Fine-tune trailing edge vs notch |
| `notchVisualCompensationRatio` | Dynamic notch-fit compensation |
| `peekMinWidth` / `peekMaxWidth` | Hover title-list width range |
| `peekHideDelay` | Delay before hiding peek after hover leave |

## Permissions

| Capability | Permission |
|------------|------------|
| List running apps, activate / hide / reopen | Usually none |
| Window titles, minimize / maximize / close | **Accessibility** |
| Apps / Launchpad toggle | Via Dock private notification (`CoreDockSendNotification`); usually no extra permission |
| Finder “New Window” | AppleScript controlling Finder (system may prompt for Automation) |

Without Accessibility, the taskbar itself still works; window title-bar actions are disabled or degraded. The system Accessibility prompt appears at most once; afterward use the hamburger menu to open Settings.

## Tech stack

- Swift / AppKit / SwiftUI
- Swift Package Manager (executable)
- Accessibility (`AXUIElement`) + `NSWorkspace` / Apple Event reopen
- Dock: `CoreDockSendNotification("com.apple.launchpad.toggle")`

## Known limitations

- Covers some left-side system menu-bar items (by design)
- Maximize geometry may need recalibration on unusual multi-monitor layouts
- Apps entry depends on Dock interfaces; behavior may vary on extreme OS versions
- Local packaging uses ad-hoc signing; public distribution should use Developer ID + notarization
- No public API to read other apps’ Dock badge counts

## Related docs

- [Changelog (Chinese)](docs/更新说明.md)
- [Chinese README](README.md)

## License

Unauthorized reproduction or redistribution is not permitted without the author’s approval.
