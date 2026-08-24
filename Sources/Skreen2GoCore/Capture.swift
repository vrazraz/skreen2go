import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

enum SelectionAction: Equatable {
    /// Hand off to the full editor (blur, visual cursor, delete, clear).
    case annotate
    case settings
    case copy
    case save
    case saveAs
    /// Record the selection as video instead of capturing a still.
    case record
    case cancel
}

/// Which job the overlay was opened for. The selection gesture is identical either way;
/// what differs is the panel, because annotating a video is not a thing you can do and
/// choosing audio sources for a still is not either.
enum CaptureMode: Equatable {
    case screenshot
    case recording
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

/// Colour swatches shown right under the panel's colour button.
///
/// Not `NSColorWell`/`NSColorPanel`: the system picker opens a window at an ordinary
/// level, which the `.screenSaver`-level overlay covers — it was there, just unreachable
/// behind the dimming. Living as a subview of the overlay keeps it visible and clickable.
final class ColorPaletteView: NSView {
    static let colors: [NSColor] = [
        .systemRed, .systemOrange, .systemYellow, .systemGreen, .systemTeal,
        .systemBlue, .systemPurple, .systemPink, .white, .black
    ]

    private static let swatchSide: CGFloat = 22
    private static let spacing: CGFloat = 6
    private static let padding: CGFloat = 8
    private static let columns = 5

    private let onPick: (NSColor) -> Void
    private var swatches: [(button: NSButton, color: NSColor)] = []

    init(selected: NSColor, onPick: @escaping (NSColor) -> Void) {
        self.onPick = onPick
        super.init(frame: .zero)

        appearance = NSAppearance(named: .aqua)
        PanelStyle.apply(to: self, cornerRadius: 8)

        let rows = stride(from: 0, to: Self.colors.count, by: Self.columns).map { start in
            let slice = Self.colors[start..<min(start + Self.columns, Self.colors.count)]
            let row = NSStackView(views: slice.map { swatch($0) })
            row.orientation = .horizontal
            row.spacing = Self.spacing
            return row
        }

        let grid = NSStackView(views: rows)
        grid.orientation = .vertical
        grid.spacing = Self.spacing
        grid.translatesAutoresizingMaskIntoConstraints = false
        addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.padding),
            grid.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.padding),
            grid.topAnchor.constraint(equalTo: topAnchor, constant: Self.padding),
            grid.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.padding)
        ])

        setSelected(selected)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var preferredSize: CGSize {
        let rows = CGFloat((Self.colors.count + Self.columns - 1) / Self.columns)
        let columns = CGFloat(min(Self.columns, Self.colors.count))
        return CGSize(
            width: columns * Self.swatchSide + (columns - 1) * Self.spacing + Self.padding * 2,
            height: rows * Self.swatchSide + (rows - 1) * Self.spacing + Self.padding * 2
        )
    }

    func setSelected(_ color: NSColor) {
        for entry in swatches {
            let chosen = ColorPaletteView.sameColor(entry.color, color)
            entry.button.layer?.borderWidth = chosen ? 3 : 1
            entry.button.layer?.borderColor = chosen
                ? NSColor.controlAccentColor.cgColor
                : NSColor.black.withAlphaComponent(0.25).cgColor
        }
    }

    /// True when a point in this view's superview coordinates lands on a swatch.
    func isOverSwatch(_ pointInSuperview: CGPoint) -> Bool {
        hitTest(pointInSuperview) is NSButton
    }

    static func sameColor(_ lhs: NSColor, _ rhs: NSColor) -> Bool {
        guard let a = lhs.usingColorSpace(.deviceRGB), let b = rhs.usingColorSpace(.deviceRGB) else {
            return false
        }
        let tolerance: CGFloat = 0.01
        return abs(a.redComponent - b.redComponent) < tolerance
            && abs(a.greenComponent - b.greenComponent) < tolerance
            && abs(a.blueComponent - b.blueComponent) < tolerance
    }

    private func swatch(_ color: NSColor) -> NSButton {
        let button = NSButton(title: "", target: self, action: #selector(pick(_:)))
        button.isBordered = false
        button.setButtonType(.momentaryChange)
        button.wantsLayer = true
        button.layer?.backgroundColor = color.cgColor
        button.layer?.cornerRadius = 4
        button.setAccessibilityTitle(color.accessibilityName)
        button.widthAnchor.constraint(equalToConstant: Self.swatchSide).isActive = true
        button.heightAnchor.constraint(equalToConstant: Self.swatchSide).isActive = true
        swatches.append((button, color))
        return button
    }

    @objc private func pick(_ sender: NSButton) {
        guard let color = swatches.first(where: { $0.button === sender })?.color else { return }
        setSelected(color)
        onPick(color)
    }
}

/// The panel that appears as soon as a selection exists (PRD §5). Icon-only: drawing
/// tools on the left, then colour, undo/redo, and the terminal actions.
/// The look shared by the floating panels over the dimmed screen.
enum PanelStyle {
    /// Translucent rather than solid, so the panel reads as floating above the shot
    /// rather than as part of it. No border: the shadow already separates it from the
    /// backdrop, and an outline on a translucent fill only muddies the edge.
    static let fill = NSColor(white: 0.97, alpha: 0.72)
    /// Nearly black, not the system default grey, so glyphs hold up against a fill you
    /// can see through.
    static let icon = NSColor(white: 0.12, alpha: 1)
    static let cornerRadius: CGFloat = 10

    static func apply(to view: NSView, cornerRadius: CGFloat = PanelStyle.cornerRadius) {
        view.wantsLayer = true
        view.layer?.backgroundColor = fill.cgColor
        view.layer?.cornerRadius = cornerRadius
        view.layer?.borderWidth = 0
        view.layer?.shadowColor = NSColor.black.cgColor
        view.layer?.shadowOpacity = 0.4
        view.layer?.shadowOffset = CGSize(width: 0, height: -2)
        view.layer?.shadowRadius = 6
    }
}

/// A button that draws a circle of a stated size, whatever frame AppKit gives it.
///
/// Rounding the button's own layer does not work here: `NSButton` sizes itself from its
/// image and stretches past an explicit height constraint — a 40pt-wide button comes out
/// 48 to 51pt tall depending on the glyph — and a corner radius of half the width on a
/// frame that is not square is a superellipse, not a circle. The shape is therefore drawn
/// in a sublayer that is always square and always centred.
private final class CircularButton: NSButton {
    var side: CGFloat = 40 { didSet { needsLayout = true } }
    var fill: NSColor = NSColor(white: 0.88, alpha: 1) { didSet { needsLayout = true } }

    private let shape = CALayer()

    override var intrinsicContentSize: NSSize { NSSize(width: side, height: side) }

    /// The circle as actually drawn.
    var circle: CGRect { shape.frame }
    var circleCornerRadius: CGFloat { shape.cornerRadius }

    override func layout() {
        super.layout()
        wantsLayer = true
        if shape.superlayer == nil {
            layer?.insertSublayer(shape, at: 0)
        }
        shape.frame = CGRect(
            x: ((bounds.width - side) / 2).rounded(),
            y: ((bounds.height - side) / 2).rounded(),
            width: side,
            height: side
        )
        shape.cornerRadius = side / 2
        shape.cornerCurve = .circular
        shape.backgroundColor = fill.cgColor
        shape.borderWidth = 1
        shape.borderColor = NSColor.black.withAlphaComponent(0.18).cgColor
    }
}

final class SelectionActionBar: NSView {
    private let onTool: (OverlayTool) -> Void
    private let onColorRequest: () -> Void
    private let onUndo: () -> Void
    private let onRedo: () -> Void
    private let onAction: (SelectionAction) -> Void

    private let colorButton = NSButton(title: "", target: nil, action: nil)
    private var toolButtons: [(button: NSButton, tool: OverlayTool)] = []
    /// Audio sources for the next recording. Kept apart from `toolButtons`, whose states
    /// are driven by the active annotation tool.
    private var systemAudioButton: NSButton?
    private var microphoneButton: NSButton?
    private let settings: SettingsStore
    private let mode: CaptureMode
    /// Hint text per control. Native tooltips are useless here: they open in a window at
    /// an ordinary level, which the `.screenSaver`-level overlay covers, so the overlay
    /// draws its own hints instead.
    private var hintTitles: [ObjectIdentifier: String] = [:]
    /// Which glyph each audio toggle wears in either state.
    private var audioSymbols: [ObjectIdentifier: (on: String, off: String)] = [:]
    private var primaryButtons: [NSButton] = []

    private static let primarySide: CGFloat = 40
    /// Extra air around the divider before the primary buttons, so the group that
    /// finishes the job stands apart from the tools that lead up to it.
    private static let primaryGap: CGFloat = 12

    init(
        color: NSColor,
        settings: SettingsStore,
        mode: CaptureMode,
        onTool: @escaping (OverlayTool) -> Void,
        onColorRequest: @escaping () -> Void,
        onUndo: @escaping () -> Void,
        onRedo: @escaping () -> Void,
        onAction: @escaping (SelectionAction) -> Void
    ) {
        self.settings = settings
        self.mode = mode
        self.onTool = onTool
        self.onColorRequest = onColorRequest
        self.onUndo = onUndo
        self.onRedo = onRedo
        self.onAction = onAction
        super.init(frame: .zero)

        // Light on purpose: the overlay dims everything around the frame, so a dark bar
        // would sink into the backdrop. A solid fill rather than a blur — translucent
        // materials sample the (dark) desktop behind the window and came out mid-grey,
        // leaving the glyphs barely legible.
        appearance = NSAppearance(named: .aqua)
        PanelStyle.apply(to: self)

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

        switch mode {
        case .screenshot: buildScreenshotControls(in: stack, color: color)
        case .recording: buildRecordingControls(in: stack)
        }
    }

    private func buildScreenshotControls(in stack: NSStackView, color: NSColor) {
        // Leaving is on the left, away from the buttons that commit to something, so the
        // pointer never passes over Cancel on its way to Save.
        stack.addArrangedSubview(button("xmark", "tool.cancel".localized("Cancel (Esc)"), #selector(cancel)))
        stack.addArrangedSubview(separator())

        stack.addArrangedSubview(toolButton("arrow.up.right", "tool.arrow".localized("Arrow"), tool: .arrow, #selector(arrowTool)))
        stack.addArrangedSubview(toolButton("rectangle", "tool.rectangle".localized("Rectangle"), tool: .rectangle, #selector(rectangleTool)))
        stack.addArrangedSubview(toolButton("textformat", "tool.text".localized("Text"), tool: .text, #selector(textTool)))

        colorButton.target = self
        colorButton.action = #selector(colorTapped)
        colorButton.isBordered = false
        colorButton.setButtonType(.momentaryChange)
        colorButton.wantsLayer = true
        colorButton.layer?.cornerRadius = 4
        colorButton.layer?.borderWidth = 1
        colorButton.layer?.borderColor = NSColor.black.withAlphaComponent(0.35).cgColor
        colorButton.setAccessibilityTitle("tool.color".localized("Color"))
        hintTitles[ObjectIdentifier(colorButton)] = "tool.color".localized("Color")
        colorButton.widthAnchor.constraint(equalToConstant: 34).isActive = true
        colorButton.heightAnchor.constraint(equalToConstant: 22).isActive = true
        stack.addArrangedSubview(colorButton)
        setColor(color)

        stack.addArrangedSubview(button("arrow.uturn.backward", "tool.undo".localized("Undo (⌘Z)"), #selector(undo)))
        stack.addArrangedSubview(button("arrow.uturn.forward", "tool.redo".localized("Redo (⇧⌘Z)"), #selector(redo)))
        stack.addArrangedSubview(button("gearshape", "tool.settings".localized("Settings"), #selector(openSettings)))

        // What a screenshot is actually for, gathered at the far end of the panel and
        // round, so the panel reads as tools first and outcomes last.
        _ = primaryGroupSeparator(in: stack)
        stack.addArrangedSubview(primaryButton(
            "doc.on.doc",
            "tool.copy".localized("Copy"),
            fill: nil,
            #selector(copyShot)
        ))
        stack.addArrangedSubview(primaryButton(
            "square.and.arrow.down",
            "tool.save".localized("Save"),
            fill: nil,
            #selector(save)
        ))
        stack.addArrangedSubview(primaryButton(
            "square.and.arrow.down.on.square",
            "tool.saveAs".localized("Save As…"),
            fill: nil,
            #selector(saveAs)
        ))

        setActiveTool(.none)
    }

    private func buildRecordingControls(in stack: NSStackView) {
        stack.addArrangedSubview(button("xmark", "tool.cancel".localized("Cancel (Esc)"), #selector(cancel)))
        stack.addArrangedSubview(separator())

        stack.addArrangedSubview(button("gearshape", "tool.settings".localized("Settings"), #selector(openSettings)))

        // The audio sources sit right beside the button that uses them, so the choice is
        // made in the same glance as the decision to record. They persist between runs.
        let systemAudio = audioToggle(
            on: "speaker.wave.2",
            off: "speaker.slash",
            "tool.audio.system".localized("System audio"),
            isOn: settings.recordsSystemAudio,
            #selector(toggleSystemAudio)
        )
        systemAudioButton = systemAudio
        stack.addArrangedSubview(systemAudio)

        let microphone = audioToggle(
            on: "mic",
            off: "mic.slash",
            "tool.audio.microphone".localized("Microphone"),
            isOn: settings.recordsMicrophone,
            #selector(toggleMicrophone)
        )
        microphoneButton = microphone
        stack.addArrangedSubview(microphone)

        _ = primaryGroupSeparator(in: stack)
        stack.addArrangedSubview(primaryButton(
            nil,
            "tool.record".localized("Record video"),
            fill: .systemRed,
            #selector(record)
        ))
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
        return hit is NSButton ? hit : nil
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
        colorButton.layer?.backgroundColor = color.cgColor
    }

    /// Where to anchor the palette, in the bar's superview coordinates.
    var colorButtonFrame: CGRect {
        guard let superview else { return colorButton.frame }
        return colorButton.convert(colorButton.bounds, to: superview)
    }

    /// Icon-only: the name lives in the tooltip so the bar stays compact.
    private func button(_ symbol: String, _ title: String, _ action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        let button = NSButton(image: image ?? NSImage(), target: self, action: action)
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.bezelStyle = .texturedRounded
        button.contentTintColor = PanelStyle.icon
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

    /// A source that is off is drawn struck through, so the state reads at a glance
    /// instead of having to be inferred from a pressed-in look.
    private func audioToggle(
        on onSymbol: String,
        off offSymbol: String,
        _ title: String,
        isOn: Bool,
        _ action: Selector
    ) -> NSButton {
        let button = self.button(onSymbol, title, action)
        button.setButtonType(.pushOnPushOff)
        audioSymbols[ObjectIdentifier(button)] = (on: onSymbol, off: offSymbol)
        setAudioToggle(button, isOn: isOn)
        return button
    }

    private func setAudioToggle(_ button: NSButton?, isOn: Bool) {
        guard let button, let symbols = audioSymbols[ObjectIdentifier(button)] else { return }
        button.state = isOn ? .on : .off
        let symbol = isOn ? symbols.on : symbols.off
        button.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: button.accessibilityTitle()
        )
    }

    /// The one or two things this panel exists to do: big, round, and impossible to miss
    /// among the icon buttons.
    private func primaryButton(
        _ symbol: String?,
        _ title: String,
        fill: NSColor?,
        _ action: Selector
    ) -> NSButton {
        let button = CircularButton(title: "", target: self, action: action)
        button.side = Self.primarySide
        button.fill = fill ?? NSColor(white: 0.88, alpha: 1)
        button.isBordered = false
        button.setButtonType(.momentaryChange)

        if let symbol {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
            button.contentTintColor = fill == nil ? PanelStyle.icon : .white
        }

        button.setAccessibilityTitle(title)
        hintTitles[ObjectIdentifier(button)] = title
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.widthAnchor.constraint(equalToConstant: Self.primarySide).isActive = true
        button.heightAnchor.constraint(equalToConstant: Self.primarySide).isActive = true
        primaryButtons.append(button)
        return button
    }

    /// A divider with room either side of it.
    private func primaryGroupSeparator(in stack: NSStackView) -> NSView {
        let previous = stack.arrangedSubviews.last
        let line = separator()
        stack.addArrangedSubview(line)
        if let previous { stack.setCustomSpacing(Self.primaryGap, after: previous) }
        stack.setCustomSpacing(Self.primaryGap, after: line)
        return line
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
    @objc private func colorTapped() { onColorRequest() }
    @objc private func undo() { onUndo() }
    @objc private func redo() { onRedo() }
    @objc private func openSettings() { onAction(.settings) }
    @objc private func record() { onAction(.record) }

    @objc private func toggleSystemAudio(_ sender: NSButton) {
        settings.recordsSystemAudio = sender.state == .on
        setAudioToggle(sender, isOn: sender.state == .on)
    }

    @objc private func toggleMicrophone(_ sender: NSButton) {
        settings.recordsMicrophone = sender.state == .on
        setAudioToggle(sender, isOn: sender.state == .on)
    }

    /// Settings can change the toggles behind the bar's back, so they are re-read whenever
    /// the settings window closes.
    func refreshAudioToggles() {
        setAudioToggle(systemAudioButton, isOn: settings.recordsSystemAudio)
        setAudioToggle(microphoneButton, isOn: settings.recordsMicrophone)
    }

    @objc private func copyShot() { onAction(.copy) }
    @objc private func save() { onAction(.save) }
    @objc private func saveAs() { onAction(.saveAs) }
    @objc private func cancel() { onAction(.cancel) }
}

extension SelectionActionBar {
    var testPrimaryButtons: [NSButton] { primaryButtons }
    /// The circles as drawn, which is what the shape has to be judged by: the buttons'
    /// own frames are whatever AppKit decides.
    var testPrimaryCircles: [(rect: CGRect, cornerRadius: CGFloat)] {
        primaryButtons.compactMap { $0 as? CircularButton }.map { ($0.circle, $0.circleCornerRadius) }
    }
    static var testPrimarySide: CGFloat { primarySide }
}

@MainActor
final class CaptureOverlayWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class CaptureOverlayView: NSView {
    var onCancel: (() -> Void)?
    /// Fired by the floating action bar.
    var onSelectionAction: ((SelectionAction, SelectionCapture) -> Void)?

    let settings: SettingsStore
    let mode: CaptureMode

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
    private var lastHoveredWindowPoint: CGPoint?
    private var lastWindowLookupAt: TimeInterval = -.infinity
    private var selectedWindow: WindowInfo?
    private var clearedSelectionOnMouseDown = false
    private var tracking: NSTrackingArea?
    private var actionBar: SelectionActionBar?
    private var colorPalette: ColorPaletteView?
    private var activeHint: (text: String, anchor: CGRect)?
    private var hintWorkItem: DispatchWorkItem?

    private static let hintDelay: TimeInterval = 0.25
    private static let windowLookupInterval: TimeInterval = 1.0 / 30.0
    private static let windowLookupDistance: CGFloat = 2

    // Annotations authored straight on the overlay, in overlay coordinates.
    private var tool: OverlayTool = .none
    private let annotationSession = AnnotationSession()
    private var annotations: [Annotation] {
        get { annotationSession.annotations }
        set { annotationSession.annotations = newValue }
    }
    private var draftAnnotation: Annotation?
    private var drawAnchor: CGPoint?
    private var currentColor: NSColor
    private var textEditor: NSTextField?
    private var textOrigin: CGPoint = .zero

    private static let handleSize: CGFloat = 8
    private static let handleHitSlop: CGFloat = 10
    private static let minimumSelectionSide: CGFloat = 8
    private static let dragThreshold: CGFloat = 3

    init(frame: CGRect, settings: SettingsStore, mode: CaptureMode = .screenshot) {
        self.mode = mode
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
            hideColorPalette()
            clearHint()
            return
        }

        let bar: SelectionActionBar
        if let existing = actionBar {
            bar = existing
        } else {
            let created = SelectionActionBar(
                color: currentColor,
                settings: settings,
                mode: mode,
                onTool: { [weak self] tool in self?.setTool(tool) },
                onColorRequest: { [weak self] in self?.toggleColorPalette() },
                onUndo: { [weak self] in self?.undo() },
                onRedo: { [weak self] in self?.redo() },
                onAction: { [weak self] action in self?.deliver(action) }
            )
            addSubview(created)
            actionBar = created
            bar = created
        }

        bar.isHidden = false
        let within = ScreenGeometry.visibleCocoaFrame(for: globalRect(for: selection))
            .map(localRect(for:)) ?? bounds
        bar.frame = FloatingBarPlacement.frame(
            barSize: bar.preferredSize,
            around: selection,
            within: within
        )
    }

    func adoptDefaultColor() {
        currentColor = settings.defaultColor
        actionBar?.setColor(currentColor)
        colorPalette?.setSelected(currentColor)
    }

    /// Resetting settings from the gear button turns both audio sources off, which would
    /// otherwise leave the panel showing them as still on.
    /// The live hint names the action Enter performs, and that differs by mode.
    private var liveHint: String {
        switch mode {
        case .screenshot:
            return "overlay.hint.live".localized(
                "Tool — draw inside   •   Edges — resize   •   Enter — editor   •   Esc — cancel"
            )
        case .recording:
            return "overlay.hint.recording".localized(
                "Edges — resize   •   Enter — start recording   •   Esc — cancel"
            )
        }
    }

    func adoptAudioSettings() {
        actionBar?.refreshAudioToggles()
    }

    private func setTool(_ tool: OverlayTool) {
        commitTextIfNeeded()
        self.tool = tool
        needsDisplay = true
    }

    private func undo() {
        commitTextIfNeeded()
        annotationSession.undo()
        needsDisplay = true
    }

    private func redo() {
        commitTextIfNeeded()
        annotationSession.redo()
        needsDisplay = true
    }

    private func pushUndo() {
        annotationSession.recordUndo()
    }

    private func deliver(_ action: SelectionAction) {
        _ = performActionIfPossible(action)
    }

    @discardableResult
    func performActionIfPossible(_ action: SelectionAction) -> Bool {
        commitTextIfNeeded()
        guard let selection,
              selection.width >= Self.minimumSelectionSide,
              selection.height >= Self.minimumSelectionSide else { return false }
        onSelectionAction?(action, capturePayload(for: selection))
        return true
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

    private func toggleColorPalette() {
        if colorPalette != nil {
            hideColorPalette()
        } else {
            showColorPalette()
        }
    }

    private func showColorPalette() {
        guard let bar = actionBar, !bar.isHidden else { return }

        let palette = ColorPaletteView(selected: currentColor) { [weak self] color in
            guard let self else { return }
            self.currentColor = color
            self.actionBar?.setColor(color)
            self.hideColorPalette()
        }
        addSubview(palette)
        colorPalette = palette

        let size = palette.preferredSize
        let anchor = bar.colorButtonFrame
        // Lined up with the colour button, but clearing the whole bar: the button is
        // centred in a bar tall enough for the primary buttons, so measuring from the
        // button alone would open the palette on top of its own panel.
        let barFrame = bar.frame
        let gap: CGFloat = 6
        var origin = CGPoint(x: anchor.midX - size.width / 2, y: barFrame.minY - gap - size.height)
        // Under the bar by default, above it when there is no room below.
        if origin.y < bounds.minY + 2 {
            origin.y = barFrame.maxY + gap
        }
        origin.x = min(max(origin.x, bounds.minX + 2), max(bounds.minX + 2, bounds.maxX - size.width - 2))
        palette.frame = CGRect(origin: origin, size: size)
        // Lay out now: the swatches must be hit-testable before the first click, not only
        // after the run loop gets around to it.
        palette.layoutSubtreeIfNeeded()
    }

    @discardableResult
    func hideColorPalette() -> Bool {
        guard let colorPalette else { return false }
        colorPalette.removeFromSuperview()
        self.colorPalette = nil
        needsDisplay = true
        return true
    }

    private func globalRect(for localRect: CGRect) -> CGRect {
        localRect.offsetBy(dx: window?.frame.minX ?? 0, dy: window?.frame.minY ?? 0)
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Copying is a screenshot action; in recording mode the shortcut belongs to
        // whatever the user was working in.
        if mode == .screenshot, AppKeyboardShortcut.isCommandC(keyCode: event.keyCode, modifiers: flags) {
            guard performActionIfPossible(.copy) else {
                super.keyDown(with: event)
                return
            }
            return
        }
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

    private func updateHoveredWindow(at localPoint: CGPoint, force: Bool = false) {
        let globalPoint = globalPoint(for: localPoint)
        let now = ProcessInfo.processInfo.systemUptime
        if !force,
           now - lastWindowLookupAt < Self.windowLookupInterval,
           let lastPoint = lastHoveredWindowPoint,
           hypot(lastPoint.x - globalPoint.x, lastPoint.y - globalPoint.y) < Self.windowLookupDistance {
            return
        }

        lastHoveredWindowPoint = globalPoint
        lastWindowLookupAt = now
        let candidate = ScreenGeometry.windowAtCocoaPoint(globalPoint)
        guard candidate?.id != hoveredWindow?.id else { return }
        hoveredWindow = candidate
        needsDisplay = true
    }

    /// The overlay's union frame may cover non-existent space between offset
    /// displays. Do not claim those pixels as an interactive screen surface.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let global = globalPoint(for: point)
        let isOnPhysicalDisplay = NSScreen.screens.contains { screen in
            screen.frame.insetBy(dx: -0.5, dy: -0.5).contains(global)
        }
        guard isOnPhysicalDisplay else { return nil }
        return super.hitTest(point)
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
        if let palette = colorPalette, palette.frame.contains(point) {
            return palette.isOverSwatch(point) ? .panelControl : .panelBackground
        }
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

        // Clicks on the panel or the palette belong to them, not to a new selection.
        if let bar = actionBar, !bar.isHidden, bar.frame.contains(point) { return }
        if let palette = colorPalette {
            if palette.frame.contains(point) { return }
            // Anywhere else dismisses it, and that click does nothing else.
            hideColorPalette()
            return
        }

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
        updateHoveredWindow(at: point, force: true)
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
    /// Enter runs whatever this overlay was opened to do: hand a still to the editor, or
    /// start recording.
    @discardableResult
    func confirmSelectionIfPossible() -> Bool {
        switch mode {
        case .screenshot: return performActionIfPossible(.annotate)
        case .recording: return performActionIfPossible(.record)
        }
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
            ? liveHint
            : "overlay.hint.idle".localized("Click — window   •   Drag — region   •   Esc — cancel")
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
    func testDeliver(_ action: SelectionAction) { deliver(action) }
    var testActionBarIsVisible: Bool { actionBar.map { !$0.isHidden } ?? false }
    var testActionBarFrame: CGRect? { actionBar.flatMap { $0.isHidden ? nil : $0.frame } }
    var testPrimaryButtons: [NSButton] { actionBar?.testPrimaryButtons ?? [] }
    var testPrimaryCircles: [(rect: CGRect, cornerRadius: CGFloat)] {
        actionBar?.testPrimaryCircles ?? []
    }
    var testTool: OverlayTool { tool }
    var testActiveHint: String? { activeHint?.text }
    var testColorPaletteFrame: CGRect? { colorPalette?.frame }
    var testCurrentColor: NSColor { currentColor }
    func testToggleColorPalette() { toggleColorPalette() }
    func testPickPaletteColor(_ color: NSColor) {
        currentColor = color
        actionBar?.setColor(color)
        hideColorPalette()
    }
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
    var testUndoDepth: Int { annotationSession.undoDepth }
    func testSetTool(_ tool: OverlayTool) { setTool(tool) }
    func testClampToSelection(_ point: CGPoint) -> CGPoint { clampToSelection(point) }
    func testCapturePayload() -> SelectionCapture? {
        selection.map { capturePayload(for: $0) }
    }
    func testPerformAction(_ action: SelectionAction) -> Bool { performActionIfPossible(action) }
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
    private let capture: any ScreenshotCapturing
    private let settings: SettingsStore
    private var mode: CaptureMode = .screenshot
    private var overlayWindow: CaptureOverlayWindow?
    private var overlayView: CaptureOverlayView?
    private var escapeMonitor: Any?
    private var isCapturing = false
    private var isRequestingAccess = false
    private(set) var isPresentingSettings = false
    private var captureTask: Task<Void, Never>?
    /// Bumped whenever a capture session is abandoned. Results carrying an old generation
    /// are dropped, so a slow capture can never open an editor over a newer one.
    private var captureGeneration = 0

    var onImageCaptured: ((NSImage, CGRect, [Annotation]) -> Void)?
    var onError: ((String) -> Void)?
    /// Shows the settings window. Owned by the app delegate, which keeps a single
    /// instance; the flag it is passed lifts the window above the overlay.
    var onShowSettings: (() -> Void)?
    /// Hands the selection to the recording session, which outlives this controller's
    /// overlay.
    var onStartRecording: ((RecordingRequest) -> Void)?

    init(settings: SettingsStore = .shared, capture: (any ScreenshotCapturing)? = nil) {
        self.settings = settings
        self.capture = capture ?? ScreenshotCapture()
    }

    func start(mode: CaptureMode = .screenshot) {
        self.mode = mode
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

        let view = CaptureOverlayView(
            frame: CGRect(origin: .zero, size: unionFrame.size),
            settings: settings,
            mode: mode
        )
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
            guard let self, self.isCapturing, !self.isPresentingSettings else { return event }
            // Escape closes the colour palette first rather than aborting the capture.
            if event.keyCode == 53, self.overlayView?.hideColorPalette() == true {
                return nil
            }
            // While the inline text field is open it owns Return and Escape.
            if self.overlayView?.isEditingText == true {
                guard event.keyCode == 53 else { return event }
                self.overlayView?.cancelTextEditing()
                return nil
            }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if self.mode == .screenshot,
               AppKeyboardShortcut.isCommandC(keyCode: event.keyCode, modifiers: flags) {
                guard self.overlayView?.performActionIfPossible(.copy) == true else { return event }
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
        Task.detached { [weak self] in
            let granted = CGRequestScreenCaptureAccess()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isRequestingAccess = false
                if granted {
                    self.start()
                } else {
                    self.onError?(CaptureError.permissionDenied.errorDescription ?? "")
                }
            }
        }
    }

    private func cancel() {
        abandonCaptureInFlight()
        dismissOverlay()
    }

    private func presentSettings() {
        let colorBefore = settings.defaultColor
        // `NSApp.runModal` pins its window to `.modalPanel` (8) and keeps reasserting it,
        // so raising the settings window above the overlay is not possible. The overlay
        // steps below that level for the duration instead.
        let overlayLevel = overlayWindow?.level
        overlayWindow?.level = .floating

        isPresentingSettings = true
        onShowSettings?()
        isPresentingSettings = false
        if let overlayLevel { overlayWindow?.level = overlayLevel }

        // Hand focus back to the overlay, which stayed up the whole time.
        if let overlayWindow {
            overlayWindow.makeKeyAndOrderFront(nil)
            if let overlayView { overlayWindow.makeFirstResponder(overlayView) }
        }
        // Only adopt the default colour if it was actually changed in there — otherwise a
        // colour picked from the palette would be silently reset.
        if !ColorPaletteView.sameColor(colorBefore, settings.defaultColor) {
            overlayView?.adoptDefaultColor()
        }
        overlayView?.adoptAudioSettings()
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
        switch action {
        case .cancel:
            cancel()
            return
        case .settings:
            // Settings leaves the frame and its annotations exactly where they are.
            presentSettings()
            return
        case .record:
            // Recording takes over from here and outlives the overlay by minutes, so it
            // deliberately misses `runCapture` and its generation counter — that machinery
            // exists to discard a stale still, and has nothing to say about a session.
            dismissOverlay()
            onStartRecording?(RecordingRequest(
                area: payload.area,
                windowID: payload.window?.id
            ))
            return
        default:
            break
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
                    CaptureFlash.shared.fly(image, from: area)
                    self.copy(image, annotations: annotations)
                case .save:
                    CaptureFlash.shared.fly(image, from: area)
                    self.save(image, annotations: annotations)
                case .saveAs:
                    self.saveAs(image, annotations: annotations)
                case .cancel, .settings, .record:
                    break
                }
            }
        )
    }

    private func copy(_ image: NSImage, annotations: [Annotation]) {
        guard let data = ScreenshotOutput.data(for: image, annotations: annotations, format: .png, settings: settings) else {
            ScreenshotOutput.showError("error.clipboard.prepare".localized("Could not prepare the image for the clipboard."))
            return
        }
        ScreenshotOutput.copy(data, settings: settings)
    }

    private func save(_ image: NSImage, annotations: [Annotation]) {
        let format = settings.outputFormat
        guard let data = ScreenshotOutput.data(for: image, annotations: annotations, format: format, settings: settings) else {
            ScreenshotOutput.showError("error.save.prepare".localized("Could not prepare the image for saving."))
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await ScreenshotOutput.save(data, format: format, settings: settings)
            } catch {
                ScreenshotOutput.showError("error.save.write".localized("Could not save the file: %@", error.localizedDescription))
            }
        }
    }

    private func saveAs(_ image: NSImage, annotations: [Annotation]) {
        let format = settings.outputFormat
        guard let data = ScreenshotOutput.data(for: image, annotations: annotations, format: format, settings: settings) else {
            ScreenshotOutput.showError("error.save.prepare".localized("Could not prepare the image for saving."))
            return
        }
        // The overlay is already gone, so there is no window to host a sheet.
        let panel = ScreenshotOutput.makeSavePanel(format: format)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { @MainActor in
            do {
                try await ScreenshotOutput.write(data, to: url, settings: settings)
            } catch {
                ScreenshotOutput.showError("error.save.write".localized("Could not save the file: %@", error.localizedDescription))
            }
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
    func testPerform(_ action: SelectionAction, payload: SelectionCapture) {
        perform(action, payload: payload)
    }
    var testHasCaptureInFlight: Bool { captureTask != nil }
    func testAbandonCaptureInFlight() { abandonCaptureInFlight() }

    private static func message(for error: Error) -> String {
        (error as? CaptureError)?.errorDescription
            ?? CaptureError.underlying(error).errorDescription
            ?? error.localizedDescription
    }
}
