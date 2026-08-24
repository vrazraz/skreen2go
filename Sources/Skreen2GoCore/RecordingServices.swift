import AVFoundation
import AppKit
import CoreGraphics
import Foundation

/// What the selection overlay hands over when the user presses record. The mirror of
/// `SelectionCapture`, minus the annotations: drawing is a screenshot tool.
struct RecordingRequest: Equatable {
    var area: CGRect
    var windowID: CGWindowID?
}

enum RecordingError: LocalizedError {
    case alreadyRunning
    case notRunning
    case selectionTooSmall
    case displayUnavailable
    case windowUnavailable
    case permissionDenied
    case startFailed(Error)
    case writeFailed(Error)
    case finishTimedOut

    var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            return "error.recording.alreadyRunning".localized("A recording is already running.")
        case .notRunning:
            return "error.recording.notRunning".localized("No recording is running.")
        case .selectionTooSmall:
            return "error.recording.selectionTooSmall".localized(
                "The selected region is too small to record."
            )
        case .displayUnavailable:
            return "error.capture.displayUnavailable".localized(
                "Could not work out which display the selected region is on."
            )
        case .windowUnavailable:
            return "error.capture.windowUnavailable".localized(
                "The window disappeared before the screenshot could be taken."
            )
        case .permissionDenied:
            return "error.capture.permissionDenied".localized(
                "No screen recording access. Enable Skreen2Go in System Settings → Privacy & Security → Screen Recording, then restart the app."
            )
        case .startFailed(let error):
            return "error.recording.startFailed".localized(
                "Could not start the recording: %@",
                error.localizedDescription
            )
        case .writeFailed(let error):
            return "error.recording.writeFailed".localized(
                "Could not save the recording: %@",
                error.localizedDescription
            )
        case .finishTimedOut:
            return "error.recording.finishTimedOut".localized(
                "The recording did not finish writing to disk in time."
            )
        }
    }
}

/// Boundary between the recording flow and ScreenCaptureKit, matching the role
/// `ScreenshotCapturing` plays for stills. Nothing from ScreenCaptureKit crosses it, so
/// the state machine on the other side can be driven entirely by a fake.
@MainActor
protocol ScreenRecording: AnyObject {
    var isRecording: Bool { get }
    /// Fires when the system ends the stream on its own — the recorded window closed, or
    /// the display went away. Without it a session would sit in `recording` forever.
    var onUnexpectedStop: ((Error?) -> Void)? { get set }
    func start(_ plan: RecordingPlan, writingTo url: URL) async throws
    /// Returns the file that was written, once the encoder has finished with it.
    func stop() async throws -> URL
}

/// Microphone access, behind a protocol so a test can assert the real thing is never
/// consulted while the microphone toggle is off — which is the guarantee that the app
/// does not ask for a microphone on first launch.
@MainActor
protocol MicrophoneAuthorizing: AnyObject {
    var isAuthorized: Bool { get }
    var isDetermined: Bool { get }
    func requestAccess() async -> Bool
}

@MainActor
protocol RecordingCountdownPresenting: AnyObject {
    func show(seconds: Int, over area: CGRect)
    func update(seconds: Int)
    func dismiss()
}

/// Where a recording is written while it is still being made.
///
/// Not straight into the user's save folder: a sandboxed app reaches that through a
/// security-scoped bookmark, and `SettingsStore.withOutputFolderAccessAsync` deliberately
/// holds that access only for the length of one closure. A recording lasts minutes, and
/// ScreenCaptureKit writes from outside our call stack. Writing into our own container and
/// moving the finished file keeps the scoped access to a single, short operation — and a
/// crash mid-recording leaves the debris in our container rather than in Downloads.
enum RecordingFiles {
    static let fileExtension = "mp4"
    private static let folderName = "Recordings"

    static func temporaryURL(
        fileManager: FileManager = .default,
        id: UUID = UUID()
    ) throws -> URL {
        let folder = fileManager.temporaryDirectory.appendingPathComponent(
            folderName,
            isDirectory: true
        )
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("\(id.uuidString).\(fileExtension)")
    }

    /// Anything still here at launch is from a run that ended badly: a recording never
    /// outlives the process that made it.
    static func staleRecordings(fileManager: FileManager = .default) -> [URL] {
        let folder = fileManager.temporaryDirectory.appendingPathComponent(
            folderName,
            isDirectory: true
        )
        let entries = (try? fileManager.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil
        )) ?? []
        return entries.filter { $0.pathExtension == fileExtension }
    }

    /// Whether a leftover file is a finished recording or a truncated write.
    ///
    /// The distinction matters: an MPEG-4 only plays once its trailer has been written, so
    /// this is the difference between a video worth handing back to the user and a stump
    /// worth deleting.
    static func isPlayable(_ url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        guard (try? await asset.load(.isPlayable)) == true else { return false }
        guard let duration = try? await asset.load(.duration) else { return false }
        return duration.seconds > 0
    }

    static func discard(_ url: URL, fileManager: FileManager = .default) {
        try? fileManager.removeItem(at: url)
    }

    /// Moves the finished recording into the save folder, giving it the same kind of name
    /// screenshots get. Copy-then-delete covers a destination on another volume, where
    /// `moveItem` fails.
    static func move(
        _ source: URL,
        into folder: URL,
        date: Date = Date(),
        fileManager: FileManager = .default
    ) throws -> URL {
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = ScreenshotNaming.uniqueURL(
            in: folder,
            prefix: ScreenshotNaming.recordingPrefix,
            extension: fileExtension,
            date: date,
            fileManager: fileManager
        )
        do {
            try fileManager.moveItem(at: source, to: destination)
        } catch {
            try fileManager.copyItem(at: source, to: destination)
            try? fileManager.removeItem(at: source)
        }
        return destination
    }
}
