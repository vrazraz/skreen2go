import AppKit

/// Boundary between the capture flow and ScreenCaptureKit. Keeping this seam small
/// makes permission, cancellation and failed-capture paths testable without asking a
/// test suite to talk to the real screen server.
@MainActor
protocol ScreenshotCapturing: AnyObject {
    var hasScreenRecordingAccess: Bool { get }
    @discardableResult
    func requestScreenRecordingAccessIfNeeded() -> Bool
    func captureWindow(_ window: WindowInfo) async throws -> NSImage
    func captureArea(_ area: CGRect) async throws -> NSImage
}
