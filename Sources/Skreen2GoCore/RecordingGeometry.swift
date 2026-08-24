import AppKit
import CoreGraphics
import Foundation

/// A display, reduced to the three facts a recording needs. `NSScreen` cannot be
/// constructed in a test, so the geometry below works on this instead and the real screens
/// are converted at the edge.
struct RecordingDisplay: Equatable {
    var displayID: CGDirectDisplayID
    /// Cocoa coordinates: bottom-left origin, shared across all displays.
    var frame: CGRect
    var backingScaleFactor: CGFloat

    init(displayID: CGDirectDisplayID, frame: CGRect, backingScaleFactor: CGFloat) {
        self.displayID = displayID
        self.frame = frame
        self.backingScaleFactor = backingScaleFactor
    }

    init(screen: NSScreen) {
        self.init(
            displayID: ScreenGeometry.displayID(for: screen),
            frame: screen.frame,
            backingScaleFactor: screen.backingScaleFactor
        )
    }

    static var current: [RecordingDisplay] {
        NSScreen.screens.map(RecordingDisplay.init(screen:))
    }
}

/// Where the frames come from. ScreenCaptureKit follows a window as it moves, so only its
/// id is needed; a region is pinned to one display.
enum RecordingSource: Equatable {
    case window(CGWindowID)
    case region(displayID: CGDirectDisplayID, sourceRect: CGRect)
}

/// Everything a recording needs, worked out before a single ScreenCaptureKit object
/// exists. Keeping it a plain value is what lets the awkward parts — display choice, pixel
/// rounding, coordinate flipping — be tested without a screen.
struct RecordingPlan: Equatable {
    var source: RecordingSource
    var pixelWidth: Int
    var pixelHeight: Int
    var showsCursor: Bool
    var showsClicks: Bool
    var capturesSystemAudio: Bool
    var capturesMicrophone: Bool
    /// True when the selection reached onto a second display and had to be cut back. The
    /// user is told, rather than silently handed a smaller video than they drew.
    var trimmedToOneDisplay: Bool
}

enum RecordingGeometry {
    /// Below this there is nothing worth recording, and the encoder would refuse anyway.
    static let minimumPixelSide = 2

    /// H.264 stores colour at half resolution in both axes, so an odd width or height has
    /// no valid encoding. A freehand drag produces one about half the time.
    static func evenPixelCount(_ points: CGFloat, scale: CGFloat) -> Int {
        let scaled = (points * max(scale, 1)).rounded()
        guard scaled.isFinite, scaled >= CGFloat(minimumPixelSide) else { return minimumPixelSide }
        let whole = Int(min(scaled, CGFloat(Int32.max)))
        return max(minimumPixelSide, whole - (whole % 2))
    }

    /// The display holding most of the selection.
    ///
    /// A region recording covers exactly one display. One `SCStream` is bound to one
    /// filter, and unlike a screenshot — which captures each display separately and
    /// composites the tiles (`ScreenCaptureService.swift:241`) — a stream cannot stitch.
    static func display(for area: CGRect, displays: [RecordingDisplay]) -> RecordingDisplay? {
        displays
            .compactMap { display -> (RecordingDisplay, CGFloat)? in
                let overlap = display.frame.intersection(area)
                guard !overlap.isNull, overlap.width > 0, overlap.height > 0 else { return nil }
                return (display, overlap.width * overlap.height)
            }
            .max { $0.1 < $1.1 }?
            .0
    }

    /// Rect relative to the display's own top-left corner, in points — the coordinate
    /// system `SCStreamConfiguration.sourceRect` expects. The same conversion as
    /// `ScreenGeometry.displayLocalRect(for:on:)`, over a value rather than an `NSScreen`.
    static func sourceRect(for area: CGRect, on display: RecordingDisplay) -> CGRect {
        let clipped = area.intersection(display.frame)
        guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return .zero }
        return CGRect(
            x: clipped.minX - display.frame.minX,
            y: display.frame.maxY - clipped.maxY,
            width: clipped.width,
            height: clipped.height
        )
    }

    static func regionPlan(
        for area: CGRect,
        displays: [RecordingDisplay],
        options: RecordingOptions
    ) throws -> RecordingPlan {
        guard let display = display(for: area, displays: displays) else {
            // The overlay spans the union of every screen, and that union has gaps between
            // displays that belong to no display at all.
            throw RecordingError.displayUnavailable
        }

        let rect = sourceRect(for: area, on: display)
        guard rect.width > 0, rect.height > 0 else { throw RecordingError.displayUnavailable }

        let scale = max(display.backingScaleFactor, 1)
        let pixelWidth = evenPixelCount(rect.width, scale: scale)
        let pixelHeight = evenPixelCount(rect.height, scale: scale)
        guard rect.width * scale >= CGFloat(minimumPixelSide),
              rect.height * scale >= CGFloat(minimumPixelSide) else {
            throw RecordingError.selectionTooSmall
        }

        // Shrink the source rect to exactly the even pixel count rather than only rounding
        // the output size. `SCStreamConfiguration` preserves the aspect ratio by default,
        // so a source rect that no longer matches `width × height` would be letterboxed
        // with black bars instead of filling the frame.
        let snapped = CGRect(
            x: rect.minX,
            y: rect.minY,
            width: CGFloat(pixelWidth) / scale,
            height: CGFloat(pixelHeight) / scale
        )

        return RecordingPlan(
            source: .region(displayID: display.displayID, sourceRect: snapped),
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            showsCursor: options.showsCursor,
            showsClicks: options.showsClicks,
            capturesSystemAudio: options.capturesSystemAudio,
            capturesMicrophone: options.capturesMicrophone,
            trimmedToOneDisplay: !display.frame.contains(area)
        )
    }

    /// A window's size is only known once its content filter exists, so the caller passes
    /// the measured size and scale in.
    static func windowPlan(
        windowID: CGWindowID,
        contentSize: CGSize,
        scale: CGFloat,
        options: RecordingOptions
    ) throws -> RecordingPlan {
        let scale = max(scale, 1)
        guard contentSize.width * scale >= CGFloat(minimumPixelSide),
              contentSize.height * scale >= CGFloat(minimumPixelSide) else {
            throw RecordingError.selectionTooSmall
        }

        return RecordingPlan(
            source: .window(windowID),
            pixelWidth: evenPixelCount(contentSize.width, scale: scale),
            pixelHeight: evenPixelCount(contentSize.height, scale: scale),
            showsCursor: options.showsCursor,
            showsClicks: options.showsClicks,
            capturesSystemAudio: options.capturesSystemAudio,
            capturesMicrophone: options.capturesMicrophone,
            trimmedToOneDisplay: false
        )
    }
}

/// The parts of a recording the user chooses: two on the selection panel, two in Settings.
struct RecordingOptions: Equatable {
    var capturesSystemAudio: Bool
    var capturesMicrophone: Bool
    var showsCursor: Bool
    var showsClicks: Bool

    init(
        capturesSystemAudio: Bool,
        capturesMicrophone: Bool,
        showsCursor: Bool,
        showsClicks: Bool
    ) {
        self.capturesSystemAudio = capturesSystemAudio
        self.capturesMicrophone = capturesMicrophone
        self.showsCursor = showsCursor
        self.showsClicks = showsClicks
    }

    init(settings: SettingsStore) {
        self.init(
            capturesSystemAudio: settings.recordsSystemAudio,
            capturesMicrophone: settings.recordsMicrophone,
            showsCursor: settings.showsCursorInRecording,
            showsClicks: settings.showsClicksInRecording
        )
    }
}
