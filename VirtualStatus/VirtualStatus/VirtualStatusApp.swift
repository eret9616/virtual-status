import SwiftUI

@main
struct VirtualStatusApp: App {
    @StateObject private var monitor = DisplayMonitor()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(monitor: monitor)
        } label: {
            MenuBarLabel(monitor: monitor)
        }
    }
}

struct MenuBarLabel: View {
    @ObservedObject var monitor: DisplayMonitor

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: monitor.hasPhysicalExternalDisplay
                  ? "checkmark.circle" : "exclamationmark.triangle")
            Text(monitor.hasPhysicalExternalDisplay ? "实体" : "虚拟")
                .font(.caption)
        }
    }
}

struct MenuContentView: View {
    @ObservedObject var monitor: DisplayMonitor

    var body: some View {
        // Status header
        if monitor.hasPhysicalExternalDisplay {
            Label("✅ 实体显示器活跃", systemImage: "checkmark.circle.fill")
        } else {
            Label("⚠️ 当前仅虚拟/内置显示器", systemImage: "exclamationmark.triangle.fill")
        }

        Divider()

        Text("当前显示器列表:")
            .font(.caption)
            .foregroundColor(.secondary)

        // Display list with toggle buttons
        ForEach(monitor.displays) { display in
            Menu {
                // Show details
                Text("Vendor: 0x\(String(display.vendorNumber, radix: 16, uppercase: true))")
                Text("Model: 0x\(String(display.modelNumber, radix: 16, uppercase: true))")
                Text("Serial: \(display.serialNumber)")
                Text("分辨率: \(display.resolution)")

                Divider()

                if display.type == .builtIn {
                    Text("内置显示器（不可更改）")
                } else if display.type == .virtual {
                    Button("标记为实体显示器") {
                        monitor.unmarkAsVirtual(display)
                    }
                } else {
                    Button("标记为虚拟显示器") {
                        monitor.markAsVirtual(display)
                    }
                }
            } label: {
                HStack {
                    Image(systemName: iconForType(display.type))
                    Text(display.name)
                    Spacer()
                    Text(display.type.rawValue)
                        .font(.caption)
                        .foregroundColor(colorForType(display.type))
                }
            }
        }

        if monitor.displays.isEmpty {
            Text("未检测到显示器")
                .foregroundColor(.secondary)
        }

        Divider()

        Toggle("虚拟显示器时显示 Dock", isOn: $monitor.autoDockEnabled)
            .help("开启后：仅虚拟/内置显示器时显示 Dock，有实体显示器时自动隐藏 Dock")

        Toggle("自动切换输入法快捷键", isOn: $monitor.autoInputShortcutEnabled)
            .help("开启后：实体显示器时用 F19，虚拟显示器时用 ⌃Space")

        Toggle("远程时放慢滚动", isOn: $monitor.autoSlowScrollEnabled)
            .help("开启后：仅虚拟屏（远程）时按下方系数放慢滚动；接实体屏时不影响。需在 系统设置>隐私与安全性>辅助功能 授权")

        if monitor.autoSlowScrollEnabled {
            Picker("滚动速度", selection: $monitor.scrollSlowFactor) {
                Text("很慢 (0.2)").tag(0.2)
                Text("慢 (0.3)").tag(0.3)
                Text("稍慢 (0.5)").tag(0.5)
            }
        }

        Divider()

        Button("刷新") {
            monitor.updateDisplays()
        }
        .keyboardShortcut("r")

        Button("退出") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private func iconForType(_ type: DisplayType) -> String {
        switch type {
        case .builtIn: return "laptopcomputer"
        case .virtual: return "display"
        case .external: return "display.trianglebadge.exclamationmark"
        }
    }

    private func colorForType(_ type: DisplayType) -> Color {
        switch type {
        case .builtIn: return .blue
        case .virtual: return .green
        case .external: return .orange
        }
    }
}
