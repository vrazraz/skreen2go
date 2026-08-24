import AppKit
import CoreImage
import Foundation

/// The lit edge behind a panel's controls.
///
/// A single gradient shown twice: as a thin rim just outside the panel, and scaled down,
/// dropped and blurred underneath as its glow. Both turn together.
///
/// The turning is a `CALayer` animation, which the window server interpolates on the GPU,
/// so the app does no per-frame work for it. The blur is the one exception, and is
/// discussed where it is set up.
final class PanelBackgroundView: NSView {
    private static let rimWidth: CGFloat = 1.5
    private static let glowOpacity: Float = 0.75
    /// Matches the `transition: opacity .5s` the effect is modelled on.
    private static let fadeDuration = 0.5
    /// A couple of tones below `PanelStyle.buttonFill`, so the controls sit slightly proud
    /// of the panel instead of dissolving into it. Part-transparent, so the blur
    /// underneath still shows through.
    private static let fill = NSColor(white: 0.85, alpha: 0.74)
    /// Greyscale, dark to light. The card this is modelled on runs blue to violet; here
    /// the panel sits over the very thing being captured, and a colourless sweep lights
    /// the edge without tinting what is behind it.
    private static let gradientColours: [CGColor] = [
        NSColor(white: 0.97, alpha: 1).cgColor,
        NSColor(white: 0.62, alpha: 1).cgColor,
        NSColor(white: 0.22, alpha: 1).cgColor
    ]

    private let cornerRadius: CGFloat
    private var effectView: NSVisualEffectView?
    private var tintLayer: CALayer?
    private var rimLayer: CAGradientLayer?
    private var glowLayer: CAGradientLayer?
    private var glowContainer: CALayer?
    private var laidOutSize: NSSize = .zero
    private var isPointerInside = false

    init(cornerRadius: CGFloat) {
        self.cornerRadius = cornerRadius
        super.init(frame: .zero)

        wantsLayer = true
        // Without this AppKit silently ignores `CALayer.filters`, and the glow would
        // simply never be blurred.
        layerUsesCoreImageFilters = true
        // The glow spills past the panel, which is the whole point of it.
        layer?.masksToBounds = false
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Decoration only: a click belongs to whatever is on top of it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        guard bounds.size != laidOutSize, bounds.width > 0, bounds.height > 0 else { return }
        laidOutSize = bounds.size
        layoutLayers()
    }

    // MARK: - Construction

    private func build() {
        // The blurred copy lives inside a larger container so the blur has somewhere to
        // spread. A gradient layer fills its own bounds edge to edge, so blurring one
        // directly would have nothing but its own colour to bleed into.
        //
        // This blur is the one thing here that costs per frame: the gradient's content
        // changes as it turns, so the filter runs again. It is bounded by the layer it
        // runs on — a few hundred points across — rather than by anything on screen, and
        // it stops entirely once the pointer is over the panel.
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

        let rim = Self.spinningGradient()
        layer?.addSublayer(rim)
        rimLayer = rim

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
        tint.backgroundColor = Self.fill.cgColor
        tint.cornerRadius = cornerRadius
        effect.layer?.addSublayer(tint)
        tintLayer = tint
    }

    // MARK: - Layout

    private func layoutLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        effectView?.frame = bounds
        tintLayer?.frame = CGRect(origin: .zero, size: bounds.size)

        let rimWidth = Self.rimWidth
        rimLayer?.frame = bounds.insetBy(dx: -rimWidth, dy: -rimWidth)
        rimLayer?.cornerRadius = cornerRadius + rimWidth

        // Scaled down and dropped, exactly as the original places its blurred copy, then
        // blurred by roughly the panel's own height so it reads as a halo rather than a
        // second rectangle.
        let radius = max(bounds.height * 0.75, 20)
        let padding = radius * 3
        let container = bounds.insetBy(dx: -padding, dy: -padding)
        glowContainer?.frame = container
        glowContainer?.opacity = isPointerInside ? 0 : Self.glowOpacity
        (glowContainer?.filters?.first as? CIFilter)?.setValue(radius, forKey: kCIInputRadiusKey)

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
    }

    // MARK: - Hover

    /// Fades the lit edge out while the pointer is over the panel, then stops it turning
    /// altogether.
    ///
    /// The point is the same one the original card makes by killing its animation on
    /// hover: once you are reaching for a control, a moving rim behind it is in the way.
    /// Taking the animations off after the fade also stops the blur being recomputed for
    /// something that is no longer visible.
    func setPointerInside(_ inside: Bool) {
        guard inside != isPointerInside else { return }
        isPointerInside = inside

        CATransaction.begin()
        CATransaction.setAnimationDuration(Self.fadeDuration)
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.isPointerInside == inside, inside else { return }
            self.glowLayer?.removeAllAnimations()
            self.rimLayer?.removeAllAnimations()
        }
        if !inside {
            glowLayer.map(Self.applySpin)
            rimLayer.map(Self.applySpin)
        }
        glowContainer?.opacity = inside ? 0 : Self.glowOpacity
        rimLayer?.opacity = inside ? 0 : 1
        CATransaction.commit()
    }

    // MARK: - The turning gradient

    /// A linear gradient whose angle turns a full circle, which is what the original
    /// animates through a custom `<angle>` property. `CAGradientLayer` has no angle, so
    /// the two ends are walked around a circle instead — the same thing, expressed in the
    /// terms Core Animation understands.
    private static func spinningGradient() -> CAGradientLayer {
        let gradient = CAGradientLayer()
        gradient.colors = gradientColours
        gradient.locations = [0, 0.43, 1]
        let steps = angleSteps()
        gradient.startPoint = steps.starts[0]
        gradient.endPoint = steps.ends[0]
        applySpin(to: gradient)
        return gradient
    }

    /// Separate from building the gradient so the turn can be put back after a hover has
    /// taken it away.
    private static func applySpin(to gradient: CAGradientLayer) {
        let steps = angleSteps()
        for (keyPath, values) in [("startPoint", steps.starts), ("endPoint", steps.ends)] {
            let spin = CAKeyframeAnimation(keyPath: keyPath)
            spin.values = values
            spin.duration = 2.5
            spin.calculationMode = .linear
            spin.repeatCount = .infinity
            spin.isRemovedOnCompletion = false
            gradient.add(spin, forKey: keyPath)
        }
    }

    private static func angleSteps() -> (starts: [CGPoint], ends: [CGPoint]) {
        let count = 36
        var starts: [CGPoint] = []
        var ends: [CGPoint] = []
        for step in 0...count {
            let angle = 2 * Double.pi * Double(step) / Double(count)
            let dx = CGFloat(cos(angle)) / 2
            let dy = CGFloat(sin(angle)) / 2
            starts.append(CGPoint(x: 0.5 - dx, y: 0.5 - dy))
            ends.append(CGPoint(x: 0.5 + dx, y: 0.5 + dy))
        }
        return (starts, ends)
    }

    // MARK: - Test hooks

    var testUsesCoreImageFilters: Bool { layerUsesCoreImageFilters }
    var testGlowOpacity: Float { glowContainer?.opacity ?? 0 }
    var testRimOpacity: Float { rimLayer?.opacity ?? 0 }
    var testRimIsTurning: Bool { (rimLayer?.animationKeys() ?? []).contains("startPoint") }
    var testGlowBlurRadius: CGFloat? {
        guard let filter = glowContainer?.filters?.first as? CIFilter,
              filter.name == "CIGaussianBlur" else { return nil }
        return filter.value(forKey: kCIInputRadiusKey) as? CGFloat
    }
}
