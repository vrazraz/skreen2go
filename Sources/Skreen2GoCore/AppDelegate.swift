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
@MainActor
final class HotKeyMonitor {
    enum RegistrationResult: Equatable {
        case registered
        case unchanged
        case failed(OSStatus)
    }

    private static var nextIdentifier: UInt32 = 1
    private static let signature: OSType = 0x534B_524E // 'SKRN'

    /// One Carbon handler for the whole process, shared by every monitor.
    ///
    /// Installing it per instance looks harmless and is not: a second
    /// `InstallEventHandler` with the same function, target and event type returns
    /// `eventHandlerAlreadyInstalledErr` (-9866), and the monitor then gave up before it
    /// ever reached `RegisterEventHotKey`. That is what stopped the recording hot key from
    /// registering as soon as there were two of them.
    private static var sharedEventHandler: EventHandlerRef?

    private static func installSharedEventHandler() -> OSStatus {
        guard sharedEventHandler == nil else { return noErr }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        var handler: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            skreenHotKeyHandler,
            1,
            &spec,
            nil,
            &handler
        )
        if status == noErr { sharedEventHandler = handler }
        return status
    }

    private let settings: SettingsStore
    /// Which of the app's hot keys this monitor owns. A key path rather than a fixed
    /// combination, so the monitor re-reads the current value on every reinstall.
    private let combination: KeyPath<SettingsStore, HotKeyCombination>
    private let handler: () -> Void
    private let identifier: UInt32

    private var hotKeyRef: EventHotKeyRef?
    private(set) var registeredCombination: HotKeyCombination?

    init(
        settings: SettingsStore,
        combination: KeyPath<SettingsStore, HotKeyCombination> = \.hotKey,
        handler: @escaping () -> Void
    ) {
        self.settings = settings
        self.combination = combination
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
        let combination = settings[keyPath: self.combination]
        // Settings post a change notification on every slider tick; re-registering the
        // hot key each time was pure churn.
        if registeredCombination == combination, hotKeyRef != nil { return .unchanged }

        uninstall()

        let handlerStatus = HotKeyMonitor.installSharedEventHandler()
        guard handlerStatus == noErr else { return .failed(handlerStatus) }

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

    /// The shared event handler is deliberately left installed: it belongs to the process,
    /// not to this monitor, and removing it here would break whichever other monitor is
    /// still registered. It goes away with the process.
    func tearDown() {
        uninstall()
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyCallbacks[identifier] = nil
    }
}

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum HotKeyRole: Hashable {
        case screenshot
        case recording
    }

    private let settings = SettingsStore.shared
    private let captureController = CaptureController()
    private let recordingController = RecordingController()
    private var statusItem: NSStatusItem?
    private var hotKeyMonitor: HotKeyMonitor!
    private var recordingHotKeyMonitor: HotKeyMonitor!
    private var editorController: EditorPanelController?
    private var settingsController: SettingsPanelController?
    /// Per key: one failed registration should not silence the other key's alert.
    private var reportedHotKeyFailures: Set<HotKeyRole> = []
    private var lastRecordingURL: URL?

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
        // Parsing the animation and standing up its Metal layer is work worth doing now:
        // done lazily it would land on the first copied screenshot, which is the one
        // moment the flourish must not stutter.
        HandFlourish.shared.prepare()
        captureController.onShowSettings = { [weak self] in
            // Called while the capture overlay is up, so it has to sit above it.
            self?.presentSettings(modal: true)
        }

        captureController.onStartRecording = { [weak self] request in
            self?.recordingController.start(request)
        }
        wireRecordingController()
        // A recording an earlier run finished but never filed away is still the user's.
        Task { @MainActor [weak self] in
            await self?.recordingController.recoverStaleRecordings()
        }

        hotKeyMonitor = HotKeyMonitor(settings: settings, combination: \.hotKey) { [weak self] in
            self?.startCapture()
        }
        reportHotKeyRegistration(hotKeyMonitor.install(), for: .screenshot, combination: settings.hotKey)

        recordingHotKeyMonitor = HotKeyMonitor(
            settings: settings,
            combination: \.recordingHotKey
        ) { [weak self] in
            self?.toggleRecording()
        }
        reportHotKeyRegistration(
            recordingHotKeyMonitor.install(),
            for: .recording,
            combination: settings.recordingHotKey
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsChanged),
            name: .skreenSettingsDidChange,
            object: settings
        )
    }

    public func applicationWillTerminate(_ notification: Notification) {
        hotKeyMonitor?.tearDown()
        recordingHotKeyMonitor?.tearDown()
        NotificationCenter.default.removeObserver(self)
    }

    /// An MPEG-4 whose trailer was never written does not play, so quitting mid-recording
    /// waits for the file to be closed rather than taking the app down on top of it.
    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard recordingController.isActive else { return .terminateNow }
        Task { @MainActor in
            await recordingController.finishBeforeTermination()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func wireRecordingController() {
        recordingController.onStateChange = { [weak self] _ in
            self?.updateRecordingIndicator()
        }
        recordingController.onStarted = { [weak self] in
            guard let self else { return }
            // Shown whether or not confirmations are switched off: it is the only place
            // the user is told which key ends the recording.
            let combination = HotKeyFormatter.string(
                keyCode: self.settings.recordingHotKey.keyCode,
                modifiers: self.settings.recordingHotKey.modifiers
            )
            ToastPresenter.shared.show(
                title: "recording.started.title".localized("Recording"),
                detail: "recording.started.detail".localized("Press %@ to stop", combination),
                symbolName: "record.circle"
            )
        }
        recordingController.onSaved = { [weak self] url in
            guard let self else { return }
            self.lastRecordingURL = url
            guard self.settings.showNotifications else { return }
            ToastPresenter.shared.show(
                title: "recording.saved.title".localized("Recording saved"),
                detail: url.lastPathComponent,
                symbolName: "checkmark.circle.fill",
                duration: 4.5,
                onClick: { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            )
        }
        recordingController.onNotice = { [weak self] notice in
            guard self?.settings.showNotifications == true else { return }
            ToastPresenter.shared.show(
                title: "recording.notice.title".localized("Recording"),
                detail: notice.message,
                symbolName: "info.circle.fill"
            )
        }
        recordingController.onError = { [weak self] message in
            self?.showRecordingError(message)
        }
    }

    @objc private func toggleRecording() {
        if recordingController.isActive {
            recordingController.stopOrCancel()
            return
        }
        editorController?.close()
        editorController = nil
        captureController.start(mode: .recording)
    }

    @objc private func revealLastRecording() {
        guard let lastRecordingURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([lastRecordingURL])
    }

    /// macOS puts its own indicator in the menu bar for as long as anything is capturing
    /// the screen — it cannot be suppressed, and clicking it stops the capture. Ours would
    /// be a second stop button standing right next to it, so it steps aside for the
    /// duration and comes back when the recording is over.
    ///
    /// Stopping through the system indicator is not merely a hard stop: it ends our stream,
    /// which reaches `onUnexpectedStop` and finishes the file exactly as our own stop does.
    private func updateRecordingIndicator() {
        statusItem?.isVisible = !recordingController.isActive
    }

    private func configureStatusItem() {
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }

        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.statusItem = statusItem
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

        let recordItem = NSMenuItem(title: "menu.record".localized("Record Screen"), action: #selector(toggleRecording), keyEquivalent: "")
        recordItem.target = self
        menu.addItem(recordItem)

        if lastRecordingURL != nil {
            let revealItem = NSMenuItem(
                title: "menu.recording.reveal".localized("Show Last Recording"),
                action: #selector(revealLastRecording),
                keyEquivalent: ""
            )
            revealItem.target = self
            menu.addItem(revealItem)
        }

        // No key equivalents anywhere in this menu. One would be live rather than
        // decorative — AppKit matches it while the menu is open — and the screenshot hot
        // key is already registered system-wide, so the same press would arrive twice and
        // `start`, which reads a second trigger as "dismiss the overlay", would cancel
        // itself out. Rather than have shortcuts on some items and not the one that would
        // matter, the menu shows none.
        let settingsItem = NSMenuItem(title: "menu.settings".localized("Settings…"), action: #selector(showSettingsFromMenu), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "menu.quit".localized("Quit"), action: #selector(terminate), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        // A language change rebuilds the item from scratch, which can happen mid-session.
        statusItem.isVisible = !recordingController.isActive
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
        if let hotKeyMonitor {
            let result = hotKeyMonitor.install()
            if result != .unchanged {
                reportHotKeyRegistration(result, for: .screenshot, combination: settings.hotKey)
            }
        }
        if let recordingHotKeyMonitor {
            let result = recordingHotKeyMonitor.install()
            if result != .unchanged {
                reportHotKeyRegistration(result, for: .recording, combination: settings.recordingHotKey)
            }
        }
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

    private func reportHotKeyRegistration(
        _ result: HotKeyMonitor.RegistrationResult,
        for role: HotKeyRole,
        combination hotKey: HotKeyCombination
    ) {
        guard case .failed(let status) = result else {
            reportedHotKeyFailures.remove(role)
            return
        }
        guard !reportedHotKeyFailures.contains(role) else { return }
        reportedHotKeyFailures.insert(role)

        // Never modal from inside `applicationDidFinishLaunching`. The app is `.accessory`
        // and has not activated, so the alert stays behind everything while its nested
        // modal loop stops the menu bar icon from answering a single click — the app looks
        // frozen, and the one thing the alert suggests, opening Settings, is unreachable.
        DispatchQueue.main.async { [weak self] in
            self?.presentHotKeyFailure(status: status, combination: hotKey)
        }
    }

    private func presentHotKeyFailure(status: OSStatus, combination hotKey: HotKeyCombination) {
        // Named from the key that actually failed — reading it back off `settings.hotKey`
        // would blame the screenshot combination for the recording key's failure.
        let combination = HotKeyFormatter.string(
            keyCode: hotKey.keyCode,
            modifiers: hotKey.modifiers
        )
        // Without this the alert opens behind whatever is frontmost and cannot be answered.
        NSApp.activate(ignoringOtherApps: true)
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

    private func showRecordingError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "error.recording.title".localized("Could not record the screen")
        alert.informativeText = message
        alert.addButton(withTitle: "button.openSystemSettings".localized("Open macOS Settings"))
        alert.addButton(withTitle: "button.close".localized("Close"))
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
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
