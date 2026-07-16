import Foundation
import CoreGraphics
import IOKit
import AppKit
import ApplicationServices

enum DisplayType: String {
    case builtIn = "内置显示器"
    case virtual = "虚拟显示器"
    case external = "外接显示器"
}

struct DisplayInfo: Identifiable {
    let id: CGDirectDisplayID
    let type: DisplayType
    let name: String
    let resolution: String
    let vendorNumber: UInt32
    let modelNumber: UInt32
    let serialNumber: UInt32
}

@MainActor
class DisplayMonitor: ObservableObject {
    @Published var displays: [DisplayInfo] = []
    @Published var hasPhysicalExternalDisplay: Bool = false
    @Published var autoDockEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(autoDockEnabled, forKey: autoDockDefaultsKey)
            if autoDockEnabled {
                applyDockPolicy()
            }
        }
    }

    @Published var autoInputShortcutEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(autoInputShortcutEnabled, forKey: autoInputShortcutDefaultsKey)
            if autoInputShortcutEnabled {
                applyInputShortcutPolicy()
            }
        }
    }

    /// 远程(仅虚拟屏)时放慢滚动
    @Published var autoSlowScrollEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(autoSlowScrollEnabled, forKey: autoSlowScrollDefaultsKey)
            applyScrollPolicy()
        }
    }

    /// 滚动缩放系数（<1 变慢），默认 0.2
    @Published var scrollSlowFactor: Double = 0.2 {
        didSet {
            UserDefaults.standard.set(scrollSlowFactor, forKey: scrollSlowFactorDefaultsKey)
            scrollFactor = scrollSlowFactor
        }
    }

    // Known virtual display vendor/model pairs
    // BetterDisplay virtual displays use specific IDs
    // Users can add more via the menu
    private var knownVirtualKeys: Set<String> = []

    private let virtualKeysDefaultsKey = "knownVirtualDisplayKeys"
    private let autoDockDefaultsKey = "autoDockEnabled"
    private let autoInputShortcutDefaultsKey = "autoInputShortcutEnabled"
    private let autoSlowScrollDefaultsKey = "autoSlowScrollEnabled"
    private let scrollSlowFactorDefaultsKey = "scrollSlowFactor"

    // MARK: - Scroll tap state (accessed from the C event-tap callback thread)
    nonisolated(unsafe) private var scrollTap: CFMachPort?
    nonisolated(unsafe) private var scrollRunLoopSource: CFRunLoopSource?
    nonisolated(unsafe) private var scrollFactor: Double = 0.2
    // 整数增量缩放后不足 1 的余数累加，避免慢速滚动被取整成 0 而卡住
    nonisolated(unsafe) private var accumLine1 = 0.0
    nonisolated(unsafe) private var accumLine2 = 0.0
    nonisolated(unsafe) private var accumPoint1 = 0.0
    nonisolated(unsafe) private var accumPoint2 = 0.0

    init() {
        loadKnownVirtualKeys()
        autoDockEnabled = UserDefaults.standard.bool(forKey: autoDockDefaultsKey)
        autoInputShortcutEnabled = UserDefaults.standard.bool(forKey: autoInputShortcutDefaultsKey)
        // 未设置过时默认开启（只有纯虚拟屏/远程时才真正激活）
        if UserDefaults.standard.object(forKey: autoSlowScrollDefaultsKey) != nil {
            autoSlowScrollEnabled = UserDefaults.standard.bool(forKey: autoSlowScrollDefaultsKey)
        } else {
            autoSlowScrollEnabled = true
        }
        // scrollSlowFactor 未设置过时保留默认 0.2
        if UserDefaults.standard.object(forKey: scrollSlowFactorDefaultsKey) != nil {
            scrollSlowFactor = UserDefaults.standard.double(forKey: scrollSlowFactorDefaultsKey)
        }
        scrollFactor = scrollSlowFactor
        updateDisplays()
        registerCallback()
    }

    func updateDisplays() {
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: 16)
        var displayCount: UInt32 = 0

        guard CGGetActiveDisplayList(16, &displayIDs, &displayCount) == .success else {
            return
        }

        let activeIDs = Array(displayIDs.prefix(Int(displayCount)))
        var newDisplays: [DisplayInfo] = []

        for displayID in activeIDs {
            let edidName = displayName(for: displayID)
            let type = detectDisplayType(displayID)
            let width = CGDisplayPixelsWide(displayID)
            let height = CGDisplayPixelsHigh(displayID)
            let vendor = CGDisplayVendorNumber(displayID)
            let model = CGDisplayModelNumber(displayID)
            let serial = CGDisplaySerialNumber(displayID)

            let name = edidName ?? "Display \(displayID)"

            let info = DisplayInfo(
                id: displayID,
                type: type,
                name: name,
                resolution: "\(width) x \(height)",
                vendorNumber: vendor,
                modelNumber: model,
                serialNumber: serial
            )
            newDisplays.append(info)
        }

        displays = newDisplays
        hasPhysicalExternalDisplay = newDisplays.contains { $0.type == .external }

        if autoDockEnabled {
            applyDockPolicy()
        }
        if autoInputShortcutEnabled {
            applyInputShortcutPolicy()
        }
        applyScrollPolicy()
    }

    // MARK: - Slow scroll (remote) control

    /// 仅当开启且当前只有虚拟屏（远程中）才放慢滚动
    private func applyScrollPolicy() {
        let shouldSlow = autoSlowScrollEnabled && !hasPhysicalExternalDisplay
        if shouldSlow {
            scrollFactor = scrollSlowFactor
            enableScrollTap()
        } else {
            disableScrollTap()
        }
    }

    private func enableScrollTap() {
        if scrollTap == nil {
            let mask = (1 << CGEventType.scrollWheel.rawValue)
            guard let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: CGEventMask(mask),
                callback: { _, type, event, userInfo in
                    guard let userInfo else { return Unmanaged.passUnretained(event) }
                    let monitor = Unmanaged<DisplayMonitor>.fromOpaque(userInfo).takeUnretainedValue()
                    return monitor.processScroll(type: type, event: event)
                },
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            ) else {
                // 创建失败：几乎都是没授予「辅助功能」权限
                print("scroll tap 创建失败——请在 系统设置>隐私与安全性>辅助功能 勾选 VirtualStatus")
                promptAccessibilityIfNeeded()
                return
            }
            scrollTap = tap
            let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            scrollRunLoopSource = src
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        }
        if let tap = scrollTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    private func disableScrollTap() {
        if let tap = scrollTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        accumLine1 = 0; accumLine2 = 0; accumPoint1 = 0; accumPoint2 = 0
    }

    /// 在事件 tap 回调线程上执行，只能访问 nonisolated 状态
    nonisolated private func processScroll(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // tap 被系统禁用时（超时/用户输入）需要重新启用
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = scrollTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }
        guard type == .scrollWheel else {
            return Unmanaged.passUnretained(event)
        }

        let f = scrollFactor

        // 固定小数增量（Double）：直接缩放
        let fx1 = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
        let fx2 = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: fx1 * f)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: fx2 * f)

        // 像素增量（Int，连续滚动/触控板风格）：带余数累加
        accumPoint1 += Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)) * f
        let op1 = Int64(accumPoint1); accumPoint1 -= Double(op1)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: op1)

        accumPoint2 += Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)) * f
        let op2 = Int64(accumPoint2); accumPoint2 -= Double(op2)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: op2)

        // 行增量（Int，经典滚轮）：带余数累加
        accumLine1 += Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis1)) * f
        let ol1 = Int64(accumLine1); accumLine1 -= Double(ol1)
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: ol1)

        accumLine2 += Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis2)) * f
        let ol2 = Int64(accumLine2); accumLine2 -= Double(ol2)
        event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: ol2)

        return Unmanaged.passUnretained(event)
    }

    private func promptAccessibilityIfNeeded() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    // MARK: - Dock control

    /// If only virtual/built-in displays → show Dock; if any physical external → hide Dock
    private func applyDockPolicy() {
        let shouldHideDock = hasPhysicalExternalDisplay
        setDockAutoHide(shouldHideDock)
    }

    private func setDockAutoHide(_ hide: Bool) {
        let value = hide ? "true" : "false"

        let setTask = Process()
        setTask.launchPath = "/usr/bin/defaults"
        setTask.arguments = ["write", "com.apple.dock", "autohide", "-bool", value]

        do {
            try setTask.run()
            setTask.waitUntilExit()

            // 重启 Dock 使设置生效
            let killTask = Process()
            killTask.launchPath = "/usr/bin/killall"
            killTask.arguments = ["Dock"]
            try killTask.run()
            killTask.waitUntilExit()
        } catch {
            print("Error setting dock autohide: \(error)")
        }
    }

    // MARK: - Input source shortcut control

    /// Physical external → F19; virtual/built-in only → ⌃Space
    private func applyInputShortcutPolicy() {
        if hasPhysicalExternalDisplay {
            // F19: charCode=65535, keyCode=80, modifiers=0
            setInputSourceShortcut(keyCode: 80, charCode: 65535, modifiers: 0)
        } else {
            // ⌃Space: charCode=32, keyCode=49, modifiers=262144
            setInputSourceShortcut(keyCode: 49, charCode: 32, modifiers: 262144)
        }
    }

    private func setInputSourceShortcut(keyCode: Int, charCode: Int, modifiers: Int) {
        let plistValue = """
        <dict>
          <key>enabled</key><true/>
          <key>value</key><dict>
            <key>type</key><string>standard</string>
            <key>parameters</key><array>
              <integer>\(charCode)</integer>
              <integer>\(keyCode)</integer>
              <integer>\(modifiers)</integer>
            </array>
          </dict>
        </dict>
        """

        let writeTask = Process()
        writeTask.launchPath = "/usr/bin/defaults"
        writeTask.arguments = ["write", "com.apple.symbolichotkeys", "AppleSymbolicHotKeys", "-dict-add", "60", plistValue]

        do {
            try writeTask.run()
            writeTask.waitUntilExit()

            // 激活设置使其立即生效
            let activateTask = Process()
            activateTask.launchPath = "/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings"
            activateTask.arguments = ["-u"]
            try activateTask.run()
            activateTask.waitUntilExit()
        } catch {
            print("Error setting input source shortcut: \(error)")
        }
    }

    // MARK: - Virtual display management

    /// Mark a display as virtual (persisted)
    func markAsVirtual(_ display: DisplayInfo) {
        let key = vendorModelKey(vendor: display.vendorNumber, model: display.modelNumber)
        knownVirtualKeys.insert(key)
        saveKnownVirtualKeys()
        updateDisplays()
    }

    /// Unmark a display as virtual (persisted)
    func unmarkAsVirtual(_ display: DisplayInfo) {
        let key = vendorModelKey(vendor: display.vendorNumber, model: display.modelNumber)
        knownVirtualKeys.remove(key)
        saveKnownVirtualKeys()
        updateDisplays()
    }

    private func vendorModelKey(vendor: UInt32, model: UInt32) -> String {
        "\(vendor)-\(model)"
    }

    private func loadKnownVirtualKeys() {
        if let saved = UserDefaults.standard.stringArray(forKey: virtualKeysDefaultsKey) {
            knownVirtualKeys = Set(saved)
        }
    }

    private func saveKnownVirtualKeys() {
        UserDefaults.standard.set(Array(knownVirtualKeys), forKey: virtualKeysDefaultsKey)
    }

    // MARK: - Detection

    private func detectDisplayType(_ displayID: CGDirectDisplayID) -> DisplayType {
        // 1. Built-in display (MacBook screen)
        if CGDisplayIsBuiltin(displayID) != 0 {
            return .builtIn
        }

        let vendor = CGDisplayVendorNumber(displayID)
        let model = CGDisplayModelNumber(displayID)

        // 2. Check user-marked virtual displays
        if knownVirtualKeys.contains(vendorModelKey(vendor: vendor, model: model)) {
            return .virtual
        }

        // 3. Check for well-known BetterDisplay dummy/virtual display patterns
        //    BetterDisplay virtual displays typically have vendor 0 and model 0,
        //    or vendor matching BetterDisplay's registered IDs
        if isLikelyVirtualDisplay(vendor: vendor, model: model, serial: CGDisplaySerialNumber(displayID)) {
            return .virtual
        }

        // 4. Default: treat as external (physical) - safer assumption
        return .external
    }

    // BetterDisplay 给它创建的虚拟屏统一使用厂商 ID 2198 (0x896)。
    // 已从 BetterDisplay 偏好设置 systemVirtual=1 的记录核实：
    // Virtual 16:10 = vendor 2198；真实体屏 vendor 均不为 2198
    // (Mi 245 HF=25001, ASUS VX24G26J=23139, Generic Display=2533, 内置=1552)。
    private static let betterDisplayVendorID: UInt32 = 2198

    private func isLikelyVirtualDisplay(vendor: UInt32, model: UInt32, serial: UInt32) -> Bool {
        // BetterDisplay 虚拟屏（任意 model，含以后新建的）
        if vendor == Self.betterDisplayVendorID {
            return true
        }

        // Vendor 0, model 0 is almost certainly virtual
        if vendor == 0 && model == 0 {
            return true
        }

        // CGVirtualDisplay creates displays with vendor 0xFFFFFFFF in some cases
        if vendor == 0xFFFFFFFF {
            return true
        }

        return false
    }

    private func displayName(for displayID: CGDirectDisplayID) -> String? {
        var iter: io_iterator_t = 0
        let matching = IOServiceMatching("IODisplayConnect")

        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iter) }

        var service: io_object_t = IOIteratorNext(iter)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iter)
            }

            if let info = IODisplayCreateInfoDictionary(service, IOOptionBits(kIODisplayOnlyPreferredName))?.takeRetainedValue() as? [String: Any] {
                let vid = info[kDisplayVendorID] as? UInt32 ?? 0
                let pid = info[kDisplayProductID] as? UInt32 ?? 0

                if vid == CGDisplayVendorNumber(displayID) && pid == CGDisplayModelNumber(displayID) {
                    if let names = info[kDisplayProductName] as? [String: String],
                       let name = names.values.first {
                        return name
                    }
                }
            }
        }

        return nil
    }

    private func registerCallback() {
        CGDisplayRegisterReconfigurationCallback({ displayID, flags, userInfo in
            guard let userInfo = userInfo else { return }
            let monitor = Unmanaged<DisplayMonitor>.fromOpaque(userInfo).takeUnretainedValue()
            if flags.contains(.beginConfigurationFlag) {
                return
            }
            DispatchQueue.main.async {
                monitor.updateDisplays()
            }
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    deinit {
        CGDisplayRemoveReconfigurationCallback({ displayID, flags, userInfo in
        }, Unmanaged.passUnretained(self).toOpaque())
    }
}
