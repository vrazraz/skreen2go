import AppKit
import Foundation

extension Notification.Name {
    static let skreenSettingsDidChange = Notification.Name("SkreenSettingsDidChange")
}

enum OutputFormat: String, CaseIterable {
    case png = "PNG"
    case jpeg = "JPEG"
}

enum OutputFolderAccessError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        "error.folder.access".localized(
            "No lasting access to the chosen folder. Pick the save folder again in Settings."
        )
    }
}

/// UI language. `system` follows macOS; the others override it inside the app only.
enum InterfaceLanguage: String, CaseIterable {
    case system
    case english = "en"
    case russian = "ru"

    /// The `.lproj` to force, or nil to let the system decide.
    var bundleCode: String? {
        self == .system ? nil : rawValue
    }

    var title: String {
        switch self {
        case .system: return "settings.language.system".localized("System")
        // Endonym: a language is named in itself, the same in every localization.
        case .english: return "English"
        // Endonym.
        case .russian: return "Русский"
        }
    }
}

enum CursorStyle: String, CaseIterable {
    case arrow
    case pointer
    case hand
    case text
    case resize
    case click

    /// Shown in the cursor menu. Kept apart from `rawValue`, which is a stable identifier.
    var title: String {
        switch self {
        case .arrow: return "cursor.arrow".localized("Arrow")
        case .pointer: return "cursor.pointer".localized("Pointing finger")
        case .hand: return "cursor.hand".localized("Open hand")
        case .text: return "cursor.text".localized("Text cursor")
        case .resize: return "cursor.resize".localized("Resize")
        case .click: return "cursor.click".localized("Click indicator")
        }
    }
}

enum AnnotationTool {
    case select
    case arrow
    case rectangle
    case text
    case blur
    case cursor(CursorStyle)
}

struct Annotation {
    let id: UUID
    var kind: AnnotationKind
    var start: CGPoint
    var end: CGPoint
    var rect: CGRect
    var text: String
    var color: NSColor
    var thickness: CGFloat
    var opacity: CGFloat

    init(
        id: UUID = UUID(),
        kind: AnnotationKind,
        start: CGPoint = .zero,
        end: CGPoint = .zero,
        rect: CGRect = .zero,
        text: String = "",
        color: NSColor,
        thickness: CGFloat,
        opacity: CGFloat
    ) {
        self.id = id
        self.kind = kind
        self.start = start
        self.end = end
        self.rect = rect
        self.text = text
        self.color = color
        self.thickness = thickness
        self.opacity = opacity
    }
}

extension Annotation {
    /// Annotations are authored in overlay (screen) coordinates; exporting needs them
    /// relative to the selected region's bottom-left corner.
    func offsetBy(dx: CGFloat, dy: CGFloat) -> Annotation {
        var moved = self
        moved.start = CGPoint(x: start.x + dx, y: start.y + dy)
        moved.end = CGPoint(x: end.x + dx, y: end.y + dy)
        moved.rect = rect.offsetBy(dx: dx, dy: dy)
        return moved
    }
}

/// The subset of tools offered directly on the capture overlay. Blur and the visual
/// cursor need the source bitmap, so they stay in the full editor.
enum OverlayTool: Equatable {
    case none
    case arrow
    case rectangle
    case text

    var annotationKind: AnnotationKind? {
        switch self {
        case .none: return nil
        case .arrow: return .arrow
        case .rectangle: return .rectangle
        case .text: return .text
        }
    }
}

enum AnnotationKind {
    case arrow
    case rectangle
    case text
    case blur
    case cursor(CursorStyle)
}

extension AnnotationKind {
    /// Rubber-banded by dragging, as opposed to placed by a click.
    var isShape: Bool {
        switch self {
        case .arrow, .rectangle, .blur: return true
        case .text, .cursor: return false
        }
    }
}

/// Minimum sizes below which a freshly drawn shape is treated as an accidental click
/// rather than a real annotation.
enum AnnotationGeometry {
    static let minimumShapeSide: CGFloat = 4
    static let minimumArrowLength: CGFloat = 6

    static func isMeaningful(_ annotation: Annotation) -> Bool {
        switch annotation.kind {
        case .arrow:
            let length = hypot(annotation.end.x - annotation.start.x, annotation.end.y - annotation.start.y)
            return length >= minimumArrowLength
        case .rectangle, .blur:
            return annotation.rect.width >= minimumShapeSide && annotation.rect.height >= minimumShapeSide
        case .text:
            return !annotation.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .cursor:
            return annotation.rect.width > 0 && annotation.rect.height > 0
        }
    }
}

struct HotKeyCombination: Equatable {
    var keyCode: UInt16
    var modifiers: NSEvent.ModifierFlags

    /// ⌃⇧S. Deliberately avoids ⌘-based combinations: the hot key is registered
    /// system-wide and swallows the event, so it would otherwise shadow common
    /// shortcuts such as ⌘⇧S ("Save As") in every other application.
    static let `default` = HotKeyCombination(keyCode: 1, modifiers: [.control, .shift])
}

final class SettingsStore {
    static let shared = SettingsStore()

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var hotKey: HotKeyCombination {
        get {
            let keyCode = (defaults.object(forKey: Key.hotKeyKeyCode) as? Int)
                .map { UInt16(truncatingIfNeeded: $0) } ?? HotKeyCombination.default.keyCode
            let modifiers = (defaults.object(forKey: Key.hotKeyModifiers) as? UInt)
                .map { NSEvent.ModifierFlags(rawValue: $0) } ?? HotKeyCombination.default.modifiers
            return HotKeyCombination(keyCode: keyCode, modifiers: modifiers)
        }
        set {
            defaults.set(Int(newValue.keyCode), forKey: Key.hotKeyKeyCode)
            defaults.set(newValue.modifiers.rawValue, forKey: Key.hotKeyModifiers)
            notify()
        }
    }

    var outputFormat: OutputFormat {
        get { OutputFormat(rawValue: defaults.string(forKey: Key.outputFormat) ?? OutputFormat.png.rawValue) ?? .png }
        set { defaults.set(newValue.rawValue, forKey: Key.outputFormat); notify() }
    }

    var outputFolderURL: URL {
        get {
            if let bookmarkData = defaults.data(forKey: Key.outputFolderBookmark),
               let bookmarkedURL = Self.resolveBookmark(bookmarkData, defaults: defaults) {
                return bookmarkedURL
            }
            if let path = defaults.string(forKey: Key.outputFolderPath) {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
            return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser
        }
    }

    /// Stores both the display path and a security-scoped bookmark. A path alone is not
    /// enough for a sandboxed app to regain access after it is relaunched.
    func setOutputFolderURL(_ url: URL) throws {
        let bookmarkData = try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        defaults.set(url.path, forKey: Key.outputFolderPath)
        defaults.set(bookmarkData, forKey: Key.outputFolderBookmark)
        notify()
    }

    /// Runs file-system work while the selected folder's sandbox extension is active.
    /// The default Downloads folder is covered by the app's downloads entitlement and does
    /// not need a bookmark.
    func withOutputFolderAccess<T>(_ body: (URL) throws -> T) throws -> T {
        let folder = outputFolderURL
        let needsSecurityScope = defaults.data(forKey: Key.outputFolderBookmark) != nil
        let didStartAccess = needsSecurityScope && folder.startAccessingSecurityScopedResource()

        guard !needsSecurityScope || didStartAccess else {
            throw OutputFolderAccessError.unavailable
        }

        defer {
            if didStartAccess {
                folder.stopAccessingSecurityScopedResource()
            }
        }
        return try body(folder)
    }

    var defaultColor: NSColor {
        get {
            guard defaults.object(forKey: Key.colorRed) != nil else { return .systemRed }
            // Read back in the same space the components were written in. Reading them as
            // calibratedRGB meant the colour you got out never quite matched the one you
            // put in.
            return NSColor(
                deviceRed: defaults.double(forKey: Key.colorRed),
                green: defaults.double(forKey: Key.colorGreen),
                blue: defaults.double(forKey: Key.colorBlue),
                alpha: defaults.double(forKey: Key.colorAlpha)
            )
        }
        set {
            let color = newValue.usingColorSpace(.deviceRGB) ?? .systemRed
            defaults.set(color.redComponent, forKey: Key.colorRed)
            defaults.set(color.greenComponent, forKey: Key.colorGreen)
            defaults.set(color.blueComponent, forKey: Key.colorBlue)
            defaults.set(color.alphaComponent, forKey: Key.colorAlpha)
            notify()
        }
    }

    var strokeThickness: CGFloat {
        get { CGFloat(defaults.object(forKey: Key.strokeThickness) as? Double ?? 3) }
        set { defaults.set(Double(newValue), forKey: Key.strokeThickness); notify() }
    }

    var strokeOpacity: CGFloat {
        get { CGFloat(defaults.object(forKey: Key.strokeOpacity) as? Double ?? 1) }
        set { defaults.set(Double(newValue), forKey: Key.strokeOpacity); notify() }
    }

    var textSize: CGFloat {
        get { CGFloat(defaults.object(forKey: Key.textSize) as? Double ?? 24) }
        set { defaults.set(Double(newValue), forKey: Key.textSize); notify() }
    }

    var textOpacity: CGFloat {
        get { CGFloat(defaults.object(forKey: Key.textOpacity) as? Double ?? 1) }
        set { defaults.set(Double(newValue), forKey: Key.textOpacity); notify() }
    }

    var textBold: Bool {
        get { defaults.object(forKey: Key.textBold) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.textBold); notify() }
    }

    var blurRadius: CGFloat {
        get { CGFloat(defaults.object(forKey: Key.blurRadius) as? Double ?? 12) }
        set { defaults.set(Double(newValue), forKey: Key.blurRadius); notify() }
    }

    var interfaceLanguage: InterfaceLanguage {
        get {
            InterfaceLanguage(rawValue: defaults.string(forKey: Key.interfaceLanguage) ?? "") ?? .system
        }
        set { defaults.set(newValue.rawValue, forKey: Key.interfaceLanguage); notify() }
    }

    var showNotifications: Bool {
        get { defaults.object(forKey: Key.showNotifications) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.showNotifications); notify() }
    }

    var launchAtLogin: Bool {
        get { defaults.object(forKey: Key.launchAtLogin) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Key.launchAtLogin); notify() }
    }

    func reset() {
        Key.all.forEach { defaults.removeObject(forKey: $0) }
        notify()
    }

    private static func resolveBookmark(_ data: Data, defaults: UserDefaults) -> URL? {
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return nil
        }

        if isStale, let refreshed = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            defaults.set(refreshed, forKey: Key.outputFolderBookmark)
        }
        return url
    }

    private func notify() {
        NotificationCenter.default.post(name: .skreenSettingsDidChange, object: self)
    }

    private enum Key {
        static let hotKeyKeyCode = "hotKeyKeyCode"
        static let hotKeyModifiers = "hotKeyModifiers"
        static let outputFormat = "outputFormat"
        static let outputFolderPath = "outputFolderPath"
        static let outputFolderBookmark = "outputFolderBookmark"
        static let colorRed = "colorRed"
        static let colorGreen = "colorGreen"
        static let colorBlue = "colorBlue"
        static let colorAlpha = "colorAlpha"
        static let strokeThickness = "strokeThickness"
        static let strokeOpacity = "strokeOpacity"
        static let textSize = "textSize"
        static let textOpacity = "textOpacity"
        static let textBold = "textBold"
        static let blurRadius = "blurRadius"
        static let interfaceLanguage = "interfaceLanguage"
        static let showNotifications = "showNotifications"
        static let launchAtLogin = "launchAtLogin"

        static let all = [
            hotKeyKeyCode, hotKeyModifiers, outputFormat, outputFolderPath, outputFolderBookmark,
            colorRed, colorGreen, colorBlue, colorAlpha, strokeThickness,
            strokeOpacity, textSize, textOpacity, textBold, blurRadius,
            showNotifications, launchAtLogin, interfaceLanguage
        ]
    }
}

final class ScreenshotDocument {
    let image: NSImage
    var annotations: [Annotation] = []
    /// Gaussian blur is expensive; the cache keeps one blurred copy per (source, radius)
    /// so dragging a blur rectangle does not re-filter the whole screenshot every frame.
    let blurCache = BlurCache()

    init(image: NSImage) {
        self.image = image
    }
}
