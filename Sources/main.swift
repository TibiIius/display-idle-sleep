import AppKit
import CoreGraphics
import Foundation
import IOKit.ps
import IOKit.pwr_mgt

private let appName = "Display Idle Sleep"
private let pollInterval: TimeInterval = 1
private let retryInterval: TimeInterval = 15
private let anyInputEvent = CGEventType(rawValue: UInt32.max)!
private let dateFormatter = ISO8601DateFormatter()

private struct DisplayStatus {
    let idleSeconds: TimeInterval
    let isOnACPower: Bool
    let isDisplayAsleep: Bool
    let isDisplaySleepPrevented: Bool?
}

private enum Settings {
    private static let timeoutKey = "timeoutSeconds"
    private static let enabledKey = "enabled"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            timeoutKey: 60.0,
            enabledKey: true,
        ])
    }

    static var timeout: TimeInterval {
        get {
            let value = UserDefaults.standard.double(forKey: timeoutKey)
            return value.isFinite && value >= 1 ? value : 60
        }
        set {
            UserDefaults.standard.set(max(1, newValue.rounded()), forKey: timeoutKey)
        }
    }

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }
}

private func writeLog(_ message: String) {
    let line = "\(dateFormatter.string(from: Date())) \(appName): \(message)\n"
    FileHandle.standardError.write(Data(line.utf8))
}

private func currentStatus() -> DisplayStatus {
    let idleSeconds = CGEventSource.secondsSinceLastEventType(
        .combinedSessionState,
        eventType: anyInputEvent
    )

    var isOnACPower = false
    if let unmanagedSnapshot = IOPSCopyPowerSourcesInfo() {
        let snapshot = unmanagedSnapshot.takeRetainedValue()
        if let unmanagedSource = IOPSGetProvidingPowerSourceType(snapshot) {
            isOnACPower = unmanagedSource.takeUnretainedValue() as String == "AC Power"
        }
    }

    var unmanagedAssertions: Unmanaged<CFDictionary>?
    let assertionResult = IOPMCopyAssertionsStatus(&unmanagedAssertions)
    let isDisplaySleepPrevented: Bool?
    if assertionResult == kIOReturnSuccess, let unmanagedAssertions {
        let assertions = unmanagedAssertions.takeRetainedValue() as NSDictionary
        let level = assertions["PreventUserIdleDisplaySleep"] as? NSNumber
        isDisplaySleepPrevented = (level?.intValue ?? 0) > 0
    } else {
        isDisplaySleepPrevented = nil
    }

    return DisplayStatus(
        idleSeconds: idleSeconds,
        isOnACPower: isOnACPower,
        isDisplayAsleep: CGDisplayIsAsleep(CGMainDisplayID()) != 0,
        isDisplaySleepPrevented: isDisplaySleepPrevented
    )
}

@discardableResult
private func requestDisplaySleep() -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    process.arguments = ["displaysleepnow"]

    do {
        try process.run()
        process.waitUntilExit()
        return process.terminationReason == .exit && process.terminationStatus == 0
    } catch {
        writeLog("could not run pmset: \(error.localizedDescription)")
        return false
    }
}

private func formatDuration(_ seconds: TimeInterval) -> String {
    let seconds = max(1, seconds.rounded())
    if seconds < 60 {
        return "\(Int(seconds)) second\(seconds == 1 ? "" : "s")"
    }

    let minutes = seconds / 60
    if minutes < 60 {
        if minutes == minutes.rounded() {
            return "\(Int(minutes)) minute\(minutes == 1 ? "" : "s")"
        }
        return String(format: "%.1f minutes", minutes)
    }

    let hours = minutes / 60
    return "\(Int(hours)) hour\(hours == 1 ? "" : "s")"
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let menu = NSMenu()
    private let summaryItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let enabledItem = NSMenuItem(title: "Automatic Display Sleep", action: nil, keyEquivalent: "")
    private let timeoutItem = NSMenuItem(title: "Turn Off After", action: nil, keyEquivalent: "")
    private let timeoutMenu = NSMenu()
    private let presetSeconds: [TimeInterval] = [60, 120, 300, 600, 900, 1800, 3600]
    private var presetItems: [NSMenuItem] = []
    private var customItem: NSMenuItem!
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var lastSleepRequest = Date.distantPast

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        buildMenu()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.menu = menu
        statusItem.button?.imagePosition = .imageOnly

        let timer = Timer(
            timeInterval: pollInterval,
            target: self,
            selector: #selector(tick),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        writeLog("started with a \(formatDuration(Settings.timeout)) AC idle timeout")
        tick()
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshMenu(with: currentStatus())
    }

    private func buildMenu() {
        menu.delegate = self

        summaryItem.isEnabled = false
        menu.addItem(summaryItem)
        menu.addItem(.separator())

        enabledItem.target = self
        enabledItem.action = #selector(toggleEnabled)
        menu.addItem(enabledItem)

        for seconds in presetSeconds {
            let item = NSMenuItem(
                title: formatDuration(seconds),
                action: #selector(selectTimeout(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = NSNumber(value: seconds)
            timeoutMenu.addItem(item)
            presetItems.append(item)
        }

        timeoutMenu.addItem(.separator())
        customItem = NSMenuItem(
            title: "Custom...",
            action: #selector(selectCustomTimeout),
            keyEquivalent: ""
        )
        customItem.target = self
        timeoutMenu.addItem(customItem)
        timeoutItem.submenu = timeoutMenu
        menu.addItem(timeoutItem)

        menu.addItem(.separator())

        let sleepNowItem = NSMenuItem(
            title: "Turn Display Off Now",
            action: #selector(sleepNow),
            keyEquivalent: ""
        )
        sleepNowItem.target = self
        menu.addItem(sleepNowItem)

        let openLogItem = NSMenuItem(
            title: "Open Activity Log",
            action: #selector(openLog),
            keyEquivalent: ""
        )
        openLogItem.target = self
        menu.addItem(openLogItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit \(appName)",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)
    }

    @objc private func tick() {
        autoreleasepool {
            let status = currentStatus()
            refreshMenu(with: status)

            let mayRequestSleep = Settings.isEnabled
                && status.isOnACPower
                && status.idleSeconds >= Settings.timeout
                && !status.isDisplayAsleep
                && status.isDisplaySleepPrevented == false
                && Date().timeIntervalSince(lastSleepRequest) >= retryInterval

            if mayRequestSleep {
                lastSleepRequest = Date()
                writeLog("requesting display sleep after \(Int(status.idleSeconds)) seconds idle")
                if !requestDisplaySleep() {
                    writeLog("pmset displaysleepnow failed")
                }
            }
        }
    }

    private func refreshMenu(with status: DisplayStatus) {
        let summary: String
        let symbol: String

        if !Settings.isEnabled {
            summary = "Automatic display sleep is off"
            symbol = "pause.circle"
        } else if !status.isOnACPower {
            summary = "Waiting for AC power"
            symbol = "battery.50percent"
        } else if status.isDisplaySleepPrevented == true {
            summary = "Paused by another app (for example Caffeine)"
            symbol = "cup.and.saucer.fill"
        } else if status.isDisplaySleepPrevented == nil {
            summary = "Paused: macOS sleep status is unavailable"
            symbol = "exclamationmark.triangle"
        } else if status.isDisplayAsleep {
            summary = "Display is asleep"
            symbol = "display"
        } else {
            let remaining = max(0, Settings.timeout - status.idleSeconds)
            summary = remaining > 0
                ? "Active: display off in \(formatDuration(remaining.rounded(.up)))"
                : "Turning display off..."
            symbol = "display"
        }

        summaryItem.title = summary
        enabledItem.state = Settings.isEnabled ? .on : .off
        timeoutItem.title = "Turn Off After: \(formatDuration(Settings.timeout))"

        var selectedPreset = false
        for item in presetItems {
            let selected = (item.representedObject as? NSNumber)?.doubleValue == Settings.timeout
            item.state = selected ? .on : .off
            selectedPreset = selectedPreset || selected
        }
        customItem.state = selectedPreset ? .off : .on

        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: summary) {
            image.isTemplate = true
            statusItem?.button?.image = image
        }
        statusItem?.button?.toolTip = "\(appName): \(summary)"
    }

    @objc private func toggleEnabled() {
        Settings.isEnabled.toggle()
        writeLog("automatic display sleep \(Settings.isEnabled ? "enabled" : "disabled")")
        refreshMenu(with: currentStatus())
    }

    @objc private func selectTimeout(_ sender: NSMenuItem) {
        guard let seconds = (sender.representedObject as? NSNumber)?.doubleValue else {
            return
        }
        setTimeout(seconds)
    }

    @objc private func selectCustomTimeout() {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Custom display timeout"
        alert.informativeText = "Enter the number of minutes of inactivity before the display turns off."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        input.placeholderString = "Minutes"
        input.stringValue = String(format: "%.2g", Settings.timeout / 60)
        alert.accessoryView = input
        alert.window.initialFirstResponder = input

        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        let formatter = NumberFormatter()
        formatter.locale = .current
        guard let minutes = formatter.number(from: input.stringValue)?.doubleValue,
              minutes.isFinite,
              minutes >= 1.0 / 60.0,
              minutes <= 24 * 60 else {
            showInvalidTimeoutAlert()
            return
        }

        setTimeout(minutes * 60)
    }

    private func setTimeout(_ seconds: TimeInterval) {
        Settings.timeout = seconds
        lastSleepRequest = .distantPast
        writeLog("timeout changed to \(formatDuration(Settings.timeout))")
        refreshMenu(with: currentStatus())
    }

    private func showInvalidTimeoutAlert() {
        let alert = NSAlert()
        alert.messageText = "Invalid timeout"
        alert.informativeText = "Enter a value from 0.02 to 1440 minutes."
        alert.alertStyle = .warning
        alert.runModal()
    }

    @objc private func sleepNow() {
        writeLog("manual display sleep requested")
        if !requestDisplaySleep() {
            writeLog("pmset displaysleepnow failed")
        }
    }

    @objc private func openLog() {
        let logURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/display-idle-sleep.log")
        NSWorkspace.shared.open(logURL)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

private func printUsage() -> Never {
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent
    print("Usage: \(executable) [--status | --sleep-now]")
    exit(64)
}

Settings.registerDefaults()
let arguments = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-psn_") }

if arguments == ["--status"] {
    let status = currentStatus()
    let prevention = status.isDisplaySleepPrevented.map(String.init) ?? "unknown"
    print(
        "enabled=\(Settings.isEnabled) " +
        "power=\(status.isOnACPower ? "AC" : "battery-or-unknown") " +
        "idle_seconds=\(String(format: "%.1f", status.idleSeconds)) " +
        "display_asleep=\(status.isDisplayAsleep) " +
        "sleep_prevented=\(prevention) " +
        "timeout_seconds=\(String(format: "%.1f", Settings.timeout))"
    )
} else if arguments == ["--sleep-now"] {
    exit(requestDisplaySleep() ? 0 : 1)
} else if arguments == ["--help"] || arguments == ["-h"] {
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent
    print("Usage: \(executable) [--status | --sleep-now]")
} else if !arguments.isEmpty {
    printUsage()
} else {
    MainActor.assumeIsolated {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}
