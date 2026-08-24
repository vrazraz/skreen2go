import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
enum ScreenshotOutput {
    static func copy(_ data: Data, settings: SettingsStore) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(data, forType: .png)
        // Some older apps only look for TIFF on the pasteboard.
        if let image = NSImage(data: data), let tiff = image.tiffRepresentation {
            pasteboard.setData(tiff, forType: .tiff)
        }
        report(.copied, settings: settings)
    }

    static func save(_ data: Data, format: OutputFormat, settings: SettingsStore) async throws -> URL {
        let url = try await settings.withOutputFolderAccessAsync { folder in
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = ScreenshotNaming.uniqueURL(in: folder, format: format, date: Date())
            try await ScreenshotFileWriter.shared.write(data, to: url)
            return url
        }
        report(.saved(url), settings: settings)
        return url
    }

    static func makeSavePanel(format: OutputFormat) -> NSSavePanel {
        let panel = NSSavePanel()
        panel.title = "savePanel.title".localized("Save Screenshot")
        panel.nameFieldStringValue = ScreenshotNaming.fileName(for: format, date: Date())
        panel.allowedContentTypes = [format == .png ? .png : .jpeg]
        panel.canCreateDirectories = true
        return panel
    }

    static func write(_ data: Data, to url: URL, settings: SettingsStore) async throws {
        try await ScreenshotFileWriter.shared.write(data, to: url)
        report(.saved(url), settings: settings)
    }

    /// Confirms a finished action, exactly once.
    ///
    /// Deliberately the on-screen toast only. Also posting to `UNUserNotificationCenter`
    /// meant two confirmations for one action, and the toast is the dependable half: it
    /// needs no authorisation, survives Do Not Disturb, and shows whether or not the app
    /// happens to be frontmost.
    static func report(_ outcome: ScreenshotOutcome, settings: SettingsStore) {
        guard settings.showNotifications else { return }
        ToastPresenter.shared.show(outcome)
    }

    static func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "error.title".localized("Error")
        alert.informativeText = message
        alert.runModal()
    }

    /// Flattens a screenshot plus the annotations drawn on the overlay.
    static func data(
        for image: NSImage,
        annotations: [Annotation],
        format: OutputFormat,
        settings: SettingsStore
    ) -> Data? {
        let document = ScreenshotDocument(image: image)
        document.annotations = annotations
        return ImageExporter.data(for: document, format: format, settings: settings)
    }

    /// Flattens a bare screenshot (no annotations) for the overlay's quick actions.
    static func data(for image: NSImage, format: OutputFormat, settings: SettingsStore) -> Data? {
        ImageExporter.data(for: ScreenshotDocument(image: image), format: format, settings: settings)
    }
}
