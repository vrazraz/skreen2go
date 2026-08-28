import AppKit
import Foundation
import ServiceManagement

enum HotKeyFormatter {
    /// ANSI virtual key codes. The previous table stopped at the letter rows, so anything
    /// else (arrows, punctuation, function keys) showed up as "Key 51".
    static let keyNames: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
        8: "C", 9: "V", 10: "§", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
        16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5",
        24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O",
        32: "U", 33: "[", 34: "I", 35: "P", 36: "Return", 37: "L", 38: "J", 39: "'",
        40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".",
        48: "Tab", 49: "Space", 50: "`", 51: "Delete", 53: "Esc",
        65: "Num .", 67: "Num *", 69: "Num +", 71: "Num Clear", 75: "Num /",
        76: "Num Enter", 78: "Num -", 81: "Num =", 82: "Num 0", 83: "Num 1",
        84: "Num 2", 85: "Num 3", 86: "Num 4", 87: "Num 5", 88: "Num 6",
        89: "Num 7", 91: "Num 8", 92: "Num 9",
        96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11",
        105: "F13", 107: "F14", 109: "F10", 111: "F12", 113: "F15", 114: "Help",
        115: "Home", 116: "Page Up", 117: "Forward Delete", 118: "F4", 119: "End",
        120: "F2", 121: "Page Down", 122: "F1",
        123: "←", 124: "→", 125: "↓", 126: "↑"
    ]

    static func string(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> String {
        var result = ""
        if modifiers.contains(.control) { result += "⌃" }
        if modifiers.contains(.option) { result += "⌥" }
        if modifiers.contains(.shift) { result += "⇧" }
        if modifiers.contains(.command) { result += "⌘" }
        result += keyNames[keyCode] ?? "Key \(keyCode)"
        return result
    }
}

/// Small seam around the system login-item API. It keeps the settings controller
/// deterministic in tests and prevents UI code from knowing how SMAppService works.
@MainActor
protocol LoginItemManaging: AnyObject {
    var isEnabled: Bool { get }
    func setEnabled(_ enabled: Bool) throws
    func disableIfEnabled() throws
}

@MainActor
final class SystemLoginItemManager: LoginItemManaging {
    var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    func disableIfEnabled() throws {
        guard isEnabled else { return }
        try SMAppService.mainApp.unregister()
    }
}

@MainActor
enum SettingsResetService {
    static func reset(
        settings: SettingsStore,
        loginItemManager: any LoginItemManaging
    ) -> Error? {
        settings.reset()
        do {
            try loginItemManager.disableIfEnabled()
            return nil
        } catch {
            return error
        }
    }
}

@MainActor
final class SettingsPanelController: NSWindowController, NSWindowDelegate {
    private let settings: SettingsStore
    private let loginItemManager: any LoginItemManaging
    private var hotKeyButton: NSButton!
    private var folderField: NSTextField!
    private var formatPopup: NSPopUpButton!
    private var copyAnimationPopup: NSPopUpButton!
    private var languagePopup: NSPopUpButton!
    private var colorWell: NSColorWell!
    private var strokeThicknessSlider: NSSlider!
    private var strokeOpacitySlider: NSSlider!
    private var textSizeSlider: NSSlider!
    private var textOpacitySlider: NSSlider!
    private var blurSlider: NSSlider!
    private var boldCheckbox: NSButton!
    private var launchCheckbox: NSButton!
    private var notificationCheckbox: NSButton!
    private var recordingHotKeyButton: NSButton!
    private var recordingCursorCheckbox: NSButton!
    private var recordingClicksCheckbox: NSButton!
    private var hotKeyRecordingMonitor: Any?
    /// Which of the two hot key buttons is waiting for a combination, if either.
    private var capturingSlot: HotKeySlot?

    enum HotKeySlot: CaseIterable {
        case screenshot
        case recording
    }

    var onClose: (() -> Void)?
    private var isRunningModal = false

    init(
        settings: SettingsStore,
        loginItemManager: (any LoginItemManaging)? = nil
    ) {
        self.settings = settings
        self.loginItemManager = loginItemManager ?? SystemLoginItemManager()
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 560, height: 650),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "settings.window.title".localized("Skreen2Go Settings")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildInterface()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let hotKeyRecordingMonitor { NSEvent.removeMonitor(hotKeyRecordingMonitor) }
    }

    /// - Parameter modal: run a modal session, so whatever is behind cannot be touched
    ///   until the settings window is dismissed (PRD §8).
    func show(modal: Bool = false) {
        refreshControls()
        guard let window else { return }
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        guard modal, !isRunningModal else { return }
        isRunningModal = true
        NSApp.runModal(for: window)
    }

    func windowWillClose(_ notification: Notification) {
        stopRecordingHotKey()
        colorWell?.deactivate()
        // Leaving the modal session running would wedge the app in a nested event loop.
        if isRunningModal {
            isRunningModal = false
            NSApp.stopModal()
        }
        onClose?()
    }

    /// Three tabs, because the jobs share almost nothing: a screenshot has colours,
    /// thickness and text; a recording has none of those; and where files land, the
    /// interface language and the two app-wide switches belong to neither in particular.
    /// Splitting them cuts what is on screen at once to a third, and each tab reads top to
    /// bottom in the order the settings are reached for — how the capture is started, what
    /// comes out of it, then how it looks.
    private func buildInterface() {
        guard let contentView = window?.contentView else { return }

        let tabView = NSTabView()
        tabView.translatesAutoresizingMaskIntoConstraints = false
        tabView.addTabViewItem(makeTab(
            "settings.tab.general",
            "General",
            build: buildSharedSettings
        ))
        tabView.addTabViewItem(makeTab(
            "settings.tab.screenshots",
            "Screenshots",
            build: buildScreenshotSettings
        ))
        tabView.addTabViewItem(makeTab(
            "settings.tab.recording",
            "Video recording",
            build: buildRecordingSettings
        ))
        // Opens on the settings that apply everywhere, which is also where they read
        // first: they hold for both of the tabs after them.
        tabView.selectTabViewItem(at: 0)
        // Lowest hugging in the column, so the tabs take the space left over.
        tabView.setContentHuggingPriority(.defaultLow, for: .vertical)

        let resetButton = NSButton(title: "settings.reset".localized("Reset settings"), target: self, action: #selector(resetSettings))
        resetButton.bezelStyle = .rounded
        let closeButton = NSButton(title: "settings.done".localized("Done"), target: self, action: #selector(closeSettings))
        closeButton.bezelStyle = .rounded
        closeButton.keyEquivalent = "\r"
        let buttons = NSStackView(views: [NSView(), resetButton, closeButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let root = NSStackView(views: [tabView, buttons])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 14
        root.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            root.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            root.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
            tabView.widthAnchor.constraint(equalTo: root.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: root.widthAnchor)
        ])

        refreshControls()
    }

    /// Reached for in this order: the key that starts a capture, the file it produces,
    /// then the tools used on it — most often first, rarest last.
    private func buildScreenshotSettings(in stack: NSStackView) {
        hotKeyButton = NSButton(title: "", target: self, action: #selector(toggleHotKeyRecording(_:)))
        hotKeyButton.bezelStyle = .rounded
        hotKeyButton.widthAnchor.constraint(equalToConstant: 200).isActive = true
        stack.addArrangedSubview(row(label: "settings.hotKey".localized("Hot key"), control: hotKeyButton))

        formatPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        formatPopup.addItems(withTitles: OutputFormat.allCases.map(\.rawValue))
        formatPopup.target = self
        formatPopup.action = #selector(formatChanged(_:))
        stack.addArrangedSubview(row(label: "settings.format".localized("File format"), control: formatPopup))

        copyAnimationPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        copyAnimationPopup.addItems(withTitles: CopyAnimation.allCases.map(\.title))
        copyAnimationPopup.target = self
        copyAnimationPopup.action = #selector(copyAnimationChanged(_:))
        stack.addArrangedSubview(row(
            label: "settings.copyAnimation".localized("Copy animation"),
            control: copyAnimationPopup
        ))

        colorWell = NSColorWell(frame: .zero)
        colorWell.target = self
        colorWell.action = #selector(colorChanged(_:))
        stack.addArrangedSubview(row(label: "settings.color".localized("Default color"), control: colorWell))

        stack.addArrangedSubview(sectionTitle("settings.section.stroke", "Arrow and rectangle"))
        strokeThicknessSlider = slider(min: 1, max: 16, action: #selector(strokeThicknessChanged(_:)))
        stack.addArrangedSubview(row(label: "settings.thickness".localized("Thickness"), control: strokeThicknessSlider))
        strokeOpacitySlider = slider(min: 0.1, max: 1, action: #selector(strokeOpacityChanged(_:)))
        stack.addArrangedSubview(row(label: "settings.opacity".localized("Opacity"), control: strokeOpacitySlider))

        stack.addArrangedSubview(sectionTitle("settings.section.text", "Text"))
        textSizeSlider = slider(min: 10, max: 72, action: #selector(textSizeChanged(_:)))
        stack.addArrangedSubview(row(label: "settings.textSize".localized("Size"), control: textSizeSlider))
        textOpacitySlider = slider(min: 0.1, max: 1, action: #selector(textOpacityChanged(_:)))
        stack.addArrangedSubview(row(label: "settings.opacity".localized("Opacity"), control: textOpacitySlider))
        boldCheckbox = NSButton(checkboxWithTitle: "settings.textBold".localized("Bold text"), target: self, action: #selector(textBoldChanged(_:)))
        stack.addArrangedSubview(boldCheckbox)

        stack.addArrangedSubview(sectionTitle("settings.section.blur", "Blur"))
        blurSlider = slider(min: 1, max: 40, action: #selector(blurChanged(_:)))
        stack.addArrangedSubview(row(label: "settings.blurRadius".localized("Intensity"), control: blurSlider))
    }

    /// Short by design: the audio sources are chosen on the panel, right before recording,
    /// because that is a decision made afresh every time rather than once and forgotten.
    private func buildRecordingSettings(in stack: NSStackView) {
        recordingHotKeyButton = NSButton(title: "", target: self, action: #selector(toggleHotKeyRecording(_:)))
        recordingHotKeyButton.bezelStyle = .rounded
        recordingHotKeyButton.widthAnchor.constraint(equalToConstant: 200).isActive = true
        stack.addArrangedSubview(row(label: "settings.recordingHotKey".localized("Recording hot key"), control: recordingHotKeyButton))

        stack.addArrangedSubview(sectionTitle("settings.section.pointer", "Pointer"))
        recordingCursorCheckbox = NSButton(
            checkboxWithTitle: "settings.recordingCursor".localized("Show the mouse cursor"),
            target: self,
            action: #selector(recordingCursorChanged(_:))
        )
        stack.addArrangedSubview(recordingCursorCheckbox)

        recordingClicksCheckbox = NSButton(
            checkboxWithTitle: "settings.recordingClicks".localized("Highlight clicks"),
            target: self,
            action: #selector(recordingClicksChanged(_:))
        )
        stack.addArrangedSubview(recordingClicksCheckbox)
    }

    private func buildSharedSettings(in stack: NSStackView) {
        folderField = NSTextField(string: "")
        folderField.isEditable = false
        folderField.lineBreakMode = .byTruncatingMiddle
        folderField.widthAnchor.constraint(equalToConstant: 260).isActive = true
        let folderButton = NSButton(title: "settings.folder.choose".localized("Choose…"), target: self, action: #selector(chooseFolder))
        folderButton.bezelStyle = .rounded
        let folderRow = NSStackView(views: [folderField, folderButton])
        folderRow.orientation = .horizontal
        folderRow.spacing = 8
        stack.addArrangedSubview(row(label: "settings.folder".localized("Save folder"), control: folderRow))

        languagePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        for language in InterfaceLanguage.allCases {
            languagePopup.addItem(withTitle: language.title)
            languagePopup.lastItem?.representedObject = language.rawValue
        }
        languagePopup.target = self
        languagePopup.action = #selector(languageChanged(_:))
        stack.addArrangedSubview(row(label: "settings.language".localized("Language"), control: languagePopup))

        launchCheckbox = NSButton(checkboxWithTitle: "settings.launchAtLogin".localized("Launch at login"), target: self, action: #selector(launchAtLoginChanged(_:)))
        stack.addArrangedSubview(launchCheckbox)

        notificationCheckbox = NSButton(checkboxWithTitle: "settings.showNotifications".localized("Show notifications"), target: self, action: #selector(notificationsChanged(_:)))
        stack.addArrangedSubview(notificationCheckbox)
    }

    private func makeTab(
        _ key: String,
        _ fallback: String,
        build: (NSStackView) -> Void
    ) -> NSTabViewItem {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        build(stack)

        // Flipped on purpose: a document view shorter than the clip view sits at the
        // bottom in AppKit's usual bottom-left origin, which left the short recording tab
        // with a band of empty space above it.
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = document

        let container = NSView()
        container.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: document.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 16),
            // Lets the document size itself to its content rather than a fixed height.
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -16)
        ])

        let item = NSTabViewItem(identifier: key)
        item.label = key.localized(fallback)
        item.view = container
        return item
    }

    private func sectionTitle(_ key: String, _ fallback: String) -> NSTextField {
        let title = NSTextField(labelWithString: key.localized(fallback))
        title.font = .boldSystemFont(ofSize: 13)
        return title
    }

    private func separatorLine() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        return line
    }

    /// Top-left origin, so content that does not fill the scroll view starts at the top.
    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }

    /// Pulls every control back from the store — needed after a reset and when the panel
    /// is reopened rather than rebuilt.
    private func refreshControls() {
        guard hotKeyButton != nil else { return }
        // Also writes both hot key button titles back from the store.
        stopRecordingHotKey()
        recordingCursorCheckbox.state = settings.showsCursorInRecording ? .on : .off
        recordingClicksCheckbox.state = settings.showsClicksInRecording ? .on : .off
        folderField.stringValue = settings.outputFolderURL.path
        formatPopup.selectItem(withTitle: settings.outputFormat.rawValue)
        // By position rather than by title: the titles are translated, so matching on them
        // would stop working the moment the interface language changes.
        if let index = CopyAnimation.allCases.firstIndex(of: settings.copyAnimation) {
            copyAnimationPopup.selectItem(at: index)
        }
        selectLanguage(settings.interfaceLanguage)
        colorWell.color = settings.defaultColor
        strokeThicknessSlider.doubleValue = Double(settings.strokeThickness)
        strokeOpacitySlider.doubleValue = Double(settings.strokeOpacity)
        textSizeSlider.doubleValue = Double(settings.textSize)
        textOpacitySlider.doubleValue = Double(settings.textOpacity)
        blurSlider.doubleValue = Double(settings.blurRadius)
        boldCheckbox.state = settings.textBold ? .on : .off
        notificationCheckbox.state = settings.showNotifications ? .on : .off
        launchCheckbox.state = loginItemManager.isEnabled ? .on : .off
    }

    private func row(label: String, control: NSView) -> NSView {
        let labelView = NSTextField(labelWithString: label)
        labelView.widthAnchor.constraint(equalToConstant: 150).isActive = true
        let row = NSStackView(views: [labelView, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        return row
    }

    private func slider(min: CGFloat, max: CGFloat, action: Selector) -> NSSlider {
        let slider = NSSlider(value: Double(min), minValue: Double(min), maxValue: Double(max), target: self, action: action)
        slider.widthAnchor.constraint(equalToConstant: 230).isActive = true
        slider.isContinuous = true
        return slider
    }

    // MARK: - Hot key recording

    @objc private func toggleHotKeyRecording(_ sender: NSButton) {
        let role: HotKeySlot = sender === recordingHotKeyButton ? .recording : .screenshot
        if capturingSlot == role {
            stopRecordingHotKey()
        } else {
            startRecordingHotKey(for: role)
        }
    }

    private func startRecordingHotKey(for slot: HotKeySlot) {
        // Only one combination can be captured at a time; starting on the other button
        // takes over rather than leaving two live monitors.
        stopRecordingHotKey()
        capturingSlot = slot
        button(for: slot)?.title = "settings.hotKey.recording".localized("Press a combination… (Esc to cancel)")
        hotKeyRecordingMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let slot = self.capturingSlot else { return event }

            // Esc leaves recording mode instead of trapping every unmodified keystroke
            // until a modified one happens to arrive.
            if event.keyCode == 53 {
                self.stopRecordingHotKey()
                return nil
            }

            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard !modifiers.isEmpty else {
                NSSound.beep()
                return nil
            }

            let combination = HotKeyCombination(keyCode: event.keyCode, modifiers: modifiers)
            switch slot {
            case .screenshot: self.settings.hotKey = combination
            case .recording: self.settings.recordingHotKey = combination
            }

            // The store refuses a combination already held by the other key, so read it
            // back rather than assuming the assignment took.
            if self.combination(for: slot) != combination {
                NSSound.beep()
                self.stopRecordingHotKey()
                self.showHotKeyConflict(combination)
                return nil
            }

            self.stopRecordingHotKey()
            return nil
        }
    }

    private func stopRecordingHotKey() {
        capturingSlot = nil
        if let hotKeyRecordingMonitor {
            NSEvent.removeMonitor(hotKeyRecordingMonitor)
            self.hotKeyRecordingMonitor = nil
        }
        for slot in HotKeySlot.allCases {
            let combination = self.combination(for: slot)
            button(for: slot)?.title = HotKeyFormatter.string(
                keyCode: combination.keyCode,
                modifiers: combination.modifiers
            )
        }
    }

    private func combination(for slot: HotKeySlot) -> HotKeyCombination {
        switch slot {
        case .screenshot: return settings.hotKey
        case .recording: return settings.recordingHotKey
        }
    }

    private func button(for slot: HotKeySlot) -> NSButton? {
        switch slot {
        case .screenshot: return hotKeyButton
        case .recording: return recordingHotKeyButton
        }
    }

    private func showHotKeyConflict(_ combination: HotKeyCombination) {
        let alert = NSAlert()
        alert.messageText = "error.hotKey.title".localized("Hot key not registered")
        alert.informativeText = "error.hotKey.conflict".localized(
            "%@ is already assigned to the other Skreen2Go hot key. Pick a different combination.",
            HotKeyFormatter.string(keyCode: combination.keyCode, modifiers: combination.modifiers)
        )
        alert.addButton(withTitle: "button.close".localized("Close"))
        alert.runModal()
    }

    // MARK: - Actions

    @objc private func chooseFolder() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do {
                try self.settings.setOutputFolderURL(url)
                self.folderField.stringValue = url.path
            } catch {
                ScreenshotOutput.showError("error.folder.bookmark".localized("Could not remember the save folder: %@", error.localizedDescription))
            }
        }
    }

    @objc private func copyAnimationChanged(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        guard CopyAnimation.allCases.indices.contains(index) else { return }
        settings.copyAnimation = CopyAnimation.allCases[index]
    }

    @objc private func formatChanged(_ sender: NSPopUpButton) {
        if let format = OutputFormat(rawValue: sender.titleOfSelectedItem ?? "PNG") {
            settings.outputFormat = format
        }
    }

    private func selectLanguage(_ language: InterfaceLanguage) {
        let index = languagePopup.itemArray.firstIndex {
            ($0.representedObject as? String) == language.rawValue
        }
        languagePopup.selectItem(at: index ?? 0)
    }

    @objc private func languageChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let language = InterfaceLanguage(rawValue: raw) else { return }
        settings.interfaceLanguage = language
        L10n.overrideLanguage = language.bundleCode
        // Every label was built with the old language, so the window is rebuilt rather
        // than relabelled control by control.
        rebuildInterface()
    }

    /// Tears the window's content down and builds it again in the current language.
    func rebuildInterface() {
        stopRecordingHotKey()
        colorWell?.deactivate()
        window?.title = "settings.window.title".localized("Skreen2Go Settings")
        window?.contentView?.subviews.forEach { $0.removeFromSuperview() }
        buildInterface()
    }

    @objc private func colorChanged(_ sender: NSColorWell) { settings.defaultColor = sender.color }
    @objc private func strokeThicknessChanged(_ sender: NSSlider) { settings.strokeThickness = CGFloat(sender.doubleValue) }
    @objc private func strokeOpacityChanged(_ sender: NSSlider) { settings.strokeOpacity = CGFloat(sender.doubleValue) }
    @objc private func textSizeChanged(_ sender: NSSlider) { settings.textSize = CGFloat(sender.doubleValue) }
    @objc private func textOpacityChanged(_ sender: NSSlider) { settings.textOpacity = CGFloat(sender.doubleValue) }
    @objc private func blurChanged(_ sender: NSSlider) { settings.blurRadius = CGFloat(sender.doubleValue) }
    @objc private func textBoldChanged(_ sender: NSButton) { settings.textBold = sender.state == .on }
    @objc private func notificationsChanged(_ sender: NSButton) { settings.showNotifications = sender.state == .on }
    @objc private func recordingCursorChanged(_ sender: NSButton) { settings.showsCursorInRecording = sender.state == .on }
    @objc private func recordingClicksChanged(_ sender: NSButton) { settings.showsClicksInRecording = sender.state == .on }

    @objc private func launchAtLoginChanged(_ sender: NSButton) {
        let enabled = sender.state == .on
        do {
            try loginItemManager.setEnabled(enabled)
            settings.launchAtLogin = enabled
        } catch {
            // Registration only works from inside a signed .app bundle; failing silently
            // used to leave the checkbox claiming a setting that never took effect.
            sender.state = enabled ? .off : .on
            settings.launchAtLogin = !enabled ? false : settings.launchAtLogin
            let alert = NSAlert()
            alert.messageText = "error.launchAtLogin.title".localized("Could not change the launch-at-login setting")
            alert.informativeText = "error.launchAtLogin.body".localized(
                "%@\n\nLaunching at login only works for a built .app in the Applications folder.",
                error.localizedDescription
            )
            alert.runModal()
            sender.state = loginItemManager.isEnabled ? .on : .off
        }
    }

    @objc private func resetSettings() {
        // The login item lives in the system, not in UserDefaults: wiping preferences has
        // to take the app back out of the launch list too, otherwise it keeps starting
        // with macOS while the setting reads "off".
        if let error = SettingsResetService.reset(
            settings: settings,
            loginItemManager: loginItemManager
        ) {
            ScreenshotOutput.showError("error.reset.launchAtLogin".localized("Settings were reset, but launching at login could not be turned off: %@", error.localizedDescription))
        }
        refreshControls()
    }

    @objc private func closeSettings() { window?.close() }
}
