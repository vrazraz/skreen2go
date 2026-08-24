import Foundation

/// Performs the potentially slow atomic write away from the main actor. The caller
/// keeps any security-scoped resource active until this operation returns.
actor ScreenshotFileWriter {
    static let shared = ScreenshotFileWriter()

    func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }
}
