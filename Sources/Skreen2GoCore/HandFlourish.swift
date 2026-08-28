import AppKit
import MetalKit
import RiveRuntime

/// The hand that reaches in whenever a screenshot lands on the clipboard.
///
/// Purely a flourish, so every failure here is silent: a missing or unreadable animation
/// leaves copying exactly as it was rather than putting an error in front of someone who
/// asked for a screenshot, not for a cartoon.
@MainActor
final class HandFlourish {
    static let shared = HandFlourish()

    /// The artboard the hand was drawn on. Its proportions decide the panel's, so the
    /// sweep is framed on screen exactly as it was framed in the editor.
    static let artboardSize = CGSize(width: 1512, height: 982)
    /// How much of the screen's width the flourish spans. Deliberately a constant rather
    /// than something derived from the selection: a flourish that changed size with every
    /// shot would read as an accident instead of as the app's own signature.
    static let widthFraction: CGFloat = 0.62
    static let maximumWidth: CGFloat = 1000
    /// Raises the flourish off dead centre, as a fraction of its own height. The hand
    /// reaches up out of the lower half of the artboard, so centring on the capture puts
    /// it lower than it looks like it should be.
    static let verticalLift: CGFloat = 0.15

    /// How much faster than authored the hand moves. `Timeline 1` was drawn at 1.417s,
    /// which is a long time to watch after a keystroke; this brings it to about 0.8s.
    /// Applied to the elapsed time handed to the runtime rather than by editing the file,
    /// so the animation stays exactly as it was drawn and only its clock changes.
    static let playbackSpeed: Double = 1.75

    private static let fileName = "hand"
    private static let animationName = "Timeline 1"
    /// The watchdog only exists because the delegate callback is the one part of this that
    /// is out of our hands; without it a silent runtime would leave a hand parked on the
    /// screen for good.
    private static let watchdogTimeout: TimeInterval = 4

    private var panel: NSPanel?
    private var viewModel: HandViewModel?
    private var watchdog: Timer?
    /// Set once the load has been tried, successfully or not, so a broken file costs one
    /// failed read rather than one per screenshot.
    private var hasAttemptedLoad = false
    /// Guards `finish` against being re-entered by a callback it caused itself. Halting
    /// the view makes the runtime announce that it stopped, and that announcement is what
    /// calls `finish` in the first place.
    private var isShowing = false

    private init() {}

    // MARK: - Geometry (pure, so the framing is testable without a screen)

    /// Centres the artboard over what was just captured, lifts it a little, then slides it
    /// back inside the screen so the hand is never half off the edge.
    static func frame(over rect: CGRect, on screen: CGRect) -> CGRect {
        let width = min(screen.width * widthFraction, maximumWidth)
        let height = width * artboardSize.height / artboardSize.width
        let origin = CGPoint(
            x: clamp(rect.midX - width / 2, lower: screen.minX, upper: screen.maxX - width),
            y: clamp(
                rect.midY - height / 2 + height * verticalLift,
                lower: screen.minY,
                upper: screen.maxY - height
            )
        )
        return CGRect(origin: origin, size: CGSize(width: width, height: height))
    }

    /// Falls back to centring when the range is inverted, which happens when the flourish
    /// is wider than the screen it is playing on.
    private static func clamp(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        guard upper > lower else { return (lower + upper) / 2 }
        return min(max(value, lower), upper)
    }

    // MARK: - Playback

    /// Builds the panel and loads the animation ahead of the first screenshot. Standing up
    /// a Metal layer and parsing the file takes long enough to be seen, and the one moment
    /// it must not be seen is the shot that triggers it.
    func prepare() {
        _ = ensureLoaded()
    }

    /// `rect` is what was just captured. It is optional because the editor can copy a
    /// shot long after the selection it came from is gone, and in that case the pointer is
    /// the best guess at where the user is looking.
    func play(over rect: CGRect?) {
        guard let viewModel = ensureLoaded(), let panel else { return }

        let anchor = rect ?? Self.pointerAnchor()
        guard let screenFrame = Self.screenFrame(for: anchor) else { return }

        panel.setFrame(Self.frame(over: anchor, on: screenFrame), display: false)
        panel.orderFrontRegardless()

        isShowing = true
        // Not `reset()`, which rebuilds the whole artboard from the file to rewind one
        // animation. `play` already rewinds: it installs a fresh animation instance and
        // winds back one that has run to its end. So a second screenshot arriving while
        // the first hand is still up restarts it rather than stacking.
        viewModel.play(animationName: Self.animationName, loop: .oneShot, direction: .forwards)

        watchdog?.invalidate()
        let watchdog = Timer(timeInterval: Self.watchdogTimeout, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish() }
        }
        // `.common` so the hand still leaves if a menu is being tracked when it ends.
        RunLoop.main.add(watchdog, forMode: .common)
        self.watchdog = watchdog
    }

    private func finish() {
        guard isShowing else { return }
        isShowing = false

        watchdog?.invalidate()
        watchdog = nil
        // `pause`, never `stop`. `stop` announces that it stopped, which lands straight
        // back here, and it rebuilds the artboard on the way — the two together walked the
        // rig over and over until the stack ran out, killing the app every time the hand
        // finished. A one-shot has already halted itself by the time this runs; the pause
        // is only here for the watchdog's sake, when it has not.
        viewModel?.pause()
        panel?.orderOut(nil)
    }

    private static func pointerAnchor() -> CGRect {
        CGRect(origin: NSEvent.mouseLocation, size: .zero)
    }

    /// An empty rect intersects nothing, so a pointer anchor has to be matched by
    /// containment instead.
    private static func screenFrame(for rect: CGRect) -> CGRect? {
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let screen = NSScreen.screens.first { $0.frame.intersects(rect) }
            ?? NSScreen.screens.first { $0.frame.contains(centre) }
            ?? NSScreen.main
        return screen?.frame
    }

    // MARK: - Loading

    private func ensureLoaded() -> HandViewModel? {
        if let viewModel { return viewModel }
        guard !hasAttemptedLoad else { return nil }
        hasAttemptedLoad = true

        // `L10n.bundle` rather than `Bundle.module` for the reason spelled out where it is
        // defined: the generated accessor traps when the resource bundle is missing, and a
        // packaging slip must not be a crash on launch. This one answers nil instead.
        //
        // `loadCdn: false` because the hand image is embedded in the file and the app has
        // no network entitlement: anything that reached for the CDN would only ever hang.
        guard let bundle = L10n.bundle,
              let model = try? RiveModel(
                  fileName: Self.fileName,
                  extension: ".riv",
                  in: bundle,
                  loadCdn: false
              )
        else {
            return nil
        }

        let viewModel = HandViewModel(
            model,
            animationName: Self.animationName,
            fit: .contain,
            alignment: .center,
            autoPlay: false
        )
        viewModel.onStopped = { [weak self] in
            MainActor.assumeIsolated { self?.finish() }
        }

        // Our own view rather than `createRiveView()`, because scaling playback means
        // overriding how the runtime is told time has passed.
        let riveView = HandRiveView()
        riveView.speed = Self.playbackSpeed
        viewModel.setView(riveView)
        // Metal clears to opaque black unless told otherwise, which would put a rectangle
        // of night over the screenshot the hand is meant to be picking up.
        riveView.wantsLayer = true
        riveView.layer?.isOpaque = false
        riveView.layer?.backgroundColor = NSColor.clear.cgColor
        // `RiveView` is an `MTKView` underneath, which is where the clear colour lives.
        riveView.clearColor = MTLClearColorMake(0, 0, 0, 0)

        let panel = makePanel()
        riveView.frame = panel.contentView?.bounds ?? .zero
        riveView.autoresizingMask = [.width, .height]
        panel.contentView?.addSubview(riveView)

        self.viewModel = viewModel
        self.panel = panel
        return viewModel
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // A shadow would trace the panel's rectangle rather than the hand inside it.
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        // Purely decorative: it must never swallow a click.
        panel.ignoresMouseEvents = true

        let content = NSView(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = content
        return panel
    }
}

/// Runs the animation off a stretched clock. `advance` is where the runtime is told how
/// much time has passed, so scaling its argument speeds the hand up without touching a
/// single keyframe.
private final class HandRiveView: RiveView {
    var speed: Double = 1

    override func advance(delta: Double) {
        super.advance(delta: delta * speed)
    }
}

/// Exists only to hear the one-shot end. `RiveViewModel` is its own player delegate, so
/// overriding is the way in — assigning our own delegate would cut the view model out of
/// its own callbacks.
private final class HandViewModel: RiveViewModel {
    var onStopped: (() -> Void)?

    override func player(stoppedWithModel riveModel: RiveModel?) {
        super.player(stoppedWithModel: riveModel)
        onStopped?()
    }
}
