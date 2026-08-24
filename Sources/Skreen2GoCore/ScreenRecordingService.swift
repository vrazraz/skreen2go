import AVFoundation
import AppKit
import CoreMedia
import Foundation
import ScreenCaptureKit

/// The one place that knows about `SCStream`. Everything above it works through
/// `ScreenRecording`, which is what lets the session state machine be tested with a fake.
@MainActor
final class ScreenRecorder: ScreenRecording {
    /// `SCStreamErrorUserDeclined`. Same constant, same reason as the screenshot path:
    /// ScreenCaptureKit reports a missing Screen Recording grant as a plain NSError.
    private static let userDeclinedErrorCode = -3801
    /// Frames are only produced when the content changes, so this is a ceiling rather
    /// than a rate: a still screen costs nothing at 60.
    private static let frameRate: CMTimeScale = 60
    /// How long to wait for the encoder to close the file after the stream stops. Long
    /// enough for a big recording to flush, short enough that the app is never wedged.
    private static let finishTimeout: TimeInterval = 10

    var onUnexpectedStop: ((Error?) -> Void)?
    private(set) var isRecording = false

    private let proxy = RecordingDelegateProxy()
    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private var outputURL: URL?
    private var finishContinuation: CheckedContinuation<Error?, Never>?
    /// The encoder's verdict when it arrives before anyone is waiting for it. That is the
    /// normal order when the system ends the stream — through its own recording indicator,
    /// say — because we only start waiting after the delegate has already told us. Without
    /// somewhere to put it the signal was dropped and the watchdog failed a recording that
    /// had in fact finished perfectly well.
    private var latchedFinish: Error??

    init() {
        proxy.onFinished = { [weak self] error in
            Task { @MainActor in self?.completeFinish(error) }
        }
        proxy.onStreamStopped = { [weak self] error in
            Task { @MainActor in self?.handleStreamStopped(error) }
        }
    }

    func start(_ plan: RecordingPlan, writingTo url: URL) async throws {
        guard !isRecording else { throw RecordingError.alreadyRunning }
        latchedFinish = nil

        let content = try await shareableContent()
        let filter = try contentFilter(for: plan, in: content)
        let configuration = streamConfiguration(for: plan)

        let stream = SCStream(filter: filter, configuration: configuration, delegate: proxy)
        let output = SCRecordingOutput(configuration: recordingConfiguration(url: url), delegate: proxy)

        do {
            // The header is explicit that a recording output must be added before capture
            // starts, otherwise the first frames never reach the file. Only one output per
            // stream is supported.
            try stream.addRecordingOutput(output)
            try await stream.startCapture()
        } catch {
            throw Self.recordingError(from: error)
        }

        self.stream = stream
        self.recordingOutput = output
        self.outputURL = url
        isRecording = true
    }

    func stop() async throws -> URL {
        guard let stream, let url = outputURL else { throw RecordingError.notRunning }

        isRecording = false
        self.stream = nil

        // Stopping the stream is what finishes the file: the header notes that a recording
        // output left attached is closed out by `stopCapture`. Never update the
        // configuration instead — that also ends the recording, just less obviously.
        do {
            try await stream.stopCapture()
        } catch {
            // An already-stopped stream is not a failure worth losing the file over.
        }

        let failure = await waitForFinish()
        recordingOutput = nil
        outputURL = nil

        if let failure { throw RecordingError.writeFailed(failure) }
        return url
    }

    // MARK: - Delegate plumbing

    private func waitForFinish() async -> Error? {
        if let latched = latchedFinish {
            latchedFinish = nil
            return latched
        }

        let watchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.finishTimeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            // The delegate methods are optional and carry no ordering guarantee, so a
            // silent encoder must not wedge the app forever.
            self?.completeFinish(RecordingError.finishTimedOut)
        }
        defer { watchdog.cancel() }

        return await withCheckedContinuation { continuation in
            finishContinuation = continuation
        }
    }

    /// Resumes exactly once, whichever of finish, failure or the watchdog arrives first —
    /// and holds onto the answer when it arrives before anyone is waiting.
    private func completeFinish(_ error: Error?) {
        guard let continuation = finishContinuation else {
            latchedFinish = .some(error)
            return
        }
        finishContinuation = nil
        continuation.resume(returning: error)
    }

    private func handleStreamStopped(_ error: Error?) {
        // A stop we asked for has already cleared `isRecording`; anything left is the
        // system ending the stream on its own — the recorded window closed, or a display
        // was unplugged. Without this the session would sit in `recording` forever.
        guard isRecording else { return }
        isRecording = false
        onUnexpectedStop?(error)
    }

    // MARK: - ScreenCaptureKit wiring

    private func shareableContent() async throws -> SCShareableContent {
        guard CGPreflightScreenCaptureAccess() else { throw RecordingError.permissionDenied }
        do {
            return try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
        } catch {
            throw Self.recordingError(from: error)
        }
    }

    private func contentFilter(
        for plan: RecordingPlan,
        in content: SCShareableContent
    ) throws -> SCContentFilter {
        switch plan.source {
        case .window(let windowID):
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                throw RecordingError.windowUnavailable
            }
            // Follows the window as it moves or changes display, and keeps the shadow and
            // the rounded-corner mask out — the same reasoning as a window screenshot.
            return SCContentFilter(desktopIndependentWindow: window)

        case .region(let displayID, _):
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw RecordingError.displayUnavailable
            }
            // Excluding our own application is what keeps the countdown, the toast and the
            // menu bar indicator out of the video. The window server evaluates the
            // exclusion live, so windows created after the stream starts are covered too.
            let ownApplications = content.applications.filter {
                $0.processID == ProcessInfo.processInfo.processIdentifier
            }
            return SCContentFilter(
                display: display,
                excludingApplications: ownApplications,
                exceptingWindows: []
            )
        }
    }

    private func streamConfiguration(for plan: RecordingPlan) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = plan.pixelWidth
        configuration.height = plan.pixelHeight
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: Self.frameRate)
        configuration.captureResolution = .best
        configuration.showsCursor = plan.showsCursor
        configuration.showMouseClicks = plan.showsClicks
        configuration.capturesAudio = plan.capturesSystemAudio
        // Our own toast and error sounds must not end up in the user's recording.
        configuration.excludesCurrentProcessAudio = true
        configuration.captureMicrophone = plan.capturesMicrophone

        switch plan.source {
        case .region(_, let sourceRect):
            configuration.sourceRect = sourceRect
            // The rect was already snapped so that it matches width x height exactly.
            configuration.scalesToFit = false
        case .window:
            // A window can be resized mid-recording while the output size is fixed, so let
            // it letterbox against black rather than stretch.
            configuration.scalesToFit = true
            configuration.backgroundColor = .black
        }
        return configuration
    }

    private func recordingConfiguration(url: URL) -> SCRecordingOutputConfiguration {
        let configuration = SCRecordingOutputConfiguration()
        configuration.outputURL = url
        // H.264 in MPEG-4 are already the defaults, but say so: this is the one place the
        // output format is decided, and it should not move silently with the SDK.
        if configuration.availableVideoCodecTypes.contains(.h264) {
            configuration.videoCodecType = .h264
        }
        if configuration.availableOutputFileTypes.contains(.mp4) {
            configuration.outputFileType = .mp4
        }
        return configuration
    }

    private static func recordingError(from error: Error) -> RecordingError {
        if let recordingError = error as? RecordingError { return recordingError }
        if (error as NSError).code == userDeclinedErrorCode { return .permissionDenied }
        return .startFailed(error)
    }
}

/// ScreenCaptureKit calls its delegates on its own queues. Keeping them on a plain object
/// that only forwards, rather than on the main-actor recorder itself, is what keeps the
/// hop explicit instead of scattered across the callbacks.
private final class RecordingDelegateProxy: NSObject, SCStreamDelegate, SCRecordingOutputDelegate {
    var onFinished: ((Error?) -> Void)?
    var onStreamStopped: ((Error?) -> Void)?

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStreamStopped?(error)
    }

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        onFinished?(nil)
    }

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        onFinished?(error)
    }
}

/// Microphone access, asked for only when the user turns the microphone on.
@MainActor
final class SystemMicrophoneAuthorizer: MicrophoneAuthorizing {
    var isAuthorized: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    var isDetermined: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) != .notDetermined
    }

    func requestAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }
}
