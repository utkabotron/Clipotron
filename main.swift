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

// MARK: - HighlightRowView

class HighlightRowView: NSView {
    var textLabel: NSTextField?
    var shortcutLabel: NSTextField?
    private var trackingArea: NSTrackingArea?
    private var isHighlighted = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self, userInfo: nil)
        addTrackingArea(trackingArea!)
    }

    override func mouseEntered(with event: NSEvent) {
        isHighlighted = true
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        isHighlighted = false
        layer?.backgroundColor = nil
    }
}

// MARK: - PopupPanel (nonactivating — doesn't steal focus)

class PopupPanel: NSPanel {
    var onSelect: ((Int) -> Void)?
    var onDismiss: (() -> Void)?
    private var rowViews: [NSView] = []
    private var clearRow: NSView?
    private var quitRow: NSView?
    private var highlightedIndex: Int = -1
    private var keyMonitor: Any?
    private var clickMonitor: Any?
    private var globalMonitor: Any?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 340, height: 10),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        self.isFloatingPanel = true
        self.level = .statusBar
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.hidesOnDeactivate = false
        self.collectionBehavior = [.auxiliary, .stationary, .moveToActiveSpace, .fullScreenAuxiliary]
    }

    func showBelow(statusItemButton button: NSStatusBarButton, items: [ClipboardItem]) {
        rowViews.removeAll()
        highlightedIndex = -1

        let panelWidth: CGFloat = 340
        let rowWidth: CGFloat = panelWidth - 16 // 8pt padding each side

        let effectView = NSVisualEffectView()
        effectView.material = .hudWindow
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.appearance = NSAppearance(named: .darkAqua)
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 10
        effectView.layer?.masksToBounds = true

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)

        // Title row
        let titleLabel = NSTextField(labelWithString: "Clipotron")
        titleLabel.font = NSFont.systemFont(ofSize: 14, weight: .bold)
        titleLabel.textColor = .labelColor
        let titleRow = NSView()
        titleRow.addSubview(titleLabel)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let toggle = NSSwitch()
        toggle.state = ClipboardManager.shared.enabled ? .on : .off
        toggle.target = self
        toggle.action = #selector(PopupPanel.toggleEnabled(_:))
        toggle.translatesAutoresizingMaskIntoConstraints = false
        titleRow.addSubview(toggle)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: titleRow.leadingAnchor, constant: 12),
            titleLabel.centerYAnchor.constraint(equalTo: titleRow.centerYAnchor),
            toggle.trailingAnchor.constraint(equalTo: titleRow.trailingAnchor, constant: -8),
            toggle.centerYAnchor.constraint(equalTo: titleRow.centerYAnchor),
            titleRow.heightAnchor.constraint(equalToConstant: 36),
        ])
        stack.addArrangedSubview(titleRow)
        titleRow.translatesAutoresizingMaskIntoConstraints = false
        titleRow.widthAnchor.constraint(equalToConstant: rowWidth).isActive = true

        // Separator between title and items (if any)
        if !items.isEmpty {
            let topSepContainer = NSView()
            let topSep = NSBox()
            topSep.boxType = .separator
            topSep.translatesAutoresizingMaskIntoConstraints = false
            topSepContainer.addSubview(topSep)
            NSLayoutConstraint.activate([
                topSep.leadingAnchor.constraint(equalTo: topSepContainer.leadingAnchor, constant: 4),
                topSep.trailingAnchor.constraint(equalTo: topSepContainer.trailingAnchor, constant: -4),
                topSep.centerYAnchor.constraint(equalTo: topSepContainer.centerYAnchor),
                topSepContainer.heightAnchor.constraint(equalToConstant: 9),
            ])
            stack.addArrangedSubview(topSepContainer)
            topSepContainer.translatesAutoresizingMaskIntoConstraints = false
            topSepContainer.widthAnchor.constraint(equalToConstant: rowWidth).isActive = true
        }

        for (i, item) in items.enumerated() {
            let row = makeRow(index: i, item: item)
            stack.addArrangedSubview(row)
            row.translatesAutoresizingMaskIntoConstraints = false
            row.widthAnchor.constraint(equalToConstant: rowWidth).isActive = true
            rowViews.append(row)
        }

        // Separator
        let separatorContainer = NSView()
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        separatorContainer.addSubview(separator)
        NSLayoutConstraint.activate([
            separator.leadingAnchor.constraint(equalTo: separatorContainer.leadingAnchor, constant: 4),
            separator.trailingAnchor.constraint(equalTo: separatorContainer.trailingAnchor, constant: -4),
            separator.centerYAnchor.constraint(equalTo: separatorContainer.centerYAnchor),
            separatorContainer.heightAnchor.constraint(equalToConstant: 9),
        ])
        stack.addArrangedSubview(separatorContainer)
        separatorContainer.translatesAutoresizingMaskIntoConstraints = false
        separatorContainer.widthAnchor.constraint(equalToConstant: rowWidth).isActive = true

        // Clear row
        let cr = makeActionRow(title: "Clear")
        stack.addArrangedSubview(cr)
        cr.translatesAutoresizingMaskIntoConstraints = false
        cr.widthAnchor.constraint(equalToConstant: rowWidth).isActive = true
        self.clearRow = cr

        // Quit row
        let qr = makeActionRow(title: "Quit")
        stack.addArrangedSubview(qr)
        qr.translatesAutoresizingMaskIntoConstraints = false
        qr.widthAnchor.constraint(equalToConstant: rowWidth).isActive = true
        self.quitRow = qr

        stack.translatesAutoresizingMaskIntoConstraints = false
        effectView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: effectView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: effectView.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: effectView.trailingAnchor),
        ])

        self.contentView = effectView

        // Calculate size: title(36) + topSep?(9) + items(28 each) + separator(9) + clear(28) + quit(28) + padding(16)
        let itemRowHeight: CGFloat = 28
        let titleHeight: CGFloat = 36
        let separatorHeight: CGFloat = 9
        let topSepHeight: CGFloat = items.isEmpty ? 0 : separatorHeight
        let totalHeight = titleHeight + topSepHeight + CGFloat(items.count) * itemRowHeight + separatorHeight + 2 * itemRowHeight + 16
        let panelSize = NSSize(width: panelWidth, height: totalHeight)

        // Position below the status item button, left-aligned to icon
        guard let buttonWindow = button.window else { return }
        let buttonRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        var origin = NSPoint(x: buttonRect.minX,
                             y: buttonRect.minY - totalHeight - 4)

        // Keep on screen
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            if origin.x < frame.minX { origin.x = frame.minX + 4 }
            if origin.x + panelSize.width > frame.maxX { origin.x = frame.maxX - panelSize.width - 4 }
            if origin.y < frame.minY { origin.y = frame.minY + 4 }
        }

        self.setFrame(NSRect(origin: origin, size: panelSize), display: true)
        self.orderFrontRegardless()

        setupMonitors()
    }

    private func makeRow(index: Int, item: ClipboardItem) -> NSView {
        let row = HighlightRowView()
        row.wantsLayer = true
        row.layer?.cornerRadius = 4

        let height: CGFloat = 28

        // Shortcut hint on the right
        let shortcutLabel = NSTextField(labelWithString: "\u{2318}\(index + 1)")
        shortcutLabel.font = NSFont.systemFont(ofSize: 11)
        shortcutLabel.textColor = NSColor.secondaryLabelColor.withAlphaComponent(0.7)
        shortcutLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        shortcutLabel.setContentHuggingPriority(.required, for: .horizontal)
        shortcutLabel.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(shortcutLabel)
        row.shortcutLabel = shortcutLabel

        switch item {
        case .text(_):
            let textLabel = NSTextField(labelWithString: item.menuTitle)
            textLabel.font = NSFont.systemFont(ofSize: 13)
            textLabel.textColor = .labelColor
            textLabel.lineBreakMode = .byTruncatingTail
            textLabel.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(textLabel)
            row.textLabel = textLabel

            NSLayoutConstraint.activate([
                textLabel.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 12),
                textLabel.trailingAnchor.constraint(equalTo: shortcutLabel.leadingAnchor, constant: -4),
                textLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                shortcutLabel.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -8),
                shortcutLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                row.heightAnchor.constraint(equalToConstant: height),
            ])

        case .image(let img, let sizeLabel):
            let thumb = makeThumbnail(image: img, height: 18)
            let imageView = NSImageView()
            imageView.image = thumb
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(imageView)

            let sizeField = NSTextField(labelWithString: sizeLabel)
            sizeField.font = NSFont.systemFont(ofSize: 11)
            sizeField.textColor = .secondaryLabelColor
            sizeField.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(sizeField)
            row.textLabel = sizeField

            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 12),
                imageView.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                imageView.heightAnchor.constraint(equalToConstant: 18),
                imageView.widthAnchor.constraint(lessThanOrEqualToConstant: 40),
                sizeField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 6),
                sizeField.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                shortcutLabel.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -8),
                shortcutLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                row.heightAnchor.constraint(equalToConstant: height),
            ])
        }

        return row
    }

    private func makeActionRow(title: String) -> NSView {
        let row = HighlightRowView()
        row.wantsLayer = true
        row.layer?.cornerRadius = 4

        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 13)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(label)
        row.textLabel = label

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 12),
            label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            row.heightAnchor.constraint(equalToConstant: 28),
        ])

        return row
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

    private func setupMonitors() {
        removeMonitors()

        // Local monitor for key events
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            return self?.handleKeyEvent(event)
        }

        // Local mouse clicks on the panel
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            self?.handleClick(event)
            return event
        }

        // Global monitor for clicks outside the panel
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.dismiss()
        }
    }

    private func handleKeyEvent(_ event: NSEvent) -> NSEvent? {
        let key = event.charactersIgnoringModifiers ?? ""
        if let num = Int(key), num >= 1, num <= 4 {
            selectAndPaste(index: num - 1)
            return nil
        }
        if event.keyCode == 53 { // Escape
            dismiss()
            return nil
        }
        return event
    }

    private func handleClick(_ event: NSEvent) {
        guard event.window === self else { return }
        guard let contentView = self.contentView else { return }
        let loc = contentView.convert(event.locationInWindow, from: nil)

        for (i, row) in rowViews.enumerated() {
            let rowFrame = row.convert(row.bounds, to: contentView)
            if rowFrame.contains(loc) {
                selectAndPaste(index: i)
                return
            }
        }

        if let cr = clearRow {
            let frame = cr.convert(cr.bounds, to: contentView)
            if frame.contains(loc) {
                ClipboardManager.shared.history.removeAll()
                dismiss()
                return
            }
        }

        if let qr = quitRow {
            let frame = qr.convert(qr.bounds, to: contentView)
            if frame.contains(loc) {
                dismiss()
                NSApplication.shared.terminate(nil)
                return
            }
        }
    }

    private var pasting = false

    func selectAndPaste(index: Int) {
        guard !pasting else { return }
        guard index >= 0, index < ClipboardManager.shared.history.count else { return }
        pasting = true
        logMsg("selectAndPaste index=\(index)")
        // 1. Close panel first (returns focus to previous app since nonactivatingPanel)
        dismiss()
        // 2. Copy to clipboard
        ClipboardManager.shared.copyToClipboard(at: index)
        // 3. Simulate Cmd+V
        ClipboardManager.shared.simulatePaste()
        // Reset after short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.pasting = false
        }
    }

    @objc func toggleEnabled(_ sender: NSSwitch) {
        ClipboardManager.shared.enabled = (sender.state == .on)
    }

    func dismiss() {
        removeMonitors()
        self.orderOut(nil)
        onDismiss?()
    }

    private func removeMonitors() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
    }

    override var canBecomeKey: Bool { true }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var panel: PopupPanel!
    var panelVisible = false
    var eventTap: CFMachPort?

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
            button.wantsLayer = true
            button.action = #selector(statusItemClicked)
            button.target = self
        }

        panel = PopupPanel()
        panel.onDismiss = { [weak self] in
            self?.panelVisible = false
            self?.statusItem.button?.highlight(false)
        }

        ClipboardManager.shared.startMonitoring()
        setupHotkey()
        logMsg("Clipotron started, AXTrusted=\(AXIsProcessTrusted())")
    }

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
                            delegate.panel.selectAndPaste(index: idx)
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

    func togglePanel() {
        if panelVisible {
            panel.dismiss()
            return
        }
        guard let button = statusItem.button else { return }
        panelVisible = true
        panel.showBelow(statusItemButton: button, items: ClipboardManager.shared.history)
        DispatchQueue.main.async { button.highlight(true) }
    }

    @objc func statusItemClicked() {
        if panelVisible {
            panel.dismiss()
            return
        }

        guard let button = statusItem.button else { return }
        panelVisible = true
        panel.showBelow(statusItemButton: button, items: ClipboardManager.shared.history)
        DispatchQueue.main.async { button.highlight(true) }
    }
}

// MARK: - Main

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
