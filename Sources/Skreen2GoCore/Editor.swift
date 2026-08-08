import AppKit
import CoreImage
import Foundation
import UniformTypeIdentifiers

/// Keeps one blurred copy of the screenshot alive. Without it every redraw — including
/// each frame of a blur-rectangle drag — ran a full-image `CIGaussianBlur` and built a
/// fresh `CIContext` per blur annotation.
final class BlurCache {
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private var cachedSource: CGImage?
    private var cachedRadius: CGFloat = .nan
    private var cachedResult: CGImage?

    func blurred(source: CGImage, radius: CGFloat) -> CGImage? {
        if let cachedResult, let cachedSource, cachedSource === source, cachedRadius == radius {
            return cachedResult
        }

        let input = CIImage(cgImage: source)
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return nil }
        // Clamping first stops the blur from pulling transparent black in at the edges.
        filter.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(radius, forKey: kCIInputRadiusKey)
        guard
            let output = filter.outputImage?.cropped(to: input.extent),
            let result = ciContext.createCGImage(output, from: input.extent)
        else { return nil }

        cachedSource = source
        cachedRadius = radius
        cachedResult = result
        return result
    }
}

enum ScreenshotNaming {
    /// PRD §9: `Screenshot 2026-08-06 at 14.30.25.png`
    static func fileName(for format: OutputFormat, date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Screenshot \(formatter.string(from: date)).\(fileExtension(for: format))"
    }

    static func fileExtension(for format: OutputFormat) -> String {
        switch format {
        case .png: return "png"
        case .jpeg: return "jpg"
        }
    }

    static func uniqueURL(
        in folder: URL,
        format: OutputFormat,
        date: Date,
        fileManager: FileManager = .default
    ) -> URL {
        let fileName = fileName(for: format, date: date)
        let baseName = (fileName as NSString).deletingPathExtension
        let ext = fileExtension(for: format)
        var candidate = folder.appendingPathComponent(fileName)
        var suffix = 2

        while fileManager.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(baseName) \(suffix).\(ext)")
            suffix += 1
        }
        return candidate
    }
}

enum AnnotationRenderer {
    static func draw(
        image: NSImage,
        annotations: [Annotation],
        in imageRect: CGRect,
        settings: SettingsStore,
        blurCache: BlurCache
    ) {
        image.draw(in: imageRect, from: .zero, operation: .copy, fraction: 1)

        for annotation in annotations {
            switch annotation.kind {
            case .arrow:
                drawArrow(annotation)
            case .rectangle:
                drawRectangle(annotation)
            case .text:
                drawText(annotation, settings: settings)
            case .blur:
                drawBlur(annotation, image: image, in: imageRect, settings: settings, blurCache: blurCache)
            case .cursor(let style):
                drawCursor(style, annotation: annotation)
            }
        }
    }

    /// Draws annotations with no backdrop, for the capture overlay where the real screen
    /// shows through. Blur and cursor need the source bitmap and are never offered there.
    static func drawAnnotations(_ annotations: [Annotation], settings: SettingsStore) {
        for annotation in annotations {
            switch annotation.kind {
            case .arrow:
                drawArrow(annotation)
            case .rectangle:
                drawRectangle(annotation)
            case .text:
                drawText(annotation, settings: settings)
            case .blur, .cursor:
                continue
            }
        }
    }

    static func textAttributes(for annotation: Annotation, settings: SettingsStore) -> [NSAttributedString.Key: Any] {
        let font = settings.textBold
            ? NSFont.systemFont(ofSize: settings.textSize, weight: .bold)
            : NSFont.systemFont(ofSize: settings.textSize, weight: .regular)
        return [
            .font: font,
            .foregroundColor: annotation.color.withAlphaComponent(annotation.opacity)
        ]
    }

    /// Measures the string instead of guessing `count * size * 0.62`, which clipped
    /// Cyrillic and any wide glyph. Re-measuring at draw time also keeps the box correct
    /// when the font settings change after the annotation was created.
    static func textBounds(_ annotation: Annotation, settings: SettingsStore) -> CGRect {
        let size = (annotation.text as NSString).size(withAttributes: textAttributes(for: annotation, settings: settings))
        return CGRect(
            origin: annotation.rect.origin,
            size: CGSize(width: ceil(size.width) + 4, height: ceil(size.height) + 2)
        )
    }

    static func bounds(of annotation: Annotation, settings: SettingsStore) -> CGRect {
        switch annotation.kind {
        case .arrow:
            return CGRect(
                x: min(annotation.start.x, annotation.end.x),
                y: min(annotation.start.y, annotation.end.y),
                width: abs(annotation.end.x - annotation.start.x),
                height: abs(annotation.end.y - annotation.start.y)
            )
        case .text:
            return textBounds(annotation, settings: settings)
        default:
            return annotation.rect
        }
    }

    private static func drawArrow(_ annotation: Annotation) {
        let color = annotation.color.withAlphaComponent(annotation.opacity)
        color.setStroke()
        color.setFill()

        let path = NSBezierPath()
        path.move(to: annotation.start)
        path.line(to: annotation.end)
        path.lineWidth = annotation.thickness
        path.lineCapStyle = .round
        path.stroke()

        let angle = atan2(annotation.end.y - annotation.start.y, annotation.end.x - annotation.start.x)
        let headLength = max(10, annotation.thickness * 4)
        let headWidth = max(5, annotation.thickness * 2.5)
        let left = CGPoint(
            x: annotation.end.x - cos(angle) * headLength + sin(angle) * headWidth,
            y: annotation.end.y - sin(angle) * headLength - cos(angle) * headWidth
        )
        let right = CGPoint(
            x: annotation.end.x - cos(angle) * headLength - sin(angle) * headWidth,
            y: annotation.end.y - sin(angle) * headLength + cos(angle) * headWidth
        )
        let head = NSBezierPath()
        head.move(to: annotation.end)
        head.line(to: left)
        head.line(to: right)
        head.close()
        head.fill()
    }

    private static func drawRectangle(_ annotation: Annotation) {
        let color = annotation.color.withAlphaComponent(annotation.opacity)
        color.setStroke()
        let path = NSBezierPath(rect: annotation.rect)
        path.lineWidth = annotation.thickness
        path.stroke()
    }

    private static func drawText(_ annotation: Annotation, settings: SettingsStore) {
        let attributes = textAttributes(for: annotation, settings: settings)
        (annotation.text as NSString).draw(in: textBounds(annotation, settings: settings), withAttributes: attributes)
    }

    private static func drawBlur(
        _ annotation: Annotation,
        image: NSImage,
        in imageRect: CGRect,
        settings: SettingsStore,
        blurCache: BlurCache
    ) {
        guard
            let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
            let blurred = blurCache.blurred(source: cgImage, radius: settings.blurRadius)
        else {
            NSColor.black.withAlphaComponent(0.25).setFill()
            annotation.rect.fill()
            return
        }

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: annotation.rect).addClip()
        let blurredImage = NSImage(cgImage: blurred, size: image.size)
        blurredImage.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
    }

    static func contrastColor(for color: NSColor) -> NSColor {
        guard let rgb = color.usingColorSpace(.deviceRGB) else { return .black }
        let luminance = 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
        return luminance > 0.6 ? .black : .white
    }

    private static func drawCursor(_ style: CursorStyle, annotation: Annotation) {
        guard annotation.rect.width > 0, annotation.rect.height > 0 else { return }
        let color = annotation.color.withAlphaComponent(annotation.opacity)
        let halo = contrastColor(for: annotation.color)

        if style == .click {
            halo.withAlphaComponent(0.9 * annotation.opacity).setStroke()
            color.withAlphaComponent(0.35 * annotation.opacity).setFill()
            let outer = NSBezierPath(ovalIn: annotation.rect)
            outer.lineWidth = max(2, annotation.thickness)
            outer.fill()
            outer.stroke()
            let innerRect = annotation.rect.insetBy(dx: annotation.rect.width * 0.27, dy: annotation.rect.height * 0.27)
            color.setFill()
            NSBezierPath(ovalIn: innerRect).fill()
            return
        }

        let symbolName: String
        switch style {
        case .arrow: symbolName = "cursorarrow"
        case .pointer: symbolName = "hand.point.up"
        case .hand: symbolName = "hand.raised"
        case .text: symbolName = "character.cursor.ibeam"
        case .resize: symbolName = "arrow.up.left.and.arrow.down.right"
        case .click: return
        }

        guard let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) else { return }

        // A template image drawn via `draw(in:)` is not tinted automatically — it always
        // came out black, ignoring the annotation colour and opacity. Composite the tint
        // manually and give it a contrasting halo so the cursor stays visible on any
        // background.
        let tinted = NSImage(size: annotation.rect.size, flipped: false) { rect in
            symbol.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = halo.withAlphaComponent(0.9)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = .zero
        shadow.set()
        tinted.draw(in: annotation.rect, from: .zero, operation: .sourceOver, fraction: annotation.opacity)
        NSGraphicsContext.restoreGraphicsState()
    }
}

enum ImageExporter {
    /// Backing-store scale of the screenshot. Reads `pixelsWide` off every representation
    /// rather than only `NSBitmapImageRep`: window captures used to arrive as a different
    /// rep class, silently exporting at 1x and discarding half the Retina detail.
    static func pixelScale(of image: NSImage) -> CGFloat {
        let width = max(1, image.size.width)
        let scale = image.representations
            .compactMap { representation -> CGFloat? in
                guard representation.pixelsWide > 0 else { return nil }
                return CGFloat(representation.pixelsWide) / width
            }
            .max() ?? 1
        return max(1, scale)
    }

    static func data(for document: ScreenshotDocument, format: OutputFormat, settings: SettingsStore) -> Data? {
        let scale = pixelScale(of: document.image)
        let pixelWidth = max(1, Int((document.image.size.width * scale).rounded()))
        let pixelHeight = max(1, Int((document.image.size.height * scale).rounded()))

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
        ) else { return nil }

        bitmap.size = document.image.size
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        AnnotationRenderer.draw(
            image: document.image,
            annotations: document.annotations,
            in: CGRect(origin: .zero, size: document.image.size),
            settings: settings,
            blurCache: document.blurCache
        )
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        switch format {
        case .png:
            return bitmap.representation(using: .png, properties: [:])
        case .jpeg:
            return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.92])
        }
    }
}

/// Everything needed to turn rendered PNG/JPEG bytes into a result the user can see.
/// Shared by the editor and by the selection action bar in the capture overlay, so both
/// paths name files, notify and report errors the same way.
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

    static func save(_ data: Data, format: OutputFormat, settings: SettingsStore) throws -> URL {
        let url = try settings.withOutputFolderAccess { folder in
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = ScreenshotNaming.uniqueURL(in: folder, format: format, date: Date())
            try data.write(to: url, options: .atomic)
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

    static func write(_ data: Data, to url: URL, settings: SettingsStore) throws {
        try data.write(to: url, options: .atomic)
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

final class AnnotationCanvasView: NSView {
    let document: ScreenshotDocument
    let settings: SettingsStore
    let zoomScale: CGFloat

    var tool: AnnotationTool = .select {
        didSet { needsDisplay = true }
    }
    var currentColor: NSColor
    var selectedAnnotationID: UUID?
    var onCancel: (() -> Void)?

    private var temporaryAnnotation: Annotation?
    private var dragStart: CGPoint?
    private var draggingAnnotationID: UUID?
    private var undoStack: [[Annotation]] = []
    private var redoStack: [[Annotation]] = []
    /// Snapshot taken when a gesture starts. It only reaches the undo stack once the
    /// gesture actually changes something — a bare click no longer inflates history, and
    /// a too-small shape no longer leaves a junk entry behind.
    private var pendingUndoSnapshot: [Annotation]?
    private var textEditor: NSTextField?
    private var textOrigin: CGPoint = .zero

    private static let undoLimit = 50

    init(frame: CGRect, document: ScreenshotDocument, settings: SettingsStore, zoomScale: CGFloat) {
        self.document = document
        self.settings = settings
        self.zoomScale = zoomScale
        self.currentColor = settings.defaultColor
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    func setTool(_ tool: AnnotationTool) {
        commitTextIfNeeded()
        self.tool = tool
    }

    /// Only changes the colour used for new annotations. It deliberately does not write
    /// through to `settings.defaultColor` — picking a colour for one screenshot should
    /// not silently rewrite the preference.
    func setColor(_ color: NSColor) {
        currentColor = color
        needsDisplay = true
    }

    func undo() {
        commitTextIfNeeded()
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(document.annotations)
        document.annotations = previous
        selectedAnnotationID = nil
        needsDisplay = true
    }

    func redo() {
        commitTextIfNeeded()
        guard let next = redoStack.popLast() else { return }
        undoStack.append(document.annotations)
        document.annotations = next
        selectedAnnotationID = nil
        needsDisplay = true
    }

    func deleteSelected() {
        commitTextIfNeeded()
        guard let selectedAnnotationID else { return }
        recordUndo()
        document.annotations.removeAll { $0.id == selectedAnnotationID }
        self.selectedAnnotationID = nil
        needsDisplay = true
    }

    func clearAnnotations() {
        commitTextIfNeeded()
        guard !document.annotations.isEmpty else { return }
        recordUndo()
        document.annotations.removeAll()
        selectedAnnotationID = nil
        needsDisplay = true
    }

    func renderedData(format: OutputFormat) -> Data? {
        commitTextIfNeeded()
        return ImageExporter.data(for: document, format: format, settings: settings)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.cgContext.scaleBy(x: zoomScale, y: zoomScale)

        let visible = document.annotations + (temporaryAnnotation.map { [$0] } ?? [])
        AnnotationRenderer.draw(
            image: document.image,
            annotations: visible,
            in: CGRect(origin: .zero, size: document.image.size),
            settings: settings,
            blurCache: document.blurCache
        )

        if let selectedAnnotationID,
           let selected = visible.first(where: { $0.id == selectedAnnotationID }) {
            let selectionRect = AnnotationRenderer.bounds(of: selected, settings: settings).insetBy(dx: -5, dy: -5)
            // Dark backing under a grey dash, so the marquee reads on light and dark
            // screenshots alike instead of vanishing into white content.
            let lineWidth = max(1, 1 / zoomScale)
            let backing = NSBezierPath(rect: selectionRect)
            backing.setLineDash([4, 3], count: 2, phase: 0)
            backing.lineWidth = lineWidth * 3
            NSColor.black.withAlphaComponent(0.55).setStroke()
            backing.stroke()

            let outline = NSBezierPath(rect: selectionRect)
            outline.setLineDash([4, 3], count: 2, phase: 0)
            outline.lineWidth = lineWidth
            SelectionBorder.coreColor.setStroke()
            outline.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch (event.keyCode, flags) {
        case (53, _):
            onCancel?()
        case (51, _), (117, _):
            deleteSelected()
        case (6, [.command]):
            undo()
        case (6, [.command, .shift]):
            redo()
        default:
            super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        commitTextIfNeeded()
        let point = imagePoint(for: event)

        switch tool {
        case .select:
            selectedAnnotationID = hitTest(point)
            draggingAnnotationID = selectedAnnotationID
            dragStart = point
            if selectedAnnotationID != nil { beginUndoGroup() }
            needsDisplay = true
        case .text:
            beginTextEditor(at: point)
        case .cursor(let style):
            recordUndo()
            let rect = CGRect(x: point.x - 18, y: point.y - 18, width: 36, height: 36)
            let annotation = Annotation(
                kind: .cursor(style),
                rect: rect,
                color: currentColor,
                thickness: settings.strokeThickness,
                opacity: settings.strokeOpacity
            )
            document.annotations.append(annotation)
            selectedAnnotationID = annotation.id
            tool = .select
            needsDisplay = true
        case .arrow, .rectangle, .blur:
            beginUndoGroup()
            dragStart = point
            temporaryAnnotation = makeAnnotation(for: tool, start: point, end: point)
            needsDisplay = true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = imagePoint(for: event)

        if let draggingAnnotationID, let dragStart {
            guard let index = document.annotations.firstIndex(where: { $0.id == draggingAnnotationID }) else { return }
            let delta = CGPoint(x: point.x - dragStart.x, y: point.y - dragStart.y)
            guard delta != .zero else { return }
            commitUndoGroup()

            var annotation = document.annotations[index]
            switch annotation.kind {
            case .arrow:
                annotation.start.x += delta.x
                annotation.start.y += delta.y
                annotation.end.x += delta.x
                annotation.end.y += delta.y
            default:
                annotation.rect = annotation.rect.offsetBy(dx: delta.x, dy: delta.y)
            }
            document.annotations[index] = annotation
            self.dragStart = point
            needsDisplay = true
            return
        }

        guard let dragStart, let temporaryAnnotation else { return }
        self.temporaryAnnotation = makeAnnotation(for: tool(for: temporaryAnnotation.kind), start: dragStart, end: point)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if let temporaryAnnotation {
            if AnnotationGeometry.isMeaningful(temporaryAnnotation) {
                commitUndoGroup()
                document.annotations.append(temporaryAnnotation)
                selectedAnnotationID = temporaryAnnotation.id
            } else {
                cancelUndoGroup()
            }
            self.temporaryAnnotation = nil
        }
        cancelUndoGroup()
        dragStart = nil
        draggingAnnotationID = nil
        needsDisplay = true
    }

    private func imagePoint(for event: NSEvent) -> CGPoint {
        let localPoint = convert(event.locationInWindow, from: nil)
        return CGPoint(x: localPoint.x / zoomScale, y: localPoint.y / zoomScale)
    }

    private func makeAnnotation(for tool: AnnotationTool, start: CGPoint, end: CGPoint) -> Annotation {
        let rect = CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
        let kind: AnnotationKind
        switch tool {
        case .arrow: kind = .arrow
        case .rectangle: kind = .rectangle
        case .blur: kind = .blur
        default: kind = .rectangle
        }
        return Annotation(
            kind: kind,
            start: start,
            end: end,
            rect: rect,
            color: currentColor,
            thickness: settings.strokeThickness,
            opacity: isBlurTool(tool) ? 1 : settings.strokeOpacity
        )
    }

    private func isBlurTool(_ tool: AnnotationTool) -> Bool {
        if case .blur = tool { return true }
        return false
    }

    private func tool(for kind: AnnotationKind) -> AnnotationTool {
        switch kind {
        case .arrow: return .arrow
        case .rectangle: return .rectangle
        case .blur: return .blur
        case .text: return .text
        case .cursor(let style): return .cursor(style)
        }
    }

    private func beginTextEditor(at point: CGPoint) {
        let frame = CGRect(
            x: point.x * zoomScale,
            y: point.y * zoomScale,
            width: max(180, settings.textSize * 8) * zoomScale,
            height: (settings.textSize + 16) * zoomScale
        )
        let field = NSTextField(frame: frame)
        field.font = settings.textBold
            ? NSFont.systemFont(ofSize: settings.textSize * zoomScale, weight: .bold)
            : NSFont.systemFont(ofSize: settings.textSize * zoomScale, weight: .regular)
        field.textColor = currentColor.withAlphaComponent(settings.textOpacity)
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
            recordUndo()
            let annotation = Annotation(
                kind: .text,
                rect: CGRect(origin: textOrigin, size: .zero),
                text: value,
                color: currentColor,
                thickness: settings.strokeThickness,
                opacity: settings.textOpacity
            )
            document.annotations.append(annotation)
            selectedAnnotationID = annotation.id
        }
        sender.removeFromSuperview()
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    private func commitTextIfNeeded() {
        if let textEditor {
            commitText(textEditor)
        }
    }

    private func beginUndoGroup() {
        pendingUndoSnapshot = document.annotations
    }

    private func commitUndoGroup() {
        guard let snapshot = pendingUndoSnapshot else { return }
        pendingUndoSnapshot = nil
        pushUndo(snapshot)
    }

    private func cancelUndoGroup() {
        pendingUndoSnapshot = nil
    }

    private func recordUndo() {
        pushUndo(document.annotations)
    }

    private func pushUndo(_ snapshot: [Annotation]) {
        undoStack.append(snapshot)
        if undoStack.count > Self.undoLimit { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    private func hitTest(_ point: CGPoint) -> UUID? {
        let tolerance = max(4, 10 / zoomScale)
        for annotation in document.annotations.reversed() {
            let bounds = AnnotationRenderer.bounds(of: annotation, settings: settings)
            if bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(point) {
                return annotation.id
            }
        }
        return nil
    }

    // Exposed for tests.
    var testTextEditor: NSTextField? { textEditor }
    func testBeginTextEditor(at point: CGPoint) { beginTextEditor(at: point) }
    var undoDepth: Int { undoStack.count }
    var redoDepth: Int { redoStack.count }

    func testBeginUndoGroup() { beginUndoGroup() }
    func testCommitUndoGroup() { commitUndoGroup() }
    func testCancelUndoGroup() { cancelUndoGroup() }
}

struct ToolbarPlacement {
    let windowFrame: CGRect
    let canvasFrame: CGRect
    let toolbarFrame: CGRect

    static func make(imageSize: NSSize, selectionFrame: CGRect, toolbarSize: NSSize) -> ToolbarPlacement {
        let gap: CGFloat = 8
        let visible = visibleFrame(for: selectionFrame, fallbackSize: imageSize)

        let maxWidth = max(240, visible.width)
        let maxHeight = max(180, visible.height - toolbarSize.height - gap)
        let scale = min(1, maxWidth / max(1, imageSize.width), maxHeight / max(1, imageSize.height))
        let canvasSize = NSSize(
            width: max(1, imageSize.width * scale),
            height: max(1, imageSize.height * scale)
        )
        let anchor = CGRect(origin: selectionFrame.origin, size: canvasSize)

        // PRD §5 order: below, right, above, left.
        let candidates = [
            CGRect(x: anchor.minX, y: anchor.minY - toolbarSize.height - gap, width: toolbarSize.width, height: toolbarSize.height),
            CGRect(x: anchor.maxX + gap, y: anchor.maxY - toolbarSize.height, width: toolbarSize.width, height: toolbarSize.height),
            CGRect(x: anchor.minX, y: anchor.maxY + gap, width: toolbarSize.width, height: toolbarSize.height),
            CGRect(x: anchor.minX - toolbarSize.width - gap, y: anchor.maxY - toolbarSize.height, width: toolbarSize.width, height: toolbarSize.height)
        ]

        for toolbar in candidates {
            let union = toolbar.union(anchor)
            guard visible.contains(union) else { continue }
            return ToolbarPlacement(
                windowFrame: union,
                canvasFrame: anchor.offsetBy(dx: -union.minX, dy: -union.minY),
                toolbarFrame: toolbar.offsetBy(dx: -union.minX, dy: -union.minY)
            )
        }

        // Nothing fits beside the canvas — typical for a full-screen capture. Overlay the
        // toolbar on the canvas instead of letting the window run off the display, which
        // used to put the buttons out of reach entirely.
        // The bar is allowed to be wider than the shot: widen the window to fit it rather
        // than squeezing the buttons into the canvas width and clipping them.
        var windowFrame = anchor
        windowFrame.size.width = min(max(anchor.width, toolbarSize.width), visible.width)
        windowFrame.size.height = min(windowFrame.height, visible.height)
        windowFrame.origin.x = clamp(windowFrame.minX, visible.minX, visible.maxX - windowFrame.width)
        windowFrame.origin.y = clamp(windowFrame.minY, visible.minY, visible.maxY - windowFrame.height)

        let canvasFrame = CGRect(
            x: ((windowFrame.width - min(anchor.width, windowFrame.width)) / 2).rounded(),
            y: 0,
            width: min(anchor.width, windowFrame.width),
            height: windowFrame.height
        )
        let toolbarWidth = min(toolbarSize.width, windowFrame.width)
        let toolbarFrame = CGRect(
            x: max(0, ((windowFrame.width - toolbarWidth) / 2).rounded()),
            y: gap,
            width: toolbarWidth,
            height: toolbarSize.height
        )
        return ToolbarPlacement(
            windowFrame: windowFrame,
            canvasFrame: canvasFrame,
            toolbarFrame: toolbarFrame
        )
    }

    private static func visibleFrame(for selectionFrame: CGRect, fallbackSize: NSSize) -> CGRect {
        let screen = NSScreen.screens.max { lhs, rhs in
            intersectionArea(lhs.frame, selectionFrame) < intersectionArea(rhs.frame, selectionFrame)
        } ?? NSScreen.main
        guard let screen else {
            return CGRect(origin: .zero, size: fallbackSize)
        }
        return screen.visibleFrame.insetBy(dx: 12, dy: 12)
    }

    private static func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let overlap = lhs.intersection(rhs)
        guard !overlap.isNull else { return 0 }
        return overlap.width * overlap.height
    }

    private static func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
        guard upper > lower else { return lower }
        return min(max(value, lower), upper)
    }
}

final class EditorToolbarView: NSVisualEffectView {
    private let cursorPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let colorWell = NSColorWell(frame: .zero)
    private var toolButtons: [(button: NSButton, key: String)] = []

    private let onTool: (AnnotationTool) -> Void
    private let onColorChange: (NSColor) -> Void
    private let onUndo: () -> Void
    private let onRedo: () -> Void
    private let onDelete: () -> Void
    private let onClear: () -> Void
    private let onSettings: () -> Void
    private let onCopy: () -> Void
    private let onSave: () -> Void
    private let onSaveAs: () -> Void
    private let onCancel: () -> Void

    init(
        color: NSColor,
        onTool: @escaping (AnnotationTool) -> Void,
        onColorChange: @escaping (NSColor) -> Void,
        onUndo: @escaping () -> Void,
        onRedo: @escaping () -> Void,
        onDelete: @escaping () -> Void,
        onClear: @escaping () -> Void,
        onSettings: @escaping () -> Void,
        onCopy: @escaping () -> Void,
        onSave: @escaping () -> Void,
        onSaveAs: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.onTool = onTool
        self.onColorChange = onColorChange
        self.onUndo = onUndo
        self.onRedo = onRedo
        self.onDelete = onDelete
        self.onClear = onClear
        self.onSettings = onSettings
        self.onCopy = onCopy
        self.onSave = onSave
        self.onSaveAs = onSaveAs
        self.onCancel = onCancel
        super.init(frame: .zero)

        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 10

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6)
        ])

        // Icon buttons with tooltips: the previous text labels needed far more width
        // than the bar ever had.
        stack.addArrangedSubview(toolButton("cursorarrow", "tool.select".localized("Select and move"), key: "select", #selector(selectTool)))
        stack.addArrangedSubview(toolButton("arrow.up.right", "tool.arrow".localized("Arrow"), key: "arrow", #selector(arrowTool)))
        stack.addArrangedSubview(toolButton("rectangle", "tool.rectangle".localized("Rectangle"), key: "rectangle", #selector(rectangleTool)))
        stack.addArrangedSubview(toolButton("textformat", "tool.text".localized("Text"), key: "text", #selector(textTool)))
        stack.addArrangedSubview(toolButton("eye.slash", "tool.blur".localized("Blur"), key: "blur", #selector(blurTool)))

        configureCursorPopup()
        stack.addArrangedSubview(cursorPopup)

        colorWell.color = color
        colorWell.target = self
        colorWell.action = #selector(colorWellChanged(_:))
        colorWell.toolTip = "tool.color.systemPicker".localized("Color — system picker")
        colorWell.widthAnchor.constraint(equalToConstant: 38).isActive = true
        colorWell.heightAnchor.constraint(equalToConstant: 24).isActive = true
        stack.addArrangedSubview(colorWell)

        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(actionButton("arrow.uturn.backward", "tool.undo".localized("Undo (⌘Z)"), #selector(undoAction)))
        stack.addArrangedSubview(actionButton("arrow.uturn.forward", "tool.redo".localized("Redo (⇧⌘Z)"), #selector(redoAction)))
        stack.addArrangedSubview(actionButton("trash", "tool.delete".localized("Delete selected (⌫)"), #selector(deleteAction)))
        stack.addArrangedSubview(actionButton("trash.slash", "tool.clear".localized("Clear all annotations"), #selector(clearAction)))
        stack.addArrangedSubview(actionButton("gearshape", "tool.settings".localized("Settings"), #selector(settingsAction)))
        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(actionButton("doc.on.doc", "tool.copy".localized("Copy"), #selector(copyAction)))
        stack.addArrangedSubview(actionButton("square.and.arrow.down", "tool.save.default".localized("Save to the default folder"), #selector(saveAction)))
        stack.addArrangedSubview(actionButton("square.and.arrow.down.on.square", "tool.saveAs".localized("Save As…"), #selector(saveAsAction)))
        stack.addArrangedSubview(actionButton("xmark", "tool.cancel".localized("Cancel (Esc)"), #selector(cancelAction)))

        updateSelectedTool("select")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Width/height the bar actually needs, so placement never has to guess.
    var preferredSize: NSSize {
        let fitting = fittingSize
        return NSSize(width: max(320, ceil(fitting.width)), height: max(40, ceil(fitting.height)))
    }

    func deactivateColorWell() {
        colorWell.deactivate()
    }

    func updateSelectedTool(_ key: String) {
        for entry in toolButtons {
            entry.button.state = entry.key == key ? .on : .off
        }
    }

    private func configureCursorPopup() {
        cursorPopup.removeAllItems()
        cursorPopup.addItem(withTitle: "cursor.menu".localized("Cursor"))
        for style in CursorStyle.allCases {
            cursorPopup.addItem(withTitle: style.title)
            cursorPopup.lastItem?.representedObject = style
        }
        cursorPopup.target = self
        cursorPopup.action = #selector(cursorChanged(_:))
        cursorPopup.controlSize = .small
        cursorPopup.toolTip = "cursor.tooltip".localized("Visual cursor")
        cursorPopup.widthAnchor.constraint(equalToConstant: 130).isActive = true
    }

    private func baseButton(_ symbol: String, _ tooltip: String, _ action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        let button = NSButton(image: image ?? NSImage(), target: self, action: action)
        button.bezelStyle = .texturedRounded
        button.imageScaling = .scaleProportionallyDown
        button.toolTip = tooltip
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.widthAnchor.constraint(equalToConstant: 30).isActive = true
        return button
    }

    private func actionButton(_ symbol: String, _ tooltip: String, _ action: Selector) -> NSButton {
        baseButton(symbol, tooltip, action)
    }

    private func toolButton(_ symbol: String, _ tooltip: String, key: String, _ action: Selector) -> NSButton {
        let button = baseButton(symbol, tooltip, action)
        button.setButtonType(.pushOnPushOff)
        toolButtons.append((button, key))
        return button
    }

    private func separator() -> NSView {
        let separator = NSBox(frame: .zero)
        separator.boxType = .separator
        separator.widthAnchor.constraint(equalToConstant: 1).isActive = true
        return separator
    }

    @objc private func selectTool() { select(.select, key: "select") }
    @objc private func arrowTool() { select(.arrow, key: "arrow") }
    @objc private func rectangleTool() { select(.rectangle, key: "rectangle") }
    @objc private func textTool() { select(.text, key: "text") }
    @objc private func blurTool() { select(.blur, key: "blur") }

    private func select(_ tool: AnnotationTool, key: String) {
        updateSelectedTool(key)
        onTool(tool)
    }

    @objc private func colorWellChanged(_ sender: NSColorWell) { onColorChange(sender.color) }
    @objc private func undoAction() { onUndo() }
    @objc private func redoAction() { onRedo() }
    @objc private func deleteAction() { onDelete() }
    @objc private func clearAction() { onClear() }
    @objc private func settingsAction() { onSettings() }
    @objc private func copyAction() { onCopy() }
    @objc private func saveAction() { onSave() }
    @objc private func saveAsAction() { onSaveAs() }
    @objc private func cancelAction() { onCancel() }

    @objc private func cursorChanged(_ sender: NSPopUpButton) {
        guard let style = sender.selectedItem?.representedObject as? CursorStyle else { return }
        // Snap back to the placeholder row so choosing the same cursor twice in a row
        // still fires — otherwise a second identical cursor could never be placed.
        sender.selectItem(at: 0)
        updateSelectedTool("cursor")
        onTool(.cursor(style))
    }
}

/// A borderless `NSPanel` refuses to become key by default, which left the editor unable
/// to receive typing or keyboard shortcuts at all.
final class EditorPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class WeakOwner<T: AnyObject> {
    weak var value: T?
}

@MainActor
final class EditorPanelController: NSWindowController, NSWindowDelegate {
    private let screenshotDocument: ScreenshotDocument
    private let settings: SettingsStore
    private let canvas: AnnotationCanvasView
    private let toolbar: EditorToolbarView
    private weak var settingsController: SettingsPanelController?
    private let selectionFrame: CGRect
    private var keyboardMonitor: Any?

    var onClose: (() -> Void)?

    init(image: NSImage, selectionFrame: CGRect, settings: SettingsStore, annotations: [Annotation] = []) {
        self.screenshotDocument = ScreenshotDocument(image: image)
        self.screenshotDocument.annotations = annotations
        self.settings = settings
        self.selectionFrame = selectionFrame

        let owner = WeakOwner<EditorPanelController>()
        let toolbar = EditorToolbarView(
            color: settings.defaultColor,
            onTool: { [owner] tool in owner.value?.canvas.setTool(tool) },
            onColorChange: { [owner] color in owner.value?.canvas.setColor(color) },
            onUndo: { [owner] in owner.value?.canvas.undo() },
            onRedo: { [owner] in owner.value?.canvas.redo() },
            onDelete: { [owner] in owner.value?.canvas.deleteSelected() },
            onClear: { [owner] in owner.value?.canvas.clearAnnotations() },
            onSettings: { [owner] in owner.value?.showSettings() },
            onCopy: { [owner] in owner.value?.copyResult() },
            onSave: { [owner] in owner.value?.saveResult() },
            onSaveAs: { [owner] in owner.value?.saveResultAs() },
            onCancel: { [owner] in owner.value?.close() }
        )
        self.toolbar = toolbar

        // Measure the bar before deciding where it goes.
        let placement = ToolbarPlacement.make(
            imageSize: image.size,
            selectionFrame: selectionFrame,
            toolbarSize: toolbar.preferredSize
        )
        toolbar.frame = placement.toolbarFrame

        let zoomScale = placement.canvasFrame.width / max(1, image.size.width)
        let canvas = AnnotationCanvasView(
            frame: placement.canvasFrame,
            document: screenshotDocument,
            settings: settings,
            zoomScale: zoomScale
        )
        self.canvas = canvas

        let root = NSView(frame: CGRect(origin: .zero, size: placement.windowFrame.size))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.clear.cgColor
        root.addSubview(canvas)
        root.addSubview(toolbar)

        let panel = EditorPanel(
            contentRect: placement.windowFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.contentView = root
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        // Without this the editor vanishes as soon as focus moves elsewhere (NSPanel
        // defaults `hidesOnDeactivate` to true), losing the unsaved screenshot.
        panel.hidesOnDeactivate = false

        super.init(window: panel)
        owner.value = self
        canvas.onCancel = { [weak self] in self?.close() }
        panel.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let keyboardMonitor { NSEvent.removeMonitor(keyboardMonitor) }
    }

    func show() {
        guard let window else { return }
        // Same ordering the capture overlay needs: a borderless panel only reliably takes
        // key focus if it is already on screen when the app activates, and the focus has
        // to be reasserted once activation lands. Without this the editor never receives
        // keyDown, so Esc, ⌘Z and text entry all silently did nothing.
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeKey()
            window.makeFirstResponder(self.canvas)
        }

        installKeyboardFallback()
    }

    /// A borderless `NSPanel` does not reliably win key focus, so the editor cannot depend
    /// on `keyDown` reaching the canvas. This monitor handles the shortcuts for whatever
    /// key events the app receives while the editor is open, and deliberately stands aside
    /// whenever the inline text editor is active.
    private func installKeyboardFallback() {
        removeKeyboardFallback()
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = self.window, window.isVisible else { return event }
            if window.firstResponder is NSTextView { return event }

            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            switch (event.keyCode, flags) {
            case (53, _):
                self.close()
            case (51, _), (117, _):
                self.canvas.deleteSelected()
            case (6, [.command]):
                self.canvas.undo()
            case (6, [.command, .shift]):
                self.canvas.redo()
            default:
                return event
            }
            return nil
        }
    }

    private func removeKeyboardFallback() {
        if let keyboardMonitor {
            NSEvent.removeMonitor(keyboardMonitor)
            self.keyboardMonitor = nil
        }
    }

    func windowWillClose(_ notification: Notification) {
        removeKeyboardFallback()
        // The colour well owns the shared NSColorPanel while active; leaving it attached
        // pointed the panel at a controller that is about to go away.
        toolbar.deactivateColorWell()
        settingsController?.close()
        settingsController = nil
        onClose?()
    }

    private func showSettings() {
        if let settingsController {
            settingsController.show()
            return
        }
        let controller = SettingsPanelController(settings: settings)
        settingsController = controller
        controller.show()
    }

    private func copyResult() {
        guard let data = canvas.renderedData(format: .png) else {
            showError("error.clipboard.prepare".localized("Could not prepare the image for the clipboard."))
            return
        }
        ScreenshotOutput.copy(data, settings: settings)
        close()
    }

    private func saveResult() {
        let format = settings.outputFormat
        guard let data = canvas.renderedData(format: format) else {
            showError("error.save.prepare".localized("Could not prepare the image for saving."))
            return
        }
        do {
            _ = try ScreenshotOutput.save(data, format: format, settings: settings)
            close()
        } catch {
            showError("error.save.write".localized("Could not save the file: %@", error.localizedDescription))
        }
    }

    private func saveResultAs() {
        guard let window else { return }
        let format = settings.outputFormat
        let panel = ScreenshotOutput.makeSavePanel(format: format)
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            guard let data = self.canvas.renderedData(format: format) else {
                self.showError("error.save.prepare".localized("Could not prepare the image for saving."))
                return
            }
            do {
                try ScreenshotOutput.write(data, to: url, settings: self.settings)
                self.close()
            } catch {
                self.showError("error.save.write".localized("Could not save the file: %@", error.localizedDescription))
            }
        }
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "error.title".localized("Error")
        alert.informativeText = message
        alert.runModal()
    }
}
