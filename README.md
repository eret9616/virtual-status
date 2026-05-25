# VirtualStatus

> macOS 菜单栏小工具:区分**实体显示器**与**虚拟显示器**,并根据当前是否接入实体外接屏,自动切换 Dock、输入法快捷键和 LinearMouse 的行为。

适合 BetterDisplay / 虚拟显示器重度用户:既要在「带外接屏」时享受 LinearMouse + ⌃F19 输入法快捷键 + 永不挡视线的 Dock,也要在「只剩内置屏」时回到 macOS 原生 ⌃Space + 始终可见的 Dock + 关掉鼠标加速。

---

## 功能

- **菜单栏图标实时反映当前状态**
  - ✅ 实体 — 至少有一台物理外接显示器
  - ⚠️ 虚拟 — 当前只有内置/虚拟显示器(例如 BetterDisplay dummy display)
- **手动标记虚拟显示器**:点开菜单 → 选中某台显示器 → 「标记为虚拟显示器」。基于 vendor + model 持久化(`UserDefaults`)。
- **自动隐藏 Dock**:接入实体屏时执行 `defaults write com.apple.dock autohide -bool true && killall Dock`,只剩虚拟/内置屏时再打开。
- **自动切换输入法快捷键**
  - 实体屏 → F19 (`keyCode=80`)
  - 虚拟/内置 → ⌃Space (`keyCode=49, modifiers=262144`)
  - 通过写入 `com.apple.symbolichotkeys` 的第 60 号热键并调用 `activateSettings -u` 立即生效。
- **自动开关 LinearMouse**:实体屏 → 启动 `com.lujjjh.LinearMouse`;虚拟屏 → `terminate()` 之。
- **显示器热插拔回调**:通过 `CGDisplayRegisterReconfigurationCallback` 监听变化,无需轮询。

## 自动识别虚拟显示器

满足任一条件即视为虚拟:

1. 用户手动标记过的 `vendor-model` 对
2. `vendor == 0 && model == 0`(BetterDisplay 等 dummy 显示器的典型特征)
3. `vendor == 0xFFFFFFFF`(`CGVirtualDisplay` 在部分情况下的取值)

`CGDisplayIsBuiltin` 返回 true 的一律视为内置。其余视为实体外接。

## 系统要求

- macOS 13.0+
- Xcode 15.0+ / Swift 5

## 构建与运行

```bash
git clone https://github.com/eret9616/virtual-status.git
cd virtual-status/VirtualStatus
open VirtualStatus.xcodeproj
```

在 Xcode 中按 ⌘R 运行即可,App 会以 `LSUIElement` 形式驻留菜单栏(不在 Dock 显示)。

要打包成独立 App:Product → Archive → Distribute App → Copy App,把 `VirtualStatus.app` 放进 `/Applications` 然后通过「系统设置 → 通用 → 登录项」开机自启。

## 文件结构

```
VirtualStatus/
├── VirtualStatusApp.swift   # SwiftUI 入口 + MenuBarExtra UI
└── DisplayMonitor.swift     # 显示器探测、状态机、三个自动化策略
```

## 注意事项

- 修改 Dock / 输入法快捷键是写入用户的 `defaults`,App 不需要任何特殊权限,但**首次切换输入法快捷键后**,系统设置里相应条目会显示为新值。
- LinearMouse 控制依赖其 bundle ID `com.lujjjh.LinearMouse`,如未安装该 app,开关无效但不会报错。
- 该 App 不修改任何显示器配置,只是「观察 + 触发系统设置变更」。

## License

MIT — 个人项目,随便用。
