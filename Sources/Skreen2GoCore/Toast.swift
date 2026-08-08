import AppKit
import Foundation

/// What a finished action reports back to the user.
enum ScreenshotOutcome: Equatable {
    case copied
    case saved(URL)

    var title: String {
        switch self {
        case .copied: return "Успешно скопировано"
        case .saved: return "Успешно сохранено"
        }
    }

    /// Second line of the toast. Saves show the file name; the toast is too narrow for a
    /// full path and the name is what the user needs to find the file.
    var toastDetail: String {
        switch self {
        case .copied: return "Изображение в буфере обмена"
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


/// A brief flash over the region that was just captured. The overlay is already gone by
/// then, so without it a copy or save gives no sign of *what* was taken.
@MainActor
final class CaptureFlash {
    static let shared = CaptureFlash()

    static let duration: TimeInterval = 0.32
    static let peakAlpha: CGFloat = 0.55

    private var panel: NSPanel?

    private init() {}

    func flash(_ rect: CGRect) {
        guard rect.width > 0, rect.height > 0 else { return }
        let panel = ensurePanel()
        panel.setFrame(rect, display: false)
        panel.alphaValue = Self.peakAlpha
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak panel] in
            panel?.orderOut(nil)
        }
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
        panel.backgroundColor = .white
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        // Purely decorative: it must never swallow a click.
        panel.ignoresMouseEvents = true
        self.panel = panel
        return panel
    }
}
