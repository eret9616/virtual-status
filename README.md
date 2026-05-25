# VirtualStatus

macOS 菜单栏小工具,区分**实体显示器**和**虚拟显示器**(比如 BetterDisplay 的 dummy display),并根据当前接的是哪种屏自动切换一些设置。

## 能做什么

菜单栏图标显示当前状态:✅ 实体 / ⚠️ 虚拟。

可选的三个自动化开关:

- **Dock**:接实体屏自动隐藏,只剩虚拟屏自动显示
- **输入法快捷键**:实体屏用 F19,虚拟屏用 ⌃Space
- **LinearMouse**:接实体屏启动,只剩虚拟屏退出

识别不准时,可以在菜单里手动「标记为虚拟显示器」,会记住。

## 使用

```bash
git clone https://github.com/eret9616/virtual-status.git
open virtual-status/VirtualStatus/VirtualStatus.xcodeproj
```

Xcode ⌘R 运行,App 驻留菜单栏。要常驻就 Archive 后丢 `/Applications`,加到登录项。

需要 macOS 13+。

## License

MIT
