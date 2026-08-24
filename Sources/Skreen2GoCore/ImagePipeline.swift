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
