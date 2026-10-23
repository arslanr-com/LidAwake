// LidAwake: a menu bar app that keeps a Mac awake, including with the lid
// closed, by toggling `pmset -a disablesleep 1/0`.
//
// The admin password is needed only once. On first use the app installs
// /etc/sudoers.d/lidawake, which lets the current user run exactly two
// commands without a password:
//   /usr/bin/pmset -a disablesleep 0
//   /usr/bin/pmset -a disablesleep 1
// The rule can be removed from the menu ("Remove Passwordless Access").
//
// With sleep disabled macOS no longer turns the built-in display off when the
// lid closes, so the app watches the lid and runs `pmset displaysleepnow`.

import AppKit
import IOKit
import IOKit.ps
import ServiceManagement

let sudoersPath = "/etc/sudoers.d/lidawake"
let batteryGuardKey = "batteryGuardEnabled"
let lidDisplayOffKey = "lidDisplayOffEnabled"
let batteryGuardLevel = 15

@discardableResult
func run(_ path: String, _ args: [String]) -> (status: Int32, output: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return (-1, error.localizedDescription) }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

/// Current SleepDisabled value from `pmset -g`.
func readSleepDisabled() -> Bool {
    let out = run("/usr/bin/pmset", ["-g"]).output
    for line in out.split(separator: "\n") where line.contains("SleepDisabled") {
        return line.split(whereSeparator: { $0 == " " || $0 == "\t" }).last == "1"
    }
    return false
}

/// (charge percent, running on battery) or nil when there is no battery.
func batteryState() -> (percent: Int, onBattery: Bool)? {
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
    else { return nil }
    for source in list {
        guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
              let cur = d[kIOPSCurrentCapacityKey] as? Int,
              let max = d[kIOPSMaxCapacityKey] as? Int, max > 0
        else { continue }
        let onBattery = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSBatteryPowerValue
        return (cur * 100 / max, onBattery)
    }
    return nil
}

/// AppleClamshellState from IOPMrootDomain: true when the lid is closed.
func isLidClosed() -> Bool {
    let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    guard root != 0 else { return false }
    defer { IOObjectRelease(root) }
    let value = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
        .takeRetainedValue()
    return (value as? Bool) ?? false
}

/// Awake state of online displays, split into built-in and external.
func displaysAwake() -> (builtIn: Bool, external: Bool) {
    var count: UInt32 = 0
    CGGetOnlineDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetOnlineDisplayList(count, &ids, &count)
    var result = (builtIn: false, external: false)
    for id in ids where CGDisplayIsAsleep(id) == 0 {
        if CGDisplayIsBuiltin(id) != 0 { result.builtIn = true } else { result.external = true }
    }
    return result
}

enum AdminResult { case ok, cancelled, failed(String) }

/// Runs a shell command as root via the system password / Touch ID prompt.
func runAsAdmin(_ command: String, prompt: String) -> AdminResult {
    let escaped = command
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    let source = "do shell script \"\(escaped)\" with prompt \"\(prompt)\" with administrator privileges"
    var error: NSDictionary?
    NSAppleScript(source: source)?.executeAndReturnError(&error)
    guard let error else { return .ok }
    if (error[NSAppleScript.errorNumber] as? Int) == -128 { return .cancelled }
    return .failed(error[NSAppleScript.errorMessage] as? String ?? "\(error)")
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    var isOn = false
    var endDate: Date?
    var tickTimer: Timer?
    var lidTimer: Timer?
    var lastDisplaySleep = Date.distantPast

    var batteryGuard: Bool {
        get { UserDefaults.standard.object(forKey: batteryGuardKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: batteryGuardKey) }
    }

    var lidDisplayOff: Bool {
        get { UserDefaults.standard.object(forKey: lidDisplayOffKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: lidDisplayOffKey) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        menu.delegate = self
        statusItem.menu = menu
        isOn = readSleepDisabled()
        updateIcon()
        tickTimer = Timer.scheduledTimer(timeInterval: 10, target: self,
                                         selector: #selector(tick), userInfo: nil, repeats: true)
        lidTimer = Timer.scheduledTimer(timeInterval: 1.5, target: self,
                                        selector: #selector(lidTick), userInfo: nil, repeats: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        if isOn { _ = setSleepDisabled(false) }
    }

    // MARK: - State

    @objc func tick() {
        let actual = readSleepDisabled()
        if actual != isOn {          // changed outside the app (Terminal etc.)
            isOn = actual
            if !actual { endDate = nil }
            updateIcon()
        }
        guard isOn else { return }
        if let end = endDate, Date() >= end {
            turn(false)
        } else if batteryGuard, let b = batteryState(), b.onBattery, b.percent < batteryGuardLevel {
            turn(false)
        }
    }

    /// Turns the built-in display off while the lid is closed. Skipped when an
    /// external display is in use, since displaysleepnow would blank it too.
    @objc func lidTick() {
        guard isOn, lidDisplayOff, isLidClosed() else { return }
        let awake = displaysAwake()
        guard awake.builtIn, !awake.external,
              Date().timeIntervalSince(lastDisplaySleep) > 10 else { return }
        lastDisplaySleep = Date()
        run("/usr/bin/pmset", ["displaysleepnow"])
    }

    func turn(_ on: Bool, for duration: TimeInterval? = nil) {
        guard setSleepDisabled(on) else { return }
        isOn = readSleepDisabled()
        endDate = (on && isOn) ? duration.map { Date().addingTimeInterval($0) } : nil
        updateIcon()
    }

    /// Switches the mode through passwordless sudo; installs the sudoers rule on first use.
    func setSleepDisabled(_ on: Bool) -> Bool {
        let args = ["-n", "/usr/bin/pmset", "-a", "disablesleep", on ? "1" : "0"]
        if run("/usr/bin/sudo", args).status == 0 { return true }
        guard installSudoersRule() else { return false }
        let retry = run("/usr/bin/sudo", args)
        if retry.status != 0 { showError("Could not switch the mode:\n\(retry.output)") }
        return retry.status == 0
    }

    func installSudoersRule() -> Bool {
        let rule = "\(NSUserName()) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1\n"
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("lidawake-sudoers-\(UUID().uuidString)")
        do { try rule.write(to: tmp, atomically: true, encoding: .utf8) } catch {
            showError("Could not create a temporary file: \(error.localizedDescription)")
            return false
        }
        defer { try? FileManager.default.removeItem(at: tmp) }
        let cmd = "/usr/sbin/visudo -cf '\(tmp.path)' && /usr/bin/install -m 0440 -o root -g wheel '\(tmp.path)' \(sudoersPath)"
        switch runAsAdmin(cmd, prompt: "LidAwake needs your password once so it can switch sleep mode without asking again.") {
        case .ok: return true
        case .cancelled: return false
        case .failed(let msg): showError("Could not set up passwordless access:\n\(msg)"); return false
        }
    }

    // MARK: - Appearance

    func updateIcon() {
        let name = isOn ? "cup.and.saucer.fill" : "moon.zzz"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: isOn ? "LidAwake: on" : "LidAwake: off")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = isOn ? "LidAwake: your Mac will stay awake" : "LidAwake: normal sleep"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        isOn = readSleepDisabled()
        updateIcon()
        menu.removeAllItems()

        menu.addItem(disabledItem(statusText()))
        if isOn, let b = batteryState(), b.onBattery {
            menu.addItem(disabledItem("On battery: \(b.percent)%"))
        }
        menu.addItem(.separator())

        menu.addItem(item(isOn ? "Turn Off" : "Turn On", #selector(toggle), key: "t"))

        let timed = NSMenuItem(title: isOn ? "Extend For" : "Turn On For", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for (title, minutes) in [("30 Minutes", 30), ("1 Hour", 60), ("2 Hours", 120), ("4 Hours", 240), ("8 Hours", 480)] {
            let it = item(title, #selector(turnOnTimed(_:)))
            it.tag = minutes
            sub.addItem(it)
        }
        if isOn && endDate != nil {
            sub.addItem(.separator())
            sub.addItem(item("Indefinitely", #selector(clearTimer)))
        }
        timed.submenu = sub
        menu.addItem(timed)
        menu.addItem(.separator())

        let lidItem = item("Turn Off Display When Lid Closes", #selector(toggleLidDisplayOff))
        lidItem.state = lidDisplayOff ? .on : .off
        menu.addItem(lidItem)

        let guardItem = item("Turn Off Below \(batteryGuardLevel)% Battery", #selector(toggleBatteryGuard))
        guardItem.state = batteryGuard ? .on : .off
        menu.addItem(guardItem)

        let login = item("Launch at Login", #selector(toggleLoginItem))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        if FileManager.default.fileExists(atPath: sudoersPath) {
            menu.addItem(item("Remove Passwordless Access", #selector(removeSudoersRule)))
        }
        menu.addItem(.separator())
        menu.addItem(item(isOn ? "Quit (Turns Off)" : "Quit", #selector(quit), key: "q"))
    }

    func statusText() -> String {
        guard isOn else { return "Normal sleep" }
        guard let end = endDate else { return "Staying awake until turned off" }
        let left = max(0, Int(end.timeIntervalSinceNow / 60))
        let f = DateFormatter()
        f.timeStyle = .short
        let leftText = left >= 60 ? "\(left / 60) h \(left % 60) min" : "\(left) min"
        return "Awake until \(f.string(from: end)) (\(leftText) left)"
    }

    func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
        it.target = self
        return it
    }

    func disabledItem(_ title: String) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        it.isEnabled = false
        return it
    }

    // MARK: - Menu actions

    @objc func toggle() { turn(!isOn) }

    @objc func turnOnTimed(_ sender: NSMenuItem) {
        turn(true, for: TimeInterval(sender.tag * 60))
    }

    @objc func clearTimer() { endDate = nil }

    @objc func toggleLidDisplayOff() { lidDisplayOff.toggle() }

    @objc func toggleBatteryGuard() { batteryGuard.toggle() }

    @objc func toggleLoginItem() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
                if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            }
        } catch {
            showError("Could not change Launch at Login: \(error.localizedDescription)")
        }
    }

    @objc func removeSudoersRule() {
        if isOn { turn(false) }
        if case .failed(let msg) = runAsAdmin("/bin/rm -f \(sudoersPath)", prompt: "LidAwake will remove passwordless access.") {
            showError(msg)
        }
    }

    @objc func quit() { NSApp.terminate(nil) }

    func showError(_ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "LidAwake"
        alert.informativeText = text
        alert.alertStyle = .warning
        alert.runModal()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
