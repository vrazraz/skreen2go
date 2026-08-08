import AppKit
import Foundation

/// What a finished action reports back to the user.
enum ScreenshotOutcome: Equatable {
    case copied
    case saved(URL)

    var title: String {
        switch self {
        case .copied: return "outcome.copied.title".localized("Copied")
        case .saved: return "outcome.saved.title".localized("Saved")
        }
    }

    /// Second line of the toast. Saves show the file name; the toast is too narrow for a
    /// full path and the name is what the user needs to find the file.
    var toastDetail: String {
        switch self {
        case .copied: return "outcome.copied.detail".localized("The image is on the clipboard")
        case .saved(let url): return url.lastPathComponent
        }
    }

    var symbolName: String {
        switch self {
        case .copied: return "doc.on.doc.fill"
        case .saved: return "checkmark.circle.fill"
        }
    }
}

/// The app's one and only confirmation banner. `UNUserNotificationCenter` is not used:
/// authorisation may be missing, Do Not Disturb swallows banners, and macOS suppresses
/// them entirely while the posting app is frontmost — which is exactly the moment a
/// screenshot action finishes.
@MainActor
final class ToastPresenter {
    static let shared = ToastPresenter()

    private static let visibleDuration: TimeInterval = 1.9
    private static let appearDuration: TimeInterval = 0.22
    private static let fadeDuration: TimeInterval = 0.28
    /// How far the panel travels while appearing and leaving.
    private static let slideDistance: CGFloat = 12

    private var panel: NSPanel?
    private var label: NSTextField?
    private var detailLabel: NSTextField?
    private var iconView: NSImageView?
    private var dismissWorkItem: DispatchWorkItem?

    private init() {}

    func show(_ outcome: ScreenshotOutcome) {
        show(title: outcome.title, detail: outcome.toastDetail, symbolName: outcome.symbolName)
    }

    func show(title: String, detail: String, symbolName: String) {
        let panel = ensurePanel()
        label?.stringValue = title
        detailLabel?.stringValue = detail
        detailLabel?.isHidden = detail.isEmpty
        iconView?.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)

        guard let content = panel.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        panel.setContentSize(NSSize(width: max(240, size.width), height: max(52, size.height)))
        position(panel)

        dismissWorkItem?.cancel()

        // Slide down into place while fading in, so a copy or save reads as an event
        // rather than a label that blinks into existence.
        let target = panel.frame
        panel.setFrame(target.offsetBy(dx: 0, dy: Self.slideDistance), display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.appearDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(target, display: true)
        }

        let work = DispatchWorkItem { [weak self] in self?.fadeOut() }
        dismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.visibleDuration, execute: work)
    }

    private func fadeOut() {
        guard let panel else { return }
        let target = panel.frame.offsetBy(dx: 0, dy: Self.slideDistance)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
            panel.animator().setFrame(target, display: true)
        } completionHandler: { [weak panel] in
            panel?.orderOut(nil)
        }
    }

    /// Centred near the top of whichever screen the pointer is on, clear of the menu bar.
    private func position(_ panel: NSPanel) {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return }

        let size = panel.frame.size
        panel.setFrameOrigin(CGPoint(
            x: visible.midX - size.width / 2,
            y: visible.maxY - size.height - 24
        ))
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 280, height: 52),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isReleasedWhenClosed = false
        // NSPanel would otherwise hide itself the moment focus moves on.
        panel.hidesOnDeactivate = false
        // Purely informational: it must never intercept a click.
        panel.ignoresMouseEvents = true

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12

        let icon = NSImageView()
        icon.symbolConfiguration = .init(pointSize: 20, weight: .semibold)
        icon.contentTintColor = .white
        icon.setContentHuggingPriority(.required, for: .horizontal)

        let title = NSTextField(labelWithString: "")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .white

        let detail = NSTextField(labelWithString: "")
        detail.font = .systemFont(ofSize: 11, weight: .regular)
        detail.textColor = NSColor.white.withAlphaComponent(0.75)
        detail.lineBreakMode = .byTruncatingMiddle
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let text = NSStackView(views: [title, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1

        let row = NSStackView(views: [icon, text])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -16),
            row.topAnchor.constraint(equalTo: background.topAnchor, constant: 9),
            row.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -9),
            detail.widthAnchor.constraint(lessThanOrEqualToConstant: 380)
        ])

        panel.contentView = background
        self.panel = panel
        self.label = title
        self.detailLabel = detail
        self.iconView = icon
        return panel
    }
}


/// The "captured" gesture: the shot shrinks and flies along an arc into the menu bar icon.
///
/// The genie warp macOS uses for minimising is a private WindowServer effect
/// (`CGSSetWindowWarp`), so this is the *scale* variant plus a curved path — close in
/// feel, no private API and no per-frame mesh deformation.
///
/// `NSWindow.animator()` only interpolates straight between two frames, so the flight is
/// stepped by a timer instead; that is what buys the curve.
@MainActor
final class CaptureFlash {
    static let shared = CaptureFlash()

    static let duration: TimeInterval = 0.42
    private static let frameRate: TimeInterval = 1.0 / 60.0
    /// Alpha holds until this much of the flight is done, then fades out.
    static let fadeStart: CGFloat = 0.45

    /// Where the flight ends. Supplied by the app delegate, which owns the status item.
    var destinationProvider: (() -> CGRect?)?

    private var panel: NSPanel?
    private var imageView: NSImageView?
    private var timer: Timer?
    private var startFrame: CGRect = .zero
    private var endFrame: CGRect = .zero
    private var startedAt: TimeInterval = 0

    private init() {}

    // MARK: - Geometry (pure, so the path is testable without animating)

    /// Eases the raw time fraction; smoothstep keeps the start and the landing gentle.
    static func eased(_ t: CGFloat) -> CGFloat {
        let clamped = min(max(t, 0), 1)
        return clamped * clamped * (3 - 2 * clamped)
    }

    /// Quadratic Bézier with the control point at (end.x, start.y): the shot sets off
    /// sideways and swoops up into the icon rather than sliding along a straight line.
    static func center(at progress: CGFloat, from start: CGPoint, to end: CGPoint) -> CGPoint {
        let t = eased(progress)
        let inverse = 1 - t
        let control = CGPoint(x: end.x, y: start.y)
        return CGPoint(
            x: inverse * inverse * start.x + 2 * inverse * t * control.x + t * t * end.x,
            y: inverse * inverse * start.y + 2 * inverse * t * control.y + t * t * end.y
        )
    }

    static func frame(at progress: CGFloat, from start: CGRect, to end: CGRect) -> CGRect {
        let t = eased(progress)
        let size = CGSize(
            width: start.width + (end.width - start.width) * t,
            height: start.height + (end.height - start.height) * t
        )
        let middle = center(
            at: progress,
            from: CGPoint(x: start.midX, y: start.midY),
            to: CGPoint(x: end.midX, y: end.midY)
        )
        return CGRect(
            x: middle.x - size.width / 2,
            y: middle.y - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    static func alpha(at progress: CGFloat) -> CGFloat {
        guard progress > fadeStart else { return 1 }
        let remaining = (progress - fadeStart) / (1 - fadeStart)
        return max(0, 1 - eased(remaining))
    }

    /// Falls back to the top-right corner, where menu bar extras live, if the status item
    /// cannot be located.
    static func fallbackDestination(for rect: CGRect) -> CGRect {
        let screen = NSScreen.screens.first { $0.frame.intersects(rect) } ?? NSScreen.main
        guard let frame = screen?.frame else {
            return CGRect(x: rect.midX, y: rect.maxY, width: 32, height: 32)
        }
        return CGRect(x: frame.maxX - 60, y: frame.maxY - 32, width: 32, height: 32)
    }

    // MARK: - Animation

    func fly(_ image: NSImage, from rect: CGRect) {
        guard rect.width > 1, rect.height > 1 else { return }

        let destination = destinationProvider?() ?? Self.fallbackDestination(for: rect)
        let panel = ensurePanel()
        imageView?.image = image

        startFrame = rect
        endFrame = destination
        startedAt = CFAbsoluteTimeGetCurrent()

        panel.setFrame(rect, display: false)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        timer?.invalidate()
        let timer = Timer(timeInterval: Self.frameRate, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.step() }
        }
        // `.common` so the flight keeps running during menu tracking or a modal session.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func step() {
        guard let panel else { return }
        let progress = CGFloat((CFAbsoluteTimeGetCurrent() - startedAt) / Self.duration)

        guard progress < 1 else {
            finish()
            return
        }
        panel.setFrame(Self.frame(at: progress, from: startFrame, to: endFrame), display: true)
        panel.alphaValue = Self.alpha(at: progress)
    }

    private func finish() {
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
        // Do not pin a full-screen bitmap in memory between shots.
        imageView?.image = nil
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        // Purely decorative: it must never swallow a click.
        panel.ignoresMouseEvents = true

        let view = NSImageView()
        view.imageScaling = .scaleAxesIndependently
        view.wantsLayer = true
        view.layer?.masksToBounds = true
        view.layer?.cornerRadius = 4
        view.layer?.borderWidth = 1
        view.layer?.borderColor = NSColor.white.withAlphaComponent(0.6).cgColor
        panel.contentView = view

        self.panel = panel
        self.imageView = view
        return panel
    }
}
