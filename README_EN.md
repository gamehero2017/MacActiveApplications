# Mac Active Applications

A Windows-style taskbar that lives in the macOS menu-bar area. It lists running apps and supports switch / restore, drag-to-reorder, drag-to-reposition, dual collapse modes, unread badge dots, hover window actions, context menus, and a system Apps (formerly Launchpad) entry.

Not limited to notched Macs — with a notch it can sit flush to the left of the cutout; without one (or on an external display) it uses the left usable part of the menu bar. Drag away from the right edge and **collapse upward** into a thin strip so it stays tidy on most screens.

[中文说明](README.md)

## Screenshots

Expanded (flush with the right edge, handle `>`):

![Expanded taskbar](docs/QQ20260806-145436.png)

Collapsed sideways to handle `<` only:

![Collapsed sideways](docs/QQ20260806-145451.png)

Expanded after dragging away (handle `∧`, collapses upward):

![Detached expanded](docs/QQ20260806-145632.png)

Hamburger settings menu:

![Settings menu](docs/QQ20260806-145510.png)

Hover window list:

![Hover window list](docs/QQ20260806-145534.png)

## Features

- Menu-bar height, flush with the top edge; defaults beside the notch when present, otherwise in the left usable menu-bar strip; rounded bottom corners
- Width scales with the number of running apps (with a maximum)
- **Drag the hamburger** horizontally within the usable strip to reposition the bar (persisted); **click** still opens settings
- Handle click collapses / expands (no auto-expand on hover)
  - **Flush with the strip’s right edge** (the notch when present): `>` / `<`, collapse sideways to the right-side handle
  - **Detached from that edge**: `∧` / `∨`, collapse upward into a thin top strip about one icon wide (typical on non-notch displays)
- Default icon order: Finder → Apps (Launchpad) → other running apps (by name); **drag to reorder**, order is remembered
- Single-click icon: bring to front; if already frontmost with visible windows, hide (Windows taskbar semantics)
- Minimized or window-closed-but-still-running apps can be restored on click (Dock-like reopen)
- **Apps / Launchpad** pinned entry (after Finder by default): click toggles open/close like the Dock; no context menu, no hover peek
- **Unread badge dots**: apps with a Dock badge show a red dot (no count); brief bounce on new messages; requires Accessibility
- Hover any app that has visible windows: title list (`[App Name] Window Title`, including single-window apps)
  - Click a title to focus the window
  - Minimize / maximize (restorable) / close (requires Accessibility)
- **Right-click app icons** (except Apps):
  - Common: Show, Hide, Reveal in Finder, Quit
  - Finder extra: New Finder Window
- **Hamburger menu** (leftmost, expanded only; icon rotates to an X while open):
  - Version (non-interactive)
  - Accessibility status (opens System Settings; system prompt at most once)
  - Show Finder (toggle)
  - Show Apps (toggle)
  - Show window list on hover (toggle)
  - Show unread badge dot (toggle; off stops Dock badge polling)
  - Remember expanded / collapsed (toggle)
  - Launch at Login (toggle; works reliably when running as a `.app`)
  - Quit Taskbar
- Menu-bar utility form: no Dock icon (`LSUIElement` / `.accessory`)
- UI strings follow the system language (Simplified Chinese / English)

## Requirements

- macOS 13+ (Apps entry on macOS 26+ uses `/System/Applications/Apps.app`; older systems fall back to Launchpad.app)
- Xcode / Swift 5.9+ (command-line tools are enough)
- **Accessibility** permission: required for window lists / buttons and unread dots (Dock `AXStatusLabel`)
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

By default this builds a **Universal** app (`arm64` + `x86_64`) in one DMG. Single-arch builds:

```bash
ARCHS=arm64 ./scripts/package-dmg.sh
ARCHS=x86_64 ./scripts/package-dmg.sh
```

Building `x86_64` on Apple Silicon requires Rosetta. Verify with `lipo -archs dist/MacActiveApplications.app/Contents/MacOS/MacActiveApplications`.

Outputs:

- `dist/MacActiveApplications.app`
- `dist/MacActiveApplications-<version>.dmg` (version from `CFBundleShortVersionString` in `Resources/Info.plist`)

Install: open the DMG and drag the app to Applications. On first launch, enable it under:

**System Settings → Privacy & Security → Accessibility**

## Project layout

```text
Sources/MacActiveApplications/
  AppDelegate.swift                 # Entry point
  Geometry/MenuBarGeometry.swift    # Menu-bar usable strip / notch flush geometry
  Model/
    RunningAppsStore.swift          # Running apps, order, activation, context actions
    RunningAppItem.swift
    DockBadgeMonitor.swift          # Dock badge polling → unread dots
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
    TaskbarView.swift               # Icons / handle / drag / badge dots
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
| `handleWidth` / `collapsedWidth` | Sideways-collapsed handle width when flush with the right edge |
| `detachedCollapsedHandleWidth` | Upward-collapsed strip width when detached |
| `collapsedStripHeight` | Top-strip height when collapsed upward |
| `settingsButtonWidth` | Hamburger button width |
| `handleTrailingExtension` | Right-edge flush fine-tune (vs notch when present) |
| `notchVisualCompensationRatio` | Visual flush compensation when a notch is present |
| `peekMinWidth` / `peekMaxWidth` | Hover title-list width range |
| `peekHideDelay` | Delay before hiding peek after hover leave |
| `unreadBadgeDotMin` / `Max` | Unread badge dot size range |

Badge poll interval: `pollInterval` in `Model/DockBadgeMonitor.swift`.

## Permissions

| Capability | Permission |
|------------|------------|
| List running apps, activate / hide / reopen | Usually none |
| Window titles, minimize / maximize / close | **Accessibility** |
| Unread dots (Dock `AXStatusLabel`) | **Accessibility** |
| Apps / Launchpad toggle | Via Dock private notification (`CoreDockSendNotification`); usually no extra permission |
| Finder “New Window” | AppleScript controlling Finder (system may prompt for Automation) |

Without Accessibility, the taskbar itself still works; window title-bar actions and unread dots are disabled or degraded. The system Accessibility prompt appears at most once; afterward use the hamburger menu to open Settings.

## Tech stack

- Swift / AppKit / SwiftUI
- Swift Package Manager (executable)
- Accessibility (`AXUIElement`) + `NSWorkspace` / Apple Event reopen
- Dock: `CoreDockSendNotification("com.apple.launchpad.toggle")`; badges via Dock `AXStatusLabel`

## Known limitations

- When expanded, occupies part of the left menu bar and may cover some system items (by design; drag aside or collapse upward)
- Maximize geometry may need recalibration on unusual multi-monitor layouts
- Apps entry depends on Dock interfaces; behavior may vary on extreme OS versions
- Unread dots require the app’s Dock tile badge and Accessibility; apps removed from the Dock won’t show dots
- Local packaging uses ad-hoc signing; public distribution should use Developer ID + notarization

## Related docs

- [Changelog (Chinese)](docs/更新说明.md)
- [Chinese README](README.md)

## License

Unauthorized reproduction or redistribution is not permitted without the author’s approval.
