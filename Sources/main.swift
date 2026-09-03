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

private func currentInputEventCount() -> UInt32 {
    CGEventSource.counterForEventType(.combinedSessionState, eventType: anyInputEvent)
}

private struct DisplayStatus {
    let idleSeconds: TimeInterval
    let isOnACPower: Bool
    let isDisplayAsleep: Bool
    let isDisplaySleepPrevented: Bool?
}

private enum Settings {
    private static let timeoutKey = "timeoutSeconds"
    private static let enabledKey = "enabled"
    private static let blackImageModeKey = "blackImageMode"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            timeoutKey: 60.0,
            enabledKey: true,
            blackImageModeKey: false,
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

    static var usesBlackImageMode: Bool {
        get { UserDefaults.standard.bool(forKey: blackImageModeKey) }
        set { UserDefaults.standard.set(newValue, forKey: blackImageModeKey) }
    }
}

@MainActor
private final class BlackoutWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
private final class BlackoutView: NSView {
    static let transparentCursor: NSCursor = {
        let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 1,
            pixelsHigh: 1,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 4,
            bitsPerPixel: 32
        )!
        representation.bitmapData?.initialize(repeating: 0, count: 4)
        let image = NSImage(size: NSSize(width: 1, height: 1))
        image.addRepresentation(representation)
        return NSCursor(image: image, hotSpot: .zero)
    }()

    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: Self.transparentCursor)
    }
}

@MainActor
private final class DisplayBlanker {
    private struct GammaTable {
        var red: [CGGammaValue]
        var green: [CGGammaValue]
        var blue: [CGGammaValue]
        let count: UInt32
    }

    private var windows: [CGDirectDisplayID: NSWindow] = [:]
    private var gammaTables: [CGDirectDisplayID: GammaTable] = [:]
    private var cursorIsHidden = false
    private var coreGraphicsCursorIsHidden = false
    private var displaysAreCaptured = false
    private var previousApplication: NSRunningApplication?
    private var watchdog: Process?
    private var watchdogInput: FileHandle?

    var isBlanking: Bool { displaysAreCaptured || !windows.isEmpty || !gammaTables.isEmpty }

    func show() {
        let isStarting = windows.isEmpty
        if isStarting {
            let currentApplication = NSRunningApplication.current
            let frontmostApplication = NSWorkspace.shared.frontmostApplication
            if frontmostApplication?.processIdentifier != currentApplication.processIdentifier {
                previousApplication = frontmostApplication
            }
        }

        let mayChangeOutput = watchdogInput != nil || startWatchdog()
        if isStarting {
            let result = CGCaptureAllDisplays()
            if result == .success {
                displaysAreCaptured = true
            } else {
                writeLog("could not capture displays for black image: \(result.rawValue)")
            }
        }

        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                continue
            }

            let displayID = CGDirectDisplayID(number.uint32Value)
            if mayChangeOutput, gammaTables[displayID] == nil {
                blackOutput(of: displayID)
            }

            guard windows[displayID] == nil else { continue }

            // This initializer interprets content coordinates relative to `screen`.
            let frame = NSRect(origin: .zero, size: screen.frame.size)
            let window = BlackoutWindow(
                contentRect: frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false,
                screen: screen
            )
            let view = BlackoutView(frame: frame)
            view.wantsLayer = true
            view.layer?.backgroundColor = NSColor.black.cgColor
            window.contentView = view
            window.backgroundColor = .black
            window.isOpaque = true
            window.hasShadow = false
            // Stay above ordinary app content; secure indicators can bypass app windows.
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.acceptsMouseMovedEvents = true
            window.ignoresMouseEvents = false
            window.isReleasedWhenClosed = false
            window.orderFrontRegardless()
            window.invalidateCursorRects(for: view)
            windows[displayID] = window
        }

        if !windows.isEmpty, !cursorIsHidden {
            NSApp.activate(ignoringOtherApps: true)
            windows.values.first?.makeKey()
            NSCursor.setHiddenUntilMouseMoves(true)
            BlackoutView.transparentCursor.set()
            cursorIsHidden = true
            if CGDisplayHideCursor(kCGNullDirectDisplay) == .success {
                coreGraphicsCursorIsHidden = true
            }
        }
    }

    func clear() {
        var restoredEveryDisplay = true
        for (displayID, var table) in gammaTables {
            let result = CGSetDisplayTransferByTable(
                displayID,
                table.count,
                &table.red,
                &table.green,
                &table.blue
            )
            if result != .success {
                restoredEveryDisplay = false
                writeLog("could not restore output table for display \(displayID): \(result.rawValue)")
            }
        }
        gammaTables.removeAll()

        if displaysAreCaptured {
            let result = CGReleaseAllDisplays()
            if result != .success {
                writeLog("could not release captured displays: \(result.rawValue)")
            }
            displaysAreCaptured = false
        }

        for window in windows.values {
            window.orderOut(nil)
        }
        windows.removeAll()

        if cursorIsHidden {
            NSCursor.setHiddenUntilMouseMoves(false)
            cursorIsHidden = false
        }
        if coreGraphicsCursorIsHidden {
            CGDisplayShowCursor(kCGNullDirectDisplay)
            coreGraphicsCursorIsHidden = false
        }
        NSCursor.arrow.set()

        if let previousApplication {
            previousApplication.activate(options: [])
            self.previousApplication = nil
        } else {
            NSApp.deactivate()
        }

        stopWatchdog(restoredEveryDisplay: restoredEveryDisplay)
    }

    private func blackOutput(of displayID: CGDirectDisplayID) {
        let capacity = CGDisplayGammaTableCapacity(displayID)
        guard capacity > 0 else {
            writeLog("display \(displayID) has no output transfer table")
            return
        }

        var red = [CGGammaValue](repeating: 0, count: Int(capacity))
        var green = red
        var blue = red
        var count: UInt32 = 0
        let readResult = CGGetDisplayTransferByTable(
            displayID,
            capacity,
            &red,
            &green,
            &blue,
            &count
        )
        guard readResult == .success, count > 0 else {
            writeLog("could not save output table for display \(displayID): \(readResult.rawValue)")
            return
        }

        red = Array(red.prefix(Int(count)))
        green = Array(green.prefix(Int(count)))
        blue = Array(blue.prefix(Int(count)))
        var zero = [CGGammaValue](repeating: 0, count: Int(count))
        let writeResult = CGSetDisplayTransferByTable(displayID, count, &zero, &zero, &zero)
        guard writeResult == .success else {
            writeLog("could not black output for display \(displayID): \(writeResult.rawValue)")
            return
        }

        gammaTables[displayID] = GammaTable(red: red, green: green, blue: blue, count: count)
    }

    private func startWatchdog() -> Bool {
        guard let executableURL = Bundle.main.executableURL else { return false }

        let process = Process()
        let input = Pipe()
        process.executableURL = executableURL
        process.arguments = ["--restore-color-on-eof"]
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice

        do {
            try process.run()
            input.fileHandleForReading.closeFile()
            watchdog = process
            watchdogInput = input.fileHandleForWriting
            return true
        } catch {
            writeLog("could not start output-restore watchdog: \(error.localizedDescription)")
            return false
        }
    }

    private func stopWatchdog(restoredEveryDisplay: Bool) {
        guard let watchdogInput else { return }
        if restoredEveryDisplay {
            try? watchdogInput.write(contentsOf: Data([1]))
        }
        try? watchdogInput.close()
        self.watchdogInput = nil
        watchdog = nil
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
    private let blackImageModeItem = NSMenuItem(title: "Black Image Mode", action: nil, keyEquivalent: "")
    private let timeoutItem = NSMenuItem(title: "Turn Off After", action: nil, keyEquivalent: "")
    private let timeoutMenu = NSMenu()
    private let presetSeconds: [TimeInterval] = [60, 120, 300, 600, 900, 1800, 3600]
    private var presetItems: [NSMenuItem] = []
    private var customItem: NSMenuItem!
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var lastSleepRequest = Date.distantPast
    private let blanker = DisplayBlanker()
    private var sleepNowItem: NSMenuItem!
    private var manualBlackoutInputCount: UInt32?

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
        blanker.clear()
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

        blackImageModeItem.target = self
        blackImageModeItem.action = #selector(toggleBlackImageMode)
        menu.addItem(blackImageModeItem)

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

        sleepNowItem = NSMenuItem(
            title: "Put All Displays to Sleep Now",
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

            if let inputCount = manualBlackoutInputCount {
                if !Settings.usesBlackImageMode || currentInputEventCount() != inputCount {
                    manualBlackoutInputCount = nil
                    blanker.clear()
                } else {
                    blanker.show()
                    return
                }
            }

            let mayRequestSleep = Settings.isEnabled
                && status.isOnACPower
                && status.idleSeconds >= Settings.timeout
                && !status.isDisplayAsleep
                && status.isDisplaySleepPrevented == false
                && Date().timeIntervalSince(lastSleepRequest) >= retryInterval

            if mayRequestSleep {
                if Settings.usesBlackImageMode {
                    if !blanker.isBlanking {
                        writeLog("showing black image after \(Int(status.idleSeconds)) seconds idle")
                    }
                    blanker.show()
                } else {
                    lastSleepRequest = Date()
                    writeLog("requesting display sleep after \(Int(status.idleSeconds)) seconds idle")
                    if !requestDisplaySleep() {
                        writeLog("pmset displaysleepnow failed")
                    }
                }
            } else if !Settings.usesBlackImageMode
                || !Settings.isEnabled
                || !status.isOnACPower
                || status.isDisplaySleepPrevented != false
                || status.idleSeconds < Settings.timeout {
                blanker.clear()
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
        } else if Settings.usesBlackImageMode && blanker.isBlanking {
            summary = "Displaying black image"
            symbol = "moon.zzz.fill"
        } else {
            let remaining = max(0, Settings.timeout - status.idleSeconds)
            summary = remaining > 0
                ? "Active: \(Settings.usesBlackImageMode ? "black image" : "display off") in \(formatDuration(remaining.rounded(.up)))"
                : Settings.usesBlackImageMode ? "Showing black image..." : "Turning display off..."
            symbol = Settings.usesBlackImageMode ? "moon.zzz.fill" : "display"
        }

        summaryItem.title = summary
        enabledItem.state = Settings.isEnabled ? .on : .off
        blackImageModeItem.state = Settings.usesBlackImageMode ? .on : .off
        timeoutItem.title = "Turn Off After: \(formatDuration(Settings.timeout))"
        sleepNowItem?.title = Settings.usesBlackImageMode
            ? "Show Black Image Now"
            : "Put All Displays to Sleep Now"

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
        if !Settings.isEnabled {
            manualBlackoutInputCount = nil
            blanker.clear()
        }
        writeLog("automatic display sleep \(Settings.isEnabled ? "enabled" : "disabled")")
        refreshMenu(with: currentStatus())
    }

    @objc private func toggleBlackImageMode() {
        Settings.usesBlackImageMode.toggle()
        manualBlackoutInputCount = nil
        blanker.clear()
        lastSleepRequest = .distantPast
        writeLog("black image mode \(Settings.usesBlackImageMode ? "enabled" : "disabled")")
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
        if Settings.usesBlackImageMode {
            writeLog("manual black image requested")
            DispatchQueue.main.async { [weak self] in
                guard let self, Settings.usesBlackImageMode else { return }
                self.manualBlackoutInputCount = currentInputEventCount()
                self.blanker.show()
                self.refreshMenu(with: currentStatus())
            }
        } else {
            writeLog("manual display sleep requested")
            if !requestDisplaySleep() {
                writeLog("pmset displaysleepnow failed")
            }
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

if arguments == ["--restore-color-on-eof"] {
    let parentExitWasClean = !FileHandle.standardInput.readDataToEndOfFile().isEmpty
    if !parentExitWasClean {
        CGDisplayRestoreColorSyncSettings()
    }
} else if arguments == ["--status"] {
    let status = currentStatus()
    let prevention = status.isDisplaySleepPrevented.map(String.init) ?? "unknown"
    print(
        "enabled=\(Settings.isEnabled) " +
        "black_image_mode=\(Settings.usesBlackImageMode) " +
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
