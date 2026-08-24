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

    /// Keeps an annotation inside an image or selection. Text is represented by its
    /// insertion point, so callers may provide its measured bounds to keep the whole
    /// rendered string visible.
    static func clamped(
        _ annotation: Annotation,
        to bounds: CGRect,
        textBounds: CGRect? = nil
    ) -> Annotation {
        var result = annotation
        switch annotation.kind {
        case .arrow:
            result.start = clamp(annotation.start, to: bounds)
            result.end = clamp(annotation.end, to: bounds)
        case .rectangle, .blur, .cursor:
            result.rect = clamp(annotation.rect, to: bounds)
        case .text:
            let measured = textBounds ?? annotation.rect
            let visible = clamp(
                CGRect(origin: annotation.rect.origin, size: measured.size),
                to: bounds
            )
            result.rect.origin = visible.origin
        }
        return result
    }

    private static func clamp(_ point: CGPoint, to bounds: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX),
            y: min(max(point.y, bounds.minY), bounds.maxY)
        )
    }

    private static func clamp(_ rect: CGRect, to bounds: CGRect) -> CGRect {
        let width = min(max(0, rect.width), bounds.width)
        let height = min(max(0, rect.height), bounds.height)
        let x = min(max(rect.minX, bounds.minX), bounds.maxX - width)
        let y = min(max(rect.minY, bounds.minY), bounds.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

struct HotKeyCombination: Equatable {
    var keyCode: UInt16
    var modifiers: NSEvent.ModifierFlags

    /// ⌃⇧S. Deliberately avoids ⌘-based combinations: the hot key is registered
    /// system-wide and swallows the event, so it would otherwise shadow common
    /// shortcuts such as ⌘⇧S ("Save As") in every other application.
    static let `default` = HotKeyCombination(keyCode: 1, modifiers: [.control, .shift])

    /// ⌃⇧R, avoiding ⌘ for the same reason. One key covers the whole recording session:
    /// it starts a selection, cancels the countdown, and stops a running recording.
    static let defaultRecording = HotKeyCombination(keyCode: 15, modifiers: [.control, .shift])
}

enum AppKeyboardShortcut {
    static func isCommandC(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        keyCode == 8 && modifiers.intersection(.deviceIndependentFlagsMask) == [.command]
    }
}

final class SettingsStore {
    static let shared = SettingsStore()

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var hotKey: HotKeyCombination {
        get {
            Self.combination(
                in: defaults,
                keyCodeKey: Key.hotKeyKeyCode,
                modifiersKey: Key.hotKeyModifiers,
                fallback: .default
            )
        }
        set {
            // Both hot keys are registered system-wide. If they held the same combination
            // only one registration would win and the other would be silently dead, so a
            // clashing assignment is refused rather than stored.
            guard newValue != recordingHotKey else { return }
            store(
                newValue,
                keyCodeKey: Key.hotKeyKeyCode,
                modifiersKey: Key.hotKeyModifiers,
                fallback: .default
            )
        }
    }

    /// Starts a recording selection, cancels the countdown, and stops a running
    /// recording — one combination for the whole session.
    var recordingHotKey: HotKeyCombination {
        get {
            Self.combination(
                in: defaults,
                keyCodeKey: Key.recordingHotKeyKeyCode,
                modifiersKey: Key.recordingHotKeyModifiers,
                fallback: .defaultRecording
            )
        }
        set {
            guard newValue != hotKey else { return }
            store(
                newValue,
                keyCodeKey: Key.recordingHotKeyKeyCode,
                modifiersKey: Key.recordingHotKeyModifiers,
                fallback: .defaultRecording
            )
        }
    }

    private static func combination(
        in defaults: UserDefaults,
        keyCodeKey: String,
        modifiersKey: String,
        fallback: HotKeyCombination
    ) -> HotKeyCombination {
        let storedKeyCode = (defaults.object(forKey: keyCodeKey) as? NSNumber)?.intValue
        let storedModifiers = (defaults.object(forKey: modifiersKey) as? NSNumber)?.uintValue
        let keyCode: UInt16
        if let storedKeyCode {
            guard (0...127).contains(storedKeyCode) else { return fallback }
            keyCode = UInt16(storedKeyCode)
        } else {
            keyCode = fallback.keyCode
        }
        let modifiers = storedModifiers.map {
            NSEvent.ModifierFlags(rawValue: $0).intersection(.deviceIndependentFlagsMask)
        } ?? fallback.modifiers
        guard !modifiers.isEmpty else { return fallback }
        return HotKeyCombination(keyCode: keyCode, modifiers: modifiers)
    }

    private func store(
        _ combination: HotKeyCombination,
        keyCodeKey: String,
        modifiersKey: String,
        fallback: HotKeyCombination
    ) {
        let keyCode = (0...127).contains(Int(combination.keyCode))
            ? combination.keyCode
            : fallback.keyCode
        let modifiers = combination.modifiers.intersection(.deviceIndependentFlagsMask)
        let validModifiers = modifiers.isEmpty ? fallback.modifiers : modifiers
        defaults.set(Int(keyCode), forKey: keyCodeKey)
        defaults.set(validModifiers.rawValue, forKey: modifiersKey)
        notify()
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

    /// Async counterpart used by screenshot saving. The security-scoped extension stays
    /// active while the file writer actor performs the actual disk I/O.
    func withOutputFolderAccessAsync<T>(_ body: (URL) async throws -> T) async throws -> T {
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
        return try await body(folder)
    }

    var defaultColor: NSColor {
        get {
            guard defaults.object(forKey: Key.colorRed) != nil else { return .systemRed }
            // Read back in the same space the components were written in. Reading them as
            // calibratedRGB meant the colour you got out never quite matched the one you
            // put in.
            return NSColor(
                deviceRed: Self.finiteComponent(Self.double(for: Key.colorRed, in: defaults, default: 0)),
                green: Self.finiteComponent(Self.double(for: Key.colorGreen, in: defaults, default: 0)),
                blue: Self.finiteComponent(Self.double(for: Key.colorBlue, in: defaults, default: 0)),
                alpha: Self.finiteComponent(Self.double(for: Key.colorAlpha, in: defaults, default: 1))
            )
        }
        set {
            let color = newValue.usingColorSpace(.deviceRGB) ?? .systemRed
            defaults.set(Self.finiteComponent(color.redComponent), forKey: Key.colorRed)
            defaults.set(Self.finiteComponent(color.greenComponent), forKey: Key.colorGreen)
            defaults.set(Self.finiteComponent(color.blueComponent), forKey: Key.colorBlue)
            defaults.set(Self.finiteComponent(color.alphaComponent), forKey: Key.colorAlpha)
            notify()
        }
    }

    var strokeThickness: CGFloat {
        get { Self.clamped(Self.double(for: Key.strokeThickness, in: defaults, default: 3), to: 1...16, default: 3) }
        set { defaults.set(Double(Self.clamped(newValue, to: 1...16, default: 3)), forKey: Key.strokeThickness); notify() }
    }

    var strokeOpacity: CGFloat {
        get { Self.clamped(Self.double(for: Key.strokeOpacity, in: defaults, default: 1), to: 0.1...1, default: 1) }
        set { defaults.set(Double(Self.clamped(newValue, to: 0.1...1, default: 1)), forKey: Key.strokeOpacity); notify() }
    }

    var textSize: CGFloat {
        get { Self.clamped(Self.double(for: Key.textSize, in: defaults, default: 24), to: 10...72, default: 24) }
        set { defaults.set(Double(Self.clamped(newValue, to: 10...72, default: 24)), forKey: Key.textSize); notify() }
    }

    var textOpacity: CGFloat {
        get { Self.clamped(Self.double(for: Key.textOpacity, in: defaults, default: 1), to: 0.1...1, default: 1) }
        set { defaults.set(Double(Self.clamped(newValue, to: 0.1...1, default: 1)), forKey: Key.textOpacity); notify() }
    }

    var textBold: Bool {
        get { defaults.object(forKey: Key.textBold) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.textBold); notify() }
    }

    var blurRadius: CGFloat {
        get { Self.clamped(Self.double(for: Key.blurRadius, in: defaults, default: 12), to: 1...40, default: 12) }
        set { defaults.set(Double(Self.clamped(newValue, to: 1...40, default: 12)), forKey: Key.blurRadius); notify() }
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

    /// Both audio sources default to off: a recording that silently carries the room or
    /// the user's music is a worse surprise than one that is missing sound.
    var recordsSystemAudio: Bool {
        get { defaults.object(forKey: Key.recordsSystemAudio) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Key.recordsSystemAudio); notify() }
    }

    var recordsMicrophone: Bool {
        get { defaults.object(forKey: Key.recordsMicrophone) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Key.recordsMicrophone); notify() }
    }

    /// Unlike a screenshot, where the pointer is noise, a screencast without it leaves the
    /// viewer guessing where the click landed.
    var showsCursorInRecording: Bool {
        get { defaults.object(forKey: Key.showsCursorInRecording) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.showsCursorInRecording); notify() }
    }

    var showsClicksInRecording: Bool {
        get { defaults.object(forKey: Key.showsClicksInRecording) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.showsClicksInRecording); notify() }
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

    private static func finiteComponent<T: BinaryFloatingPoint>(_ value: T) -> CGFloat {
        guard value.isFinite else { return 1 }
        return CGFloat(min(max(value, 0), 1))
    }

    private static func double(for key: String, in defaults: UserDefaults, default fallback: Double) -> Double {
        (defaults.object(forKey: key) as? NSNumber)?.doubleValue ?? fallback
    }

    private static func clamped<T: BinaryFloatingPoint>(
        _ value: T,
        to range: ClosedRange<T>,
        default fallback: T
    ) -> CGFloat {
        guard value.isFinite else { return CGFloat(fallback) }
        return CGFloat(min(max(value, range.lowerBound), range.upperBound))
    }

    private enum Key {
        static let hotKeyKeyCode = "hotKeyKeyCode"
        static let hotKeyModifiers = "hotKeyModifiers"
        static let recordingHotKeyKeyCode = "recordingHotKeyKeyCode"
        static let recordingHotKeyModifiers = "recordingHotKeyModifiers"
        static let recordsSystemAudio = "recordsSystemAudio"
        static let recordsMicrophone = "recordsMicrophone"
        static let showsCursorInRecording = "showsCursorInRecording"
        static let showsClicksInRecording = "showsClicksInRecording"
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
            showNotifications, launchAtLogin, interfaceLanguage,
            recordingHotKeyKeyCode, recordingHotKeyModifiers, recordsSystemAudio,
            recordsMicrophone, showsCursorInRecording, showsClicksInRecording
        ]
    }
}

final class ScreenshotDocument {
    let image: NSImage
    let session = AnnotationSession()

    var annotations: [Annotation] {
        get { session.annotations }
        set { session.annotations = newValue }
    }
    /// Gaussian blur is expensive; the cache keeps one blurred copy per (source, radius)
    /// so dragging a blur rectangle does not re-filter the whole screenshot every frame.
    let blurCache = BlurCache()

    init(image: NSImage) {
        self.image = image
    }
}
