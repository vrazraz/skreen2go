import AppKit
import Foundation

/// The 3-2-1 shown over the chosen area before the first frame is captured.
///
/// Sits at `.screenSaver` level for the same reason the selection overlay does: anything
/// lower is covered by full-screen windows, which is exactly what people record. It is
/// dismissed before the stream starts, and our own windows are excluded from the stream
/// regardless, so it never appears in the video.
@MainActor
final class RecordingCountdownPanel: RecordingCountdownPresenting {
    private static let side: CGFloat = 168

    private var panel: NSPanel?
    private var numberLabel: NSTextField?

    func show(seconds: Int, over area: CGRect) {
        let panel = ensurePanel()
        update(seconds: seconds)
        position(panel, over: area)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    func update(seconds: Int) {
        numberLabel?.stringValue = String(seconds)
    }

    func dismiss() {
        panel?.orderOut(nil)
    }

    private func position(_ panel: NSPanel, over area: CGRect) {
        // Centred on the area itself when it is big enough to hold the panel, and on the
        // owning display otherwise, so a small selection is not buried under the numeral.
        let anchor: CGRect
        if area.width >= Self.side * 1.5, area.height >= Self.side * 1.5 {
            anchor = area
        } else {
            anchor = ScreenGeometry.screen(bestMatchingCocoaRect: area)?.frame ?? area
        }
        panel.setFrameOrigin(CGPoint(
            x: anchor.midX - Self.side / 2,
            y: anchor.midY - Self.side / 2
        ))
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: Self.side, height: Self.side),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        // The user is about to interact with whatever they are recording; the countdown
        // must not swallow a click meant for it.
        panel.ignoresMouseEvents = true

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 24
        background.layer?.masksToBounds = true

        let number = NSTextField(labelWithString: "")
        number.font = .monospacedDigitSystemFont(ofSize: 72, weight: .semibold)
        number.textColor = .white
        number.alignment = .center

        let caption = NSTextField(
            labelWithString: "recording.countdown.caption".localized("Recording starts in…")
        )
        caption.font = .systemFont(ofSize: 12, weight: .regular)
        caption.textColor = NSColor.white.withAlphaComponent(0.75)
        caption.alignment = .center
        caption.lineBreakMode = .byTruncatingTail

        let stack = NSStackView(views: [number, caption])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: background.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: background.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: background.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: background.trailingAnchor, constant: -12)
        ])

        panel.contentView = background
        self.panel = panel
        numberLabel = number
        return panel
    }
}
