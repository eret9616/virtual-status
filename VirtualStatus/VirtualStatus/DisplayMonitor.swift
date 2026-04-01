import Foundation
import CoreGraphics
import IOKit
import AppKit

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

    @Published var autoLinearMouseEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(autoLinearMouseEnabled, forKey: autoLinearMouseDefaultsKey)
            if autoLinearMouseEnabled {
                applyLinearMousePolicy()
            }
        }
    }

    // Known virtual display vendor/model pairs
    // BetterDisplay virtual displays use specific IDs
    // Users can add more via the menu
    private var knownVirtualKeys: Set<String> = []

    private let virtualKeysDefaultsKey = "knownVirtualDisplayKeys"
    private let autoDockDefaultsKey = "autoDockEnabled"
    private let autoInputShortcutDefaultsKey = "autoInputShortcutEnabled"
    private let autoLinearMouseDefaultsKey = "autoLinearMouseEnabled"

    init() {
        loadKnownVirtualKeys()
        autoDockEnabled = UserDefaults.standard.bool(forKey: autoDockDefaultsKey)
        autoInputShortcutEnabled = UserDefaults.standard.bool(forKey: autoInputShortcutDefaultsKey)
        autoLinearMouseEnabled = UserDefaults.standard.bool(forKey: autoLinearMouseDefaultsKey)
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
            let type = detectDisplayType(displayID)
            let width = CGDisplayPixelsWide(displayID)
            let height = CGDisplayPixelsHigh(displayID)
            let vendor = CGDisplayVendorNumber(displayID)
            let model = CGDisplayModelNumber(displayID)
            let serial = CGDisplaySerialNumber(displayID)

            let name = displayName(for: displayID)
                ?? "Display \(displayID)"

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
        if autoLinearMouseEnabled {
            applyLinearMousePolicy()
        }
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

    // MARK: - LinearMouse control

    private func applyLinearMousePolicy() {
        let isRunning = isLinearMouseRunning()
        if hasPhysicalExternalDisplay {
            if !isRunning {
                launchLinearMouse()
            }
        } else {
            if isRunning {
                quitLinearMouse()
            }
        }
    }

    private func isLinearMouseRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.lujjjh.LinearMouse" }
    }

    private func launchLinearMouse() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.lujjjh.LinearMouse") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if let error = error {
                    print("Error launching LinearMouse: \(error)")
                }
            }
        }
    }

    private func quitLinearMouse() {
        for app in NSWorkspace.shared.runningApplications where app.bundleIdentifier == "com.lujjjh.LinearMouse" {
            app.terminate()
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

    private func isLikelyVirtualDisplay(vendor: UInt32, model: UInt32, serial: UInt32) -> Bool {
        // Vendor 0, model 0 is almost certainly virtual
        if vendor == 0 && model == 0 {
            return true
        }

        // CGVirtualDisplay (used by BetterDisplay) creates displays with
        // vendor 0xFFFFFFFF or 0x0 in some cases
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
