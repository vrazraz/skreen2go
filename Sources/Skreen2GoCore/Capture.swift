import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

struct WindowInfo {
    let id: CGWindowID
    let frame: CGRect
    let ownerName: String
    let title: String
}

enum CaptureError: LocalizedError {
    case permissionDenied
    case windowUnavailable
    case displayUnavailable
    case renderFailed
    case underlying(Error)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Нет доступа к записи экрана. Откройте «Системные настройки → Конфиденциальность и безопасность → Запись экрана» и включите Skreen2Go, затем перезапустите приложение."
        case .windowUnavailable:
            return "Окно исчезло до того, как удалось сделать снимок."
        case .displayUnavailable:
            return "Не удалось определить дисплей для выбранной области."
        case .renderFailed:
            return "Не удалось собрать изображение из захваченных данных."
        case .underlying(let error):
            return "Не удалось сделать снимок: \(error.localizedDescription)"
        }
    }
}

enum ScreenGeometry {
    static func displayID(for screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            ?? CGMainDisplayID()
    }

    static func quartzPoint(for cocoaPoint: CGPoint) -> CGPoint? {
        guard let screen = screen(containingCocoaPoint: cocoaPoint) else { return nil }
        let displayBounds = CGDisplayBounds(displayID(for: screen))
        let scaleX = displayBounds.width / screen.frame.width
        let scaleY = displayBounds.height / screen.frame.height
        let localX = (cocoaPoint.x - screen.frame.minX) * scaleX
        let localYFromTop = (screen.frame.maxY - cocoaPoint.y) * scaleY
        return CGPoint(x: displayBounds.minX + localX, y: displayBounds.minY + localYFromTop)
    }

    /// `NSRect.contains` excludes the top and right edges, which loses the cursor on the
    /// last row of pixels of a display; nudge such points back inside before matching.
    static func screen(containingCocoaPoint point: CGPoint) -> NSScreen? {
        if let exact = NSScreen.screens.first(where: { $0.frame.contains(point) }) { return exact }
        return NSScreen.screens.first { screen in
            let frame = screen.frame.insetBy(dx: -0.5, dy: -0.5)
            return frame.contains(point)
        }
    }

    static func quartzRect(for cocoaRect: CGRect, on screen: NSScreen) -> CGRect {
        let displayBounds = CGDisplayBounds(displayID(for: screen))
        let scaleX = displayBounds.width / screen.frame.width
        let scaleY = displayBounds.height / screen.frame.height
        let x = displayBounds.minX + (cocoaRect.minX - screen.frame.minX) * scaleX
        let y = displayBounds.minY + (screen.frame.maxY - cocoaRect.maxY) * scaleY
        return CGRect(
            x: x,
            y: y,
            width: cocoaRect.width * scaleX,
            height: cocoaRect.height * scaleY
        )
    }

    /// Rect relative to the display's own top-left corner, in points — the coordinate
    /// system `SCStreamConfiguration.sourceRect` expects.
    static func displayLocalRect(for cocoaRect: CGRect, on screen: NSScreen) -> CGRect {
        CGRect(
            x: cocoaRect.minX - screen.frame.minX,
            y: screen.frame.maxY - cocoaRect.maxY,
            width: cocoaRect.width,
            height: cocoaRect.height
        )
    }

    /// Picks the display that actually holds most of the rect. Matching the *first*
    /// intersecting screen converted windows straddling two displays using the wrong
    /// display's scale factor.
    static func screen(bestMatchingQuartzRect quartzRect: CGRect) -> NSScreen? {
        NSScreen.screens
            .compactMap { screen -> (NSScreen, CGFloat)? in
                let overlap = CGDisplayBounds(displayID(for: screen)).intersection(quartzRect)
                guard !overlap.isNull, overlap.width > 0, overlap.height > 0 else { return nil }
                return (screen, overlap.width * overlap.height)
            }
            .max { $0.1 < $1.1 }?
            .0
    }

    static func cocoaRect(for quartzRect: CGRect) -> CGRect? {
        guard let screen = screen(bestMatchingQuartzRect: quartzRect) else { return nil }

        let displayBounds = CGDisplayBounds(displayID(for: screen))
        let scaleX = screen.frame.width / displayBounds.width
        let scaleY = screen.frame.height / displayBounds.height
        let x = screen.frame.minX + (quartzRect.minX - displayBounds.minX) * scaleX
        let y = screen.frame.minY + (displayBounds.maxY - quartzRect.maxY) * scaleY
        return CGRect(
            x: x,
            y: y,
            width: quartzRect.width * scaleX,
            height: quartzRect.height * scaleY
        )
    }

    static func windowAtCocoaPoint(_ cocoaPoint: CGPoint) -> WindowInfo? {
        guard let quartzPoint = quartzPoint(for: cocoaPoint) else { return nil }
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return nil }

        let ownPID = ProcessInfo.processInfo.processIdentifier

        for window in windowList {
            guard
                let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue,
                layer == 0,
                let alpha = (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue,
                alpha > 0.01,
                let pid = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                pid != ownPID,
                let boundsDictionary = window[kCGWindowBounds as String] as? NSDictionary,
                let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary),
                bounds.width > 20,
                bounds.height > 20,
                bounds.contains(quartzPoint),
                let windowNumber = (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                let cocoaFrame = cocoaRect(for: bounds)
            else { continue }

            let owner = window[kCGWindowOwnerName as String] as? String ?? ""
            let title = window[kCGWindowName as String] as? String ?? ""
            return WindowInfo(id: windowNumber, frame: cocoaFrame, ownerName: owner, title: title)
        }

        return nil
    }
}

/// Builds an `NSImage` that keeps a real `NSBitmapImageRep`, so downstream code can
/// recover the pixel dimensions. `NSImage(cgImage:size:)` produces an
/// `NSCGImageSnapshotRep` instead, which used to make the exporter silently fall back
/// to 1x and throw away Retina detail.
func makeImage(from cgImage: CGImage, pointSize: CGSize) -> NSImage {
    let representation = NSBitmapImageRep(cgImage: cgImage)
    representation.size = pointSize
    let image = NSImage(size: pointSize)
    image.addRepresentation(representation)
    return image
}

@MainActor
final class ScreenshotCapture {
    /// `SCStreamErrorDomain` code for "the user declined screen recording".
    private static let userDeclinedErrorCode = -3801

    var hasScreenRecordingAccess: Bool {
        CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    func requestScreenRecordingAccessIfNeeded() -> Bool {
        guard !hasScreenRecordingAccess else { return true }
        return CGRequestScreenCaptureAccess()
    }

    private func shareableContent() async throws -> SCShareableContent {
        guard hasScreenRecordingAccess else { throw CaptureError.permissionDenied }
        do {
            return try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            if (error as NSError).code == Self.userDeclinedErrorCode { throw CaptureError.permissionDenied }
            throw CaptureError.underlying(error)
        }
    }

    private func captureImage(filter: SCContentFilter, configuration: SCStreamConfiguration) async throws -> CGImage {
        do {
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        } catch {
            if (error as NSError).code == Self.userDeclinedErrorCode { throw CaptureError.permissionDenied }
            throw CaptureError.underlying(error)
        }
    }

    func captureWindow(_ window: WindowInfo) async throws -> NSImage {
        let content = try await shareableContent()
        guard let target = content.windows.first(where: { $0.windowID == window.id }) else {
            throw CaptureError.windowUnavailable
        }

        let filter = SCContentFilter(desktopIndependentWindow: target)
        let contentRect = filter.contentRect
        guard contentRect.width > 0, contentRect.height > 0 else { throw CaptureError.windowUnavailable }
        let scale = CGFloat(filter.pointPixelScale)

        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int((contentRect.width * scale).rounded()))
        configuration.height = max(1, Int((contentRect.height * scale).rounded()))
        configuration.captureResolution = .best
        configuration.scalesToFit = false
        configuration.showsCursor = false
        // PRD §4: neither the drop shadow nor the rounded corner mask belongs in the shot.
        configuration.ignoreShadowsSingleWindow = true
        configuration.ignoreGlobalClipSingleWindow = true

        let cgImage = try await captureImage(filter: filter, configuration: configuration)
        return makeImage(from: cgImage, pointSize: contentRect.size)
    }

    func captureArea(_ area: CGRect) async throws -> NSImage {
        let content = try await shareableContent()
        // Excluding our own process is what keeps the dimming overlay out of the
        // screenshot — previously this relied on `orderOut` winning a race against the
        // window server.
        let ownApplications = content.applications.filter {
            $0.processID == ProcessInfo.processInfo.processIdentifier
        }

        let screens = NSScreen.screens.filter { $0.frame.intersects(area) }
        guard !screens.isEmpty else { throw CaptureError.displayUnavailable }

        let scale = screens.map(\.backingScaleFactor).max() ?? 1
        let pixelWidth = max(1, Int((area.width * scale).rounded()))
        let pixelHeight = max(1, Int((area.height * scale).rounded()))

        var tiles: [(image: CGImage, rect: CGRect)] = []
        for screen in screens {
            let intersection = area.intersection(screen.frame)
            guard !intersection.isNull, intersection.width > 1, intersection.height > 1 else { continue }
            guard let display = content.displays.first(where: {
                $0.displayID == ScreenGeometry.displayID(for: screen)
            }) else { continue }

            let filter = SCContentFilter(
                display: display,
                excludingApplications: ownApplications,
                exceptingWindows: []
            )
            let sourceRect = ScreenGeometry.displayLocalRect(for: intersection, on: screen)

            let configuration = SCStreamConfiguration()
            configuration.sourceRect = sourceRect
            configuration.width = max(1, Int((sourceRect.width * scale).rounded()))
            configuration.height = max(1, Int((sourceRect.height * scale).rounded()))
            configuration.captureResolution = .best
            configuration.scalesToFit = false
            configuration.showsCursor = false

            let cgImage = try await captureImage(filter: filter, configuration: configuration)
            tiles.append((cgImage, intersection))
        }

        guard !tiles.isEmpty else { throw CaptureError.displayUnavailable }
        return try composite(tiles: tiles, area: area, scale: scale, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
    }

    private func composite(
        tiles: [(image: CGImage, rect: CGRect)],
        area: CGRect,
        scale: CGFloat,
        pixelWidth: Int,
        pixelHeight: Int
    ) throws -> NSImage {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelWidth,
            pixelsHigh: pixelHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: .alphaFirst,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { throw CaptureError.renderFailed }

        guard let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw CaptureError.renderFailed
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        // Opaque backdrop: a selection spanning displays of different sizes has gaps that
        // would otherwise stay transparent and turn into garbage once exported as JPEG.
        NSColor.black.setFill()
        NSRect(origin: .zero, size: NSSize(width: pixelWidth, height: pixelHeight)).fill()

        for tile in tiles {
            let destination = CGRect(
                x: (tile.rect.minX - area.minX) * scale,
                y: (tile.rect.minY - area.minY) * scale,
                width: tile.rect.width * scale,
                height: tile.rect.height * scale
            )
            graphicsContext.cgContext.draw(tile.image, in: destination)
        }

        graphicsContext.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        bitmap.size = area.size
        let image = NSImage(size: area.size)
        image.addRepresentation(bitmap)
        return image
    }
}

/// Selection frame outline: a grey core between two hairlines, so at least one of the
/// three always contrasts with what is underneath. A plain white border used to vanish
/// over light content.
///
/// Which side gets which hairline matters. Outside the selection the overlay has already
/// dimmed everything, so a *light* hairline reads there. Inside is untouched screen
/// content that may be anything, and white content is the hard case — so the *dark*
/// hairline goes inward.
enum SelectionBorder {
    static let coreColor = NSColor(white: 0.62, alpha: 1)
    static let coreWidth: CGFloat = 2

    static func stroke(_ rect: CGRect, scale: CGFloat = 1) {
        let hairline = max(1, 1 / scale)
        let core = coreWidth / scale
        let offset = (core + hairline) / 2

        NSColor.white.withAlphaComponent(0.9).setStroke()
        strokeRect(rect.insetBy(dx: -offset, dy: -offset), lineWidth: hairline)

        NSColor.black.withAlphaComponent(0.75).setStroke()
        strokeRect(rect.insetBy(dx: offset, dy: offset), lineWidth: hairline)

        coreColor.setStroke()
        strokeRect(rect, lineWidth: core)
    }

    private static func strokeRect(_ rect: CGRect, lineWidth: CGFloat) {
        let path = NSBezierPath(rect: rect)
        path.lineWidth = lineWidth
        path.stroke()
    }
}


enum SelectionAction {
    /// Hand off to the full editor (blur, visual cursor, delete, clear, settings).
    case annotate
    case copy
    case save
    case saveAs
    case cancel
}

/// What the overlay hands to the controller when a terminal action runs: the region to
/// capture plus the annotations already drawn on it, in image coordinates.
struct SelectionCapture {
    let area: CGRect
    let annotations: [Annotation]
    /// Set while the frame is still exactly a window's frame, untouched by the user.
    /// Capturing through the window filter is what keeps shadows and rounded corners out
    /// (PRD §4) and ignores anything overlapping it; an area capture can do neither.
    let window: WindowInfo?
}

/// Places the floating action bar next to a selection using the PRD §5 priority:
/// below, then right, then above, then left, and finally overlaid inside the selection.
/// The bar keeps its natural width even when that is wider than the selection — it is
/// only nudged horizontally so it stays on screen.
enum FloatingBarPlacement {
    static func frame(
        barSize: CGSize,
        around selection: CGRect,
        within bounds: CGRect,
        gap: CGFloat = 8
    ) -> CGRect {
        let width = min(barSize.width, bounds.width)
        let height = min(barSize.height, bounds.height)
        let x = clamp(selection.minX, bounds.minX, bounds.maxX - width)
        let y = clamp(selection.maxY - height, bounds.minY, bounds.maxY - height)

        let candidates = [
            CGRect(x: x, y: selection.minY - gap - height, width: width, height: height),
            CGRect(x: selection.maxX + gap, y: y, width: width, height: height),
            CGRect(x: x, y: selection.maxY + gap, width: width, height: height),
            CGRect(x: selection.minX - gap - width, y: y, width: width, height: height)
        ]

        for candidate in candidates where bounds.contains(candidate) {
            return candidate
        }

        // No room outside — sit inside the selection, along its bottom edge.
        let insideX = clamp(selection.midX - width / 2, bounds.minX, bounds.maxX - width)
        let insideY = clamp(selection.minY + gap, bounds.minY, bounds.maxY - height)
        return CGRect(x: insideX, y: insideY, width: width, height: height)
    }

    private static func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
        guard upper > lower else { return lower }
        return min(max(value, lower), upper)
    }
}

/// The panel that appears as soon as a selection exists (PRD §5). Icon-only: drawing
/// tools on the left, then colour, undo/redo, and the terminal actions.
final class SelectionActionBar: NSView {
    private let onTool: (OverlayTool) -> Void
    private let onColor: (NSColor) -> Void
    private let onUndo: () -> Void
    private let onRedo: () -> Void
    private let onAction: (SelectionAction) -> Void

    private let colorWell = NSColorWell(frame: .zero)
    private var toolButtons: [(button: NSButton, tool: OverlayTool)] = []
    /// Hint text per control. Native tooltips are useless here: they open in a window at
    /// an ordinary level, which the `.screenSaver`-level overlay covers, so the overlay
    /// draws its own hints instead.
    private var hintTitles: [ObjectIdentifier: String] = [:]

    init(
        color: NSColor,
        onTool: @escaping (OverlayTool) -> Void,
        onColor: @escaping (NSColor) -> Void,
        onUndo: @escaping () -> Void,
        onRedo: @escaping () -> Void,
        onAction: @escaping (SelectionAction) -> Void
    ) {
        self.onTool = onTool
        self.onColor = onColor
        self.onUndo = onUndo
        self.onRedo = onRedo
        self.onAction = onAction
        super.init(frame: .zero)

        // Light on purpose: the overlay dims everything around the frame, so a dark bar
        // would sink into the backdrop. A solid fill rather than a blur — translucent
        // materials sample the (dark) desktop behind the window and came out mid-grey,
        // leaving the glyphs barely legible.
        appearance = NSAppearance(named: .aqua)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.97, alpha: 0.98).cgColor
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(white: 0.55, alpha: 0.9).cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.4
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        layer?.shadowRadius = 6

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6)
        ])

        stack.addArrangedSubview(toolButton("arrow.up.right", "Стрелка", tool: .arrow, #selector(arrowTool)))
        stack.addArrangedSubview(toolButton("rectangle", "Рамка", tool: .rectangle, #selector(rectangleTool)))
        stack.addArrangedSubview(toolButton("textformat", "Текст", tool: .text, #selector(textTool)))

        colorWell.color = color
        colorWell.target = self
        colorWell.action = #selector(colorChanged(_:))
        hintTitles[ObjectIdentifier(colorWell)] = "Цвет"
        colorWell.widthAnchor.constraint(equalToConstant: 34).isActive = true
        colorWell.heightAnchor.constraint(equalToConstant: 22).isActive = true
        stack.addArrangedSubview(colorWell)

        stack.addArrangedSubview(button("arrow.uturn.backward", "Отменить (⌘Z)", #selector(undo)))
        stack.addArrangedSubview(button("arrow.uturn.forward", "Повторить (⇧⌘Z)", #selector(redo)))
        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(button("doc.on.doc", "Копировать", #selector(copyShot)))
        stack.addArrangedSubview(button("square.and.arrow.down", "Сохранить", #selector(save)))
        stack.addArrangedSubview(button("square.and.arrow.down.on.square", "Сохранить как…", #selector(saveAs)))
        stack.addArrangedSubview(button("xmark", "Отмена (Esc)", #selector(cancel)))

        setActiveTool(.none)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var preferredSize: CGSize {
        let fitting = fittingSize
        return CGSize(width: max(180, ceil(fitting.width)), height: max(34, ceil(fitting.height)))
    }

    /// The interactive control under a point given in the bar's *superview* coordinates,
    /// or nil for padding, separators and the bar's own background.
    func control(at pointInSuperview: CGPoint) -> NSView? {
        guard let hit = hitTest(pointInSuperview) else { return nil }
        return (hit is NSButton || hit is NSColorWell) ? hit : nil
    }

    /// Hint text plus the control's frame in the overlay's coordinates.
    func hint(at pointInSuperview: CGPoint) -> (text: String, anchor: CGRect)? {
        guard let control = control(at: pointInSuperview),
              let text = hintTitles[ObjectIdentifier(control)],
              let superview
        else { return nil }
        return (text, control.convert(control.bounds, to: superview))
    }

    func setActiveTool(_ tool: OverlayTool) {
        for entry in toolButtons {
            entry.button.state = entry.tool == tool ? .on : .off
        }
    }

    func setColor(_ color: NSColor) {
        colorWell.color = color
    }

    func deactivateColorWell() {
        colorWell.deactivate()
    }

    /// Icon-only: the name lives in the tooltip so the bar stays compact.
    private func button(_ symbol: String, _ title: String, _ action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        let button = NSButton(image: image ?? NSImage(), target: self, action: action)
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.bezelStyle = .texturedRounded
        button.setAccessibilityTitle(title)
        hintTitles[ObjectIdentifier(button)] = title
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.widthAnchor.constraint(equalToConstant: 30).isActive = true
        return button
    }

    private func toolButton(_ symbol: String, _ title: String, tool: OverlayTool, _ action: Selector) -> NSButton {
        let button = self.button(symbol, title, action)
        button.setButtonType(.pushOnPushOff)
        toolButtons.append((button, tool))
        return button
    }

    private func separator() -> NSView {
        let separator = NSBox(frame: .zero)
        separator.boxType = .separator
        separator.widthAnchor.constraint(equalToConstant: 1).isActive = true
        return separator
    }

    /// Pressing the active tool again puts the selection back into edit mode.
    private func select(_ tool: OverlayTool) {
        let active = toolButtons.first { $0.tool == tool }?.button.state == .on
        let resolved: OverlayTool = active ? tool : .none
        setActiveTool(resolved)
        onTool(resolved)
    }

    @objc private func arrowTool() { select(.arrow) }
    @objc private func rectangleTool() { select(.rectangle) }
    @objc private func textTool() { select(.text) }
    @objc private func colorChanged(_ sender: NSColorWell) { onColor(sender.color) }
    @objc private func undo() { onUndo() }
    @objc private func redo() { onRedo() }
    @objc private func copyShot() { onAction(.copy) }
    @objc private func save() { onAction(.save) }
    @objc private func saveAs() { onAction(.saveAs) }
    @objc private func cancel() { onAction(.cancel) }
}

final class CaptureOverlayWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class CaptureOverlayView: NSView {
    var onCancel: (() -> Void)?
    /// Fired by the floating action bar.
    var onSelectionAction: ((SelectionAction, SelectionCapture) -> Void)?

    let settings: SettingsStore

    /// Grab points around a live selection.
    enum Handle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    }

    private enum Gesture {
        case none
        /// Rubber-banding a brand new selection.
        case creating(anchor: CGPoint)
        /// Sliding an existing selection; `grab` is the cursor offset inside it.
        case moving(grab: CGSize)
        /// Dragging one handle; `fixed` is the corner/edge that stays put.
        case resizing(handle: Handle, fixed: CGPoint)
    }

    /// The selection stays live after the mouse is released so it can be nudged and
    /// resized before the screenshot is taken; Enter (or a double click) confirms it.
    private var selection: CGRect?
    private var gesture: Gesture = .none
    private var hoveredWindow: WindowInfo?
    private var selectedWindow: WindowInfo?
    private var clearedSelectionOnMouseDown = false
    private var tracking: NSTrackingArea?
    private var actionBar: SelectionActionBar?
    private var activeHint: (text: String, anchor: CGRect)?
    private var hintWorkItem: DispatchWorkItem?

    private static let hintDelay: TimeInterval = 0.25

    // Annotations authored straight on the overlay, in overlay coordinates.
    private var tool: OverlayTool = .none
    private var annotations: [Annotation] = []
    private var draftAnnotation: Annotation?
    private var drawAnchor: CGPoint?
    private var undoStack: [[Annotation]] = []
    private var redoStack: [[Annotation]] = []
    private var currentColor: NSColor
    private var textEditor: NSTextField?
    private var textOrigin: CGPoint = .zero

    private static let undoLimit = 50

    private static let handleSize: CGFloat = 8
    private static let handleHitSlop: CGFloat = 10
    private static let minimumSelectionSide: CGFloat = 8
    private static let dragThreshold: CGFloat = 3

    init(frame: CGRect, settings: SettingsStore) {
        self.settings = settings
        self.currentColor = settings.defaultColor
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }

    var isEditingText: Bool { textEditor != nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    /// PRD §5: the panel shows up as soon as a selection exists, and disappears once an
    /// action runs. It is hidden mid-gesture so it never sits under the cursor while the
    /// frame is being drawn or dragged.
    private func updateActionBar(visible: Bool) {
        guard visible, let selection else {
            actionBar?.isHidden = true
            clearHint()
            return
        }

        let bar: SelectionActionBar
        if let existing = actionBar {
            bar = existing
        } else {
            let created = SelectionActionBar(
                color: currentColor,
                onTool: { [weak self] tool in self?.setTool(tool) },
                onColor: { [weak self] color in self?.currentColor = color },
                onUndo: { [weak self] in self?.undo() },
                onRedo: { [weak self] in self?.redo() },
                onAction: { [weak self] action in self?.deliver(action) }
            )
            addSubview(created)
            actionBar = created
            bar = created
        }

        bar.isHidden = false
        bar.frame = FloatingBarPlacement.frame(
            barSize: bar.preferredSize,
            around: selection,
            within: bounds
        )
    }

    private func setTool(_ tool: OverlayTool) {
        commitTextIfNeeded()
        self.tool = tool
        needsDisplay = true
    }

    private func undo() {
        commitTextIfNeeded()
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(annotations)
        annotations = previous
        needsDisplay = true
    }

    private func redo() {
        commitTextIfNeeded()
        guard let next = redoStack.popLast() else { return }
        undoStack.append(annotations)
        annotations = next
        needsDisplay = true
    }

    private func pushUndo() {
        undoStack.append(annotations)
        if undoStack.count > Self.undoLimit { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    private func deliver(_ action: SelectionAction) {
        commitTextIfNeeded()
        guard let selection else { return }
        onSelectionAction?(action, capturePayload(for: selection))
    }

    private func beginDrawing(at point: CGPoint, in selection: CGRect) {
        commitTextIfNeeded()

        if tool == .text {
            beginTextEditor(at: point)
            return
        }
        drawAnchor = point
        draftAnnotation = makeDraft(from: point, to: point)
        needsDisplay = true
    }

    private func makeDraft(from anchor: CGPoint, to point: CGPoint) -> Annotation? {
        guard let kind = tool.annotationKind, kind.isShape else { return nil }
        let clamped = clampToSelection(point)
        let anchorInside = clampToSelection(anchor)
        return Annotation(
            kind: kind,
            start: anchorInside,
            end: clamped,
            rect: normalizedRect(from: anchorInside, to: clamped),
            color: currentColor,
            thickness: settings.strokeThickness,
            opacity: settings.strokeOpacity
        )
    }

    /// PRD §7: annotations may not leave the selected region.
    private func clampToSelection(_ point: CGPoint) -> CGPoint {
        guard let selection else { return point }
        return CGPoint(
            x: min(max(point.x, selection.minX), selection.maxX),
            y: min(max(point.y, selection.minY), selection.maxY)
        )
    }

    private func finishDrawing() {
        defer {
            drawAnchor = nil
            draftAnnotation = nil
            updateActionBar(visible: true)
            needsDisplay = true
        }
        guard let draft = draftAnnotation, AnnotationGeometry.isMeaningful(draft) else { return }
        pushUndo()
        annotations.append(draft)
    }

    private func beginTextEditor(at point: CGPoint) {
        let field = NSTextField(frame: CGRect(
            x: point.x,
            y: point.y,
            width: max(200, settings.textSize * 8),
            height: settings.textSize + 14
        ))
        field.font = settings.textBold
            ? NSFont.systemFont(ofSize: settings.textSize, weight: .bold)
            : NSFont.systemFont(ofSize: settings.textSize, weight: .regular)
        field.textColor = currentColor
        // No fill, no bezel: what you type is exactly what lands in the image.
        field.drawsBackground = false
        field.isBezeled = false
        field.isBordered = false
        field.focusRingType = .none
        field.isEditable = true
        field.isSelectable = true
        field.usesSingleLineMode = true
        field.target = self
        field.action = #selector(commitText(_:))
        addSubview(field)
        textEditor = field
        textOrigin = point
        window?.makeFirstResponder(field)
    }

    @objc private func commitText(_ sender: NSTextField) {
        textEditor = nil
        let value = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty {
            pushUndo()
            annotations.append(Annotation(
                kind: .text,
                rect: CGRect(origin: textOrigin, size: .zero),
                text: value,
                color: currentColor,
                thickness: settings.strokeThickness,
                opacity: settings.textOpacity
            ))
        }
        sender.removeFromSuperview()
        window?.makeFirstResponder(self)
        updateActionBar(visible: true)
        needsDisplay = true
    }

    private func commitTextIfNeeded() {
        if let textEditor { commitText(textEditor) }
    }

    /// Annotations are stored in overlay coordinates; the exporter needs them relative to
    /// the selection's bottom-left corner.
    private func capturePayload(for selection: CGRect) -> SelectionCapture {
        SelectionCapture(
            area: globalRect(for: selection),
            annotations: annotations.map { $0.offsetBy(dx: -selection.minX, dy: -selection.minY) },
            window: selectedWindow
        )
    }

    private func globalRect(for localRect: CGRect) -> CGRect {
        localRect.offsetBy(dx: window?.frame.minX ?? 0, dy: window?.frame.minY ?? 0)
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch (event.keyCode, flags) {
        case (53, _):
            onCancel?()
        case (36, _), (76, _):
            confirmSelectionIfPossible()
        case (6, [.command]):
            undo()
        case (6, [.command, .shift]):
            redo()
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: - Geometry helpers

    private func globalPoint(for localPoint: CGPoint) -> CGPoint {
        guard let window else { return localPoint }
        return CGPoint(x: window.frame.minX + localPoint.x, y: window.frame.minY + localPoint.y)
    }

    private func localRect(for globalRect: CGRect) -> CGRect {
        guard let window else { return globalRect }
        return globalRect.offsetBy(dx: -window.frame.minX, dy: -window.frame.minY)
    }

    private func normalizedRect(from anchor: CGPoint, to point: CGPoint) -> CGRect {
        CGRect(
            x: min(anchor.x, point.x),
            y: min(anchor.y, point.y),
            width: abs(point.x - anchor.x),
            height: abs(point.y - anchor.y)
        )
    }

    func handlePoint(_ handle: Handle, in rect: CGRect) -> CGPoint {
        switch handle {
        case .topLeft: return CGPoint(x: rect.minX, y: rect.maxY)
        case .top: return CGPoint(x: rect.midX, y: rect.maxY)
        case .topRight: return CGPoint(x: rect.maxX, y: rect.maxY)
        case .right: return CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomRight: return CGPoint(x: rect.maxX, y: rect.minY)
        case .bottom: return CGPoint(x: rect.midX, y: rect.minY)
        case .bottomLeft: return CGPoint(x: rect.minX, y: rect.minY)
        case .left: return CGPoint(x: rect.minX, y: rect.midY)
        }
    }

    /// The point that must stay anchored while `handle` is dragged.
    private func fixedPoint(opposite handle: Handle, in rect: CGRect) -> CGPoint {
        switch handle {
        case .topLeft: return CGPoint(x: rect.maxX, y: rect.minY)
        case .topRight: return CGPoint(x: rect.minX, y: rect.minY)
        case .bottomRight: return CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomLeft: return CGPoint(x: rect.maxX, y: rect.maxY)
        case .top: return CGPoint(x: rect.minX, y: rect.minY)
        case .bottom: return CGPoint(x: rect.minX, y: rect.maxY)
        case .left: return CGPoint(x: rect.maxX, y: rect.minY)
        case .right: return CGPoint(x: rect.minX, y: rect.minY)
        }
    }

    func handle(at point: CGPoint, in rect: CGRect) -> Handle? {
        Handle.allCases.first { handle in
            let centre = handlePoint(handle, in: rect)
            let slop = Self.handleHitSlop
            return abs(point.x - centre.x) <= slop && abs(point.y - centre.y) <= slop
        }
    }

    private func resized(_ rect: CGRect, handle: Handle, fixed: CGPoint, to point: CGPoint) -> CGRect {
        switch handle {
        case .topLeft, .topRight, .bottomLeft, .bottomRight:
            return normalizedRect(from: fixed, to: point)
        case .top, .bottom:
            // Horizontal extent is untouched when dragging a horizontal edge.
            let vertical = normalizedRect(from: fixed, to: CGPoint(x: fixed.x, y: point.y))
            return CGRect(x: rect.minX, y: vertical.minY, width: rect.width, height: vertical.height)
        case .left, .right:
            let horizontal = normalizedRect(from: fixed, to: CGPoint(x: point.x, y: fixed.y))
            return CGRect(x: horizontal.minX, y: rect.minY, width: horizontal.width, height: rect.height)
        }
    }

    private func clamped(_ rect: CGRect) -> CGRect {
        var result = rect
        result.size.width = min(result.width, bounds.width)
        result.size.height = min(result.height, bounds.height)
        result.origin.x = min(max(result.minX, bounds.minX), max(bounds.minX, bounds.maxX - result.width))
        result.origin.y = min(max(result.minY, bounds.minY), max(bounds.minY, bounds.maxY - result.height))
        return result
    }

    // MARK: - Mouse

    private func updateHoveredWindow(at localPoint: CGPoint) {
        let candidate = ScreenGeometry.windowAtCocoaPoint(globalPoint(for: localPoint))
        guard candidate?.id != hoveredWindow?.id else { return }
        hoveredWindow = candidate
        needsDisplay = true
    }

    /// What the pointer is over, which decides the cursor.
    enum CursorTarget: Equatable {
        case panelControl
        case panelBackground
        case handle(Handle)
        case insideSelection
        case outsideSelection
    }

    func cursorTarget(at point: CGPoint) -> CursorTarget {
        if let bar = actionBar, !bar.isHidden, bar.frame.contains(point) {
            return bar.control(at: point) != nil ? .panelControl : .panelBackground
        }
        guard let selection else { return .outsideSelection }
        if let handle = handle(at: point, in: selection) { return .handle(handle) }
        return selection.contains(point) ? .insideSelection : .outsideSelection
    }

    private func cursor(for target: CursorTarget) -> NSCursor {
        switch target {
        case .panelControl:
            return .pointingHand
        case .panelBackground:
            return .arrow
        case .handle(let handle):
            switch handle {
            case .left, .right: return .resizeLeftRight
            case .top, .bottom: return .resizeUpDown
            default: return .crosshair
            }
        case .insideSelection:
            return tool == .none ? .openHand : .crosshair
        case .outsideSelection:
            return .crosshair
        }
    }

    private func updateCursor(at point: CGPoint) {
        cursor(for: cursorTarget(at: point)).set()
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        updateCursor(at: point)
        updateHint(at: point)
        // A live selection replaces window highlighting entirely.
        if selection == nil {
            updateHoveredWindow(at: point)
        }
    }

    private func updateHint(at point: CGPoint) {
        let candidate = actionBar.flatMap { bar -> (text: String, anchor: CGRect)? in
            guard !bar.isHidden else { return nil }
            return bar.hint(at: point)
        }

        guard let candidate else {
            clearHint()
            return
        }
        // Already showing this one: leave it alone rather than restarting the delay.
        if activeHint?.text == candidate.text { return }

        hintWorkItem?.cancel()
        if activeHint != nil {
            // Moving between neighbouring buttons swaps the hint immediately.
            activeHint = candidate
            needsDisplay = true
            return
        }

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.activeHint = candidate
            self.needsDisplay = true
        }
        hintWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hintDelay, execute: work)
    }

    private func clearHint() {
        hintWorkItem?.cancel()
        hintWorkItem = nil
        guard activeHint != nil else { return }
        activeHint = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        clearedSelectionOnMouseDown = false

        // Clicks that land on the action bar are the bar's business, not a new selection.
        if let bar = actionBar, !bar.isHidden, bar.frame.contains(point) { return }

        if event.clickCount >= 2, let selection, selection.contains(point) {
            confirmSelectionIfPossible()
            return
        }

        if let current = selection {
            // Handles win over drawing, so the frame stays adjustable with a tool active.
            if let handle = handle(at: point, in: current) {
                gesture = .resizing(handle: handle, fixed: fixedPoint(opposite: handle, in: current))
                return
            }
            if tool != .none, current.contains(point) {
                beginDrawing(at: point, in: current)
                return
            }
            if current.contains(point) {
                gesture = .moving(grab: CGSize(width: point.x - current.minX, height: point.y - current.minY))
                NSCursor.closedHand.set()
                return
            }
            // Pressing outside the selection discards it and starts over.
            selection = nil
            selectedWindow = nil
            clearedSelectionOnMouseDown = true
            updateActionBar(visible: false)
            needsDisplay = true
        }

        gesture = .creating(anchor: point)
        // A drag that starts inside a highlighted window must still produce a region, so
        // the highlight is only consulted for a plain click.
        updateHoveredWindow(at: point)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        if let anchor = drawAnchor {
            // Drawing an annotation must not take the panel away: it sits outside the
            // selection and already swallows clicks that land on it.
            draftAnnotation = makeDraft(from: anchor, to: point)
            needsDisplay = true
            return
        }

        // Moving or resizing the frame does hide it, so it never ends up under the cursor.
        updateActionBar(visible: false)

        switch gesture {
        case .none:
            return
        case .creating(let anchor):
            let rect = normalizedRect(from: anchor, to: point)
            guard rect.width > Self.dragThreshold || rect.height > Self.dragThreshold else { return }
            selection = clamped(rect)
            hoveredWindow = nil
            selectedWindow = nil
        case .moving(let grab):
            moveSelection(grab: grab, to: point)
        case .resizing(let handle, let fixed):
            resizeSelection(handle: handle, fixed: fixed, to: point)
        }

        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if drawAnchor != nil {
            finishDrawing()
            return
        }

        let creating: Bool
        if case .creating = gesture { creating = true } else { creating = false }
        gesture = .none

        if let current = selection,
           current.width >= Self.minimumSelectionSide,
           current.height >= Self.minimumSelectionSide {
            // Keep it live and editable instead of capturing straight away, and offer the
            // actions right next to it.
            needsDisplay = true
            updateActionBar(visible: true)
            updateCursor(at: convert(event.locationInWindow, from: nil))
            return
        }

        selection = nil
        selectedWindow = nil
        updateActionBar(visible: false)

        guard creating, !clearedSelectionOnMouseDown else {
            needsDisplay = true
            return
        }

        if let hoveredWindow {
            // Same flow as a dragged region: the window becomes a live frame with the
            // panel, the tools and the handles, instead of capturing straight away.
            selectWindow(hoveredWindow)
        } else {
            onCancel?()
        }
    }

    /// Editing the frame by hand means it no longer matches a window, so the capture has
    /// to fall back from the window filter to a plain area grab.
    private func moveSelection(grab: CGSize, to point: CGPoint) {
        guard let current = selection else { return }
        selection = clamped(CGRect(
            x: point.x - grab.width,
            y: point.y - grab.height,
            width: current.width,
            height: current.height
        ))
        selectedWindow = nil
    }

    private func resizeSelection(handle: Handle, fixed: CGPoint, to point: CGPoint) {
        guard let current = selection else { return }
        selection = clamped(resized(current, handle: handle, fixed: fixed, to: point))
        selectedWindow = nil
    }

    private func selectWindow(_ window: WindowInfo) {
        let local = localRect(for: window.frame)
        let fitted = clamped(local)
        selection = fitted
        // A window clipped by the overlay bounds no longer matches what the window filter
        // returns, so such a frame falls back to an area capture.
        let matchesExactly = abs(fitted.width - local.width) < 0.5
            && abs(fitted.height - local.height) < 0.5
        selectedWindow = matchesExactly ? window : nil
        hoveredWindow = nil
        gesture = .none
        updateActionBar(visible: true)
        needsDisplay = true
    }

    /// Returns `false` when there is nothing to confirm, so a caller routing a key event
    /// here can pass the event on instead of swallowing it.
    @discardableResult
    func confirmSelectionIfPossible() -> Bool {
        commitTextIfNeeded()
        guard let selection,
              selection.width >= Self.minimumSelectionSide,
              selection.height >= Self.minimumSelectionSide else { return false }
        onSelectionAction?(.annotate, capturePayload(for: selection))
        return true
    }

    /// Ends an in-progress text field without committing. Returns whether there was one.
    @discardableResult
    func cancelTextEditing() -> Bool {
        guard let textEditor else { return false }
        self.textEditor = nil
        textEditor.removeFromSuperview()
        window?.makeFirstResponder(self)
        updateActionBar(visible: true)
        needsDisplay = true
        return true
    }

    // MARK: - Drawing

    /// Alpha low enough to be invisible, high enough that the window still hit-tests here.
    /// The focus area used to be punched out with `compositingOperation = .clear`, leaving
    /// it fully transparent — and macOS routes clicks on transparent pixels of a
    /// non-opaque window straight through to whatever is underneath. That made it
    /// impossible to start, move or resize a selection over a highlighted window: the
    /// clicks landed in the app below and deactivated the overlay instead.
    private static let hitTestableAlpha: CGFloat = 1.0 / 255.0

    /// How much the area outside the selection is darkened.
    static let dimmingAlpha: CGFloat = 0.6

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let focusRect = selection ?? hoveredWindow.map { localRect(for: $0.frame) }
        guard let focusRect, focusRect.width > 0, focusRect.height > 0 else {
            NSColor.black.withAlphaComponent(Self.dimmingAlpha).setFill()
            bounds.fill()
            drawHint(forLiveSelection: false)
            return
        }

        // Dim around the focus rect rather than clearing a hole in it.
        NSColor.black.withAlphaComponent(Self.dimmingAlpha).setFill()
        for band in dimmingBands(around: focusRect) { band.fill() }

        NSColor.black.withAlphaComponent(Self.hitTestableAlpha).setFill()
        focusRect.intersection(bounds).fill()

        SelectionBorder.stroke(focusRect)

        if selection != nil {
            drawOverlayAnnotations(clippedTo: focusRect)
            drawHandles(for: focusRect)
            drawSizeBadge(for: focusRect)
        }
        drawHint(forLiveSelection: selection != nil)
        drawButtonHint()
    }

    private func drawOverlayAnnotations(clippedTo rect: CGRect) {
        let visible = annotations + (draftAnnotation.map { [$0] } ?? [])
        guard !visible.isEmpty else { return }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        AnnotationRenderer.drawAnnotations(visible, settings: settings)
        NSGraphicsContext.restoreGraphicsState()
    }

    /// The four rectangles covering everything outside `rect`.
    func dimmingBands(around rect: CGRect) -> [CGRect] {
        let focus = rect.intersection(bounds)
        guard !focus.isNull, focus.width > 0, focus.height > 0 else { return [bounds] }
        return [
            CGRect(x: bounds.minX, y: focus.maxY, width: bounds.width, height: bounds.maxY - focus.maxY),
            CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: focus.minY - bounds.minY),
            CGRect(x: bounds.minX, y: focus.minY, width: focus.minX - bounds.minX, height: focus.height),
            CGRect(x: focus.maxX, y: focus.minY, width: bounds.maxX - focus.maxX, height: focus.height)
        ].filter { $0.width > 0 && $0.height > 0 }
    }

    private func drawHandles(for rect: CGRect) {
        for handle in Handle.allCases {
            let centre = handlePoint(handle, in: rect)
            let box = CGRect(
                x: centre.x - Self.handleSize / 2,
                y: centre.y - Self.handleSize / 2,
                width: Self.handleSize,
                height: Self.handleSize
            )
            NSColor.black.withAlphaComponent(0.6).setStroke()
            let outline = NSBezierPath(rect: box.insetBy(dx: -0.5, dy: -0.5))
            outline.lineWidth = 1
            outline.stroke()

            SelectionBorder.coreColor.setFill()
            NSBezierPath(rect: box).fill()
        }
    }

    private func drawSizeBadge(for rect: CGRect) {
        let text = "\(Int(rect.width.rounded())) × \(Int(rect.height.rounded()))"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        var origin = CGPoint(x: rect.minX + 6, y: rect.maxY + 8)
        if origin.y + size.height > bounds.maxY - 4 {
            origin.y = rect.maxY - size.height - 8
        }
        let textRect = CGRect(origin: origin, size: size)
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: textRect.insetBy(dx: -6, dy: -4), xRadius: 5, yRadius: 5).fill()
        (text as NSString).draw(in: textRect, withAttributes: attributes)
    }

    private func drawButtonHint() {
        guard let activeHint else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let size = (activeHint.text as NSString).size(withAttributes: attributes)
        let padding = CGSize(width: 9, height: 5)
        let boxSize = CGSize(width: size.width + padding.width * 2, height: size.height + padding.height * 2)
        let gap: CGFloat = 7

        var origin = CGPoint(
            x: activeHint.anchor.midX - boxSize.width / 2,
            y: activeHint.anchor.minY - gap - boxSize.height
        )
        // Below the button by default; above it when there is no room underneath.
        if origin.y < bounds.minY + 2 {
            origin.y = activeHint.anchor.maxY + gap
        }
        origin.x = min(max(origin.x, bounds.minX + 2), max(bounds.minX + 2, bounds.maxX - boxSize.width - 2))

        let box = CGRect(origin: origin, size: boxSize)
        NSColor.black.withAlphaComponent(0.85).setFill()
        NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
        (activeHint.text as NSString).draw(
            in: CGRect(
                x: box.minX + padding.width,
                y: box.minY + padding.height,
                width: size.width,
                height: size.height
            ),
            withAttributes: attributes
        )
    }

    private func drawHint(forLiveSelection isLive: Bool) {
        let message = isLive
            ? "Инструмент — рисовать внутри   •   За края — размер   •   Enter — редактор   •   Esc — отмена"
            : "Клик — окно   •   Перетащите мышью — область   •   Esc — отмена"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let size = (message as NSString).size(withAttributes: attributes)
        let messageRect = CGRect(
            x: max(16, (bounds.width - size.width) / 2),
            y: max(16, bounds.height - size.height - 28),
            width: size.width,
            height: size.height
        )
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: messageRect.insetBy(dx: -14, dy: -8), xRadius: 10, yRadius: 10).fill()
        (message as NSString).draw(in: messageRect, withAttributes: attributes)
    }

    // Exposed for tests.
    var testSelection: CGRect? { selection }
    var testActionBarIsVisible: Bool { actionBar.map { !$0.isHidden } ?? false }
    var testActionBarFrame: CGRect? { actionBar.flatMap { $0.isHidden ? nil : $0.frame } }
    var testTool: OverlayTool { tool }
    var testActiveHint: String? { activeHint?.text }
    func testForceHint(at point: CGPoint) {
        guard let bar = actionBar, !bar.isHidden, let hint = bar.hint(at: point) else { return }
        activeHint = hint
        needsDisplay = true
    }
    func testHint(at point: CGPoint) -> String? {
        guard let bar = actionBar, !bar.isHidden else { return nil }
        return bar.hint(at: point)?.text
    }
    var testSelectedWindow: WindowInfo? { selectedWindow }
    func testSelectWindow(_ window: WindowInfo) { selectWindow(window) }
    func testMoveSelection(grab: CGSize, to point: CGPoint) { moveSelection(grab: grab, to: point) }
    func testResizeSelection(handle: Handle, to point: CGPoint) {
        guard let selection else { return }
        resizeSelection(handle: handle, fixed: fixedPoint(opposite: handle, in: selection), to: point)
    }
    func testCursorTarget(at point: CGPoint) -> CursorTarget { cursorTarget(at: point) }
    func testCursor(at point: CGPoint) -> NSCursor { cursor(for: cursorTarget(at: point)) }
    func testLayoutActionBar() { actionBar?.layoutSubtreeIfNeeded() }
    var testTextEditor: NSTextField? { textEditor }
    func testBeginTextEditor(at point: CGPoint) { beginTextEditor(at: point) }
    var testAnnotations: [Annotation] { annotations }
    var testUndoDepth: Int { undoStack.count }
    func testSetTool(_ tool: OverlayTool) { setTool(tool) }
    func testClampToSelection(_ point: CGPoint) -> CGPoint { clampToSelection(point) }
    func testCapturePayload() -> SelectionCapture? {
        selection.map { capturePayload(for: $0) }
    }
    func testAddAnnotation(_ annotation: Annotation) {
        pushUndo()
        annotations.append(annotation)
    }
    func testSimulateDraw(from: CGPoint, to: CGPoint) {
        guard let selection else { return }
        beginDrawing(at: from, in: selection)
        draftAnnotation = makeDraft(from: from, to: to)
        finishDrawing()
    }
    func testUndo() { undo() }
    func testRedo() { redo() }
    func testShowActionBar() { updateActionBar(visible: true) }
    func testHideActionBar() { updateActionBar(visible: false) }
    func testSetSelection(_ rect: CGRect) { selection = clamped(rect) }
    func testClampedRect(_ rect: CGRect) -> CGRect { clamped(rect) }
    func testResize(_ rect: CGRect, handle: Handle, to point: CGPoint) -> CGRect {
        clamped(resized(rect, handle: handle, fixed: fixedPoint(opposite: handle, in: rect), to: point))
    }
}


@MainActor
final class CaptureController {
    private let capture = ScreenshotCapture()
    private let settings: SettingsStore
    private var overlayWindow: CaptureOverlayWindow?
    private var overlayView: CaptureOverlayView?
    private var escapeMonitor: Any?
    private var isCapturing = false
    private var isRequestingAccess = false
    private var captureTask: Task<Void, Never>?
    /// Bumped whenever a capture session is abandoned. Results carrying an old generation
    /// are dropped, so a slow capture can never open an editor over a newer one.
    private var captureGeneration = 0

    var onImageCaptured: ((NSImage, CGRect, [Annotation]) -> Void)?
    var onError: ((String) -> Void)?

    init(settings: SettingsStore = .shared) {
        self.settings = settings
    }

    func start() {
        // Triggering capture while the overlay is on screen dismisses it, so a stuck
        // overlay can never lock the user out of the hot key.
        if overlayWindow != nil {
            cancel()
            return
        }
        // Otherwise a capture from a previous trigger may still be in flight; abandon it
        // rather than letting its result arrive on top of the new session.
        abandonCaptureInFlight()

        // Settle the permission before dimming the screen. Handing the user a selection
        // overlay that cannot possibly produce an image is worse than explaining the
        // problem up front.
        guard capture.hasScreenRecordingAccess else {
            requestScreenRecordingAccess()
            return
        }

        guard let unionFrame = NSScreen.screens.map(\.frame).reduce(nil, { partial, frame in
            partial.map { $0.union(frame) } ?? frame
        }) else { return }

        isCapturing = true

        let panel = CaptureOverlayWindow(
            contentRect: unionFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        // NSPanel defaults this to true: the full-screen selection overlay would quietly
        // hide itself the moment the app lost active status, swallowing every click.
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true

        let view = CaptureOverlayView(frame: CGRect(origin: .zero, size: unionFrame.size), settings: settings)
        view.onCancel = { [weak self] in self?.cancel() }
        view.onSelectionAction = { [weak self] action, payload in self?.perform(action, payload: payload) }
        panel.contentView = view
        overlayWindow = panel
        overlayView = view

        // Order the panel in before activating, then claim key focus again once the
        // activation has actually landed. Activating first left the panel visible but
        // never key, so Esc (and every other key) went nowhere.
        panel.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak panel, weak view] in
            guard let panel else { return }
            panel.makeKey()
            if let view { panel.makeFirstResponder(view) }
        }

        installEscapeFallbackMonitor()

    }

    /// A full-screen overlay at `.screenSaver` level does not reliably win key focus, so
    /// `CaptureOverlayView.keyDown` cannot be trusted to fire at all. Every shortcut the
    /// overlay needs is therefore routed through this monitor: Esc so the user is never
    /// stranded behind the dimmed screen, and Return/Enter so a live selection can
    /// actually be confirmed.
    private func installEscapeFallbackMonitor() {
        removeEscapeFallbackMonitor()
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isCapturing else { return event }
            // While the inline text field is open it owns Return and Escape.
            if self.overlayView?.isEditingText == true {
                guard event.keyCode == 53 else { return event }
                self.overlayView?.cancelTextEditing()
                return nil
            }
            switch event.keyCode {
            case 53:
                self.cancel()
                return nil
            case 36, 76:
                guard self.overlayView?.confirmSelectionIfPossible() == true else { return event }
                return nil
            default:
                return event
            }
        }
    }

    private func removeEscapeFallbackMonitor() {
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }
    }

    /// `CGRequestScreenCaptureAccess` blocks its thread until the user answers the system
    /// prompt, so running it on the main thread froze the menu bar behind the dialog.
    private func requestScreenRecordingAccess() {
        guard !isRequestingAccess else { return }
        isRequestingAccess = true

        // Captured strongly on purpose: the controller lives as long as the app, and the
        // prompt must still be able to report its answer.
        Task.detached { [self] in
            let granted = CGRequestScreenCaptureAccess()
            await MainActor.run {
                isRequestingAccess = false
                if granted {
                    start()
                } else {
                    onError?(CaptureError.permissionDenied.errorDescription ?? "")
                }
            }
        }
    }

    private func cancel() {
        abandonCaptureInFlight()
        dismissOverlay()
    }

    private func abandonCaptureInFlight() {
        captureTask?.cancel()
        captureTask = nil
        captureGeneration += 1
        isCapturing = false
    }

    /// Single entry point for capture work. Keeping the task lets a second trigger cancel
    /// the first, and the generation check discards anything the cancelled task still
    /// manages to produce.
    private func runCapture(
        produce: @escaping @MainActor () async throws -> NSImage,
        deliver: @escaping @MainActor (NSImage) -> Void
    ) {
        captureTask?.cancel()
        captureGeneration += 1
        let generation = captureGeneration

        captureTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.captureGeneration == generation {
                    self.captureTask = nil
                    self.isCapturing = false
                }
            }
            do {
                let image = try await produce()
                guard !Task.isCancelled, self.captureGeneration == generation else { return }
                deliver(image)
            } catch is CancellationError {
                return
            } catch {
                guard self.captureGeneration == generation else { return }
                self.onError?(Self.message(for: error))
            }
        }
    }

    /// Runs one of the action-bar buttons: capture first, then either hand the image to
    /// the editor or finish the job outright.
    private func perform(_ action: SelectionAction, payload: SelectionCapture) {
        if case .cancel = action {
            cancel()
            return
        }

        dismissOverlay()
        let area = payload.area
        let annotations = payload.annotations
        let window = payload.window
        runCapture(
            produce: { [capture] in
                if let window {
                    return try await capture.captureWindow(window)
                }
                return try await capture.captureArea(area)
            },
            deliver: { [weak self] image in
                guard let self else { return }
                switch action {
                case .annotate:
                    // The full editor keeps the annotations drawn on the overlay.
                    self.onImageCaptured?(image, area, annotations)
                case .copy:
                    CaptureFlash.shared.flash(area)
                    self.copy(image, annotations: annotations)
                case .save:
                    CaptureFlash.shared.flash(area)
                    self.save(image, annotations: annotations)
                case .saveAs:
                    self.saveAs(image, annotations: annotations)
                case .cancel:
                    break
                }
            }
        )
    }

    private func copy(_ image: NSImage, annotations: [Annotation]) {
        guard let data = ScreenshotOutput.data(for: image, annotations: annotations, format: .png, settings: settings) else {
            ScreenshotOutput.showError("Не удалось подготовить изображение для буфера обмена.")
            return
        }
        ScreenshotOutput.copy(data, settings: settings)
    }

    private func save(_ image: NSImage, annotations: [Annotation]) {
        let format = settings.outputFormat
        guard let data = ScreenshotOutput.data(for: image, annotations: annotations, format: format, settings: settings) else {
            ScreenshotOutput.showError("Не удалось подготовить изображение для сохранения.")
            return
        }
        do {
            _ = try ScreenshotOutput.save(data, format: format, settings: settings)
        } catch {
            ScreenshotOutput.showError("Не удалось сохранить файл: \(error.localizedDescription)")
        }
    }

    private func saveAs(_ image: NSImage, annotations: [Annotation]) {
        let format = settings.outputFormat
        guard let data = ScreenshotOutput.data(for: image, annotations: annotations, format: format, settings: settings) else {
            ScreenshotOutput.showError("Не удалось подготовить изображение для сохранения.")
            return
        }
        // The overlay is already gone, so there is no window to host a sheet.
        let panel = ScreenshotOutput.makeSavePanel(format: format)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ScreenshotOutput.write(data, to: url, settings: settings)
        } catch {
            ScreenshotOutput.showError("Не удалось сохранить файл: \(error.localizedDescription)")
        }
    }

    private func dismissOverlay() {
        removeEscapeFallbackMonitor()
        overlayWindow?.orderOut(nil)
        overlayWindow = nil
        overlayView = nil
    }

    deinit {
        captureTask?.cancel()
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
    }

    // Exposed for tests.
    var testCaptureGeneration: Int { captureGeneration }
    var testHasCaptureInFlight: Bool { captureTask != nil }
    func testAbandonCaptureInFlight() { abandonCaptureInFlight() }

    private static func message(for error: Error) -> String {
        (error as? CaptureError)?.errorDescription
            ?? CaptureError.underlying(error).errorDescription
            ?? error.localizedDescription
    }
}
