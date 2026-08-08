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

    private func makeOverlay(size: CGSize = CGSize(width: 1200, height: 800)) -> CaptureOverlayView {
        CaptureOverlayView(frame: CGRect(origin: .zero, size: size), settings: makeSettings())
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

    @Test("Reset also unregisters the system login item")
    func resetUnregistersLoginItem() throws {
        // The system side cannot be exercised in a unit test, so pin the wiring instead:
        // resetSettings() must go through LaunchAtLogin, not stop at UserDefaults.
        let path = #filePath.replacingOccurrences(
            of: "/Tests/Skreen2GoCoreTests/RegressionTests.swift",
            with: "/Sources/Skreen2GoCore/Settings.swift"
        )
        let source = try String(contentsOfFile: path, encoding: .utf8)
        let reset = try #require(source.range(of: "func resetSettings()"))
        let body = String(source[reset.lowerBound...].prefix(600))

        #expect(body.contains("settings.reset()"))
        #expect(body.contains("LaunchAtLogin.disableIfEnabled"), "reset leaves the login item registered")
    }

    // MARK: - Action confirmations

    @Test("Copying reports that it succeeded")
    func copyOutcomeWording() {
        let outcome = ScreenshotOutcome.copied
        #expect(outcome.title == "Успешно скопировано")
        #expect(outcome.toastDetail.isEmpty == false)
        #expect(outcome.symbolName.isEmpty == false)
    }

    @Test("Saving reports success and names the file")
    func saveOutcomeWording() {
        let url = URL(fileURLWithPath: "/Users/someone/Downloads/Screenshot 2026-08-08 at 12.00.00.png")
        let outcome = ScreenshotOutcome.saved(url)

        #expect(outcome.title == "Успешно сохранено")
        #expect(outcome.toastDetail == "Screenshot 2026-08-08 at 12.00.00.png")
    }

    @Test("Exactly one confirmation channel is wired up")
    func onlyTheToastConfirms() {
        // Guards against the duplicate-notification regression: nothing may post to
        // UNUserNotificationCenter alongside the toast.
        let sources = try! FileManager.default.contentsOfDirectory(
            atPath: #filePath.replacingOccurrences(
                of: "/Tests/Skreen2GoCoreTests/RegressionTests.swift",
                with: "/Sources/Skreen2GoCore"
            )
        )
        for name in sources where name.hasSuffix(".swift") {
            let path = #filePath.replacingOccurrences(
                of: "/Tests/Skreen2GoCoreTests/RegressionTests.swift",
                with: "/Sources/Skreen2GoCore/" + name
            )
            let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            #expect(
                text.contains("UNUserNotificationCenter.current().add") == false,
                "\(name) posts a system notification — that would double up with the toast"
            )
        }
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
        // save-as, cancel.
        #expect(hints.count == 11, "found hints: \(hints.sorted())")
        #expect(hints.contains("Стрелка"))
        #expect(hints.contains("Цвет"))
        #expect(hints.contains("Настройки"))
    }

    @Test("Hovering a control makes its hint the active one")
    func hoveringSetsActiveHint() throws {
        let overlay = makeOverlay(size: CGSize(width: 1200, height: 800))
        overlay.testSetSelection(CGRect(x: 200, y: 300, width: 500, height: 300))
        overlay.testShowActionBar()
        overlay.testLayoutActionBar()

        let bar = try #require(overlay.testActionBarFrame)
        #expect(overlay.testActiveHint == nil)

        // First control from the left is the arrow tool.
        overlay.testForceHint(at: CGPoint(x: bar.minX + 22, y: bar.midY))
        #expect(overlay.testActiveHint == "Стрелка")
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
}
