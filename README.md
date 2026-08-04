# Mac Active Applications

macOS 刘海左侧的 Windows 风格任务栏：覆盖菜单栏左侧区域，展示当前运行中的应用，支持切换、恢复最小化/无窗口应用，以及多窗口悬停预览与窗口操作。

## 功能

- 吸附在刘海**左侧**，高度与菜单栏一致，默认展开
- 宽度随运行中应用数量自适应（有上限）
- 点击把手收起 / 展开（无 hover 自动展开）
- 单击图标：切换到前台；若已是前台且有可见窗口则隐藏（Windows 任务栏语义）
- 最小化或关窗未退出时，点击可恢复到前台（Dock 式 reopen）
- 多窗口应用悬停：弹出标题栏列表（`[应用名] 窗口标题`）
  - 点击标题聚焦窗口
  - 最小化 / 最大化（可还原）/ 关闭（需辅助功能权限）
- 菜单栏工具形态：不占用 Dock（`LSUIElement` / `.accessory`）

## 环境要求

- macOS 13+
- Xcode / Swift 5.9+（命令行工具即可）
- **辅助功能**权限：多窗口列表与窗口按钮操作需要

## 快速运行

```bash
cd MacActiveApplications
swift run
```

或用 Xcode 打开：

```bash
open Package.swift
```

选择 scheme `MacActiveApplications`，目标 My Mac，Run。

## 打包 DMG

```bash
./scripts/package-dmg.sh
```

产物：

- `dist/MacActiveApplications.app`
- `dist/MacActiveApplications-1.0.0.dmg`

安装：打开 DMG，将 App 拖入「应用程序」。首次使用请在：

**系统设置 → 隐私与安全性 → 辅助功能**

中勾选本应用。

## 项目结构

```text
Sources/MacActiveApplications/
  AppDelegate.swift              # 入口
  Geometry/MenuBarGeometry.swift # 刘海吸附与菜单栏几何
  Model/
    RunningAppsStore.swift       # 运行中应用列表与激活逻辑
    RunningAppItem.swift
    AppWindowService.swift       # 窗口枚举 / 最小/最大/关闭（Accessibility）
  Panel/
    MenuBarPanel.swift           # 任务栏面板
    WindowPeekController.swift   # 多窗口悬停弹出层
  UI/
    TaskbarView.swift
    TaskbarStyle.swift           # 尺寸与样式常量
Resources/
  Info.plist
  AppIcon.icns                   # 打包用图标
  AppIcon.icon/                  # Icon Composer 源（可选）
scripts/
  package-dmg.sh                 # Release 编译 → .app → DMG
```

## 常用配置

在 `UI/TaskbarStyle.swift` 中可调：

| 常量 | 含义 |
|------|------|
| `handleWidth` / `collapsedWidth` | 收起把手宽度 |
| `handleTrailingExtension` | 右缘相对刘海的微调 |
| `notchVisualCompensationRatio` | 刘海贴合动态补偿比例 |
| `peekMinWidth` / `peekMaxWidth` | 悬停标题栏宽度范围 |
| `peekHideDelay` | 悬停离开后收起延迟 |

## 权限说明

| 能力 | 权限 |
|------|------|
| 列出运行中应用、激活 / hide / reopen | 一般不需要特殊权限 |
| 多窗口标题、最小/最大/关闭 | **辅助功能（Accessibility）** |

未授权辅助功能时，任务栏主体仍可用；窗口标题栏按钮会不可用或降级。

## 技术栈

- Swift / AppKit / SwiftUI
- Swift Package Manager（executable）
- Accessibility (`AXUIElement`) + `NSWorkspace` / Apple Event reopen

## 已知限制

- 会遮挡菜单栏左侧部分系统菜单项（产品设计如此）
- 最大化几何在极端多屏布局下可能需再校准
- 当前为本地工具打包（ad-hoc 签名）；对外分发建议 Developer ID + 公证

## 许可

按需自行补充。
