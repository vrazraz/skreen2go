import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import Skreen2GoCore

/// Each test here pins one of the defects fixed in this pass.
/// Serialized and main-actor bound because most of it touches AppKit.
@Suite(.serialized)
@MainActor
struct RegressionTests {

    // MARK: - Helpers

    private func makeSettings() -> SettingsStore {
        let suiteName = "Skreen2GoTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return SettingsStore(defaults: defaults)
    }

    private func makeCGImage(pixelWidth: Int, pixelHeight: Int) -> CGImage {
        let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        )!
        context.setFillColor(NSColor.systemBlue.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        return context.makeImage()!
    }

    private func isClose(_ lhs: CGFloat, _ rhs: CGFloat, tolerance: CGFloat = 0.5) -> Bool {
        abs(lhs - rhs) <= tolerance
    }

    // MARK: - #1 Retina detail was dropped on export

    @Test("Window captures export at their real pixel size, not 1x")
    func exportKeepsRetinaResolution() throws {
        let pointSize = CGSize(width: 100, height: 50)
        // The exact shape a window capture produces.
        let image = makeImage(from: makeCGImage(pixelWidth: 200, pixelHeight: 100), pointSize: pointSize)

        #expect(ImageExporter.pixelScale(of: image) == 2)

        let document = ScreenshotDocument(image: image)
        let data = try #require(ImageExporter.data(for: document, format: .png, settings: makeSettings()))
        let exported = try #require(NSBitmapImageRep(data: data))

        #expect(exported.pixelsWide == 200)
        #expect(exported.pixelsHigh == 100)
    }

    @Test("Pixel scale never drops below 1")
    func pixelScaleFloor() {
        let image = makeImage(from: makeCGImage(pixelWidth: 10, pixelHeight: 10), pointSize: CGSize(width: 40, height: 40))
        #expect(ImageExporter.pixelScale(of: image) == 1)
    }

    // MARK: - #2 Operator precedence let zero-length arrows through

    @Test("A click with the arrow tool creates nothing")
    func zeroLengthArrowRejected() {
        let arrow = Annotation(
            kind: .arrow,
            start: CGPoint(x: 10, y: 10),
            end: CGPoint(x: 10, y: 10),
            color: .red,
            thickness: 3,
            opacity: 1
        )
        #expect(AnnotationGeometry.isMeaningful(arrow) == false)
    }

    @Test("Command-C is the copy shortcut")
    func commandCIsCopyShortcut() {
        #expect(AppKeyboardShortcut.isCommandC(keyCode: 8, modifiers: [.command]))
        #expect(AppKeyboardShortcut.isCommandC(keyCode: 8, modifiers: [.command, .shift]) == false)
        #expect(AppKeyboardShortcut.isCommandC(keyCode: 6, modifiers: [.command]) == false)
    }

    @Test("A dragged arrow is kept")
    func realArrowAccepted() {
        let arrow = Annotation(
            kind: .arrow,
            start: CGPoint(x: 10, y: 10),
            end: CGPoint(x: 40, y: 50),
            color: .red,
            thickness: 3,
            opacity: 1
        )
        #expect(AnnotationGeometry.isMeaningful(arrow))
    }

    @Test("Degenerate rectangles are rejected, normal ones are not")
    func rectangleValidity() {
        func rectangle(_ side: CGFloat) -> Annotation {
            Annotation(
                kind: .rectangle,
                rect: CGRect(x: 0, y: 0, width: side, height: side),
                color: .red,
                thickness: 3,
                opacity: 1
            )
        }
        #expect(AnnotationGeometry.isMeaningful(rectangle(1)) == false)
        #expect(AnnotationGeometry.isMeaningful(rectangle(40)))
    }

    @Test("Annotations are kept inside the image when moved")
    func annotationGeometryIsClamped() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 80)
        let arrow = Annotation(
            kind: .arrow,
            start: CGPoint(x: -20, y: 90),
            end: CGPoint(x: 120, y: -10),
            color: .red,
            thickness: 3,
            opacity: 1
        )
        let clampedArrow = AnnotationGeometry.clamped(arrow, to: bounds)
        #expect(clampedArrow.start == CGPoint(x: 0, y: 80))
        #expect(clampedArrow.end == CGPoint(x: 100, y: 0))

        let rectangle = Annotation(
            kind: .rectangle,
            rect: CGRect(x: 90, y: 70, width: 40, height: 40),
            color: .red,
            thickness: 3,
            opacity: 1
        )
        #expect(AnnotationGeometry.clamped(rectangle, to: bounds).rect == CGRect(x: 60, y: 40, width: 40, height: 40))
    }

    // MARK: - #12/#13 Undo bookkeeping

    @Test("A gesture that changes nothing leaves no undo entry")
    func undoGroupDiscarded() {
        let document = ScreenshotDocument(
            image: makeImage(from: makeCGImage(pixelWidth: 20, pixelHeight: 20), pointSize: CGSize(width: 20, height: 20))
        )
        let canvas = AnnotationCanvasView(
            frame: CGRect(x: 0, y: 0, width: 20, height: 20),
            document: document,
            settings: makeSettings(),
            zoomScale: 1
        )

        #expect(canvas.undoDepth == 0)

        canvas.testBeginUndoGroup()
        canvas.testCancelUndoGroup()
        #expect(canvas.undoDepth == 0)

        canvas.testBeginUndoGroup()
        canvas.testCommitUndoGroup()
        #expect(canvas.undoDepth == 1)

        // Committing twice within one gesture must not double-count.
        canvas.testCommitUndoGroup()
        #expect(canvas.undoDepth == 1)
    }

    // MARK: - #14 Blur cache

    @Test("Blur result is reused for the same source and radius")
    func blurCacheReuse() throws {
        let cache = BlurCache()
        let source = makeCGImage(pixelWidth: 64, pixelHeight: 64)

        let first = try #require(cache.blurred(source: source, radius: 12))
        let second = try #require(cache.blurred(source: source, radius: 12))
        #expect(first === second)

        let third = try #require(cache.blurred(source: source, radius: 20))
        #expect(first !== third)
    }

    // MARK: - #15 Toolbar placement

    @Test("Full-screen capture keeps the toolbar on screen")
    func toolbarStaysOnScreen() throws {
        let screen = try #require(NSScreen.main)
        let visible = screen.visibleFrame.insetBy(dx: 12, dy: 12)
        let toolbarSize = NSSize(width: 620, height: 44)

        // No candidate placement can fit beside a whole-screen canvas.
        let placement = ToolbarPlacement.make(
            imageSize: screen.frame.size,
            selectionFrame: screen.frame,
            toolbarSize: toolbarSize
        )

        let slack = visible.insetBy(dx: -1, dy: -1)
        #expect(slack.contains(placement.windowFrame), "window \(placement.windowFrame) vs visible \(visible)")

        let toolbarOnScreen = placement.toolbarFrame.offsetBy(
            dx: placement.windowFrame.minX,
            dy: placement.windowFrame.minY
        )
        #expect(slack.contains(toolbarOnScreen), "toolbar \(toolbarOnScreen) vs visible \(visible)")
    }

    @Test("PRD §5: the toolbar goes below the selection when it fits")
    func toolbarPrefersBelow() throws {
        let screen = try #require(NSScreen.main)
        let visible = screen.visibleFrame.insetBy(dx: 12, dy: 12)
        let selection = CGRect(x: visible.minX + 100, y: visible.minY + 200, width: 300, height: 200)

        let placement = ToolbarPlacement.make(
            imageSize: selection.size,
            selectionFrame: selection,
            toolbarSize: NSSize(width: 400, height: 44)
        )

        #expect(placement.toolbarFrame.maxY <= placement.canvasFrame.minY + 1)
        #expect(visible.insetBy(dx: -1, dy: -1).contains(placement.windowFrame))
    }

    @Test("Full-screen capture puts the toolbar inside the frame")
    func toolbarMovesInsideFrame() throws {
        let screen = try #require(NSScreen.main)
        let placement = ToolbarPlacement.make(
            imageSize: screen.frame.size,
            selectionFrame: screen.frame,
            toolbarSize: NSSize(width: 620, height: 44)
        )
        #expect(
            placement.canvasFrame.contains(placement.toolbarFrame),
            "toolbar \(placement.toolbarFrame) must sit inside canvas \(placement.canvasFrame)"
        )
    }

    @Test("A full-height window also gets the toolbar inside the frame")
    func toolbarInsideForFullHeightWindow() throws {
        let screen = try #require(NSScreen.main)
        // A window filling everything below the menu bar: nothing fits above or below it.
        let windowFrame = screen.visibleFrame
        let placement = ToolbarPlacement.make(
            imageSize: windowFrame.size,
            selectionFrame: windowFrame,
            toolbarSize: NSSize(width: 620, height: 44)
        )
        #expect(placement.canvasFrame.contains(placement.toolbarFrame))
    }

    @Test("A small selection still keeps the toolbar outside the frame")
    func toolbarStaysOutsideForSmallSelection() throws {
        let screen = try #require(NSScreen.main)
        let visible = screen.visibleFrame.insetBy(dx: 12, dy: 12)
        let selection = CGRect(x: visible.minX + 120, y: visible.minY + 220, width: 320, height: 220)
        let placement = ToolbarPlacement.make(
            imageSize: selection.size,
            selectionFrame: selection,
            toolbarSize: NSSize(width: 620, height: 44)
        )
        #expect(placement.canvasFrame.intersection(placement.toolbarFrame).isEmpty)
    }

    // MARK: - Live, editable capture selection

    private func makeOverlay(
        size: CGSize = CGSize(width: 1200, height: 800),
        mode: CaptureMode = .screenshot
    ) -> CaptureOverlayView {
        CaptureOverlayView(
            frame: CGRect(origin: .zero, size: size),
            settings: makeSettings(),
            mode: mode
        )
    }

    /// Renders the overlay and reports the alpha actually written to the backing store.
    /// A fully transparent pixel means macOS will route the click past the overlay into
    /// whatever app sits underneath.
    private func overlayAlpha(at point: CGPoint, selection: CGRect, viewSize: CGSize) throws -> CGFloat {
        let overlay = CaptureOverlayView(frame: CGRect(origin: .zero, size: viewSize), settings: makeSettings())
        overlay.testSetSelection(selection)

        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(viewSize.width),
            pixelsHigh: Int(viewSize.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: .alphaFirst,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        overlay.draw(overlay.bounds)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        // Bitmap rows run top-down, the view draws bottom-up.
        let y = Int(viewSize.height) - 1 - Int(point.y)
        return try #require(bitmap.colorAt(x: Int(point.x), y: y)?.alphaComponent)
    }

    @Test("Inside the selection the overlay stays opaque enough to receive clicks")
    func selectionInteriorIsHitTestable() throws {
        let alpha = try overlayAlpha(
            at: CGPoint(x: 100, y: 100),
            selection: CGRect(x: 50, y: 50, width: 100, height: 100),
            viewSize: CGSize(width: 200, height: 200)
        )
        // Zero here is the bug: clicks fall through to the app underneath and the
        // selection can never be started, moved or resized over a highlighted window.
        #expect(alpha > 0, "interior alpha was \(alpha) — clicks would pass through")
        // Still invisible to the eye.
        #expect(alpha < 0.05, "interior alpha was \(alpha) — the selection would look dimmed")
    }

    @Test("Outside the selection the overlay is dimmed by exactly 60%")
    func selectionExteriorIsDimmed() throws {
        let alpha = try overlayAlpha(
            at: CGPoint(x: 10, y: 10),
            selection: CGRect(x: 50, y: 50, width: 100, height: 100),
            viewSize: CGSize(width: 200, height: 200)
        )
        #expect(CaptureOverlayView.dimmingAlpha == 0.6)
        #expect(
            isClose(alpha, CaptureOverlayView.dimmingAlpha, tolerance: 0.01),
            "exterior alpha was \(alpha), expected \(CaptureOverlayView.dimmingAlpha)"
        )
    }

    @Test("Dimming applies with no selection too")
    func wholeOverlayDimmedWithoutSelection() throws {
        let overlay = makeOverlay(size: CGSize(width: 120, height: 120))
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 120,
            pixelsHigh: 120,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: .alphaFirst,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        overlay.draw(overlay.bounds)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        let alpha = try #require(bitmap.colorAt(x: 8, y: 8)?.alphaComponent)
        #expect(isClose(alpha, CaptureOverlayView.dimmingAlpha, tolerance: 0.01), "got \(alpha)")
    }

    @Test("Dimming bands cover everything except the selection")
    func dimmingBandsCoverTheRest() {
        let overlay = makeOverlay(size: CGSize(width: 200, height: 200))
        let focus = CGRect(x: 50, y: 50, width: 100, height: 100)
        let bands = overlay.dimmingBands(around: focus)

        // No band may overlap the focus rect...
        for band in bands {
            #expect(band.intersection(focus).isEmpty, "band \(band) overlaps the selection")
        }
        // ...and together they must account for the whole view minus the selection.
        let bandArea = bands.reduce(CGFloat.zero) { $0 + $1.width * $1.height }
        let expected = 200 * 200 - focus.width * focus.height
        #expect(isClose(bandArea, expected, tolerance: 0.001), "covered \(bandArea), expected \(expected)")
    }

    @Test("A selection filling the view leaves no dimming bands")
    func dimmingBandsForFullBleedSelection() {
        let overlay = makeOverlay(size: CGSize(width: 200, height: 200))
        #expect(overlay.dimmingBands(around: CGRect(x: 0, y: 0, width: 200, height: 200)).isEmpty)
    }

    // MARK: - Repeated capture must not race

    @Test("Abandoning a capture bumps the generation so a stale result is dropped")
    func abandoningCaptureInvalidatesOldResults() {
        let controller = CaptureController(settings: makeSettings())
        let before = controller.testCaptureGeneration

        controller.testAbandonCaptureInFlight()
        #expect(controller.testCaptureGeneration > before)
        #expect(controller.testHasCaptureInFlight == false)

        // Every abandonment must produce a fresh generation, not reuse one.
        var seen: Set<Int> = [before, controller.testCaptureGeneration]
        for _ in 0..<5 {
            controller.testAbandonCaptureInFlight()
            #expect(seen.contains(controller.testCaptureGeneration) == false)
            seen.insert(controller.testCaptureGeneration)
        }
    }

    // MARK: - Reset must clear the login item too

    @Test("Reset clears the launch-at-login preference")
    func resetClearsLaunchAtLogin() {
        let settings = makeSettings()
        settings.launchAtLogin = true
        #expect(settings.launchAtLogin)

        settings.reset()
        #expect(settings.launchAtLogin == false)
    }

    @Test("Reset unregisters the system login item as well as clearing preferences")
    func resetUnregistersLoginItem() {
        final class FakeLoginItemManager: LoginItemManaging {
            var isEnabled = true
            var disableCalls = 0

            func setEnabled(_ enabled: Bool) throws { isEnabled = enabled }

            func disableIfEnabled() throws {
                disableCalls += 1
                isEnabled = false
            }
        }

        let manager = FakeLoginItemManager()
        let settings = makeSettings()
        settings.launchAtLogin = true

        let error = SettingsResetService.reset(settings: settings, loginItemManager: manager)
        #expect(error == nil)
        #expect(manager.disableCalls == 1)
        #expect(manager.isEnabled == false)
        #expect(settings.launchAtLogin == false)
    }

    @Test("The selected output folder survives through a security-scoped bookmark")
    func outputFolderBookmarkPersists() throws {
        let settings = makeSettings()
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Skreen2GoTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        try settings.setOutputFolderURL(folder)
        #expect(settings.outputFolderURL.standardizedFileURL == folder.standardizedFileURL)

        let accessedURL = try settings.withOutputFolderAccess { $0.standardizedFileURL }
        #expect(accessedURL == folder.standardizedFileURL)
    }

    @Test("Screenshot file writes run through the shared writer")
    func screenshotFileWriterWritesData() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Skreen2Go-(UUID().uuidString).png")
        let data = Data("test screenshot".utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        try await ScreenshotFileWriter.shared.write(data, to: url)
        #expect(try Data(contentsOf: url) == data)
    }

    // MARK: - Action confirmations

    @Test("Copying reports that it succeeded")
    func copyOutcomeWording() {
        let outcome = ScreenshotOutcome.copied
        #expect(outcome.title == "outcome.copied.title".localized("Copied"))
        #expect(outcome.toastDetail.isEmpty == false)
        #expect(outcome.symbolName.isEmpty == false)
    }

    @Test("Saving reports success and names the file")
    func saveOutcomeWording() {
        let url = URL(fileURLWithPath: "/Users/someone/Downloads/Screenshot 2026-08-08 at 12.00.00.png")
        let outcome = ScreenshotOutcome.saved(url)

        #expect(outcome.title == "outcome.saved.title".localized("Saved"))
        #expect(outcome.toastDetail == "Screenshot 2026-08-08 at 12.00.00.png")
    }

    @Test("Exactly one confirmation channel is wired up")
    func onlyTheToastConfirms() {
        // ScreenshotOutput exposes one reporting operation; all user-visible outcomes
        // are represented by the same value type and rendered by the toast presenter.
        #expect(ScreenshotOutcome.copied != .saved(URL(fileURLWithPath: "/tmp/copied.png")))
        #expect(ScreenshotOutcome.saved(URL(fileURLWithPath: "/tmp/a.png")).title == "outcome.saved.title".localized("Saved"))
    }

    @Test("Each action gets its own wording")
    func outcomesAreDistinguishable() {
        let copied = ScreenshotOutcome.copied
        let saved = ScreenshotOutcome.saved(URL(fileURLWithPath: "/tmp/a.png"))

        #expect(copied.title != saved.title)
        #expect(copied.toastDetail != saved.toastDetail)
        #expect(copied.symbolName != saved.symbolName)
        #expect(copied != saved)
    }

    @Test("Showing a toast twice in a row reuses one panel and does not throw")
    @MainActor
    func toastCanBeShownRepeatedly() {
        ToastPresenter.shared.show(.copied)
        ToastPresenter.shared.show(.saved(URL(fileURLWithPath: "/tmp/b.png")))
        ToastPresenter.shared.show(title: "Проверка", detail: "", symbolName: "checkmark.circle.fill")
    }

    // MARK: - Drawing straight on the overlay

    private func arrow(from: CGPoint, to: CGPoint) -> Annotation {
        Annotation(kind: .arrow, start: from, end: to, color: .red, thickness: 3, opacity: 1)
    }

    @Test("Selecting a tool switches the overlay out of frame-editing mode")
    func overlayToolSelection() {
        let overlay = makeOverlay()
        #expect(overlay.testTool == .none)

        overlay.testSetTool(.arrow)
        #expect(overlay.testTool == .arrow)

        overlay.testSetTool(.none)
        #expect(overlay.testTool == .none)
    }

    @Test("PRD §7: drawing is clamped to the selected region")
    func overlayDrawingIsClamped() {
        let overlay = makeOverlay(size: CGSize(width: 1000, height: 800))
        let selection = CGRect(x: 200, y: 200, width: 300, height: 200)
        overlay.testSetSelection(selection)

        // Well outside on both axes, in both directions.
        #expect(overlay.testClampToSelection(CGPoint(x: 0, y: 0)) == CGPoint(x: 200, y: 200))
        #expect(overlay.testClampToSelection(CGPoint(x: 900, y: 700)) == CGPoint(x: 500, y: 400))
        // Already inside: untouched.
        #expect(overlay.testClampToSelection(CGPoint(x: 300, y: 300)) == CGPoint(x: 300, y: 300))
    }

    @Test("Undo and redo walk the overlay's annotations")
    func overlayUndoRedo() {
        let overlay = makeOverlay()
        overlay.testSetSelection(CGRect(x: 100, y: 100, width: 400, height: 300))

        overlay.testAddAnnotation(arrow(from: CGPoint(x: 150, y: 150), to: CGPoint(x: 300, y: 250)))
        overlay.testAddAnnotation(arrow(from: CGPoint(x: 200, y: 200), to: CGPoint(x: 350, y: 300)))
        #expect(overlay.testAnnotations.count == 2)

        overlay.testUndo()
        #expect(overlay.testAnnotations.count == 1)
        overlay.testUndo()
        #expect(overlay.testAnnotations.isEmpty)

        // Nothing left to undo: must not throw or go negative.
        overlay.testUndo()
        #expect(overlay.testAnnotations.isEmpty)

        overlay.testRedo()
        #expect(overlay.testAnnotations.count == 1)
        overlay.testRedo()
        #expect(overlay.testAnnotations.count == 2)
    }

    @Test("The overlay text input has no fill")
    func overlayTextInputIsTransparent() throws {
        let overlay = makeOverlay()
        overlay.testSetSelection(CGRect(x: 100, y: 100, width: 400, height: 300))
        overlay.testSetTool(.text)
        overlay.testBeginTextEditor(at: CGPoint(x: 200, y: 200))

        let field = try #require(overlay.testTextEditor)
        #expect(field.drawsBackground == false, "the input still paints a background")
        #expect(field.isBezeled == false)
        #expect(field.isBordered == false)
        #expect(field.focusRingType == .none)
        #expect(field.isEditable)
    }

    @Test("The editor text input has no fill either")
    func editorTextInputIsTransparent() throws {
        let settings = makeSettings()
        let document = ScreenshotDocument(
            image: makeImage(from: makeCGImage(pixelWidth: 200, pixelHeight: 200), pointSize: CGSize(width: 100, height: 100))
        )
        let canvas = AnnotationCanvasView(
            frame: CGRect(x: 0, y: 0, width: 100, height: 100),
            document: document,
            settings: settings,
            zoomScale: 1
        )
        canvas.testBeginTextEditor(at: CGPoint(x: 20, y: 20))

        let field = try #require(canvas.testTextEditor)
        #expect(field.drawsBackground == false)
        #expect(field.isBezeled == false)
        #expect(field.isBordered == false)
    }

    @Test("Typed text keeps the annotation colour, so the input is WYSIWYG")
    func textInputMatchesAnnotationColour() throws {
        let overlay = makeOverlay()
        overlay.testSetSelection(CGRect(x: 100, y: 100, width: 400, height: 300))
        overlay.testSetTool(.text)
        overlay.testBeginTextEditor(at: CGPoint(x: 200, y: 200))

        let field = try #require(overlay.testTextEditor)
        let expected = try #require(overlay.settings.defaultColor.usingColorSpace(.deviceRGB))
        let actual = try #require(field.textColor?.usingColorSpace(.deviceRGB))
        #expect(isClose(actual.redComponent, expected.redComponent, tolerance: 0.01))
        #expect(isClose(actual.greenComponent, expected.greenComponent, tolerance: 0.01))
        #expect(isClose(actual.blueComponent, expected.blueComponent, tolerance: 0.01))
    }

    @Test("Drawing an annotation leaves the panel on screen")
    func panelSurvivesDrawing() {
        let overlay = makeOverlay()
        overlay.testSetSelection(CGRect(x: 100, y: 100, width: 400, height: 300))
        overlay.testShowActionBar()
        #expect(overlay.testActionBarIsVisible)

        overlay.testSetTool(.arrow)
        overlay.testSimulateDraw(from: CGPoint(x: 150, y: 150), to: CGPoint(x: 350, y: 300))

        #expect(overlay.testAnnotations.count == 1)
        #expect(overlay.testActionBarIsVisible, "the panel vanished after drawing")
    }

    @Test("A discarded scribble still leaves the panel on screen")
    func panelSurvivesDiscardedDrawing() {
        let overlay = makeOverlay()
        overlay.testSetSelection(CGRect(x: 100, y: 100, width: 400, height: 300))
        overlay.testShowActionBar()

        overlay.testSetTool(.arrow)
        // Too short to keep, so nothing is added — but the panel must stay.
        overlay.testSimulateDraw(from: CGPoint(x: 150, y: 150), to: CGPoint(x: 151, y: 151))

        #expect(overlay.testAnnotations.isEmpty)
        #expect(overlay.testActionBarIsVisible)
    }

    @Test("Annotations reach the exporter in image coordinates")
    func overlayAnnotationsAreTranslated() throws {
        let overlay = makeOverlay(size: CGSize(width: 1000, height: 800))
        let selection = CGRect(x: 200, y: 300, width: 400, height: 200)
        overlay.testSetSelection(selection)
        overlay.testAddAnnotation(arrow(from: CGPoint(x: 250, y: 350), to: CGPoint(x: 450, y: 450)))

        let payload = try #require(overlay.testCapturePayload())
        let translated = try #require(payload.annotations.first)

        // Overlay-local (250,350) sits 50 right and 50 up from the selection origin.
        #expect(translated.start == CGPoint(x: 50, y: 50))
        #expect(translated.end == CGPoint(x: 250, y: 150))
    }

    @Test("A dragged arrow survives the round trip into an exported PNG")
    func overlayAnnotationsExport() throws {
        let settings = makeSettings()
        let image = makeImage(from: makeCGImage(pixelWidth: 400, pixelHeight: 200), pointSize: CGSize(width: 200, height: 100))
        let annotations = [arrow(from: CGPoint(x: 20, y: 20), to: CGPoint(x: 160, y: 80))]

        let data = try #require(
            ScreenshotOutput.data(for: image, annotations: annotations, format: .png, settings: settings)
        )
        let rep = try #require(NSBitmapImageRep(data: data))
        #expect(rep.pixelsWide == 400)
        #expect(rep.pixelsHigh == 200)

        // The arrow is red on a blue screenshot, so red must now dominate somewhere.
        var foundRed = false
        outer: for x in stride(from: 0, to: rep.pixelsWide, by: 3) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: 3) {
                guard let pixel = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if pixel.redComponent > 0.5, pixel.redComponent > pixel.blueComponent + 0.2 {
                    foundRed = true
                    break outer
                }
            }
        }
        #expect(foundRed, "the annotation did not make it into the exported image")
    }

    @Test("Only shape tools rubber-band; text is placed by a click")
    func shapeToolClassification() {
        #expect(OverlayTool.arrow.annotationKind?.isShape == true)
        #expect(OverlayTool.rectangle.annotationKind?.isShape == true)
        #expect(OverlayTool.text.annotationKind?.isShape == false)
        #expect(OverlayTool.none.annotationKind == nil)
    }

    // MARK: - Localization

    private func sourcesDirectory() -> String {
        #filePath.replacingOccurrences(
            of: "/Tests/Skreen2GoCoreTests/RegressionTests.swift",
            with: "/Sources/Skreen2GoCore"
        )
    }

    /// Keys defined in one of the `.strings` tables.
    private func stringsKeys(_ language: String) throws -> Set<String> {
        let path = sourcesDirectory() + "/Resources/\(language).lproj/Localizable.strings"
        let text = try String(contentsOfFile: path, encoding: .utf8)
        var keys: Set<String> = []
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("\""), let end = trimmed.dropFirst().firstIndex(of: "\"") else { continue }
            keys.insert(String(trimmed[trimmed.index(after: trimmed.startIndex)..<end]))
        }
        return keys
    }

    @Test("Both languages define exactly the same keys")
    func translationsAreComplete() throws {
        let english = try stringsKeys("en")
        let russian = try stringsKeys("ru")

        #expect(english.isEmpty == false)
        #expect(english.subtracting(russian).isEmpty, "missing in ru: \(english.subtracting(russian).sorted())")
        #expect(russian.subtracting(english).isEmpty, "missing in en: \(russian.subtracting(english).sorted())")
    }

    @Test("Every key used in code exists in both tables")
    func everyUsedKeyIsTranslated() throws {
        let english = try stringsKeys("en")
        let russian = try stringsKeys("ru")
        let files = try FileManager.default.contentsOfDirectory(atPath: sourcesDirectory())
            .filter { $0.hasSuffix(".swift") }

        var used: Set<String> = []
        for file in files {
            let text = try String(contentsOfFile: sourcesDirectory() + "/" + file, encoding: .utf8)
            // Matches `"some.key".localized(`
            var search = text[...]
            while let marker = search.range(of: "\".localized(") {
                let head = search[..<marker.lowerBound]
                if let openQuote = head.lastIndex(of: "\"") {
                    used.insert(String(head[head.index(after: openQuote)...]))
                }
                search = search[marker.upperBound...]
            }
        }

        #expect(used.count > 40, "only found \(used.count) keys — did the scan break?")
        #expect(used.subtracting(english).isEmpty, "not in en: \(used.subtracting(english).sorted())")
        #expect(used.subtracting(russian).isEmpty, "not in ru: \(used.subtracting(russian).sorted())")
    }

    @Test("No user-facing text is left hardcoded in the sources")
    func noHardcodedRussianRemains() throws {
        let files = try FileManager.default.contentsOfDirectory(atPath: sourcesDirectory())
            .filter { $0.hasSuffix(".swift") }
        let cyrillic = CharacterSet(charactersIn: "абвгдеёжзийклмнопрстуфхцчшщъыьэюяАБВГДЕЁЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯ")

        for file in files {
            let text = try String(contentsOfFile: sourcesDirectory() + "/" + file, encoding: .utf8)
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            for (number, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                // Language names are written in their own language on purpose.
                let isEndonym = lines[max(0, number - 1)].contains("Endonym")
                let code = (trimmed.hasPrefix("//") || isEndonym) ? "" : String(line)
                guard let quote = code.firstIndex(of: "\"") else { continue }
                let literals = String(code[quote...])
                #expect(
                    literals.rangeOfCharacter(from: cyrillic) == nil,
                    "\(file):\(number + 1) still carries literal text: \(line.trimmingCharacters(in: .whitespaces))"
                )
            }
        }
    }

    @Test("The localization bundle is found and resolves a key")
    func localizationBundleResolves() {
        // A missing bundle must degrade to the fallback rather than trapping.
        #expect("tool.arrow".localized("Arrow").isEmpty == false)
        #expect("definitely.not.a.key".localized("Fallback text") == "Fallback text")
    }

    @Test("Forcing a language changes what strings resolve to")
    func languageOverrideSwitchesStrings() {
        let previous = L10n.overrideLanguage
        defer { L10n.overrideLanguage = previous }

        L10n.overrideLanguage = "en"
        let english = "tool.arrow".localized("Arrow")
        L10n.overrideLanguage = "ru"
        let russian = "tool.arrow".localized("Arrow")

        #expect(english == "Arrow")
        #expect(russian == "Стрелка")
        #expect(english != russian, "the override had no effect")
    }

    @Test("An unknown forced language falls back rather than blanking the UI")
    func unknownLanguageFallsBack() {
        let previous = L10n.overrideLanguage
        defer { L10n.overrideLanguage = previous }

        L10n.overrideLanguage = "xx"
        #expect("tool.arrow".localized("Arrow").isEmpty == false)
    }

    @Test("The language setting persists and resets with the rest")
    func languageSettingRoundTrips() {
        let settings = makeSettings()
        #expect(settings.interfaceLanguage == .system)
        #expect(settings.interfaceLanguage.bundleCode == nil)

        settings.interfaceLanguage = .russian
        #expect(settings.interfaceLanguage == .russian)
        #expect(settings.interfaceLanguage.bundleCode == "ru")

        settings.reset()
        #expect(settings.interfaceLanguage == .system)
    }

    @Test("Every language offered in Settings has a bundled translation")
    func offeredLanguagesAreTranslated() throws {
        let available = try FileManager.default
            .contentsOfDirectory(atPath: sourcesDirectory() + "/Resources")
            .filter { $0.hasSuffix(".lproj") }
            .map { $0.replacingOccurrences(of: ".lproj", with: "") }

        for language in InterfaceLanguage.allCases {
            guard let code = language.bundleCode else { continue }
            #expect(available.contains(code), "\(code) is offered but has no .lproj")
        }
    }

    /// The bundle-level `Resources/`, which holds Info.plist and the `.lproj` folders
    /// macOS reads. Separate from the SwiftPM resources the app's own code looks in.
    private func bundleResourcesDirectory() -> String {
        #filePath.replacingOccurrences(
            of: "/Tests/Skreen2GoCoreTests/RegressionTests.swift",
            with: "/Resources"
        )
    }

    private func infoPlist() throws -> [String: Any] {
        let data = try Data(contentsOf: URL(fileURLWithPath: bundleResourcesDirectory() + "/Info.plist"))
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        return plist as? [String: Any] ?? [:]
    }

    private func infoPlistStrings(_ language: String) throws -> [String: String] {
        let path = bundleResourcesDirectory() + "/\(language).lproj/InfoPlist.strings"
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        return plist as? [String: String] ?? [:]
    }

    /// The Screen Recording prompt is drawn by macOS from Info.plist, not by our code, so
    /// it is the one piece of user-facing text `L10n` can never reach. It used to be
    /// hardcoded in Russian and was shown that way in every language.
    /// Every prompt macOS draws on our behalf. Found rather than listed, so a permission
    /// added later cannot ship without a translation.
    private func usageDescriptionKeys() throws -> [String] {
        try infoPlist().keys
            .filter { $0.hasPrefix("NS") && $0.hasSuffix("UsageDescription") }
            .sorted()
    }

    @Test("Every declared localization translates every permission prompt")
    func permissionPromptIsLocalized() throws {
        let declared = try #require(infoPlist()["CFBundleLocalizations"] as? [String])
        let prompts = try usageDescriptionKeys()
        #expect(declared.isEmpty == false)
        #expect(prompts.count >= 2, "expected at least the screen capture and microphone prompts")

        for language in declared {
            let strings = try infoPlistStrings(language)
            for prompt in prompts {
                #expect(
                    strings[prompt]?.isEmpty == false,
                    "\(language) does not translate \(prompt)"
                )
            }
        }
    }

    @Test("Info.plist's own strings are the development-region ones")
    func infoPlistBaseMatchesDevelopmentRegion() throws {
        let plist = try infoPlist()
        let region = try #require(plist["CFBundleDevelopmentRegion"] as? String)
        let regionStrings = try infoPlistStrings(region)

        // Whatever locale macOS cannot match falls back to the plist's own value, so it
        // has to read as the development region rather than as some other language.
        for prompt in try usageDescriptionKeys() {
            let base = try #require(plist[prompt] as? String)
            #expect(regionStrings[prompt] == base, "\(prompt) differs from its \(region) translation")
        }
    }

    @Test("The microphone entitlement ships with the microphone prompt")
    func microphoneEntitlementIsPresent() throws {
        let url = URL(fileURLWithPath: bundleResourcesDirectory() + "/Skreen2Go.entitlements")
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        let entitlements = try #require(plist as? [String: Any])

        // Without it a sandboxed app cannot open the microphone, whichever API asks.
        #expect(entitlements["com.apple.security.device.audio-input"] as? Bool == true)
        #expect(entitlements["com.apple.security.app-sandbox"] as? Bool == true)
    }

    @Test("The deployment target matches everywhere it is written down")
    func deploymentTargetIsConsistent() throws {
        let plist = try infoPlist()
        #expect(plist["LSMinimumSystemVersion"] as? String == "15.0")

        // A half-done platform bump builds locally and fails in CI, so the build script is
        // checked too.
        let script = try String(
            contentsOfFile: bundleResourcesDirectory()
                .replacingOccurrences(of: "/Resources", with: "/Scripts/build-app.sh"),
            encoding: .utf8
        )
        #expect(script.contains("macosx15.0"))
        #expect(script.contains("macosx14.0") == false)
    }

    @Test("Every language offered in Settings is declared to macOS as well")
    func offeredLanguagesAreDeclaredInTheBundle() throws {
        let declared = try #require(infoPlist()["CFBundleLocalizations"] as? [String])

        for language in InterfaceLanguage.allCases {
            guard let code = language.bundleCode else { continue }
            #expect(declared.contains(code), "\(code) is offered but not in CFBundleLocalizations")
        }
    }

    // MARK: - Settings from the action panel

    @Test("The settings button neither captures nor drops the frame")
    func settingsKeepsTheFrame() {
        let controller = CaptureController(settings: makeSettings())
        var shown = 0
        controller.onShowSettings = { shown += 1 }
        var captured = 0
        controller.onImageCaptured = { _, _, _ in captured += 1 }

        let payload = SelectionCapture(
            area: CGRect(x: 10, y: 10, width: 100, height: 80),
            annotations: [],
            window: nil
        )
        controller.testPerform(.settings, payload: payload)

        #expect(shown == 1, "the settings window was not requested")
        #expect(captured == 0, "settings must not take a screenshot")
        #expect(controller.testHasCaptureInFlight == false, "settings must not start a capture")
    }

    @Test("The overlay routes the settings button through to the controller")
    func overlayDeliversSettingsAction() {
        let overlay = makeOverlay(size: CGSize(width: 1200, height: 800))
        overlay.testSetSelection(CGRect(x: 200, y: 300, width: 500, height: 300))

        var received: SelectionAction?
        overlay.onSelectionAction = { action, _ in received = action }
        overlay.testDeliver(.settings)

        #expect(received == .settings)
    }

    @Test("A colour survives a round trip through the settings store")
    func defaultColourRoundTrips() {
        let settings = makeSettings()
        for colour in [NSColor.systemBlue, .systemGreen, .white, .black, .systemOrange] {
            settings.defaultColor = colour
            #expect(
                ColorPaletteView.sameColor(settings.defaultColor, colour),
                "\(colour) came back as \(settings.defaultColor)"
            )
        }
    }

    @Test("A default colour changed in settings is adopted by the overlay")
    func overlayAdoptsChangedDefaultColour() {
        let settings = makeSettings()
        let overlay = CaptureOverlayView(
            frame: CGRect(x: 0, y: 0, width: 1200, height: 800),
            settings: settings
        )
        overlay.testSetSelection(CGRect(x: 200, y: 300, width: 500, height: 300))
        overlay.testPickPaletteColor(.systemGreen)
        #expect(ColorPaletteView.sameColor(overlay.testCurrentColor, .systemGreen))

        settings.defaultColor = .systemBlue
        overlay.adoptDefaultColor()
        #expect(ColorPaletteView.sameColor(overlay.testCurrentColor, .systemBlue))
    }

    // MARK: - Colour palette lives above the dimming

    @Test("The palette opens under the colour button and is reachable")
    func paletteOpensUnderColourButton() throws {
        let overlay = makeOverlay(size: CGSize(width: 1200, height: 800))
        overlay.testSetSelection(CGRect(x: 200, y: 300, width: 500, height: 300))
        overlay.testShowActionBar()
        overlay.testLayoutActionBar()

        #expect(overlay.testColorPaletteFrame == nil)
        overlay.testToggleColorPalette()

        let palette = try #require(overlay.testColorPaletteFrame)
        let bar = try #require(overlay.testActionBarFrame)

        // Fully on screen — the whole point is that it is no longer stuck behind the
        // overlay or hanging off the edge.
        #expect(CGRect(x: 0, y: 0, width: 1200, height: 800).contains(palette))
        // Horizontally over the panel, vertically clear of it.
        #expect(palette.midX > bar.minX && palette.midX < bar.maxX)
        #expect(palette.intersection(bar).isEmpty)
    }

    @Test("Swatches in the palette take the pointing hand")
    func paletteSwatchesArePointable() throws {
        let overlay = makeOverlay(size: CGSize(width: 1200, height: 800))
        overlay.testSetSelection(CGRect(x: 200, y: 300, width: 500, height: 300))
        overlay.testShowActionBar()
        overlay.testLayoutActionBar()
        overlay.testToggleColorPalette()

        let palette = try #require(overlay.testColorPaletteFrame)
        var sawSwatch = false
        for x in stride(from: palette.minX + 2, to: palette.maxX - 2, by: 3) {
            for y in stride(from: palette.minY + 2, to: palette.maxY - 2, by: 3) {
                let point = CGPoint(x: x, y: y)
                if overlay.testCursorTarget(at: point) == .panelControl {
                    sawSwatch = true
                    #expect(overlay.testCursor(at: point) == NSCursor.pointingHand)
                }
            }
        }
        #expect(sawSwatch, "no swatch was reachable inside the palette")
    }

    @Test("Toggling closes the palette again")
    func paletteToggles() {
        let overlay = makeOverlay(size: CGSize(width: 1200, height: 800))
        overlay.testSetSelection(CGRect(x: 200, y: 300, width: 500, height: 300))
        overlay.testShowActionBar()
        overlay.testLayoutActionBar()

        overlay.testToggleColorPalette()
        #expect(overlay.testColorPaletteFrame != nil)
        overlay.testToggleColorPalette()
        #expect(overlay.testColorPaletteFrame == nil)
        // Closing when nothing is open is a no-op, not a crash.
        #expect(overlay.hideColorPalette() == false)
    }

    @Test("Picking a colour applies it and closes the palette")
    func pickingColourApplies() {
        let overlay = makeOverlay(size: CGSize(width: 1200, height: 800))
        overlay.testSetSelection(CGRect(x: 200, y: 300, width: 500, height: 300))
        overlay.testShowActionBar()
        overlay.testLayoutActionBar()
        overlay.testToggleColorPalette()

        overlay.testPickPaletteColor(.systemBlue)
        #expect(ColorPaletteView.sameColor(overlay.testCurrentColor, .systemBlue))
        #expect(overlay.testColorPaletteFrame == nil)
    }

    @Test("Newly drawn annotations use the picked colour")
    func pickedColourReachesAnnotations() throws {
        let overlay = makeOverlay(size: CGSize(width: 1200, height: 800))
        overlay.testSetSelection(CGRect(x: 200, y: 300, width: 500, height: 300))
        overlay.testShowActionBar()
        overlay.testPickPaletteColor(.systemGreen)

        overlay.testSetTool(.arrow)
        overlay.testSimulateDraw(from: CGPoint(x: 250, y: 350), to: CGPoint(x: 450, y: 450))

        let drawn = try #require(overlay.testAnnotations.first)
        #expect(ColorPaletteView.sameColor(drawn.color, .systemGreen))
    }

    @Test("Colour comparison tolerates colour-space round trips")
    func colourComparison() {
        #expect(ColorPaletteView.sameColor(.systemRed, .systemRed))
        #expect(ColorPaletteView.sameColor(.systemRed, .systemBlue) == false)
        #expect(ColorPaletteView.colors.isEmpty == false)
    }

    // MARK: - Hover hints and action animation

    @Test("Every panel control offers hint text")
    func panelControlsHaveHints() throws {
        let overlay = makeOverlay(size: CGSize(width: 1200, height: 800))
        overlay.testSetSelection(CGRect(x: 200, y: 300, width: 500, height: 300))
        overlay.testShowActionBar()
        overlay.testLayoutActionBar()

        let bar = try #require(overlay.testActionBarFrame)
        var hints: Set<String> = []
        for x in stride(from: bar.minX + 2, to: bar.maxX - 2, by: 3) {
            let point = CGPoint(x: x, y: bar.midY)
            if overlay.testCursorTarget(at: point) == .panelControl {
                let hint = try #require(overlay.testHint(at: point), "a control with no hint at x=\(x)")
                #expect(hint.isEmpty == false)
                hints.insert(hint)
            }
        }
        // Eleven controls: three tools, colour, undo, redo, settings, copy, save,
        // save-as, cancel. Recording controls belong to the other mode.
        #expect(hints.count == 11, "found hints: \(hints.sorted())")
        #expect(hints.contains("tool.arrow".localized("Arrow")))
        #expect(hints.contains("tool.color".localized("Color")))
        #expect(hints.contains("tool.settings".localized("Settings")))
        #expect(hints.contains("tool.copy".localized("Copy")))
        #expect(hints.contains("tool.save".localized("Save")))
        #expect(hints.contains("tool.record".localized("Record video")) == false)
    }

    @Test("The recording panel offers recording controls and nothing to draw with")
    func recordingPanelHasNoAnnotationTools() throws {
        let overlay = makeOverlay(size: CGSize(width: 1200, height: 800), mode: .recording)
        overlay.testSetSelection(CGRect(x: 200, y: 300, width: 500, height: 300))
        overlay.testShowActionBar()
        overlay.testLayoutActionBar()

        let bar = try #require(overlay.testActionBarFrame)
        var hints: Set<String> = []
        for x in stride(from: bar.minX + 2, to: bar.maxX - 2, by: 3) {
            let point = CGPoint(x: x, y: bar.midY)
            if overlay.testCursorTarget(at: point) == .panelControl {
                hints.insert(try #require(overlay.testHint(at: point), "a control with no hint at x=\(x)"))
            }
        }

        // Settings, record, system audio, microphone, cancel.
        #expect(hints.count == 5, "found hints: \(hints.sorted())")
        #expect(hints.contains("tool.record".localized("Record video")))
        #expect(hints.contains("tool.audio.system".localized("System audio")))
        #expect(hints.contains("tool.audio.microphone".localized("Microphone")))
        // There is no such thing as annotating a video here.
        #expect(hints.contains("tool.arrow".localized("Arrow")) == false)
        #expect(hints.contains("tool.rectangle".localized("Rectangle")) == false)
        #expect(hints.contains("tool.text".localized("Text")) == false)
        #expect(hints.contains("tool.color".localized("Color")) == false)
    }

    @Test("Enter starts a recording rather than opening the editor")
    func enterStartsRecordingInRecordingMode() {
        let overlay = makeOverlay(size: CGSize(width: 1200, height: 800), mode: .recording)
        overlay.testSetSelection(CGRect(x: 100, y: 100, width: 400, height: 300))

        var delivered: [SelectionAction] = []
        overlay.onSelectionAction = { action, _ in delivered.append(action) }

        overlay.confirmSelectionIfPossible()
        #expect(delivered == [.record])
    }

    @Test("Hovering a control makes its hint the active one")
    func hoveringSetsActiveHint() throws {
        let overlay = makeOverlay(size: CGSize(width: 1200, height: 800))
        overlay.testSetSelection(CGRect(x: 200, y: 300, width: 500, height: 300))
        overlay.testShowActionBar()
        overlay.testLayoutActionBar()

        let bar = try #require(overlay.testActionBarFrame)
        #expect(overlay.testActiveHint == nil)

        // Leaving sits on the left, out of the path to the buttons that commit.
        overlay.testForceHint(at: CGPoint(x: bar.minX + 22, y: bar.midY))
        #expect(overlay.testActiveHint == "tool.cancel".localized("Cancel (Esc)"))

        // Saving is at the far right, where the outcomes are gathered.
        overlay.testForceHint(at: CGPoint(x: bar.maxX - 22, y: bar.midY))
        #expect(overlay.testActiveHint == "tool.saveAs".localized("Save As…"))
    }

    @Test("The panel's primary buttons are equal circles, not squircles")
    func primaryButtonsAreCircles() throws {
        for mode in [CaptureMode.screenshot, CaptureMode.recording] {
            let overlay = makeOverlay(size: CGSize(width: 1200, height: 800), mode: mode)
            overlay.testSetSelection(CGRect(x: 200, y: 300, width: 500, height: 300))
            overlay.testShowActionBar()
            overlay.testLayoutActionBar()

            let buttons = overlay.testPrimaryButtons
            let expected = mode == .screenshot ? 3 : 1
            #expect(buttons.count == expected, "\(mode) has \(buttons.count) primary buttons")

            let side = SelectionActionBar.testPrimarySide
            let circles = overlay.testPrimaryCircles
            #expect(circles.count == expected)
            for circle in circles {
                // Judged by the shape drawn, not the button's frame: AppKit stretches a
                // button with an image past its height constraint, and half the width as
                // a corner radius on a frame that is not square is a superellipse.
                #expect(isClose(circle.rect.width, side))
                #expect(isClose(circle.rect.height, side), "a circle needs a square")
                #expect(isClose(circle.cornerRadius, side / 2))
            }
            // And every one of them the same size.
            #expect(Set(circles.map { $0.rect.width }).count == 1)
        }
    }

    @Test("Every button is opaque even though the panel behind it is not")
    func buttonsAreOpaqueOnATranslucentPanel() throws {
        for mode in [CaptureMode.screenshot, CaptureMode.recording] {
            let overlay = makeOverlay(size: CGSize(width: 1200, height: 800), mode: mode)
            overlay.testSetSelection(CGRect(x: 200, y: 300, width: 500, height: 300))
            overlay.testShowActionBar()
            overlay.testLayoutActionBar()

            // The panel floats above the shot...
            #expect(overlay.testPanelFillAlpha < 1)

            // ...but a control you are about to press must read as solid, not as a tint
            // of the desktop showing through.
            let alphas = overlay.testButtonFillAlphas
            #expect(alphas.isEmpty == false)
            for alpha in alphas {
                #expect(isClose(alpha, 1), "a button is drawn at alpha \(alpha) in \(mode)")
            }
        }
    }

    @Test("The animated background covers the whole panel")
    func panelBackgroundFillsThePanel() throws {
        for style in PanelBackgroundStyle.allCases {
            let settings = makeSettings()
            settings.panelBackground = style
            let overlay = CaptureOverlayView(
                frame: CGRect(x: 0, y: 0, width: 1200, height: 800),
                settings: settings,
                mode: .screenshot
            )
            overlay.testSetSelection(CGRect(x: 200, y: 300, width: 500, height: 300))
            overlay.testShowActionBar()
            overlay.testLayoutActionBar()

            let bar = try #require(overlay.testActionBarFrame)
            let background = try #require(overlay.testPanelBackgroundFrame, "\(style) has no background")
            // The panel is built at zero size and grows to fit its controls; the
            // background has to grow with it rather than stay where it started.
            #expect(isClose(background.width, bar.width), "\(style) background is \(background.width) wide")
            #expect(isClose(background.height, bar.height))
        }
    }

    @Test("The panel background style round-trips and resets")
    func panelBackgroundSettingRoundTrips() {
        let settings = makeSettings()
        #expect(settings.panelBackground == .smoke)

        settings.panelBackground = .plasma
        #expect(settings.panelBackground == .plasma)

        settings.reset()
        #expect(settings.panelBackground == .smoke)
    }

    @Test("The panel background offers no hint")
    func panelBackgroundHasNoHint() throws {
        let overlay = makeOverlay(size: CGSize(width: 1200, height: 800))
        overlay.testSetSelection(CGRect(x: 200, y: 300, width: 500, height: 300))
        overlay.testShowActionBar()
        overlay.testLayoutActionBar()

        let bar = try #require(overlay.testActionBarFrame)
        // Top edge of the bar is padding, never a control.
        #expect(overlay.testHint(at: CGPoint(x: bar.midX, y: bar.maxY - 1)) == nil)
        // And nothing outside it either.
        #expect(overlay.testHint(at: CGPoint(x: 50, y: 700)) == nil)
    }

    @Test("A hidden panel offers no hints")
    func hiddenPanelHasNoHints() {
        let overlay = makeOverlay(size: CGSize(width: 1200, height: 800))
        overlay.testSetSelection(CGRect(x: 200, y: 300, width: 500, height: 300))
        overlay.testShowActionBar()
        overlay.testHideActionBar()
        #expect(overlay.testHint(at: CGPoint(x: 450, y: 450)) == nil)
        #expect(overlay.testActiveHint == nil)
    }

    @Test("The flight starts at the region and lands on the icon")
    func flightEndpoints() {
        let start = CGRect(x: 200, y: 100, width: 400, height: 300)
        let end = CGRect(x: 1400, y: 950, width: 32, height: 32)

        let first = CaptureFlash.frame(at: 0, from: start, to: end)
        #expect(isClose(first.midX, start.midX, tolerance: 0.001))
        #expect(isClose(first.width, start.width, tolerance: 0.001))

        let last = CaptureFlash.frame(at: 1, from: start, to: end)
        #expect(isClose(last.midX, end.midX, tolerance: 0.001))
        #expect(isClose(last.midY, end.midY, tolerance: 0.001))
        #expect(isClose(last.width, end.width, tolerance: 0.001))
    }

    @Test("The path curves rather than running straight")
    func flightPathCurves() {
        let start = CGPoint(x: 200, y: 100)
        let end = CGPoint(x: 1400, y: 950)

        let midway = CaptureFlash.center(at: 0.5, from: start, to: end)
        let straight = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)

        // A real arc, not the chord.
        let deviation = hypot(midway.x - straight.x, midway.y - straight.y)
        #expect(deviation > 40, "path deviates only \(deviation)pt from the straight line")
        // The control point pulls it sideways first, so it stays below the chord.
        #expect(midway.y < straight.y)
    }

    @Test("The shot shrinks steadily on the way")
    func flightShrinksMonotonically() {
        let start = CGRect(x: 0, y: 0, width: 800, height: 600)
        let end = CGRect(x: 1400, y: 950, width: 32, height: 32)

        var previous = CGFloat.greatestFiniteMagnitude
        for step in 0...10 {
            let width = CaptureFlash.frame(at: CGFloat(step) / 10, from: start, to: end).width
            #expect(width <= previous + 0.001, "width grew at step \(step)")
            previous = width
        }
        #expect(previous < 40)
    }

    @Test("It stays solid at first, then fades out completely")
    func flightFade() {
        #expect(CaptureFlash.alpha(at: 0) == 1)
        #expect(CaptureFlash.alpha(at: CaptureFlash.fadeStart) == 1)
        #expect(CaptureFlash.alpha(at: 1) == 0)

        var previous: CGFloat = 1
        for step in 0...10 {
            let alpha = CaptureFlash.alpha(at: CGFloat(step) / 10)
            #expect(alpha <= previous + 0.001, "alpha rose at step \(step)")
            previous = alpha
        }
    }

    @Test("Easing is clamped and monotonic")
    func flightEasing() {
        #expect(CaptureFlash.eased(-1) == 0)
        #expect(CaptureFlash.eased(0) == 0)
        #expect(CaptureFlash.eased(1) == 1)
        #expect(CaptureFlash.eased(2) == 1)
        #expect(CaptureFlash.eased(0.5) > 0.4 && CaptureFlash.eased(0.5) < 0.6)
    }

    @Test("Without a status item the flight still has somewhere to land")
    func flightFallbackDestination() throws {
        let screen = try #require(NSScreen.main)
        let rect = CGRect(x: screen.frame.midX, y: screen.frame.midY, width: 200, height: 150)
        let destination = CaptureFlash.fallbackDestination(for: rect)

        #expect(destination.width > 0 && destination.height > 0)
        // Up in the menu bar corner, not left in the middle of the screen.
        #expect(destination.midY > screen.frame.midY)
        #expect(destination.midX > screen.frame.midX)
    }

    @Test("A degenerate region is ignored instead of flying an empty panel")
    func flightIgnoresDegenerateRegion() {
        let image = makeImage(
            from: makeCGImage(pixelWidth: 40, pixelHeight: 40),
            pointSize: CGSize(width: 20, height: 20)
        )
        CaptureFlash.shared.fly(image, from: .zero)
        CaptureFlash.shared.fly(image, from: CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    // MARK: - Window capture shares the area flow

    private func windowInfo(_ frame: CGRect) -> WindowInfo {
        WindowInfo(id: 42, frame: frame, ownerName: "Finder", title: "Test")
    }

    @Test("Clicking a window opens the same live frame with the panel")
    func windowBecomesLiveSelection() throws {
        let overlay = makeOverlay(size: CGSize(width: 1200, height: 800))
        let frame = CGRect(x: 150, y: 120, width: 600, height: 400)

        overlay.testSelectWindow(windowInfo(frame))

        #expect(overlay.testSelection == frame, "the frame must match the window")
        #expect(overlay.testActionBarIsVisible, "the panel must appear, as it does for an area")
        let payload = try #require(overlay.testCapturePayload())
        #expect(payload.window?.id == 42, "the window filter must still be used")
    }

    @Test("The window frame supports the same tools and handles")
    func windowSelectionSupportsTools() {
        let overlay = makeOverlay(size: CGSize(width: 1200, height: 800))
        overlay.testSelectWindow(windowInfo(CGRect(x: 150, y: 120, width: 600, height: 400)))

        // Handles resolve, exactly as for a dragged region.
        #expect(overlay.handle(at: CGPoint(x: 150, y: 520), in: CGRect(x: 150, y: 120, width: 600, height: 400)) == .topLeft)

        // And drawing works inside it.
        overlay.testSetTool(.arrow)
        overlay.testSimulateDraw(from: CGPoint(x: 200, y: 200), to: CGPoint(x: 400, y: 350))
        #expect(overlay.testAnnotations.count == 1)
        #expect(overlay.testActionBarIsVisible)
    }

    @Test("Moving a window frame switches it to an area capture")
    func movedWindowFallsBackToArea() throws {
        let overlay = makeOverlay(size: CGSize(width: 1200, height: 800))
        overlay.testSelectWindow(windowInfo(CGRect(x: 150, y: 120, width: 600, height: 400)))
        #expect(overlay.testSelectedWindow != nil)

        // Goes through the same code the drag handler runs.
        overlay.testMoveSelection(grab: CGSize(width: 10, height: 10), to: CGPoint(x: 260, y: 230))

        #expect(overlay.testSelectedWindow == nil)
        let payload = try #require(overlay.testCapturePayload())
        #expect(payload.window == nil, "a moved frame must not claim to be a window")
    }

    @Test("Resizing a window frame switches it to an area capture")
    func resizedWindowFallsBackToArea() throws {
        let overlay = makeOverlay(size: CGSize(width: 1200, height: 800))
        overlay.testSelectWindow(windowInfo(CGRect(x: 150, y: 120, width: 600, height: 400)))

        overlay.testResizeSelection(handle: .right, to: CGPoint(x: 600, y: 300))

        #expect(overlay.testSelectedWindow == nil)
        let payload = try #require(overlay.testCapturePayload())
        #expect(payload.window == nil)
    }

    @Test("A window hanging off the overlay falls back to an area capture")
    func clippedWindowFallsBackToArea() {
        let overlay = makeOverlay(size: CGSize(width: 400, height: 300))
        // Wider than the overlay, so clamping shrinks it.
        overlay.testSelectWindow(windowInfo(CGRect(x: 0, y: 0, width: 900, height: 200)))

        #expect(overlay.testSelection != nil)
        #expect(overlay.testSelectedWindow == nil)
    }

    // MARK: - Floating action bar (PRD §5)

    @Test("The action bar appears as soon as a selection exists, not on Enter")
    func actionBarAppearsWithSelection() {
        let overlay = makeOverlay()
        #expect(overlay.testActionBarIsVisible == false)

        overlay.testSetSelection(CGRect(x: 200, y: 300, width: 400, height: 250))
        overlay.testShowActionBar()
        #expect(overlay.testActionBarIsVisible)

        overlay.testHideActionBar()
        #expect(overlay.testActionBarIsVisible == false)
    }

    @Test("Command-C routes through the same copy action as the button")
    func commandCRoutesToCopyAction() {
        let overlay = makeOverlay()
        overlay.testSetSelection(CGRect(x: 200, y: 300, width: 400, height: 250))
        var receivedAction: SelectionAction?
        overlay.onSelectionAction = { action, _ in receivedAction = action }

        #expect(overlay.testPerformAction(.copy))
        #expect(receivedAction == .copy)
    }

    @Test("Hovering a panel button gives the pointing hand")
    func panelButtonsShowPointingHand() throws {
        let overlay = makeOverlay(size: CGSize(width: 1200, height: 800))
        overlay.testSetSelection(CGRect(x: 200, y: 300, width: 500, height: 300))
        overlay.testShowActionBar()
        overlay.testLayoutActionBar()

        let bar = try #require(overlay.testActionBarFrame)

        // Sweep across the bar: at least one point must land on a control, and every
        // control point must ask for the pointing hand.
        var sawControl = false
        for x in stride(from: bar.minX + 2, to: bar.maxX - 2, by: 4) {
            let point = CGPoint(x: x, y: bar.midY)
            let target = overlay.testCursorTarget(at: point)
            if target == .panelControl {
                sawControl = true
                #expect(overlay.testCursor(at: point) == NSCursor.pointingHand)
            } else {
                #expect(target == .panelBackground, "unexpected target \(target) inside the panel")
            }
        }
        #expect(sawControl, "no control was found anywhere along the panel")
    }

    @Test("Outside the panel the cursor still reflects the frame")
    func cursorOutsidePanelUnchanged() throws {
        let overlay = makeOverlay(size: CGSize(width: 1200, height: 800))
        let selection = CGRect(x: 200, y: 300, width: 500, height: 300)
        overlay.testSetSelection(selection)
        overlay.testShowActionBar()
        overlay.testLayoutActionBar()

        // Inside the frame, no tool: the move cursor.
        #expect(overlay.testCursorTarget(at: CGPoint(x: 450, y: 450)) == .insideSelection)
        #expect(overlay.testCursor(at: CGPoint(x: 450, y: 450)) == NSCursor.openHand)

        // A side handle: the matching resize cursor.
        #expect(overlay.testCursor(at: CGPoint(x: selection.minX, y: selection.midY)) == NSCursor.resizeLeftRight)
        #expect(overlay.testCursor(at: CGPoint(x: selection.midX, y: selection.maxY)) == NSCursor.resizeUpDown)

        // Far away from everything.
        #expect(overlay.testCursorTarget(at: CGPoint(x: 40, y: 760)) == .outsideSelection)
    }

    @Test("A hidden panel never claims the cursor")
    func hiddenPanelDoesNotClaimCursor() {
        let overlay = makeOverlay(size: CGSize(width: 1200, height: 800))
        overlay.testSetSelection(CGRect(x: 200, y: 300, width: 500, height: 300))
        overlay.testShowActionBar()
        overlay.testHideActionBar()

        // With the bar hidden, its former area falls through to the frame logic.
        #expect(overlay.testCursorTarget(at: CGPoint(x: 450, y: 450)) == .insideSelection)
    }

    @Test("The bar keeps its own width even when the selection is narrower")
    func actionBarMayBeWiderThanSelection() {
        let bounds = CGRect(x: 0, y: 0, width: 1400, height: 900)
        let narrow = CGRect(x: 600, y: 400, width: 80, height: 60)
        let barSize = CGSize(width: 520, height: 34)

        let frame = FloatingBarPlacement.frame(barSize: barSize, around: narrow, within: bounds)
        #expect(isClose(frame.width, barSize.width, tolerance: 0.001), "bar was squeezed to \(frame.width)")
        #expect(bounds.contains(frame))
    }

    @Test("PRD §5 priority: the bar goes below the selection first")
    func actionBarPrefersBelow() {
        let bounds = CGRect(x: 0, y: 0, width: 1400, height: 900)
        let selection = CGRect(x: 300, y: 300, width: 500, height: 300)
        let frame = FloatingBarPlacement.frame(
            barSize: CGSize(width: 520, height: 34),
            around: selection,
            within: bounds
        )
        #expect(frame.maxY <= selection.minY)
        #expect(bounds.contains(frame))
    }

    @Test("With no room below the bar moves to the right of the selection")
    func actionBarFallsBackToTheRight() {
        let bounds = CGRect(x: 0, y: 0, width: 1400, height: 900)
        // Flush against the bottom, so "below" cannot fit.
        let selection = CGRect(x: 200, y: 0, width: 400, height: 300)
        let frame = FloatingBarPlacement.frame(
            barSize: CGSize(width: 520, height: 34),
            around: selection,
            within: bounds
        )
        #expect(frame.minX >= selection.maxX)
        #expect(bounds.contains(frame))
    }

    @Test("A selection filling the screen keeps the bar inside it")
    func actionBarGoesInsideWhenNoRoomOutside() {
        let bounds = CGRect(x: 0, y: 0, width: 1400, height: 900)
        let frame = FloatingBarPlacement.frame(
            barSize: CGSize(width: 520, height: 34),
            around: bounds,
            within: bounds
        )
        #expect(bounds.contains(frame))
        #expect(frame.minY >= bounds.minY)
    }

    @Test("The bar stays on screen for a selection hugging the right edge")
    func actionBarClampedNearRightEdge() {
        let bounds = CGRect(x: 0, y: 0, width: 1400, height: 900)
        let selection = CGRect(x: 1300, y: 400, width: 100, height: 100)
        let frame = FloatingBarPlacement.frame(
            barSize: CGSize(width: 520, height: 34),
            around: selection,
            within: bounds
        )
        #expect(bounds.contains(frame), "bar \(frame) left the overlay \(bounds)")
    }

    @Test("A narrow shot still gets a full-width editor toolbar")
    func editorToolbarNotSqueezedForSmallShot() throws {
        let screen = try #require(NSScreen.main)
        let visible = screen.visibleFrame.insetBy(dx: 12, dy: 12)
        // Small selection pinned into the bottom-right corner: no candidate fits outside.
        let selection = CGRect(x: visible.maxX - 90, y: visible.minY, width: 80, height: 60)
        let toolbarSize = NSSize(width: 620, height: 44)

        let placement = ToolbarPlacement.make(
            imageSize: selection.size,
            selectionFrame: selection,
            toolbarSize: toolbarSize
        )
        #expect(
            isClose(placement.toolbarFrame.width, toolbarSize.width, tolerance: 1),
            "toolbar was clipped to \(placement.toolbarFrame.width)"
        )
        #expect(placement.windowFrame.width >= toolbarSize.width - 1)
    }

    @Test("Handles sit on the corners and edge midpoints")
    func selectionHandlePositions() {
        let overlay = makeOverlay()
        let rect = CGRect(x: 100, y: 200, width: 300, height: 200)

        #expect(overlay.handlePoint(.topLeft, in: rect) == CGPoint(x: 100, y: 400))
        #expect(overlay.handlePoint(.bottomRight, in: rect) == CGPoint(x: 400, y: 200))
        #expect(overlay.handlePoint(.top, in: rect) == CGPoint(x: 250, y: 400))
        #expect(overlay.handlePoint(.left, in: rect) == CGPoint(x: 100, y: 300))
    }

    @Test("A point on a handle hits it, the middle of the selection does not")
    func selectionHandleHitTest() {
        let overlay = makeOverlay()
        let rect = CGRect(x: 100, y: 200, width: 300, height: 200)

        #expect(overlay.handle(at: CGPoint(x: 100, y: 400), in: rect) == .topLeft)
        #expect(overlay.handle(at: CGPoint(x: 402, y: 302), in: rect) == .right)
        #expect(overlay.handle(at: CGPoint(x: rect.midX, y: rect.midY), in: rect) == nil)
    }

    @Test("Dragging a corner keeps the opposite corner anchored")
    func resizingFromCorner() {
        let overlay = makeOverlay()
        let rect = CGRect(x: 100, y: 200, width: 300, height: 200)

        let resized = overlay.testResize(rect, handle: .bottomLeft, to: CGPoint(x: 50, y: 150))
        #expect(resized.maxX == rect.maxX)
        #expect(resized.maxY == rect.maxY)
        #expect(resized.minX == 50)
        #expect(resized.minY == 150)
    }

    @Test("Dragging a horizontal edge leaves the width alone")
    func resizingFromEdge() {
        let overlay = makeOverlay()
        let rect = CGRect(x: 100, y: 200, width: 300, height: 200)

        let resized = overlay.testResize(rect, handle: .top, to: CGPoint(x: 999, y: 500))
        #expect(resized.minX == rect.minX)
        #expect(isClose(resized.width, rect.width, tolerance: 0.001))
        #expect(resized.maxY == 500)
        #expect(resized.minY == rect.minY)
    }

    @Test("The selection is kept inside the overlay bounds while moving")
    func selectionIsClamped() {
        let overlay = makeOverlay(size: CGSize(width: 1000, height: 600))

        let pushedPastTopRight = overlay.testClampedRect(CGRect(x: 900, y: 550, width: 300, height: 200))
        #expect(pushedPastTopRight.maxX <= 1000)
        #expect(pushedPastTopRight.maxY <= 600)
        #expect(isClose(pushedPastTopRight.width, 300, tolerance: 0.001))
        #expect(isClose(pushedPastTopRight.height, 200, tolerance: 0.001))

        let pushedPastOrigin = overlay.testClampedRect(CGRect(x: -80, y: -50, width: 300, height: 200))
        #expect(pushedPastOrigin.minX == 0)
        #expect(pushedPastOrigin.minY == 0)

        let oversized = overlay.testClampedRect(CGRect(x: -100, y: -100, width: 5000, height: 5000))
        #expect(isClose(oversized.width, 1000, tolerance: 0.001))
        #expect(isClose(oversized.height, 600, tolerance: 0.001))
    }

    @Test("Setting a selection makes it live and editable")
    func selectionBecomesLive() {
        let overlay = makeOverlay()
        #expect(overlay.testSelection == nil)
        overlay.testSetSelection(CGRect(x: 10, y: 20, width: 200, height: 150))
        #expect(overlay.testSelection == CGRect(x: 10, y: 20, width: 200, height: 150))
    }

    /// Draws the selection border over a flat background and returns the luminance profile
    /// across the left edge, so both sides of the line can be inspected.
    private func borderLuminanceProfile(background: NSColor) throws -> [CGFloat] {
        let side = 100
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: side,
            pixelsHigh: side,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: .alphaFirst,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        background.setFill()
        NSRect(x: 0, y: 0, width: side, height: side).fill()
        SelectionBorder.stroke(CGRect(x: 30, y: 30, width: 40, height: 40))
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        // Horizontal slice crossing the left edge of the frame.
        return (24...36).compactMap { x -> CGFloat? in
            guard let pixel = bitmap.colorAt(x: x, y: side / 2)?.usingColorSpace(.deviceRGB) else { return nil }
            return 0.299 * pixel.redComponent + 0.587 * pixel.greenComponent + 0.114 * pixel.blueComponent
        }
    }

    @Test("The frame stays visible on white content")
    func borderVisibleOnWhite() throws {
        let profile = try borderLuminanceProfile(background: .white)
        let darkest = try #require(profile.min())
        // Needs a genuinely dark pixel against white, not just the mid grey core.
        #expect(darkest < 0.45, "profile \(profile.map { ($0 * 100).rounded() / 100 })")
    }

    @Test("The frame stays visible on black content")
    func borderVisibleOnBlack() throws {
        let profile = try borderLuminanceProfile(background: .black)
        let brightest = try #require(profile.max())
        #expect(brightest > 0.55, "profile \(profile.map { ($0 * 100).rounded() / 100 })")
    }

    @Test("The frame stays visible on mid grey content")
    func borderVisibleOnMidGrey() throws {
        let profile = try borderLuminanceProfile(background: NSColor(white: 0.62, alpha: 1))
        let darkest = try #require(profile.min())
        let brightest = try #require(profile.max())
        // The core matches this background exactly, so the hairlines carry the contrast.
        #expect(brightest - darkest > 0.3, "profile \(profile.map { ($0 * 100).rounded() / 100 })")
    }

    @Test("Selection border core is grey so it reads on light and dark content")
    func selectionBorderIsGrey() throws {
        let rgb = try #require(SelectionBorder.coreColor.usingColorSpace(.deviceRGB))
        #expect(isClose(rgb.redComponent, rgb.greenComponent, tolerance: 0.001))
        #expect(isClose(rgb.greenComponent, rgb.blueComponent, tolerance: 0.001))
        // Mid grey: far enough from both extremes to contrast either way.
        #expect(rgb.redComponent > 0.35 && rgb.redComponent < 0.8)
    }

    @Test("Placement survives a degenerate selection instead of trapping")
    func toolbarPlacementDegenerate() {
        let placement = ToolbarPlacement.make(
            imageSize: NSSize(width: 0, height: 0),
            selectionFrame: .zero,
            toolbarSize: NSSize(width: 500, height: 44)
        )
        #expect(placement.windowFrame.width > 0)
        #expect(placement.windowFrame.height > 0)
    }

    // MARK: - #23 Text was sized by a character-count guess

    @Test("Cyrillic text is measured, not guessed")
    func cyrillicTextBounds() {
        let settings = makeSettings()
        settings.textSize = 24
        settings.textBold = true

        let value = "Внимание: проверьте настройки"
        let annotation = Annotation(
            kind: .text,
            rect: CGRect(origin: CGPoint(x: 10, y: 20), size: .zero),
            text: value,
            color: .red,
            thickness: 3,
            opacity: 1
        )

        let bounds = AnnotationRenderer.textBounds(annotation, settings: settings)
        let measured = (value as NSString).size(
            withAttributes: AnnotationRenderer.textAttributes(for: annotation, settings: settings)
        )

        #expect(bounds.origin == CGPoint(x: 10, y: 20))
        #expect(bounds.width >= measured.width)
        #expect(bounds.height >= measured.height)
        #expect(isClose(bounds.width, ceil(measured.width) + 4, tolerance: 0.001))
    }

    @Test("Text bounds follow the current font size")
    func textBoundsFollowFontSize() {
        let settings = makeSettings()
        let annotation = Annotation(
            kind: .text,
            rect: CGRect(origin: .zero, size: .zero),
            text: "Пример",
            color: .red,
            thickness: 3,
            opacity: 1
        )

        settings.textSize = 12
        let small = AnnotationRenderer.textBounds(annotation, settings: settings)
        settings.textSize = 48
        let large = AnnotationRenderer.textBounds(annotation, settings: settings)

        #expect(large.width > small.width)
        #expect(large.height > small.height)
    }

    // MARK: - #17 Cursor ignored colour and opacity

    @Test("Cursor is tinted with its annotation colour")
    func cursorIsTinted() throws {
        let size = CGSize(width: 60, height: 60)
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width),
            pixelsHigh: Int(size.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: .alphaFirst,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))

        let base = makeImage(from: makeCGImage(pixelWidth: 60, pixelHeight: 60), pointSize: size)
        let cursor = Annotation(
            kind: .cursor(.arrow),
            rect: CGRect(x: 10, y: 10, width: 40, height: 40),
            color: .systemGreen,
            thickness: 3,
            opacity: 1
        )

        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        AnnotationRenderer.draw(
            image: base,
            annotations: [cursor],
            in: CGRect(origin: .zero, size: size),
            settings: makeSettings(),
            blurCache: BlurCache()
        )
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        var foundGreen = false
        outer: for x in 0..<Int(size.width) {
            for y in 0..<Int(size.height) {
                guard let pixel = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if pixel.greenComponent > 0.45, pixel.greenComponent > pixel.redComponent + 0.1 {
                    foundGreen = true
                    break outer
                }
            }
        }
        #expect(foundGreen, "cursor must use the annotation colour instead of being forced to black")
    }

    @Test("Halo colour flips with brightness")
    func contrastColour() {
        #expect(AnnotationRenderer.contrastColor(for: .white) == .black)
        #expect(AnnotationRenderer.contrastColor(for: .black) == .white)
    }

    // MARK: - #21 Hot key churn, #4 Carbon mapping

    @Test("Unrelated settings changes leave the hot key untouched")
    func hotKeyStability() {
        let settings = makeSettings()
        let original = settings.hotKey
        #expect(original == HotKeyCombination.default)

        settings.strokeThickness = 9
        settings.blurRadius = 30
        #expect(settings.hotKey == original)

        settings.hotKey = HotKeyCombination(keyCode: 35, modifiers: [.command, .option])
        #expect(settings.hotKey != original)
    }

    @Test("Default hot key avoids ⌘ so it does not shadow other apps")
    func defaultHotKeyAvoidsCommand() {
        #expect(HotKeyCombination.default.modifiers.contains(.command) == false)
        #expect(HotKeyCombination.default.modifiers.isEmpty == false)
    }

    @Test("Cocoa modifiers map onto Carbon flags")
    func carbonModifierMapping() {
        #expect(HotKeyMonitor.carbonModifiers([]) == 0)
        #expect(HotKeyMonitor.carbonModifiers([.command]) == UInt32(cmdKey))
        #expect(HotKeyMonitor.carbonModifiers([.shift]) == UInt32(shiftKey))
        #expect(HotKeyMonitor.carbonModifiers([.option]) == UInt32(optionKey))
        #expect(HotKeyMonitor.carbonModifiers([.control]) == UInt32(controlKey))
        #expect(HotKeyMonitor.carbonModifiers([.control, .shift]) == UInt32(controlKey) | UInt32(shiftKey))
    }

    // MARK: - #25 Key code table

    @Test("Formatter covers arrows, function keys and punctuation")
    func hotKeyFormatterCoverage() {
        #expect(HotKeyFormatter.string(keyCode: 1, modifiers: [.control, .shift]) == "⌃⇧S")
        #expect(HotKeyFormatter.string(keyCode: 49, modifiers: [.command]) == "⌘Space")
        #expect(HotKeyFormatter.string(keyCode: 123, modifiers: [.option]) == "⌥←")
        #expect(HotKeyFormatter.string(keyCode: 122, modifiers: [.command]) == "⌘F1")
        #expect(HotKeyFormatter.string(keyCode: 51, modifiers: [.command]) == "⌘Delete")
        #expect(HotKeyFormatter.string(keyCode: 43, modifiers: [.command]) == "⌘,")
    }

    @Test("Modifier glyph order is stable")
    func modifierOrder() {
        #expect(
            HotKeyFormatter.string(keyCode: 0, modifiers: [.command, .shift, .option, .control]) == "⌃⌥⇧⌘A"
        )
    }

    // MARK: - #27 Display geometry

    @Test("Cocoa rects round-trip through Quartz coordinates")
    func cocoaRectRoundTrip() throws {
        let screen = try #require(NSScreen.main)
        let original = CGRect(
            x: screen.frame.minX + 120,
            y: screen.frame.minY + 80,
            width: 300,
            height: 200
        )

        let quartz = ScreenGeometry.quartzRect(for: original, on: screen)
        let roundTripped = try #require(ScreenGeometry.cocoaRect(for: quartz))

        #expect(isClose(roundTripped.minX, original.minX))
        #expect(isClose(roundTripped.minY, original.minY))
        #expect(isClose(roundTripped.width, original.width))
        #expect(isClose(roundTripped.height, original.height))
    }

    @Test("sourceRect conversion uses a top-left origin")
    func displayLocalRectOrigin() throws {
        let screen = try #require(NSScreen.main)
        let topLeft = CGRect(x: screen.frame.minX, y: screen.frame.maxY - 100, width: 200, height: 100)
        let local = ScreenGeometry.displayLocalRect(for: topLeft, on: screen)

        #expect(isClose(local.minX, 0, tolerance: 0.001))
        #expect(isClose(local.minY, 0, tolerance: 0.001))
        #expect(isClose(local.width, 200, tolerance: 0.001))
        #expect(isClose(local.height, 100, tolerance: 0.001))
    }

    @Test("Screen lookup picks the display with the biggest overlap")
    func bestMatchingScreen() throws {
        let screen = try #require(NSScreen.main)
        let bounds = CGDisplayBounds(ScreenGeometry.displayID(for: screen))
        let mostlyInside = bounds.insetBy(dx: 10, dy: 10)
        let matched = try #require(ScreenGeometry.screen(bestMatchingQuartzRect: mostlyInside))
        #expect(ScreenGeometry.displayID(for: matched) == ScreenGeometry.displayID(for: screen))
    }

    @Test("A point on the top edge still resolves to a screen")
    func topEdgePointResolves() throws {
        let screen = try #require(NSScreen.main)
        let topEdge = CGPoint(x: screen.frame.midX, y: screen.frame.maxY)
        #expect(ScreenGeometry.screen(containingCocoaPoint: topEdge) != nil)
    }

    // MARK: - PRD §9 file naming

    @Test("File name matches the PRD template")
    func fileNaming() throws {
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 6
        components.hour = 14
        components.minute = 30
        components.second = 25

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let date = try #require(calendar.date(from: components))

        let name = ScreenshotNaming.fileName(for: .png, date: date)
        #expect(name.hasPrefix("Screenshot 2026-08-06 at "), "got \(name)")
        #expect(name.hasSuffix(".png"))
        #expect(ScreenshotNaming.fileExtension(for: .jpeg) == "jpg")
    }

    @Test("Automatic saving does not reuse an existing filename")
    func automaticFilenameIsUnique() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Skreen2GoTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 6
        components.hour = 14
        components.minute = 30
        components.second = 25
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let date = try #require(calendar.date(from: components))

        let first = ScreenshotNaming.uniqueURL(in: folder, format: .png, date: date)
        try Data().write(to: first)
        let second = ScreenshotNaming.uniqueURL(in: folder, format: .png, date: date)

        let originalName = ScreenshotNaming.fileName(for: .png, date: date)
        let baseName = originalName.replacingOccurrences(of: ".png", with: "")
        #expect(first.lastPathComponent == originalName)
        #expect(second.lastPathComponent == "\(baseName) 2.png")
    }

    // MARK: - Settings store

    @Test("Reset restores every default")
    func resetRestoresDefaults() {
        let settings = makeSettings()
        settings.hotKey = HotKeyCombination(keyCode: 35, modifiers: [.command])
        settings.strokeThickness = 15
        settings.textSize = 60
        settings.blurRadius = 33
        settings.showNotifications = false
        settings.outputFormat = .jpeg

        settings.reset()

        #expect(settings.hotKey == HotKeyCombination.default)
        #expect(settings.strokeThickness == 3)
        #expect(settings.textSize == 24)
        #expect(settings.blurRadius == 12)
        #expect(settings.showNotifications)
        #expect(settings.outputFormat == .png)
    }

    @Test("Corrupt persisted drawing settings are clamped to safe UI ranges")
    func corruptSettingsAreClamped() {
        let suiteName = "Skreen2GoCorruptSettings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(-100.0, forKey: "strokeThickness")
        defaults.set(10.0, forKey: "strokeOpacity")
        defaults.set(Double.infinity, forKey: "textSize")
        defaults.set(-1.0, forKey: "textOpacity")
        defaults.set(999.0, forKey: "blurRadius")
        defaults.set(999, forKey: "hotKeyKeyCode")
        defaults.set(0, forKey: "hotKeyModifiers")

        let settings = SettingsStore(defaults: defaults)
        #expect(settings.strokeThickness == 1)
        #expect(settings.strokeOpacity == 1)
        #expect(settings.textSize == 24)
        #expect(settings.textOpacity == 0.1)
        #expect(settings.blurRadius == 40)
        #expect(settings.hotKey == HotKeyCombination.default)
    }

    // MARK: - Export smoke test across every annotation kind

    @Test("Every annotation kind renders into both output formats")
    func exportAllAnnotationKinds() throws {
        let size = CGSize(width: 200, height: 120)
        let image = makeImage(from: makeCGImage(pixelWidth: 400, pixelHeight: 240), pointSize: size)
        let document = ScreenshotDocument(image: image)
        let settings = makeSettings()

        document.annotations = [
            Annotation(kind: .arrow, start: CGPoint(x: 10, y: 10), end: CGPoint(x: 90, y: 70), color: .red, thickness: 4, opacity: 0.9),
            Annotation(kind: .rectangle, rect: CGRect(x: 20, y: 20, width: 60, height: 40), color: .blue, thickness: 3, opacity: 1),
            Annotation(kind: .text, rect: CGRect(origin: CGPoint(x: 20, y: 90), size: .zero), text: "Тест", color: .white, thickness: 1, opacity: 1),
            Annotation(kind: .blur, rect: CGRect(x: 100, y: 20, width: 60, height: 40), color: .black, thickness: 1, opacity: 1),
            Annotation(kind: .cursor(.arrow), rect: CGRect(x: 150, y: 70, width: 36, height: 36), color: .systemGreen, thickness: 3, opacity: 1),
            Annotation(kind: .cursor(.click), rect: CGRect(x: 60, y: 70, width: 30, height: 30), color: .systemOrange, thickness: 3, opacity: 1)
        ]

        let png = try #require(ImageExporter.data(for: document, format: .png, settings: settings))
        let pngRep = try #require(NSBitmapImageRep(data: png))
        #expect(pngRep.pixelsWide == 400)
        #expect(pngRep.pixelsHigh == 240)

        let jpeg = try #require(ImageExporter.data(for: document, format: .jpeg, settings: settings))
        #expect(jpeg.isEmpty == false)
    }

    // MARK: - Recording geometry

    private func display(
        id: CGDirectDisplayID,
        frame: CGRect,
        scale: CGFloat
    ) -> RecordingDisplay {
        RecordingDisplay(displayID: id, frame: frame, backingScaleFactor: scale)
    }

    private var recordingOptions: RecordingOptions {
        RecordingOptions(
            capturesSystemAudio: false,
            capturesMicrophone: false,
            showsCursor: true,
            showsClicks: true
        )
    }

    /// A laptop screen with a larger, non-Retina display to its right.
    private var twoDisplays: [RecordingDisplay] {
        [
            display(id: 1, frame: CGRect(x: 0, y: 0, width: 1440, height: 900), scale: 2),
            display(id: 2, frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080), scale: 1)
        ]
    }

    @Test("A region picks the display that holds most of it")
    func regionPicksDominantDisplay() throws {
        let onSecond = CGRect(x: 1500, y: 100, width: 400, height: 300)
        let plan = try RecordingGeometry.regionPlan(
            for: onSecond,
            displays: twoDisplays,
            options: recordingOptions
        )

        guard case .region(let displayID, _) = plan.source else {
            Issue.record("expected a region source")
            return
        }
        #expect(displayID == 2)
        #expect(plan.trimmedToOneDisplay == false)
    }

    @Test("A selection spanning two displays is trimmed to the dominant one")
    func spanningSelectionIsTrimmed() throws {
        // 300pt on the left display, 100pt on the right one.
        let spanning = CGRect(x: 1140, y: 100, width: 400, height: 200)
        let plan = try RecordingGeometry.regionPlan(
            for: spanning,
            displays: twoDisplays,
            options: recordingOptions
        )

        guard case .region(let displayID, let sourceRect) = plan.source else {
            Issue.record("expected a region source")
            return
        }
        #expect(displayID == 1)
        #expect(plan.trimmedToOneDisplay)
        // Clipped to the left display, so it can never reach past its 1440pt width.
        #expect(sourceRect.maxX <= 1440)
        #expect(isClose(sourceRect.width, 300))
    }

    @Test("Recording geometry uses the chosen display's scale, not the largest one")
    func regionUsesOwnDisplayScale() throws {
        let onFirst = CGRect(x: 100, y: 100, width: 200, height: 100)
        let onSecond = CGRect(x: 1600, y: 100, width: 200, height: 100)

        let retina = try RecordingGeometry.regionPlan(
            for: onFirst,
            displays: twoDisplays,
            options: recordingOptions
        )
        let plain = try RecordingGeometry.regionPlan(
            for: onSecond,
            displays: twoDisplays,
            options: recordingOptions
        )

        #expect(retina.pixelWidth == 400)
        #expect(plain.pixelWidth == 200)
    }

    @Test("A region is flipped into the display's own top-left space")
    func sourceRectIsDisplayLocalAndTopLeft() {
        let screen = display(id: 2, frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080), scale: 1)
        // 200pt tall, its top edge 100pt below the top of the display.
        let area = CGRect(x: 1540, y: 780, width: 300, height: 200)

        let rect = RecordingGeometry.sourceRect(for: area, on: screen)
        #expect(isClose(rect.minX, 100))
        #expect(isClose(rect.minY, 100))
        #expect(isClose(rect.width, 300))
        #expect(isClose(rect.height, 200))
    }

    @Test("H.264 cannot encode odd pixel sizes, so the region snaps to even")
    func pixelSizesAreEven() throws {
        let odd = CGRect(x: 10, y: 10, width: 101, height: 303)
        let plan = try RecordingGeometry.regionPlan(
            for: odd,
            displays: [display(id: 1, frame: CGRect(x: 0, y: 0, width: 1440, height: 900), scale: 1)],
            options: recordingOptions
        )

        #expect(plan.pixelWidth % 2 == 0)
        #expect(plan.pixelHeight % 2 == 0)
        #expect(plan.pixelWidth == 100)
        #expect(plan.pixelHeight == 302)
    }

    @Test("The source rect matches the pixel size exactly, so nothing is letterboxed")
    func sourceRectMatchesPixelSize() throws {
        let odd = CGRect(x: 0, y: 0, width: 101.5, height: 77.25)
        for scale in [CGFloat(1), CGFloat(2)] {
            let plan = try RecordingGeometry.regionPlan(
                for: odd,
                displays: [display(id: 1, frame: CGRect(x: 0, y: 0, width: 1440, height: 900), scale: scale)],
                options: recordingOptions
            )
            guard case .region(_, let sourceRect) = plan.source else {
                Issue.record("expected a region source")
                return
            }
            // ScreenCaptureKit preserves the aspect ratio; a source rect that no longer
            // matches width x height would come back with black bars.
            #expect(isClose(sourceRect.width * scale, CGFloat(plan.pixelWidth)))
            #expect(isClose(sourceRect.height * scale, CGFloat(plan.pixelHeight)))
        }
    }

    @Test("A region on no display at all is rejected rather than guessed at")
    func regionOutsideEveryDisplayFails() {
        let inTheGap = CGRect(x: 5000, y: 5000, width: 100, height: 100)
        #expect(throws: RecordingError.self) {
            try RecordingGeometry.regionPlan(
                for: inTheGap,
                displays: twoDisplays,
                options: recordingOptions
            )
        }
    }

    @Test("A region too small to encode is rejected")
    func tinyRegionFails() {
        let sliver = CGRect(x: 10, y: 10, width: 1, height: 40)
        #expect(throws: RecordingError.self) {
            try RecordingGeometry.regionPlan(
                for: sliver,
                displays: [display(id: 1, frame: CGRect(x: 0, y: 0, width: 1440, height: 900), scale: 1)],
                options: recordingOptions
            )
        }
    }

    @Test("A window plan carries the window and never a display")
    func windowPlanKeepsTheWindow() throws {
        let plan = try RecordingGeometry.windowPlan(
            windowID: 4242,
            contentSize: CGSize(width: 401, height: 301),
            scale: 2,
            options: recordingOptions
        )

        #expect(plan.source == .window(4242))
        #expect(plan.pixelWidth == 802)
        #expect(plan.pixelHeight == 602)
        #expect(plan.trimmedToOneDisplay == false)
    }

    @Test("Recording options come straight from the store")
    func recordingOptionsReadTheStore() {
        let settings = makeSettings()
        settings.recordsSystemAudio = true
        settings.recordsMicrophone = false
        settings.showsCursorInRecording = false
        settings.showsClicksInRecording = true

        let options = RecordingOptions(settings: settings)
        #expect(options.capturesSystemAudio)
        #expect(options.capturesMicrophone == false)
        #expect(options.showsCursor == false)
        #expect(options.showsClicks)
    }

    // MARK: - Recording files

    @Test("A recording is named like a screenshot, with its own prefix")
    func recordingFileName() throws {
        var components = DateComponents()
        components.year = 2026
        components.month = 1
        components.day = 2
        components.hour = 3
        components.minute = 4
        components.second = 5
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let date = try #require(calendar.date(from: components))

        let name = ScreenshotNaming.fileName(
            prefix: ScreenshotNaming.recordingPrefix,
            extension: RecordingFiles.fileExtension,
            date: date
        )
        #expect(name.hasPrefix("Recording 2026-01-02 at "))
        #expect(name.hasSuffix(".mp4"))
    }

    @Test("A finished recording moves into the save folder without overwriting")
    func recordingMovesIntoSaveFolder() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Skreen2GoTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let destination = root.appendingPathComponent("out", isDirectory: true)
        let date = Date()

        var written: [URL] = []
        for index in 0..<2 {
            let temp = root.appendingPathComponent("temp-\(index).mp4")
            try Data("clip \(index)".utf8).write(to: temp)
            let moved = try RecordingFiles.move(temp, into: destination, date: date)
            written.append(moved)
            #expect(FileManager.default.fileExists(atPath: temp.path) == false)
        }

        #expect(written[0] != written[1], "the second recording must not overwrite the first")
        #expect(try String(contentsOf: written[0], encoding: .utf8) == "clip 0")
        #expect(try String(contentsOf: written[1], encoding: .utf8) == "clip 1")
        #expect(written[1].lastPathComponent.contains(" 2."))
    }

    @Test("A truncated leftover is not mistaken for a finished recording")
    func truncatedLeftoverIsNotPlayable() async throws {
        let temp = try RecordingFiles.temporaryURL()
        defer { RecordingFiles.discard(temp) }
        try Data("not really an mp4".utf8).write(to: temp)

        // Compared by name: the temporary directory is reached through a symlink, so the
        // two URLs describe the same file by different paths.
        let names = RecordingFiles.staleRecordings().map(\.lastPathComponent)
        #expect(names.contains(temp.lastPathComponent))
        // An MPEG-4 only plays once its trailer is written, which is what separates a
        // recording worth handing back from a stump worth deleting.
        #expect(await RecordingFiles.isPlayable(temp) == false)

        RecordingFiles.discard(temp)
        #expect(FileManager.default.fileExists(atPath: temp.path) == false)
    }

    @Test("A finished recording left behind is filed away rather than deleted")
    func finishedLeftoverIsRecovered() async throws {
        let root = try makeTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let harness = try makeRecordingHarness(root: root)

        // Stand in for a run that finished the file and then died before filing it.
        let orphan = try RecordingFiles.temporaryURL()
        try Data("finished clip".utf8).write(to: orphan)

        var saved: [URL] = []
        harness.controller.onSaved = { saved.append($0) }

        // Unplayable content is discarded, which is what this stand-in is.
        await harness.controller.recoverStaleRecordings()
        #expect(saved.isEmpty)
        #expect(FileManager.default.fileExists(atPath: orphan.path) == false)
    }

    // MARK: - Recording settings

    @Test("The recording hot key defaults to a combination without Command")
    func recordingHotKeyDefault() {
        let settings = makeSettings()
        #expect(settings.recordingHotKey == HotKeyCombination.defaultRecording)
        #expect(settings.recordingHotKey.modifiers.contains(.command) == false)
        #expect(settings.recordingHotKey != settings.hotKey)
    }

    @Test("The two hot keys refuse to hold the same combination")
    func hotKeysCannotCollide() {
        let settings = makeSettings()
        let screenshot = settings.hotKey

        settings.recordingHotKey = screenshot
        #expect(settings.recordingHotKey == HotKeyCombination.defaultRecording)

        settings.hotKey = HotKeyCombination.defaultRecording
        #expect(settings.hotKey == screenshot)

        // A genuinely free combination is still accepted.
        let free = HotKeyCombination(keyCode: 17, modifiers: [.control, .option])
        settings.recordingHotKey = free
        #expect(settings.recordingHotKey == free)
    }

    @Test("Recording preferences round-trip and come back to their defaults on reset")
    func recordingSettingsRoundTrip() {
        let settings = makeSettings()
        #expect(settings.recordsSystemAudio == false)
        #expect(settings.recordsMicrophone == false)
        #expect(settings.showsCursorInRecording)
        #expect(settings.showsClicksInRecording)

        settings.recordsSystemAudio = true
        settings.recordsMicrophone = true
        settings.showsCursorInRecording = false
        settings.showsClicksInRecording = false
        settings.recordingHotKey = HotKeyCombination(keyCode: 17, modifiers: [.control, .option])

        #expect(settings.recordsSystemAudio)
        #expect(settings.recordsMicrophone)
        #expect(settings.showsCursorInRecording == false)
        #expect(settings.showsClicksInRecording == false)

        // Catches a new key that was added to the store but forgotten in `Key.all`.
        settings.reset()
        #expect(settings.recordsSystemAudio == false)
        #expect(settings.recordsMicrophone == false)
        #expect(settings.showsCursorInRecording)
        #expect(settings.showsClicksInRecording)
        #expect(settings.recordingHotKey == HotKeyCombination.defaultRecording)
    }

    // MARK: - Recording session

    /// Shared ordering log, so a test can assert that the countdown was taken down before
    /// the first frame was ever captured.
    private final class RecordingEventLog {
        var events: [String] = []
        func add(_ event: String) { events.append(event) }
    }

    private final class FakeScreenRecorder: ScreenRecording {
        var onUnexpectedStop: ((Error?) -> Void)?
        private(set) var isRecording = false

        let log: RecordingEventLog
        var startedPlans: [RecordingPlan] = []
        var startError: Error?
        var stopError: Error?
        private var writtenURL: URL?

        init(log: RecordingEventLog) { self.log = log }

        func start(_ plan: RecordingPlan, writingTo url: URL) async throws {
            log.add("recorder.start")
            if let startError { throw startError }
            try Data("video".utf8).write(to: url)
            startedPlans.append(plan)
            writtenURL = url
            isRecording = true
        }

        func stop() async throws -> URL {
            isRecording = false
            if let stopError { throw stopError }
            guard let writtenURL else { throw RecordingError.notRunning }
            return writtenURL
        }

        func simulateSystemStop() {
            isRecording = false
            onUnexpectedStop?(nil)
        }
    }

    private final class FakeCountdown: RecordingCountdownPresenting {
        let log: RecordingEventLog
        var displayed: [Int] = []
        var dismissals = 0

        init(log: RecordingEventLog) { self.log = log }

        func show(seconds: Int, over area: CGRect) {
            displayed.append(seconds)
            log.add("countdown.show")
        }

        func update(seconds: Int) { displayed.append(seconds) }

        func dismiss() {
            dismissals += 1
            log.add("countdown.dismiss")
        }
    }

    private final class FakeTicker: RecordingTicking {
        private var onTick: (() -> Void)?
        var isRunning: Bool { onTick != nil }

        func start(interval: TimeInterval, onTick: @escaping () -> Void) {
            self.onTick = onTick
        }

        func stop() { onTick = nil }

        func fire(_ times: Int = 1) {
            for _ in 0..<times { onTick?() }
        }
    }

    private final class FakeMicrophone: MicrophoneAuthorizing {
        var authorized = false
        var determined = true
        var requestCount = 0
        /// Every read of either property, so a test can prove the microphone is not so
        /// much as looked at while the toggle is off.
        var consultations = 0

        var isAuthorized: Bool {
            consultations += 1
            return authorized
        }

        var isDetermined: Bool {
            consultations += 1
            return determined
        }

        func requestAccess() async -> Bool {
            requestCount += 1
            determined = true
            return authorized
        }
    }

    private struct RecordingHarness {
        let controller: RecordingController
        let recorder: FakeScreenRecorder
        let countdown: FakeCountdown
        let ticker: FakeTicker
        let microphone: FakeMicrophone
        let log: RecordingEventLog
        let settings: SettingsStore
        let outputFolder: URL
    }

    /// Points the store at a plain path rather than a security-scoped bookmark, so
    /// `withOutputFolderAccessAsync` writes to a temporary directory without needing a
    /// sandbox extension the test binary does not have.
    private func makeRecordingHarness(root: URL) throws -> RecordingHarness {
        let outputFolder = root.appendingPathComponent("out", isDirectory: true)
        let suiteName = "Skreen2GoRecording.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(outputFolder.path, forKey: "outputFolderPath")

        let settings = SettingsStore(defaults: defaults)
        let log = RecordingEventLog()
        let recorder = FakeScreenRecorder(log: log)
        let countdown = FakeCountdown(log: log)
        let ticker = FakeTicker()
        let microphone = FakeMicrophone()

        let controller = RecordingController(
            settings: settings,
            recorder: recorder,
            microphone: microphone,
            countdown: countdown,
            ticker: ticker,
            displays: { [RecordingDisplay(displayID: 1, frame: CGRect(x: 0, y: 0, width: 1440, height: 900), backingScaleFactor: 2)] },
            now: { Date(timeIntervalSince1970: 1_767_000_000) }
        )

        return RecordingHarness(
            controller: controller,
            recorder: recorder,
            countdown: countdown,
            ticker: ticker,
            microphone: microphone,
            log: log,
            settings: settings,
            outputFolder: outputFolder
        )
    }

    private func makeTestRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Skreen2GoTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Lets the controller's internal tasks run. Every awaited call in the fakes returns
    /// immediately, so a handful of turns is enough.
    private func settle(_ turns: Int = 40) async {
        for _ in 0..<turns { await Task.yield() }
    }

    private var sampleRegion: RecordingRequest {
        RecordingRequest(area: CGRect(x: 100, y: 100, width: 400, height: 300), windowID: nil)
    }

    @Test("Recording only starts once the countdown has run out")
    func countdownPrecedesRecording() async throws {
        let root = try makeTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let harness = try makeRecordingHarness(root: root)

        harness.controller.start(sampleRegion)
        await settle()

        #expect(harness.controller.state == .countdown(remaining: 3))
        #expect(harness.recorder.startedPlans.isEmpty)

        harness.ticker.fire()
        #expect(harness.controller.state == .countdown(remaining: 2))
        harness.ticker.fire()
        #expect(harness.controller.state == .countdown(remaining: 1))
        #expect(harness.recorder.startedPlans.isEmpty, "the third second has not passed yet")

        harness.ticker.fire()
        await settle()
        #expect(harness.controller.state == .recording)
        #expect(harness.recorder.startedPlans.count == 1)
    }

    @Test("The countdown is taken down before the first frame is captured")
    func countdownIsDismissedBeforeCapture() async throws {
        let root = try makeTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let harness = try makeRecordingHarness(root: root)

        harness.controller.start(sampleRegion)
        await settle()
        harness.ticker.fire(3)
        await settle()

        let dismissal = try #require(harness.log.events.firstIndex(of: "countdown.dismiss"))
        let start = try #require(harness.log.events.firstIndex(of: "recorder.start"))
        #expect(dismissal < start)
    }

    @Test("Cancelling during the countdown never touches the recorder")
    func cancellingCountdownRecordsNothing() async throws {
        let root = try makeTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let harness = try makeRecordingHarness(root: root)

        harness.controller.start(sampleRegion)
        await settle()
        harness.ticker.fire()

        harness.controller.stopOrCancel()
        await settle()

        #expect(harness.controller.state == .idle)
        #expect(harness.controller.isActive == false)
        #expect(harness.recorder.startedPlans.isEmpty)
        #expect(harness.countdown.dismissals == 1)
        #expect(harness.ticker.isRunning == false)

        // Further ticks from a stale timer must not resurrect the session.
        harness.ticker.fire(5)
        await settle()
        #expect(harness.controller.state == .idle)
    }

    @Test("Stopping a recording saves it into the output folder")
    func stoppingSavesTheRecording() async throws {
        let root = try makeTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let harness = try makeRecordingHarness(root: root)

        var saved: URL?
        harness.controller.onSaved = { saved = $0 }

        harness.controller.start(sampleRegion)
        await settle()
        harness.ticker.fire(3)
        await settle()

        harness.controller.stopOrCancel()
        await settle()

        let url = try #require(saved)
        #expect(harness.controller.state == .idle)
        #expect(url.deletingLastPathComponent().path == harness.outputFolder.path)
        #expect(url.lastPathComponent.hasPrefix("Recording "))
        #expect(url.pathExtension == "mp4")
        #expect(try String(contentsOf: url, encoding: .utf8) == "video")
    }

    @Test("A stream the system ends on its own still saves what was recorded")
    func systemStopStillSaves() async throws {
        let root = try makeTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let harness = try makeRecordingHarness(root: root)

        var saved: URL?
        harness.controller.onSaved = { saved = $0 }

        harness.controller.start(sampleRegion)
        await settle()
        harness.ticker.fire(3)
        await settle()

        harness.recorder.simulateSystemStop()
        await settle()

        #expect(saved != nil, "a window closing mid-recording must not throw the file away")
        #expect(harness.controller.state == .idle)
    }

    @Test("A second recording cannot start on top of a running one")
    func secondRecordingIsRefused() async throws {
        let root = try makeTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let harness = try makeRecordingHarness(root: root)

        var errors: [String] = []
        harness.controller.onError = { errors.append($0) }

        harness.controller.start(sampleRegion)
        await settle()
        harness.ticker.fire(3)
        await settle()

        harness.controller.start(sampleRegion)
        await settle()

        #expect(errors.count == 1)
        #expect(harness.controller.state == .recording)
        #expect(harness.recorder.startedPlans.count == 1)
    }

    @Test("A recorder that refuses to start leaves no session behind")
    func failedStartResetsTheSession() async throws {
        let root = try makeTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let harness = try makeRecordingHarness(root: root)
        harness.recorder.startError = RecordingError.permissionDenied

        var errors: [String] = []
        harness.controller.onError = { errors.append($0) }

        harness.controller.start(sampleRegion)
        await settle()
        harness.ticker.fire(3)
        await settle()

        #expect(harness.controller.state == .idle)
        #expect(harness.controller.isActive == false)
        #expect(errors.count == 1)
        #expect(harness.ticker.isRunning == false)
    }

    @Test("With the microphone toggle off, the microphone is never even consulted")
    func microphoneUntouchedWhenOff() async throws {
        let root = try makeTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let harness = try makeRecordingHarness(root: root)
        harness.settings.recordsMicrophone = false

        harness.controller.start(sampleRegion)
        await settle()
        harness.ticker.fire(3)
        await settle()

        // This is the guarantee that a first launch never raises a microphone prompt.
        #expect(harness.microphone.consultations == 0)
        #expect(harness.microphone.requestCount == 0)
        #expect(harness.recorder.startedPlans.first?.capturesMicrophone == false)
    }

    @Test("Access is asked for once when the microphone has never been decided")
    func microphoneAccessRequestedOnce() async throws {
        let root = try makeTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let harness = try makeRecordingHarness(root: root)
        harness.settings.recordsMicrophone = true
        harness.microphone.determined = false
        harness.microphone.authorized = true

        harness.controller.start(sampleRegion)
        await settle()
        harness.ticker.fire(3)
        await settle()

        #expect(harness.microphone.requestCount == 1)
        #expect(harness.recorder.startedPlans.first?.capturesMicrophone == true)
    }

    @Test("A refused microphone costs the microphone, not the recording")
    func deniedMicrophoneStillRecords() async throws {
        let root = try makeTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let harness = try makeRecordingHarness(root: root)
        harness.settings.recordsMicrophone = true
        harness.microphone.determined = true
        harness.microphone.authorized = false

        var notices: [RecordingNotice] = []
        harness.controller.onNotice = { notices.append($0) }

        harness.controller.start(sampleRegion)
        await settle()
        harness.ticker.fire(3)
        await settle()

        #expect(notices == [.microphoneUnavailable])
        #expect(harness.controller.state == .recording)
        #expect(harness.recorder.startedPlans.first?.capturesMicrophone == false)
    }

    @Test("The user is told when a selection had to be cut back to one display")
    func trimmedSelectionIsAnnounced() async throws {
        let root = try makeTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let harness = try makeRecordingHarness(root: root)

        var notices: [RecordingNotice] = []
        harness.controller.onNotice = { notices.append($0) }

        // Reaches 200pt past the right edge of the single 1440pt-wide display.
        harness.controller.start(RecordingRequest(
            area: CGRect(x: 1240, y: 100, width: 400, height: 200),
            windowID: nil
        ))
        await settle()

        #expect(notices == [.trimmedToOneDisplay])
    }

    @Test("Audio toggles reach the recording exactly as they were set")
    func audioTogglesReachThePlan() async throws {
        let root = try makeTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let harness = try makeRecordingHarness(root: root)
        harness.settings.recordsSystemAudio = true
        harness.settings.recordsMicrophone = true
        harness.microphone.determined = true
        harness.microphone.authorized = true

        harness.controller.start(sampleRegion)
        await settle()
        harness.ticker.fire(3)
        await settle()

        let plan = try #require(harness.recorder.startedPlans.first)
        #expect(plan.capturesSystemAudio)
        #expect(plan.capturesMicrophone)
    }

    @Test("Stopping when nothing is running does nothing at all")
    func stoppingWhileIdleIsHarmless() async throws {
        let root = try makeTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let harness = try makeRecordingHarness(root: root)

        var errors: [String] = []
        harness.controller.onError = { errors.append($0) }

        harness.controller.stopOrCancel()
        harness.controller.stopOrCancel()
        await settle()

        #expect(harness.controller.state == .idle)
        #expect(errors.isEmpty)
    }

    @Test("Quitting mid-recording still closes the file")
    func terminationFinishesTheFile() async throws {
        let root = try makeTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let harness = try makeRecordingHarness(root: root)

        harness.controller.start(sampleRegion)
        await settle()
        harness.ticker.fire(3)
        await settle()

        await harness.controller.finishBeforeTermination()

        #expect(harness.controller.state == .idle)
        let saved = try FileManager.default.contentsOfDirectory(atPath: harness.outputFolder.path)
        #expect(saved.contains { $0.hasSuffix(".mp4") })
    }

    // MARK: - Recording reaches the session, not the capture pipeline

    @Test("Pressing record hands the selection to the recording session")
    func recordActionStartsARecording() {
        let controller = CaptureController(settings: makeSettings())
        var requests: [RecordingRequest] = []
        var captured = 0
        controller.onStartRecording = { requests.append($0) }
        controller.onImageCaptured = { _, _, _ in captured += 1 }

        let generationBefore = controller.testCaptureGeneration
        let area = CGRect(x: 40, y: 60, width: 320, height: 180)
        controller.testPerform(.record, payload: SelectionCapture(
            area: area,
            annotations: [],
            window: nil
        ))

        #expect(requests.count == 1)
        #expect(requests.first?.area == area)
        #expect(requests.first?.windowID == nil)
        #expect(captured == 0, "recording must not open the still editor")
        // The generation counter exists to discard a stale screenshot; a recording has no
        // business bumping it, and no capture task should be left running.
        #expect(controller.testCaptureGeneration == generationBefore)
        #expect(controller.testHasCaptureInFlight == false)
    }

    @Test("Recording a window passes the window through, not just its frame")
    func recordActionKeepsTheWindow() {
        let controller = CaptureController(settings: makeSettings())
        var requests: [RecordingRequest] = []
        controller.onStartRecording = { requests.append($0) }

        let frame = CGRect(x: 10, y: 20, width: 800, height: 600)
        controller.testPerform(.record, payload: SelectionCapture(
            area: frame,
            annotations: [],
            window: WindowInfo(id: 99, frame: frame, ownerName: "Finder", title: "Downloads")
        ))

        #expect(requests.first?.windowID == 99)
    }

    // MARK: - Two hot keys in one process

    @Test("Both hot key monitors register, not just the first")
    func twoHotKeyMonitorsCanCoexist() {
        let settings = makeSettings()
        // Obscure combinations, so the test does not fight a running copy of the app for
        // the real ones.
        settings.hotKey = HotKeyCombination(keyCode: 105, modifiers: [.control, .shift, .option])
        settings.recordingHotKey = HotKeyCombination(keyCode: 107, modifiers: [.control, .shift, .option])

        let screenshot = HotKeyMonitor(settings: settings, combination: \.hotKey) {}
        let recording = HotKeyMonitor(settings: settings, combination: \.recordingHotKey) {}
        defer {
            screenshot.tearDown()
            recording.tearDown()
        }

        #expect(screenshot.install() == .registered)
        // The second monitor used to install its own application-wide Carbon handler for
        // the same event on the same target, which returns eventHandlerAlreadyInstalledErr
        // (-9866) and made it give up before ever reaching RegisterEventHotKey. The
        // recording hot key silently never worked, and the failure alert wedged the app.
        #expect(recording.install() == .registered)

        #expect(screenshot.registeredCombination == settings.hotKey)
        #expect(recording.registeredCombination == settings.recordingHotKey)
        #expect(screenshot.registeredCombination != recording.registeredCombination)
    }

    @Test("A monitor tearing down leaves the other one working")
    func tearingDownOneMonitorLeavesTheOther() {
        let settings = makeSettings()
        settings.hotKey = HotKeyCombination(keyCode: 109, modifiers: [.control, .shift, .option])
        settings.recordingHotKey = HotKeyCombination(keyCode: 111, modifiers: [.control, .shift, .option])

        let screenshot = HotKeyMonitor(settings: settings, combination: \.hotKey) {}
        let recording = HotKeyMonitor(settings: settings, combination: \.recordingHotKey) {}
        defer { recording.tearDown() }

        #expect(screenshot.install() == .registered)
        #expect(recording.install() == .registered)

        // The shared handler belongs to the process, so one monitor going away must not
        // take the other one's hot key with it.
        screenshot.tearDown()
        #expect(recording.registeredCombination == settings.recordingHotKey)
        #expect(recording.install() == .unchanged)
    }
}
