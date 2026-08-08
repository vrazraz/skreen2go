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

/// Wraps `SMAppService` so the login item is managed in exactly one place: the checkbox
/// and the reset button both go through here.
@MainActor
enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    static func disableIfEnabled() throws {
        guard isEnabled else { return }
        try SMAppService.mainApp.unregister()
    }
}

@MainActor
final class SettingsPanelController: NSWindowController, NSWindowDelegate {
    private let settings: SettingsStore
    private var hotKeyButton: NSButton!
    private var folderField: NSTextField!
    private var formatPopup: NSPopUpButton!
    private var colorWell: NSColorWell!
    private var strokeThicknessSlider: NSSlider!
    private var strokeOpacitySlider: NSSlider!
    private var textSizeSlider: NSSlider!
    private var textOpacitySlider: NSSlider!
    private var blurSlider: NSSlider!
    private var boldCheckbox: NSButton!
    private var launchCheckbox: NSButton!
    private var notificationCheckbox: NSButton!
    private var hotKeyRecordingMonitor: Any?
    private var recordingHotKey = false

    var onClose: (() -> Void)?

    init(settings: SettingsStore) {
        self.settings = settings
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 560, height: 650),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Настройки Skreen2Go"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildInterface()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let hotKeyRecordingMonitor { NSEvent.removeMonitor(hotKeyRecordingMonitor) }
    }

    func show() {
        refreshControls()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        stopRecordingHotKey()
        colorWell?.deactivate()
        onClose?()
    }

    private func buildInterface() {
        guard let contentView = window?.contentView else { return }
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: contentView.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])

        let documentView = NSView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = documentView

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(stack)

        NSLayoutConstraint.activate([
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: documentView.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 24),
            // Lets the document view size itself to the content instead of a hard-coded 900pt.
            stack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -24)
        ])

        let title = NSTextField(labelWithString: "Общие настройки")
        title.font = .boldSystemFont(ofSize: 18)
        stack.addArrangedSubview(title)

        hotKeyButton = NSButton(title: "", target: self, action: #selector(toggleHotKeyRecording))
        hotKeyButton.bezelStyle = .rounded
        hotKeyButton.widthAnchor.constraint(equalToConstant: 200).isActive = true
        stack.addArrangedSubview(row(label: "Горячая клавиша", control: hotKeyButton))

        folderField = NSTextField(string: "")
        folderField.isEditable = false
        folderField.lineBreakMode = .byTruncatingMiddle
        folderField.widthAnchor.constraint(equalToConstant: 260).isActive = true
        let folderButton = NSButton(title: "Выбрать…", target: self, action: #selector(chooseFolder))
        folderButton.bezelStyle = .rounded
        let folderRow = NSStackView(views: [folderField, folderButton])
        folderRow.orientation = .horizontal
        folderRow.spacing = 8
        stack.addArrangedSubview(row(label: "Папка сохранения", control: folderRow))

        formatPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        formatPopup.addItems(withTitles: OutputFormat.allCases.map(\.rawValue))
        formatPopup.target = self
        formatPopup.action = #selector(formatChanged(_:))
        stack.addArrangedSubview(row(label: "Формат файла", control: formatPopup))

        colorWell = NSColorWell(frame: .zero)
        colorWell.target = self
        colorWell.action = #selector(colorChanged(_:))
        stack.addArrangedSubview(row(label: "Цвет по умолчанию", control: colorWell))

        let strokeTitle = NSTextField(labelWithString: "Стрелка и рамка")
        strokeTitle.font = .boldSystemFont(ofSize: 14)
        stack.addArrangedSubview(strokeTitle)
        strokeThicknessSlider = slider(min: 1, max: 16, action: #selector(strokeThicknessChanged(_:)))
        stack.addArrangedSubview(row(label: "Толщина", control: strokeThicknessSlider))
        strokeOpacitySlider = slider(min: 0.1, max: 1, action: #selector(strokeOpacityChanged(_:)))
        stack.addArrangedSubview(row(label: "Прозрачность", control: strokeOpacitySlider))

        let textTitle = NSTextField(labelWithString: "Текст")
        textTitle.font = .boldSystemFont(ofSize: 14)
        stack.addArrangedSubview(textTitle)
        textSizeSlider = slider(min: 10, max: 72, action: #selector(textSizeChanged(_:)))
        stack.addArrangedSubview(row(label: "Размер", control: textSizeSlider))
        textOpacitySlider = slider(min: 0.1, max: 1, action: #selector(textOpacityChanged(_:)))
        stack.addArrangedSubview(row(label: "Прозрачность", control: textOpacitySlider))
        boldCheckbox = NSButton(checkboxWithTitle: "Жирный текст", target: self, action: #selector(textBoldChanged(_:)))
        stack.addArrangedSubview(boldCheckbox)

        let blurTitle = NSTextField(labelWithString: "Размытие")
        blurTitle.font = .boldSystemFont(ofSize: 14)
        stack.addArrangedSubview(blurTitle)
        blurSlider = slider(min: 1, max: 40, action: #selector(blurChanged(_:)))
        stack.addArrangedSubview(row(label: "Интенсивность", control: blurSlider))

        launchCheckbox = NSButton(checkboxWithTitle: "Запускать вместе с macOS", target: self, action: #selector(launchAtLoginChanged(_:)))
        stack.addArrangedSubview(launchCheckbox)

        notificationCheckbox = NSButton(checkboxWithTitle: "Показывать уведомления", target: self, action: #selector(notificationsChanged(_:)))
        stack.addArrangedSubview(notificationCheckbox)

        let resetButton = NSButton(title: "Сбросить настройки", target: self, action: #selector(resetSettings))
        resetButton.bezelStyle = .rounded
        let closeButton = NSButton(title: "Готово", target: self, action: #selector(closeSettings))
        closeButton.bezelStyle = .rounded
        let buttons = NSStackView(views: [resetButton, closeButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        stack.addArrangedSubview(buttons)

        refreshControls()
    }

    /// Pulls every control back from the store — needed after a reset and when the panel
    /// is reopened rather than rebuilt.
    private func refreshControls() {
        guard hotKeyButton != nil else { return }
        stopRecordingHotKey()
        hotKeyButton.title = HotKeyFormatter.string(
            keyCode: settings.hotKey.keyCode,
            modifiers: settings.hotKey.modifiers
        )
        folderField.stringValue = settings.outputFolderURL.path
        formatPopup.selectItem(withTitle: settings.outputFormat.rawValue)
        colorWell.color = settings.defaultColor
        strokeThicknessSlider.doubleValue = Double(settings.strokeThickness)
        strokeOpacitySlider.doubleValue = Double(settings.strokeOpacity)
        textSizeSlider.doubleValue = Double(settings.textSize)
        textOpacitySlider.doubleValue = Double(settings.textOpacity)
        blurSlider.doubleValue = Double(settings.blurRadius)
        boldCheckbox.state = settings.textBold ? .on : .off
        notificationCheckbox.state = settings.showNotifications ? .on : .off
        launchCheckbox.state = LaunchAtLogin.isEnabled ? .on : .off
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

    @objc private func toggleHotKeyRecording() {
        if recordingHotKey {
            stopRecordingHotKey()
        } else {
            startRecordingHotKey()
        }
    }

    private func startRecordingHotKey() {
        recordingHotKey = true
        hotKeyButton.title = "Нажмите комбинацию… (Esc — отмена)"
        hotKeyRecordingMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.recordingHotKey else { return event }

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

            self.settings.hotKey = HotKeyCombination(keyCode: event.keyCode, modifiers: modifiers)
            self.stopRecordingHotKey()
            return nil
        }
    }

    private func stopRecordingHotKey() {
        recordingHotKey = false
        if let hotKeyRecordingMonitor {
            NSEvent.removeMonitor(hotKeyRecordingMonitor)
            self.hotKeyRecordingMonitor = nil
        }
        hotKeyButton?.title = HotKeyFormatter.string(
            keyCode: settings.hotKey.keyCode,
            modifiers: settings.hotKey.modifiers
        )
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
            self.settings.outputFolderURL = url
            self.folderField.stringValue = url.path
        }
    }

    @objc private func formatChanged(_ sender: NSPopUpButton) {
        if let format = OutputFormat(rawValue: sender.titleOfSelectedItem ?? "PNG") {
            settings.outputFormat = format
        }
    }

    @objc private func colorChanged(_ sender: NSColorWell) { settings.defaultColor = sender.color }
    @objc private func strokeThicknessChanged(_ sender: NSSlider) { settings.strokeThickness = CGFloat(sender.doubleValue) }
    @objc private func strokeOpacityChanged(_ sender: NSSlider) { settings.strokeOpacity = CGFloat(sender.doubleValue) }
    @objc private func textSizeChanged(_ sender: NSSlider) { settings.textSize = CGFloat(sender.doubleValue) }
    @objc private func textOpacityChanged(_ sender: NSSlider) { settings.textOpacity = CGFloat(sender.doubleValue) }
    @objc private func blurChanged(_ sender: NSSlider) { settings.blurRadius = CGFloat(sender.doubleValue) }
    @objc private func textBoldChanged(_ sender: NSButton) { settings.textBold = sender.state == .on }
    @objc private func notificationsChanged(_ sender: NSButton) { settings.showNotifications = sender.state == .on }

    @objc private func launchAtLoginChanged(_ sender: NSButton) {
        let enabled = sender.state == .on
        do {
            try LaunchAtLogin.setEnabled(enabled)
            settings.launchAtLogin = enabled
        } catch {
            // Registration only works from inside a signed .app bundle; failing silently
            // used to leave the checkbox claiming a setting that never took effect.
            sender.state = enabled ? .off : .on
            settings.launchAtLogin = !enabled ? false : settings.launchAtLogin
            let alert = NSAlert()
            alert.messageText = "Не удалось изменить автозапуск"
            alert.informativeText = """
            \(error.localizedDescription)

            Автозапуск работает только для собранного .app из папки «Программы». \
            Соберите приложение через Scripts/build-app.sh и запустите его оттуда.
            """
            alert.runModal()
            sender.state = LaunchAtLogin.isEnabled ? .on : .off
        }
    }

    @objc private func resetSettings() {
        settings.reset()
        // The login item lives in the system, not in UserDefaults: wiping preferences has
        // to take the app back out of the launch list too, otherwise it keeps starting
        // with macOS while the setting reads "off".
        do {
            try LaunchAtLogin.disableIfEnabled()
        } catch {
            ScreenshotOutput.showError("Настройки сброшены, но автозапуск отключить не удалось: \(error.localizedDescription)")
        }
        refreshControls()
    }

    @objc private func closeSettings() { window?.close() }
}
