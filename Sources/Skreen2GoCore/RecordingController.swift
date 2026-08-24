import AppKit
import Foundation

enum RecordingState: Equatable {
    case idle
    case countdown(remaining: Int)
    case recording
    case finalising
}

/// Something worth telling the user that is not a failure: the recording still happens,
/// just not quite as asked.
enum RecordingNotice: Equatable {
    case trimmedToOneDisplay
    case microphoneUnavailable

    var message: String {
        switch self {
        case .trimmedToOneDisplay:
            return "recording.notice.singleDisplay".localized(
                "Video records one display, so the selection was trimmed."
            )
        case .microphoneUnavailable:
            return "recording.notice.microphoneUnavailable".localized(
                "No microphone access — recording without it."
            )
        }
    }
}

/// One-second ticks, behind a protocol so the countdown can be driven instantly in a test
/// instead of waiting three real seconds.
@MainActor
protocol RecordingTicking: AnyObject {
    func start(interval: TimeInterval, onTick: @escaping () -> Void)
    func stop()
}

@MainActor
final class RecordingTicker: RecordingTicking {
    private var timer: Timer?

    func start(interval: TimeInterval, onTick: @escaping () -> Void) {
        stop()
        // `.common` matters: in the default mode an open menu stops the run loop from
        // firing timers, which would leave the countdown frozen behind it.
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            Task { @MainActor in onTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}

/// Owns a recording from the moment the user presses record until the file is in the save
/// folder.
///
/// Deliberately not part of `CaptureController`: that class is built around one-shot
/// capture, down to the generation counter whose whole job is to *invalidate* work in
/// flight. A recording outlives the overlay by minutes, so it belongs to something that
/// lives as long as the app does.
@MainActor
final class RecordingController {
    static let countdownSeconds = 3

    var onStateChange: ((RecordingState) -> Void)?
    var onStarted: (() -> Void)?
    var onSaved: ((URL) -> Void)?
    var onNotice: ((RecordingNotice) -> Void)?
    var onError: ((String) -> Void)?

    private(set) var state: RecordingState = .idle {
        didSet {
            guard state != oldValue else { return }
            onStateChange?(state)
        }
    }

    /// True from the first countdown tick until the file is saved — what the menu bar
    /// indicator follows.
    var isActive: Bool { state != .idle }

    private let settings: SettingsStore
    private let recorder: any ScreenRecording
    private let microphone: any MicrophoneAuthorizing
    private let countdown: any RecordingCountdownPresenting
    private let ticker: any RecordingTicking
    private let displays: () -> [RecordingDisplay]
    private let now: () -> Date

    private var pendingPlan: RecordingPlan?

    init(
        settings: SettingsStore = .shared,
        recorder: (any ScreenRecording)? = nil,
        microphone: (any MicrophoneAuthorizing)? = nil,
        countdown: (any RecordingCountdownPresenting)? = nil,
        ticker: (any RecordingTicking)? = nil,
        displays: @escaping () -> [RecordingDisplay] = { RecordingDisplay.current },
        now: @escaping () -> Date = Date.init
    ) {
        self.settings = settings
        self.recorder = recorder ?? ScreenRecorder()
        self.microphone = microphone ?? SystemMicrophoneAuthorizer()
        self.countdown = countdown ?? RecordingCountdownPanel()
        self.ticker = ticker ?? RecordingTicker()
        self.displays = displays
        self.now = now

        self.recorder.onUnexpectedStop = { [weak self] _ in
            // The system ended the stream — the recorded window closed, most likely. What
            // was recorded so far is still worth keeping.
            self?.finishRecording()
        }
    }

    // MARK: - Entry points

    func start(_ request: RecordingRequest) {
        guard case .idle = state else {
            report(RecordingError.alreadyRunning)
            return
        }

        let plan: RecordingPlan
        do {
            plan = try makePlan(for: request)
        } catch {
            report(error)
            return
        }

        if plan.trimmedToOneDisplay { onNotice?(.trimmedToOneDisplay) }

        Task { @MainActor in
            var prepared = plan
            await authorizeMicrophoneIfNeeded(for: &prepared)
            guard case .idle = state else { return }
            beginCountdown(with: prepared, over: request.area)
        }
    }

    /// What the hot key and the menu bar icon call. Cancels a countdown, stops a running
    /// recording, and does nothing at all when there is nothing to stop.
    func stopOrCancel() {
        switch state {
        case .idle, .finalising:
            return
        case .countdown:
            cancelCountdown()
        case .recording:
            finishRecording()
        }
    }

    // MARK: - Countdown

    private func beginCountdown(with plan: RecordingPlan, over area: CGRect) {
        pendingPlan = plan
        state = .countdown(remaining: Self.countdownSeconds)
        countdown.show(seconds: Self.countdownSeconds, over: area)
        ticker.start(interval: 1) { [weak self] in self?.tick() }
    }

    private func tick() {
        switch state {
        case .countdown(let remaining) where remaining > 1:
            state = .countdown(remaining: remaining - 1)
            countdown.update(seconds: remaining - 1)
        case .countdown:
            beginRecording()
        case .idle, .recording, .finalising:
            ticker.stop()
        }
    }

    private func cancelCountdown() {
        ticker.stop()
        countdown.dismiss()
        pendingPlan = nil
        state = .idle
    }

    // MARK: - Recording

    private func beginRecording() {
        guard let plan = pendingPlan else {
            cancelCountdown()
            return
        }
        pendingPlan = nil

        // The countdown panel goes before the first frame is captured. Our windows are
        // excluded from the stream anyway, but a window recording has no exclusion list,
        // so leaving it up would be a race worth not having.
        countdown.dismiss()

        Task { @MainActor in
            do {
                let url = try RecordingFiles.temporaryURL()
                try await recorder.start(plan, writingTo: url)
                // Nothing left to count: the menu bar indicator during a recording is the
                // system's, not ours.
                ticker.stop()
                state = .recording
                onStarted?()
            } catch {
                ticker.stop()
                state = .idle
                report(error)
            }
        }
    }

    private func finishRecording() {
        guard case .recording = state else { return }
        ticker.stop()
        state = .finalising

        Task { @MainActor in
            do {
                let temporaryURL = try await recorder.stop()
                let saved = try await settings.withOutputFolderAccessAsync { folder in
                    try RecordingFiles.move(temporaryURL, into: folder, date: self.now())
                }
                state = .idle
                onSaved?(saved)
            } catch {
                state = .idle
                report(error)
            }
        }
    }

    /// Hands back a recording an earlier run finished but never managed to file away.
    ///
    /// Deleting leftovers unseen was the easy thing to do and the wrong one: a finished
    /// video the user never received is exactly what should survive a bad exit. Only a
    /// truncated write is discarded.
    func recoverStaleRecordings() async {
        for url in RecordingFiles.staleRecordings() {
            guard await RecordingFiles.isPlayable(url) else {
                RecordingFiles.discard(url)
                continue
            }
            do {
                let saved = try await settings.withOutputFolderAccessAsync { folder in
                    try RecordingFiles.move(url, into: folder, date: self.now())
                }
                onSaved?(saved)
            } catch {
                // Leave it where it is rather than destroying it; the next launch tries again.
                continue
            }
        }
    }

    /// Quitting mid-recording must still close the file: an MPEG-4 whose trailer was never
    /// written does not play at all.
    func finishBeforeTermination() async {
        guard case .recording = state else { return }
        ticker.stop()
        state = .finalising
        do {
            let temporaryURL = try await recorder.stop()
            _ = try? await settings.withOutputFolderAccessAsync { folder in
                try RecordingFiles.move(temporaryURL, into: folder, date: self.now())
            }
        } catch {
            // Nothing useful to show: the app is on its way out.
        }
        state = .idle
    }

    // MARK: - Helpers

    private func makePlan(for request: RecordingRequest) throws -> RecordingPlan {
        let options = RecordingOptions(settings: settings)
        if let windowID = request.windowID {
            return try RecordingGeometry.windowPlan(
                windowID: windowID,
                contentSize: request.area.size,
                scale: scale(for: request.area),
                options: options
            )
        }
        return try RecordingGeometry.regionPlan(
            for: request.area,
            displays: displays(),
            options: options
        )
    }

    private func scale(for area: CGRect) -> CGFloat {
        RecordingGeometry.display(for: area, displays: displays())?.backingScaleFactor ?? 1
    }

    /// Asked for only when the microphone toggle is on, so a user who never turns it on is
    /// never prompted. A refusal costs the microphone, not the recording.
    private func authorizeMicrophoneIfNeeded(for plan: inout RecordingPlan) async {
        guard plan.capturesMicrophone else { return }
        if !microphone.isDetermined {
            _ = await microphone.requestAccess()
        }
        guard !microphone.isAuthorized else { return }
        plan.capturesMicrophone = false
        onNotice?(.microphoneUnavailable)
    }

    private func report(_ error: Error) {
        onError?(error.localizedDescription)
    }
}
