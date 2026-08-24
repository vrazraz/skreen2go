import AppKit
import CoreImage
import Foundation

/// How the floating panels are filled.
///
/// Every one of these animates on `CALayer` properties alone, which the window server
/// interpolates on the GPU: once an animation is added the app does no per-frame work at
/// all. Nothing here uses `backgroundFilters` or redraws on a timer, which are the two
/// ways a decorative background turns into a running cost.
enum PanelBackgroundStyle: String, CaseIterable {
    case glass
    case blobs
    case plasma

    static let `default` = PanelBackgroundStyle.glass

    var title: String {
        switch self {
        case .glass: return "panelBackground.glass".localized("Live glass")
        case .blobs: return "panelBackground.blobs".localized("Drifting blobs")
        case .plasma: return "panelBackground.plasma".localized("Plasma")
        }
    }
}

/// The animated fill behind a panel's controls.
///
/// The edges are feathered rather than cut: the panel fades out instead of ending at a
/// rounded rectangle, so it reads as part of the overlay rather than a card dropped on
/// top of it. That is also why there is no shadow — a shadow needs an edge to cast from.
final class PanelBackgroundView: NSView {
    /// Colours stay this faint on purpose. The panel sits over whatever the user is about
    /// to capture, and a background that competes with it is a background doing the wrong
    /// job.
    private static let tintAlpha: CGFloat = 0.16
    private static let featherInset: CGFloat = 6

    private let style: PanelBackgroundStyle
    private let cornerRadius: CGFloat
    private var effectView: NSVisualEffectView?
    private var maskedSize: NSSize = .zero

    init(style: PanelBackgroundStyle, cornerRadius: CGFloat) {
        self.style = style
        self.cornerRadius = cornerRadius
        super.init(frame: .zero)

        wantsLayer = true
        layer?.masksToBounds = true
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Decoration only: a click belongs to whatever is on top of it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        guard bounds.size != maskedSize, bounds.width > 0, bounds.height > 0 else { return }
        maskedSize = bounds.size
        applyFeather()
        layoutStyleLayers()
    }

    // MARK: - Construction

    private func build() {
        switch style {
        case .glass: buildGlass()
        case .blobs: buildBlobs()
        case .plasma: buildPlasma()
        }
    }

    private func buildGlass() {
        // The system's own blur, which is both the cheapest way to get one and the only
        // one that samples what is actually behind the window.
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        addSubview(effect)
        effectView = effect

        let tint = CAGradientLayer()
        tint.colors = Self.tints.map { $0.cgColor }
        tint.startPoint = CGPoint(x: 0, y: 0.5)
        tint.endPoint = CGPoint(x: 1, y: 0.5)
        tint.opacity = 1
        layer?.addSublayer(tint)
        // Sliding the colour stops walks the tint across the panel without moving or
        // resizing anything.
        tint.add(Self.slide(from: [0, 0.35, 0.7], to: [0.3, 0.65, 1], duration: 14), forKey: "drift")
        styleLayers.append(tint)
    }

    private func buildBlobs() {
        layer?.backgroundColor = PanelStyle.fill.cgColor

        for (index, colour) in Self.tints.enumerated() {
            let blob = CAGradientLayer()
            blob.type = .radial
            // A radial gradient is its own blur: no filter has to run to soften it.
            blob.colors = [colour.cgColor, colour.withAlphaComponent(0).cgColor]
            blob.locations = [0, 1]
            blob.startPoint = CGPoint(x: 0.5, y: 0.5)
            blob.endPoint = CGPoint(x: 1, y: 1)
            layer?.addSublayer(blob)
            styleLayers.append(blob)

            let drift = CABasicAnimation(keyPath: "position.x")
            drift.duration = 11 + Double(index) * 3
            drift.autoreverses = true
            drift.repeatCount = .infinity
            drift.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            drift.timeOffset = Double(index) * 4
            blobDrifts.append(drift)
        }
    }

    private func buildPlasma() {
        layer?.backgroundColor = PanelStyle.fill.cgColor

        // Two copies of one seamless texture, scrolled at different speeds in opposite
        // directions. The texture is built once; after that the movement is a position
        // animation and costs nothing per frame.
        for (index, colour) in Self.tints.prefix(2).enumerated() {
            let field = CALayer()
            field.contents = Self.plasmaTexture(tinted: colour)
            field.contentsGravity = .resize
            field.opacity = 1
            layer?.addSublayer(field)
            styleLayers.append(field)
            plasmaDirections.append(index.isMultiple(of: 2) ? -1 : 1)
        }
    }

    // MARK: - Layout

    private var styleLayers: [CALayer] = []
    private var blobDrifts: [CABasicAnimation] = []
    private var plasmaDirections: [CGFloat] = []

    private func layoutStyleLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        switch style {
        case .glass:
            // Sized here for the same reason the background itself is pinned: it is built
            // before the panel knows how wide its controls make it.
            effectView?.frame = bounds
            styleLayers.first?.frame = bounds

        case .blobs:
            let side = max(bounds.height * 2.4, 90)
            for (index, blob) in styleLayers.enumerated() {
                let y = bounds.midY - side / 2
                let x = bounds.width * CGFloat(index + 1) / CGFloat(styleLayers.count + 1) - side / 2
                blob.frame = CGRect(x: x, y: y, width: side, height: side)
                guard index < blobDrifts.count else { continue }
                let drift = blobDrifts[index]
                drift.fromValue = blob.position.x - bounds.width * 0.22
                drift.toValue = blob.position.x + bounds.width * 0.22
                blob.add(drift, forKey: "drift")
            }

        case .plasma:
            for (index, field) in styleLayers.enumerated() {
                // Twice the width, holding the texture twice over, so sliding by exactly
                // one width lands back where it started and the loop cannot be seen.
                field.frame = CGRect(x: 0, y: 0, width: bounds.width * 2, height: bounds.height)
                let direction = index < plasmaDirections.count ? plasmaDirections[index] : -1
                let scroll = CABasicAnimation(keyPath: "position.x")
                scroll.fromValue = field.position.x
                scroll.toValue = field.position.x + direction * bounds.width
                scroll.duration = 18 + Double(index) * 7
                scroll.repeatCount = .infinity
                scroll.isRemovedOnCompletion = false
                field.add(scroll, forKey: "scroll")
            }
        }
    }

    /// Fades the panel out towards its edges instead of cutting it off.
    private func applyFeather() {
        guard let mask = Self.featherImage(
            size: bounds.size,
            cornerRadius: cornerRadius,
            feather: Self.featherInset
        ) else { return }

        if let effectView {
            // `NSVisualEffectView` masks itself; going through its own property keeps the
            // blur clipped correctly rather than clipped twice.
            effectView.maskImage = mask
            layer?.mask = nil
        } else {
            let maskLayer = CALayer()
            maskLayer.frame = bounds
            maskLayer.contents = mask.cgImage(
                forProposedRect: nil,
                context: nil,
                hints: nil
            )
            layer?.mask = maskLayer
        }
    }

    // MARK: - Ingredients

    private static let tints: [NSColor] = [
        NSColor.systemTeal.withAlphaComponent(tintAlpha),
        NSColor.systemBlue.withAlphaComponent(tintAlpha),
        NSColor.systemPurple.withAlphaComponent(tintAlpha)
    ]

    private static func slide(from: [NSNumber], to: [NSNumber], duration: Double) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: "locations")
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        return animation
    }

    /// A rounded rectangle with a soft edge, drawn once per size and reused.
    private static func featherImage(
        size: NSSize,
        cornerRadius: CGFloat,
        feather: CGFloat
    ) -> NSImage? {
        guard size.width > feather * 2, size.height > feather * 2 else { return nil }

        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.clear.setFill()
        NSBezierPath(rect: CGRect(origin: .zero, size: size)).fill()

        // Concentric rings of rising opacity: a blur without running one, and the whole
        // thing happens once, when the panel changes size.
        let steps = Int(feather)
        for step in 0...max(steps, 1) {
            let inset = feather - CGFloat(step)
            let alpha = CGFloat(step) / CGFloat(max(steps, 1))
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset)
            guard rect.width > 0, rect.height > 0 else { continue }
            NSColor(white: 0, alpha: alpha).setFill()
            NSBezierPath(
                roundedRect: rect,
                xRadius: max(cornerRadius - inset, 0),
                yRadius: max(cornerRadius - inset, 0)
            ).fill()
        }
        image.unlockFocus()
        return image
    }

    /// A seamless field of soft blotches, tiled twice across so it can be scrolled without
    /// a visible seam. Built from sines on an integer lattice, which is what makes both
    /// edges match exactly.
    private static func plasmaTexture(tinted colour: NSColor) -> CGImage? {
        let width = 128
        let height = 32
        let components = colour.usingColorSpace(.deviceRGB) ?? .systemBlue

        guard let context = CGContext(
            data: nil,
            width: width * 2,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        guard let pixels = context.data else { return nil }

        let buffer = pixels.bindMemory(to: UInt8.self, capacity: width * 2 * height * 4)
        let red = components.redComponent
        let green = components.greenComponent
        let blue = components.blueComponent
        let peak = components.alphaComponent

        for y in 0..<height {
            for x in 0..<width {
                let u = Double(x) / Double(width)
                let v = Double(y) / Double(height)
                // Integer frequencies only: every wave completes a whole number of cycles
                // across the texture, so the right edge meets the left exactly.
                let field =
                    sin(2 * .pi * (u * 1)) * 0.5 +
                    sin(2 * .pi * (u * 2 + v * 1)) * 0.3 +
                    sin(2 * .pi * (u * 3 - v * 2)) * 0.2
                let intensity = max(0, min(1, (field + 1) / 2))
                let alpha = peak * CGFloat(intensity)

                for copy in 0..<2 {
                    let offset = ((y * width * 2) + x + copy * width) * 4
                    buffer[offset] = UInt8(red * alpha * 255)
                    buffer[offset + 1] = UInt8(green * alpha * 255)
                    buffer[offset + 2] = UInt8(blue * alpha * 255)
                    buffer[offset + 3] = UInt8(alpha * 255)
                }
            }
        }
        return context.makeImage()
    }
}
