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
    case glow
    case smoke
    case glass
    case blobs
    case plasma

    static let `default` = PanelBackgroundStyle.glow

    var title: String {
        switch self {
        case .glow: return "panelBackground.glow".localized("Glowing edge")
        case .smoke: return "panelBackground.smoke".localized("Curling smoke")
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
        // Without this AppKit silently ignores `CALayer.filters`, and the glow would
        // simply never be blurred.
        layerUsesCoreImageFilters = true
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
        if !isEdgeLit { applyFeather() }
        layoutStyleLayers()
    }

    // MARK: - Construction

    /// The glowing edge is the one style built around a crisp outline rather than a fill
    /// that fades out, so it keeps its rounded rectangle and lets the glow spill past it.
    private var isEdgeLit: Bool { style == .glow }

    private func build() {
        switch style {
        case .glow: buildGlow()
        case .smoke: buildSmoke()
        case .glass: buildGlass()
        case .blobs: buildBlobs()
        case .plasma: buildPlasma()
        }
    }

    /// A rotating gradient shown twice: once as a rim just outside the panel, once
    /// scaled down, dropped and genuinely blurred underneath as its glow. Both turn
    /// together.
    ///
    /// The blur is a real `CIGaussianBlur`, as in the original, and it is the one thing in
    /// this file that costs something per frame: the gradient's content changes as it
    /// turns, so the filter runs again. It is bounded by the size of the layer it runs
    /// on — a few hundred points across — rather than by anything on screen.
    private func buildGlow() {
        layer?.masksToBounds = false

        // The blurred copy lives inside a larger container so the blur has somewhere to
        // spread. A gradient layer fills its own bounds edge to edge, so blurring one
        // directly would have nothing but its own colour to bleed into.
        let container = CALayer()
        container.masksToBounds = false
        let gradient = Self.spinningGradient()
        container.addSublayer(gradient)
        if let blur = CIFilter(name: "CIGaussianBlur") {
            container.filters = [blur]
        }
        layer?.addSublayer(container)
        glowContainer = container
        glowLayer = gradient

        rimLayer = Self.spinningGradient()
        if let rimLayer { layer?.addSublayer(rimLayer) }

        // The fill sits on top of the rim, so only the rim's outer margin shows.
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.appearance = NSAppearance(named: .aqua)
        effect.wantsLayer = true
        effect.layer?.cornerRadius = cornerRadius
        effect.layer?.masksToBounds = true
        addSubview(effect)
        effectView = effect

        // Painted over the material rather than instead of it: the blur stays, and the
        // panel lands on a definite tone rather than whatever the desktop happens to be.
        let tint = CALayer()
        tint.backgroundColor = Self.glowFill.cgColor
        tint.cornerRadius = cornerRadius
        effect.layer?.addSublayer(tint)
        glowTint = tint
    }

    /// Real particles rather than a moving picture of some: `CAEmitterLayer` is simulated
    /// by the window server on the GPU, so a few dozen puffs cost the app nothing per
    /// frame — the same budget as the gradient styles, for far more life.
    private func buildSmoke() {
        layer?.backgroundColor = PanelStyle.fill.cgColor
        let puff = Self.puffImage()

        for (index, colour) in Self.smokeTints.enumerated() {
            let emitter = CAEmitterLayer()
            // Born throughout the panel rather than along one edge: it is only about 50pt
            // tall, so anything rising from the bottom would be gone before it read as
            // smoke at all.
            emitter.emitterShape = .rectangle
            emitter.emitterMode = .volume
            emitter.renderMode = .unordered
            // A fixed seed per emitter keeps each plume's character stable between runs
            // instead of occasionally starting out bunched up.
            emitter.seed = UInt32(1_301 + index * 977)

            let cell = CAEmitterCell()
            cell.contents = puff
            cell.color = colour.cgColor
            cell.birthRate = 5
            cell.lifetime = 8
            cell.lifetimeRange = 3
            // Slow and wide: smoke reads by how it spreads, not by how fast it travels.
            // The drift is mostly sideways, along the panel's long axis, so a puff stays
            // in view for most of its life.
            cell.velocity = 5
            cell.velocityRange = 4
            cell.emissionLongitude = .pi / 2
            cell.emissionRange = .pi
            cell.yAcceleration = 1.5
            // Opposite sideways drift per plume is what makes them wind around each other.
            cell.xAcceleration = index.isMultiple(of: 2) ? 9 : -9
            cell.scale = 0.45
            cell.scaleRange = 0.3
            cell.scaleSpeed = 0.16
            cell.spin = 0.6
            cell.spinRange = 1.1
            cell.alphaSpeed = -0.1
            emitter.emitterCells = [cell]

            layer?.addSublayer(emitter)
            styleLayers.append(emitter)
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
    private var rimLayer: CAGradientLayer?
    private var glowLayer: CAGradientLayer?
    private var glowContainer: CALayer?
    private var glowTint: CALayer?

    /// For tests: the blur actually attached to the glow, and its radius.
    var testGlowBlurRadius: CGFloat? {
        guard let filter = glowContainer?.filters?.first as? CIFilter,
              filter.name == "CIGaussianBlur" else { return nil }
        return filter.value(forKey: kCIInputRadiusKey) as? CGFloat
    }
    var testUsesCoreImageFilters: Bool { layerUsesCoreImageFilters }
    private var blobDrifts: [CABasicAnimation] = []
    private var plasmaDirections: [CGFloat] = []

    private func layoutStyleLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        switch style {
        case .glow:
            effectView?.frame = bounds
            glowTint?.frame = CGRect(origin: .zero, size: bounds.size)

            let rimWidth = Self.rimWidth
            rimLayer?.frame = bounds.insetBy(dx: -rimWidth, dy: -rimWidth)
            rimLayer?.cornerRadius = cornerRadius + rimWidth

            // Scaled down and dropped, exactly as the original places its blurred copy,
            // then blurred by roughly the panel's own height so it reads as a halo rather
            // than a second rectangle.
            let radius = max(bounds.height * 0.75, 20)
            let padding = radius * 3
            let container = bounds.insetBy(dx: -padding, dy: -padding)
            glowContainer?.frame = container
            glowContainer?.opacity = 0.75
            (glowContainer?.filters?.first as? CIFilter)?
                .setValue(radius, forKey: kCIInputRadiusKey)

            let inner = bounds
                .insetBy(dx: bounds.width * 0.1, dy: bounds.height * 0.1)
                .offsetBy(dx: 0, dy: -bounds.height / 6)
            glowLayer?.frame = CGRect(
                x: inner.minX - container.minX,
                y: inner.minY - container.minY,
                width: inner.width,
                height: inner.height
            )
            glowLayer?.cornerRadius = cornerRadius

        case .smoke:
            for (index, emitter) in styleLayers.compactMap({ $0 as? CAEmitterLayer }).enumerated() {
                emitter.frame = bounds
                emitter.emitterSize = CGSize(width: bounds.width * 0.6, height: bounds.height)
                let origin = CGPoint(x: bounds.midX, y: bounds.midY)
                emitter.emitterPosition = origin

                // The source itself wanders on an ellipse, so the plumes curl instead of
                // rising in a straight column.
                let path = CGMutablePath()
                path.addEllipse(in: CGRect(
                    x: origin.x - bounds.width * 0.2,
                    y: origin.y - bounds.height * 0.3,
                    width: bounds.width * 0.4,
                    height: bounds.height * 0.6
                ))
                let wander = CAKeyframeAnimation(keyPath: "emitterPosition")
                wander.path = path
                wander.duration = 13 + Double(index) * 5
                wander.repeatCount = .infinity
                wander.calculationMode = .paced
                wander.timeOffset = Double(index) * 6
                wander.isRemovedOnCompletion = false
                emitter.add(wander, forKey: "wander")
            }

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

    private static let rimWidth: CGFloat = 1
    /// A couple of tones below `PanelStyle.buttonFill`, so the controls sit slightly
    /// proud of the panel instead of dissolving into it. Part-transparent, so the blur
    /// underneath still shows through.
    private static let glowFill = NSColor(white: 0.85, alpha: 0.74)
    /// Greyscale, dark to light. The card this is modelled on runs blue to violet; here
    /// the panel sits over the very thing being captured, and a colourless sweep lights
    /// the edge without tinting what is behind it.
    private static let glowColours: [CGColor] = [
        NSColor(white: 0.97, alpha: 1).cgColor,
        NSColor(white: 0.62, alpha: 1).cgColor,
        NSColor(white: 0.22, alpha: 1).cgColor
    ]

    /// A linear gradient whose angle turns a full circle, which is what the original
    /// animates through a custom `<angle>` property. `CAGradientLayer` has no angle, so
    /// the two ends are walked around a circle instead — the same thing, expressed in the
    /// terms Core Animation understands.
    private static func spinningGradient() -> CAGradientLayer {
        let gradient = CAGradientLayer()
        gradient.colors = glowColours
        gradient.locations = [0, 0.43, 1]

        let steps = 36
        var starts: [CGPoint] = []
        var ends: [CGPoint] = []
        for step in 0...steps {
            let angle = 2 * Double.pi * Double(step) / Double(steps)
            let dx = CGFloat(cos(angle)) / 2
            let dy = CGFloat(sin(angle)) / 2
            starts.append(CGPoint(x: 0.5 - dx, y: 0.5 - dy))
            ends.append(CGPoint(x: 0.5 + dx, y: 0.5 + dy))
        }
        gradient.startPoint = starts[0]
        gradient.endPoint = ends[0]

        for (keyPath, values) in [("startPoint", starts), ("endPoint", ends)] {
            let spin = CAKeyframeAnimation(keyPath: keyPath)
            spin.values = values
            spin.duration = 2.5
            spin.calculationMode = .linear
            spin.repeatCount = .infinity
            spin.isRemovedOnCompletion = false
            gradient.add(spin, forKey: keyPath)
        }
        return gradient
    }

    /// Far stronger than the gradient styles': a puff is thin on its own, and only the
    /// places where several overlap should read at all.
    private static let smokeTints: [NSColor] = [
        NSColor.systemTeal.withAlphaComponent(0.5),
        NSColor.systemIndigo.withAlphaComponent(0.45),
        NSColor.systemPurple.withAlphaComponent(0.4)
    ]

    /// One soft round blob, tinted per plume by `CAEmitterCell.color`.
    private static func puffImage() -> CGImage? {
        let side = 64
        guard let context = CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        let centre = CGPoint(x: side / 2, y: side / 2)
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [
                CGColor(red: 1, green: 1, blue: 1, alpha: 1),
                CGColor(red: 1, green: 1, blue: 1, alpha: 0.5),
                CGColor(red: 1, green: 1, blue: 1, alpha: 0)
            ] as CFArray,
            locations: [0, 0.45, 1]
        ) else { return nil }

        context.drawRadialGradient(
            gradient,
            startCenter: centre,
            startRadius: 0,
            endCenter: centre,
            endRadius: CGFloat(side) / 2,
            options: []
        )
        return context.makeImage()
    }

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
