import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

struct WindowInfo {
    let id: CGWindowID
    let frame: CGRect
    let ownerName: String
    let title: String
}

enum CaptureError: LocalizedError {
    case permissionDenied
    case windowUnavailable
    case displayUnavailable
    case renderFailed
    case underlying(Error)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "error.capture.permissionDenied".localized("No screen recording access. Enable Skreen2Go in System Settings → Privacy & Security → Screen Recording, then restart the app.")
        case .windowUnavailable:
            return "error.capture.windowUnavailable".localized("The window disappeared before the screenshot could be taken.")
        case .displayUnavailable:
            return "error.capture.displayUnavailable".localized("Could not work out which display the selected region is on.")
        case .renderFailed:
            return "error.capture.renderFailed".localized("Could not assemble an image from the captured data.")
        case .underlying(let error):
            return "error.capture.underlying".localized("Could not take the screenshot: %@", error.localizedDescription)
        }
    }
}

enum ScreenGeometry {
    static func displayID(for screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            ?? CGMainDisplayID()
    }

    static func quartzPoint(for cocoaPoint: CGPoint) -> CGPoint? {
        guard let screen = screen(containingCocoaPoint: cocoaPoint) else { return nil }
        let displayBounds = CGDisplayBounds(displayID(for: screen))
        let scaleX = displayBounds.width / screen.frame.width
        let scaleY = displayBounds.height / screen.frame.height
        let localX = (cocoaPoint.x - screen.frame.minX) * scaleX
        let localYFromTop = (screen.frame.maxY - cocoaPoint.y) * scaleY
        return CGPoint(x: displayBounds.minX + localX, y: displayBounds.minY + localYFromTop)
    }

    /// `NSRect.contains` excludes the top and right edges, which loses the cursor on the
    /// last row of pixels of a display; nudge such points back inside before matching.
    static func screen(containingCocoaPoint point: CGPoint) -> NSScreen? {
        if let exact = NSScreen.screens.first(where: { $0.frame.contains(point) }) { return exact }
        return NSScreen.screens.first { screen in
            let frame = screen.frame.insetBy(dx: -0.5, dy: -0.5)
            return frame.contains(point)
        }
    }

    static func quartzRect(for cocoaRect: CGRect, on screen: NSScreen) -> CGRect {
        let displayBounds = CGDisplayBounds(displayID(for: screen))
        let scaleX = displayBounds.width / screen.frame.width
        let scaleY = displayBounds.height / screen.frame.height
        let x = displayBounds.minX + (cocoaRect.minX - screen.frame.minX) * scaleX
        let y = displayBounds.minY + (screen.frame.maxY - cocoaRect.maxY) * scaleY
        return CGRect(
            x: x,
            y: y,
            width: cocoaRect.width * scaleX,
            height: cocoaRect.height * scaleY
        )
    }

    /// Rect relative to the display's own top-left corner, in points — the coordinate
    /// system `SCStreamConfiguration.sourceRect` expects.
    static func displayLocalRect(for cocoaRect: CGRect, on screen: NSScreen) -> CGRect {
        CGRect(
            x: cocoaRect.minX - screen.frame.minX,
            y: screen.frame.maxY - cocoaRect.maxY,
            width: cocoaRect.width,
            height: cocoaRect.height
        )
    }

    /// Picks the display that actually holds most of the rect. Matching the *first*
    /// intersecting screen converted windows straddling two displays using the wrong
    /// display's scale factor.
    static func screen(bestMatchingQuartzRect quartzRect: CGRect) -> NSScreen? {
        NSScreen.screens
            .compactMap { screen -> (NSScreen, CGFloat)? in
                let overlap = CGDisplayBounds(displayID(for: screen)).intersection(quartzRect)
                guard !overlap.isNull, overlap.width > 0, overlap.height > 0 else { return nil }
                return (screen, overlap.width * overlap.height)
            }
            .max { $0.1 < $1.1 }?
            .0
    }

    /// Picks the physical display that owns most of a Cocoa-space rectangle. The
    /// union frame used by the overlay can contain gaps between displays, so callers
    /// should use this instead of treating the union as one giant screen.
    static func screen(bestMatchingCocoaRect cocoaRect: CGRect) -> NSScreen? {
        NSScreen.screens
            .compactMap { screen -> (NSScreen, CGFloat)? in
                let overlap = screen.frame.intersection(cocoaRect)
                guard !overlap.isNull, overlap.width > 0, overlap.height > 0 else { return nil }
                return (screen, overlap.width * overlap.height)
            }
            .max { $0.1 < $1.1 }?
            .0
    }

    static func visibleCocoaFrame(for cocoaRect: CGRect) -> CGRect? {
        screen(bestMatchingCocoaRect: cocoaRect)?.visibleFrame
    }

    static func cocoaRect(for quartzRect: CGRect) -> CGRect? {
        guard let screen = screen(bestMatchingQuartzRect: quartzRect) else { return nil }

        let displayBounds = CGDisplayBounds(displayID(for: screen))
        let scaleX = screen.frame.width / displayBounds.width
        let scaleY = screen.frame.height / displayBounds.height
        let x = screen.frame.minX + (quartzRect.minX - displayBounds.minX) * scaleX
        let y = screen.frame.minY + (displayBounds.maxY - quartzRect.maxY) * scaleY
        return CGRect(
            x: x,
            y: y,
            width: quartzRect.width * scaleX,
            height: quartzRect.height * scaleY
        )
    }

    static func windowAtCocoaPoint(_ cocoaPoint: CGPoint) -> WindowInfo? {
        guard let quartzPoint = quartzPoint(for: cocoaPoint) else { return nil }
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return nil }

        let ownPID = ProcessInfo.processInfo.processIdentifier

        for window in windowList {
            guard
                let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue,
                layer == 0,
                let alpha = (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue,
                alpha > 0.01,
                let pid = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                pid != ownPID,
                let boundsDictionary = window[kCGWindowBounds as String] as? NSDictionary,
                let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary),
                bounds.width > 20,
                bounds.height > 20,
                bounds.contains(quartzPoint),
                let windowNumber = (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                let cocoaFrame = cocoaRect(for: bounds)
            else { continue }

            let owner = window[kCGWindowOwnerName as String] as? String ?? ""
            let title = window[kCGWindowName as String] as? String ?? ""
            return WindowInfo(id: windowNumber, frame: cocoaFrame, ownerName: owner, title: title)
        }

        return nil
    }
}

/// Builds an `NSImage` that keeps a real `NSBitmapImageRep`, so downstream code can
/// recover the pixel dimensions. `NSImage(cgImage:size:)` produces an
/// `NSCGImageSnapshotRep` instead, which used to make the exporter silently fall back
/// to 1x and throw away Retina detail.
func makeImage(from cgImage: CGImage, pointSize: CGSize) -> NSImage {
    let representation = NSBitmapImageRep(cgImage: cgImage)
    representation.size = pointSize
    let image = NSImage(size: pointSize)
    image.addRepresentation(representation)
    return image
}

@MainActor
final class ScreenshotCapture: ScreenshotCapturing {
    /// `SCStreamErrorDomain` code for "the user declined screen recording".
    private static let userDeclinedErrorCode = -3801

    var hasScreenRecordingAccess: Bool {
        CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    func requestScreenRecordingAccessIfNeeded() -> Bool {
        guard !hasScreenRecordingAccess else { return true }
        return CGRequestScreenCaptureAccess()
    }

    private func shareableContent() async throws -> SCShareableContent {
        guard hasScreenRecordingAccess else { throw CaptureError.permissionDenied }
        do {
            return try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            if (error as NSError).code == Self.userDeclinedErrorCode { throw CaptureError.permissionDenied }
            throw CaptureError.underlying(error)
        }
    }

    private func captureImage(filter: SCContentFilter, configuration: SCStreamConfiguration) async throws -> CGImage {
        do {
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        } catch {
            if (error as NSError).code == Self.userDeclinedErrorCode { throw CaptureError.permissionDenied }
            throw CaptureError.underlying(error)
        }
    }

    func captureWindow(_ window: WindowInfo) async throws -> NSImage {
        let content = try await shareableContent()
        guard let target = content.windows.first(where: { $0.windowID == window.id }) else {
            throw CaptureError.windowUnavailable
        }

        let filter = SCContentFilter(desktopIndependentWindow: target)
        let contentRect = filter.contentRect
        guard contentRect.width > 0, contentRect.height > 0 else { throw CaptureError.windowUnavailable }
        let scale = CGFloat(filter.pointPixelScale)

        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int((contentRect.width * scale).rounded()))
        configuration.height = max(1, Int((contentRect.height * scale).rounded()))
        configuration.captureResolution = .best
        configuration.scalesToFit = false
        configuration.showsCursor = false
        // PRD §4: neither the drop shadow nor the rounded corner mask belongs in the shot.
        configuration.ignoreShadowsSingleWindow = true
        configuration.ignoreGlobalClipSingleWindow = true

        let cgImage = try await captureImage(filter: filter, configuration: configuration)
        return makeImage(from: cgImage, pointSize: contentRect.size)
    }

    func captureArea(_ area: CGRect) async throws -> NSImage {
        let content = try await shareableContent()
        // Excluding our own process is what keeps the dimming overlay out of the
        // screenshot — previously this relied on `orderOut` winning a race against the
        // window server.
        let ownApplications = content.applications.filter {
            $0.processID == ProcessInfo.processInfo.processIdentifier
        }

        let screens = NSScreen.screens.filter { $0.frame.intersects(area) }
        guard !screens.isEmpty else { throw CaptureError.displayUnavailable }

        // The composite has one consistent output scale, but each display must be
        // requested at its own scale. A Retina display next to a 1x display used to
        // make the latter request too many pixels and produce distorted tiles.
        let scale = screens.map(\.backingScaleFactor).max() ?? 1
        let pixelWidth = max(1, Int((area.width * scale).rounded()))
        let pixelHeight = max(1, Int((area.height * scale).rounded()))

        var tiles: [(image: CGImage, rect: CGRect)] = []
        for screen in screens {
            let intersection = area.intersection(screen.frame)
            guard !intersection.isNull, intersection.width > 1, intersection.height > 1 else { continue }
            guard let display = content.displays.first(where: {
                $0.displayID == ScreenGeometry.displayID(for: screen)
            }) else { continue }

            let filter = SCContentFilter(
                display: display,
                excludingApplications: ownApplications,
                exceptingWindows: []
            )
            let sourceRect = ScreenGeometry.displayLocalRect(for: intersection, on: screen)
            let tileScale = max(1, screen.backingScaleFactor)

            let configuration = SCStreamConfiguration()
            configuration.sourceRect = sourceRect
            configuration.width = max(1, Int((sourceRect.width * tileScale).rounded()))
            configuration.height = max(1, Int((sourceRect.height * tileScale).rounded()))
            configuration.captureResolution = .best
            configuration.scalesToFit = false
            configuration.showsCursor = false

            let cgImage = try await captureImage(filter: filter, configuration: configuration)
            tiles.append((cgImage, intersection))
        }

        guard !tiles.isEmpty else { throw CaptureError.displayUnavailable }
        return try composite(tiles: tiles, area: area, scale: scale, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
    }

    private func composite(
        tiles: [(image: CGImage, rect: CGRect)],
        area: CGRect,
        scale: CGFloat,
        pixelWidth: Int,
        pixelHeight: Int
    ) throws -> NSImage {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelWidth,
            pixelsHigh: pixelHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: .alphaFirst,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { throw CaptureError.renderFailed }

        guard let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw CaptureError.renderFailed
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        // Opaque backdrop: a selection spanning displays of different sizes has gaps that
        // would otherwise stay transparent and turn into garbage once exported as JPEG.
        NSColor.black.setFill()
        NSRect(origin: .zero, size: NSSize(width: pixelWidth, height: pixelHeight)).fill()

        for tile in tiles {
            let destination = CGRect(
                x: (tile.rect.minX - area.minX) * scale,
                y: (tile.rect.minY - area.minY) * scale,
                width: tile.rect.width * scale,
                height: tile.rect.height * scale
            )
            graphicsContext.cgContext.draw(tile.image, in: destination)
        }

        graphicsContext.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        bitmap.size = area.size
        let image = NSImage(size: area.size)
        image.addRepresentation(bitmap)
        return image
    }
}

/// Selection frame outline: a grey core between two hairlines, so at least one of the
/// three always contrasts with what is underneath. A plain white border used to vanish
/// over light content.
///
/// Which side gets which hairline matters. Outside the selection the overlay has already
/// dimmed everything, so a *light* hairline reads there. Inside is untouched screen
/// content that may be anything, and white content is the hard case — so the *dark*
/// hairline goes inward.
enum SelectionBorder {
    static let coreColor = NSColor(white: 0.62, alpha: 1)
    static let coreWidth: CGFloat = 2

    static func stroke(_ rect: CGRect, scale: CGFloat = 1) {
        let hairline = max(1, 1 / scale)
        let core = coreWidth / scale
        let offset = (core + hairline) / 2

        NSColor.white.withAlphaComponent(0.9).setStroke()
        strokeRect(rect.insetBy(dx: -offset, dy: -offset), lineWidth: hairline)

        NSColor.black.withAlphaComponent(0.75).setStroke()
        strokeRect(rect.insetBy(dx: offset, dy: offset), lineWidth: hairline)

        coreColor.setStroke()
        strokeRect(rect, lineWidth: core)
    }

    private static func strokeRect(_ rect: CGRect, lineWidth: CGFloat) {
        let path = NSBezierPath(rect: rect)
        path.lineWidth = lineWidth
        path.stroke()
    }
}


