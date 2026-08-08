import AppKit
import Carbon.HIToolbox
import Foundation

private var hotKeyCallbacks: [UInt32: () -> Void] = [:]

private func skreenHotKeyHandler(
    _ callRef: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr else { return status }
    hotKeyCallbacks[hotKeyID.id]?()
    return noErr
}

/// Registers the shortcut with Carbon rather than `NSEvent.addGlobalMonitorForEvents`.
/// The monitor approach needed Input Monitoring permission that the app never requested,
/// and it could not swallow the event — the combination also reached whatever app was
/// frontmost. `RegisterEventHotKey` needs no extra permission and consumes the key.
final class HotKeyMonitor {
    enum RegistrationResult: Equatable {
        case registered
        case unchanged
        case failed(OSStatus)
    }

    private static var nextIdentifier: UInt32 = 1
    private static let signature: OSType = 0x534B_524E // 'SKRN'

    private let settings: SettingsStore
    private let handler: () -> Void
    private let identifier: UInt32

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private(set) var registeredCombination: HotKeyCombination?

    init(settings: SettingsStore, handler: @escaping () -> Void) {
        self.settings = settings
        self.handler = handler
        self.identifier = HotKeyMonitor.nextIdentifier
        HotKeyMonitor.nextIdentifier += 1
    }

    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        return result
    }

    @discardableResult
    func install() -> RegistrationResult {
        let combination = settings.hotKey
        // Settings post a change notification on every slider tick; re-registering the
        // hot key each time was pure churn.
        if registeredCombination == combination, hotKeyRef != nil { return .unchanged }

        uninstall()

        if eventHandler == nil {
            var spec = EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            )
            let status = InstallEventHandler(
                GetApplicationEventTarget(),
                skreenHotKeyHandler,
                1,
                &spec,
                nil,
                &eventHandler
            )
            guard status == noErr else { return .failed(status) }
        }

        hotKeyCallbacks[identifier] = handler
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(combination.keyCode),
            HotKeyMonitor.carbonModifiers(combination.modifiers),
            EventHotKeyID(signature: HotKeyMonitor.signature, id: identifier),
            GetApplicationEventTarget(),
            0,
            &ref
        )

        guard status == noErr, let ref else {
            hotKeyCallbacks[identifier] = nil
            return .failed(status)
        }

        hotKeyRef = ref
        registeredCombination = combination
        return .registered
    }

    func uninstall() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        hotKeyCallbacks[identifier] = nil
        registeredCombination = nil
    }

    func tearDown() {
        uninstall()
        if let eventHandler { RemoveEventHandler(eventHandler) }
        eventHandler = nil
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
        hotKeyCallbacks[identifier] = nil
    }
}

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = SettingsStore.shared
    private let captureController = CaptureController()
    private var statusItem: NSStatusItem!
    private var hotKeyMonitor: HotKeyMonitor!
    private var editorController: EditorPanelController?
    private var settingsController: SettingsPanelController?
    private var hasReportedHotKeyFailure = false

    public override init() {
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        L10n.overrideLanguage = settings.interfaceLanguage.bundleCode
        configureStatusItem()

        captureController.onImageCaptured = { [weak self] image, selectionFrame, annotations in
            self?.presentEditor(image: image, selectionFrame: selectionFrame, annotations: annotations)
        }
        captureController.onError = { [weak self] message in
            self?.showCaptureError(message)
        }
        // The flight animation lands on the menu bar icon, whose position only the status
        // item knows.
        CaptureFlash.shared.destinationProvider = { [weak self] in
            self?.statusItem?.button?.window?.frame
        }
        captureController.onShowSettings = { [weak self] in
            // Called while the capture overlay is up, so it has to sit above it.
            self?.presentSettings(modal: true)
        }

        hotKeyMonitor = HotKeyMonitor(settings: settings) { [weak self] in
            self?.startCapture()
        }
        reportHotKeyRegistration(hotKeyMonitor.install())

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsChanged),
            name: .skreenSettingsDidChange,
            object: settings
        )
    }

    public func applicationWillTerminate(_ notification: Notification) {
        hotKeyMonitor?.tearDown()
        NotificationCenter.default.removeObserver(self)
    }

    private func configureStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem.button else { return }
        let image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "menu.capture".localized("Take Screenshot"))
        image?.isTemplate = true
        button.image = image
        button.toolTip = "menu.statusItem.tooltip".localized("Skreen2Go — take a screenshot")

        let menu = NSMenu()
        menu.autoenablesItems = false

        let captureItem = NSMenuItem(title: "menu.capture".localized("Take Screenshot"), action: #selector(startCapture), keyEquivalent: "")
        captureItem.target = self
        menu.addItem(captureItem)

        let settingsItem = NSMenuItem(title: "menu.settings".localized("Settings…"), action: #selector(showSettingsFromMenu), keyEquivalent: ",")
        settingsItem.keyEquivalentModifierMask = [.command]
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "menu.quit".localized("Quit"), action: #selector(terminate), keyEquivalent: "q")
        quitItem.keyEquivalentModifierMask = [.command]
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func presentEditor(image: NSImage, selectionFrame: CGRect, annotations: [Annotation]) {
        editorController?.close()
        let editor = EditorPanelController(
            image: image,
            selectionFrame: selectionFrame,
            settings: settings,
            annotations: annotations
        )
        editor.onClose = { [weak self] in
            self?.editorController = nil
        }
        editorController = editor
        editor.show()
    }

    @objc private func settingsChanged() {
        let language = settings.interfaceLanguage.bundleCode
        if L10n.overrideLanguage != language {
            L10n.overrideLanguage = language
            // The menu was built in the previous language.
            configureStatusItem()
        }
        guard let hotKeyMonitor else { return }
        let result = hotKeyMonitor.install()
        if result != .unchanged { reportHotKeyRegistration(result) }
    }

    @objc private func startCapture() {
        editorController?.close()
        editorController = nil
        captureController.start()
    }

    @objc private func showSettingsFromMenu() {
        presentSettings(modal: false)
    }

    private func presentSettings(modal: Bool) {
        // Reuse the existing controller. Replacing it dropped the only strong reference
        // to a window that was still on screen.
        if let settingsController {
            settingsController.show(modal: modal)
            return
        }
        let controller = SettingsPanelController(settings: settings)
        controller.onClose = { [weak self] in
            self?.settingsController = nil
        }
        settingsController = controller
        controller.show(modal: modal)
    }

    @objc private func terminate() {
        NSApp.terminate(nil)
    }

    private func reportHotKeyRegistration(_ result: HotKeyMonitor.RegistrationResult) {
        guard case .failed(let status) = result else {
            hasReportedHotKeyFailure = false
            return
        }
        guard !hasReportedHotKeyFailure else { return }
        hasReportedHotKeyFailure = true

        let combination = HotKeyFormatter.string(
            keyCode: settings.hotKey.keyCode,
            modifiers: settings.hotKey.modifiers
        )
        let alert = NSAlert()
        alert.messageText = "error.hotKey.title".localized("Hot key not registered")
        alert.informativeText = "error.hotKey.body".localized(
            "The combination %1$@ could not be assigned (error %2$d).",
            combination,
            Int(status)
        )
        alert.addButton(withTitle: "button.openSettings".localized("Open Settings"))
        alert.addButton(withTitle: "button.close".localized("Close"))
        if alert.runModal() == .alertFirstButtonReturn {
            presentSettings(modal: false)
        }
    }

    private func showCaptureError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "error.capture.title".localized("Could not take the screenshot")
        alert.informativeText = message
        alert.addButton(withTitle: "button.openSystemSettings".localized("Open macOS Settings"))
        alert.addButton(withTitle: "button.close".localized("Close"))
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
