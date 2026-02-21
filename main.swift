import AppKit
import Carbon

// MARK: - Logging

func logMsg(_ msg: String) {
    let url = URL(fileURLWithPath: NSHomeDirectory() + "/clipotron.log")
    let line = "\(Date()): \(msg)\n"
    if let fh = try? FileHandle(forWritingTo: url) {
        fh.seekToEndOfFile()
        fh.write(line.data(using: .utf8)!)
        fh.closeFile()
    } else {
        try? line.data(using: .utf8)?.write(to: url)
    }
}

// MARK: - ClipboardItem

enum ClipboardItem {
    case text(String)
    case image(NSImage, sizeLabel: String)

    var menuTitle: String {
        switch self {
        case .text(let s):
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: " ")
            if trimmed.count > 60 {
                return String(trimmed.prefix(60)) + "..."
            }
            return trimmed
        case .image(_, let sizeLabel):
            return "Image \(sizeLabel)"
        }
    }
}

// MARK: - ClipboardManager

class ClipboardManager {
    static let shared = ClipboardManager()

    var history: [ClipboardItem] = []
    let maxItems = 4
    var enabled: Bool = true

    private var lastChangeCount: Int = 0
    private var pollingTimer: Timer?
    var ignoreNextChange = false

    func startMonitoring() {
        lastChangeCount = NSPasteboard.general.changeCount
        pollingTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            self?.checkClipboard()
        }
    }

    private func checkClipboard() {
        let pb = NSPasteboard.general
        let current = pb.changeCount
        guard current != lastChangeCount else { return }
        lastChangeCount = current

        guard enabled else { return }

        if ignoreNextChange {
            ignoreNextChange = false
            return
        }

        // Try text first
        if let str = pb.string(forType: .string), !str.isEmpty {
            if case .text(let existing) = history.first, existing == str {
                return
            }
            history.insert(.text(str), at: 0)
            if history.count > maxItems { history.removeLast() }
            return
        }

        // Try image
        let imageTypes: [NSPasteboard.PasteboardType] = [.tiff, .png]
        for type in imageTypes {
            if let data = pb.data(forType: type), let image = NSImage(data: data) {
                let size = image.size
                let sizeLabel = "\(Int(size.width))x\(Int(size.height))"
                history.insert(.image(image, sizeLabel: sizeLabel), at: 0)
                if history.count > maxItems { history.removeLast() }
                return
            }
        }
    }

    func copyToClipboard(at index: Int) {
        guard index >= 0, index < history.count else { return }
        let item = history[index]
        let pb = NSPasteboard.general

        pb.clearContents()
        ignoreNextChange = true
        switch item {
        case .text(let str):
            pb.setString(str, forType: .string)
        case .image(let img, _):
            if let tiff = img.tiffRepresentation {
                pb.setData(tiff, forType: .tiff)
            }
        }
    }

    func simulatePaste() {
        let cmdFlag = CGEventFlags(rawValue: UInt64(CGEventFlags.maskCommand.rawValue) | 0x000008)
        let source = CGEventSource(stateID: .combinedSessionState)
        source?.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )

        let keyVDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
        let keyVUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        keyVDown?.flags = cmdFlag
        keyVUp?.flags = cmdFlag
        keyVDown?.post(tap: .cgSessionEventTap)
        keyVUp?.post(tap: .cgSessionEventTap)
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var panelVisible = false
    var eventTap: CFMachPort?
    private var pasting = false

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            let bundle = Bundle.main
            if let iconPath = bundle.path(forResource: "icon", ofType: "png"),
               let img = NSImage(contentsOfFile: iconPath) {
                img.size = NSSize(width: 18, height: 18)
                img.isTemplate = true
                button.image = img
            } else {
                button.title = "V"
                button.font = NSFont.boldSystemFont(ofSize: 14)
            }
            button.action = #selector(statusItemClicked)
            button.target = self
        }

        ClipboardManager.shared.startMonitoring()
        setupHotkey()
        logMsg("Clipotron started, AXTrusted=\(AXIsProcessTrusted())")
    }

    // MARK: - Menu

    func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        // Header with toggle
        let headerItem = NSMenuItem()
        let headerView = NSView(frame: NSRect(x: 0, y: 0, width: 250, height: 30))

        let titleLabel = NSTextField(labelWithString: "Clipotron")
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .bold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        headerView.addSubview(titleLabel)

        let toggle = NSSwitch()
        toggle.state = ClipboardManager.shared.enabled ? .on : .off
        toggle.target = self
        toggle.action = #selector(toggleEnabled(_:))
        toggle.translatesAutoresizingMaskIntoConstraints = false
        headerView.addSubview(toggle)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 14),
            titleLabel.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            toggle.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -14),
            toggle.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
        ])

        headerItem.view = headerView
        menu.addItem(headerItem)
        menu.addItem(.separator())

        // Clipboard items
        let items = ClipboardManager.shared.history
        if items.isEmpty {
            let empty = NSMenuItem(title: "No items", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for (i, item) in items.enumerated() {
                let mi = NSMenuItem(title: item.menuTitle, action: #selector(pasteItem(_:)), keyEquivalent: "\(i + 1)")
                mi.keyEquivalentModifierMask = [.command]
                mi.tag = i
                mi.target = self

                // Thumbnail for images
                if case .image(let img, _) = item {
                    let thumb = makeThumbnail(image: img, height: 18)
                    mi.image = thumb
                }

                menu.addItem(mi)
            }
        }

        menu.addItem(.separator())

        let clearItem = NSMenuItem(title: "Clear", action: #selector(clearHistory), keyEquivalent: "")
        clearItem.target = self
        menu.addItem(clearItem)

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    private func makeThumbnail(image: NSImage, height: CGFloat) -> NSImage {
        let ratio = height / image.size.height
        let width = image.size.width * ratio
        let thumbSize = NSSize(width: min(width, 60), height: height)
        let thumb = NSImage(size: thumbSize)
        thumb.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: thumbSize),
                   from: NSRect(origin: .zero, size: image.size),
                   operation: .copy, fraction: 1.0)
        thumb.unlockFocus()
        return thumb
    }

    // MARK: - Actions

    @objc func pasteItem(_ sender: NSMenuItem) {
        let index = sender.tag
        guard !pasting else { return }
        guard index >= 0, index < ClipboardManager.shared.history.count else { return }
        pasting = true
        logMsg("pasteItem index=\(index)")
        ClipboardManager.shared.copyToClipboard(at: index)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            ClipboardManager.shared.simulatePaste()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self?.pasting = false
            }
        }
    }

    func pasteItemDirectly(index: Int) {
        guard !pasting else { return }
        guard index >= 0, index < ClipboardManager.shared.history.count else { return }
        pasting = true
        logMsg("pasteItemDirectly index=\(index)")
        // Close menu first
        statusItem.menu?.cancelTracking()
        ClipboardManager.shared.copyToClipboard(at: index)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            ClipboardManager.shared.simulatePaste()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self?.pasting = false
            }
        }
    }

    @objc func toggleEnabled(_ sender: NSSwitch) {
        ClipboardManager.shared.enabled = (sender.state == .on)
    }

    @objc func clearHistory() {
        ClipboardManager.shared.history.removeAll()
    }

    @objc func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Show menu

    func showMenu() {
        guard let button = statusItem.button else { return }
        let menu = buildMenu()
        panelVisible = true
        statusItem.menu = menu
        button.performClick(nil)
        statusItem.menu = nil
    }

    func togglePanel() {
        showMenu()
    }

    @objc func statusItemClicked() {
        showMenu()
    }

    // MARK: - NSMenuDelegate

    func menuDidClose(_ menu: NSMenu) {
        panelVisible = false
    }

    // MARK: - Hotkey

    func setupHotkey() {
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)

        let callback: CGEventTapCallBack = { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let refcon = refcon {
                    let delegate = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()
                    if let tap = delegate.eventTap {
                        CGEvent.tapEnable(tap: tap, enable: true)
                    }
                }
                return Unmanaged.passRetained(event)
            }

            guard type == .keyDown else { return Unmanaged.passRetained(event) }

            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let flags = event.flags

            // Option+V: keyCode 9, alternate flag, no cmd/ctrl
            if keyCode == 9
                && flags.contains(.maskAlternate)
                && !flags.contains(.maskCommand)
                && !flags.contains(.maskControl) {
                if let refcon = refcon {
                    let delegate = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()
                    DispatchQueue.main.async {
                        delegate.togglePanel()
                    }
                }
                return nil
            }

            // Cmd+1..4: paste from history — only when panel is open
            let numberKeyCodes: [Int64] = [18, 19, 20, 21]
            if let refcon = refcon {
                let delegate = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()
                if delegate.panelVisible
                    && flags.contains(.maskCommand)
                    && !flags.contains(.maskAlternate)
                    && !flags.contains(.maskControl) {
                    if let idx = numberKeyCodes.firstIndex(of: keyCode),
                       idx < ClipboardManager.shared.history.count {
                        DispatchQueue.main.async {
                            delegate.pasteItemDirectly(index: idx)
                        }
                        return nil
                    }
                }
            }

            return Unmanaged.passRetained(event)
        }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: refcon
        ) else {
            logMsg("Failed to create event tap for hotkey")
            return
        }

        self.eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        logMsg("Hotkey Option+V registered")
    }
}

// MARK: - Main

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
