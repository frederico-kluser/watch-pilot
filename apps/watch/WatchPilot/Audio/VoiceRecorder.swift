import AVFoundation
import Foundation

/// Records a short voice command as 16 kHz mono AAC.
///
/// The file lives in `Documents/InProgress/` rather than `tmp/` because watchOS can
/// unlink the descriptor of an interrupted recording in `tmp/`, and the audio is
/// still needed after the wrist goes down.
final class VoiceRecorder: NSObject, AVAudioRecorderDelegate {
    enum Failure: LocalizedError {
        case session(String)
        case recorder(String)

        var errorDescription: String? {
            switch self {
            case .session(let detail): return "Microfone indisponível: \(detail)"
            case .recorder(let detail): return "Não consegui gravar: \(detail)"
            }
        }
    }

    private(set) var recorder: AVAudioRecorder?
    private(set) var currentURL: URL?

    /// Fires when the system takes the microphone away mid-recording — wrist down,
    /// another app, a call. The audio captured so far is still valid, so the owner
    /// should upload it instead of leaving the orb claiming to listen to a dead mic.
    var onCaptureInterrupted: ((URL) -> Void)?

    private var observers: [NSObjectProtocol] = []

    /// `AVAudioSessionDidBecomeInactiveNotification` (watchOS 27+), by value.
    private static let sessionDidBecomeInactive = Notification.Name(
        "AVAudioSessionDidBecomeInactiveNotification"
    )

    var isRecording: Bool { recorder?.isRecording ?? false }

    /// Start a new recording, replacing any previous take.
    func start() throws {
        // Finish the previous take *before* touching the session: `stop(discardFile:)`
        // ends with `setActive(false)`, so calling it after activating would deactivate
        // the session this method just activated and leave `record()` on an inactive
        // session (the recorder then captures nothing).
        stop(discardFile: true)

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.duckOthers])
            try session.setActive(true, options: [])
        } catch {
            throw Failure.session(error.localizedDescription)
        }

        let url = try Self.newRecordingURL()
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 48_000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        do {
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.delegate = self
            recorder.isMeteringEnabled = true
            guard recorder.prepareToRecord(), recorder.record() else {
                throw Failure.recorder("o sistema recusou a gravação")
            }
            self.recorder = recorder
            self.currentURL = url
            observeInterruptions()
        } catch let failure as Failure {
            // Never leave the microphone open — nor other audio ducked by `.duckOthers` —
            // when the start fails after the session was activated. Nobody else in the app
            // deactivates it, so a throw here would leak an active input session.
            Self.deactivateSession()
            throw failure
        } catch {
            Self.deactivateSession()
            throw Failure.recorder(error.localizedDescription)
        }
    }

    /// Stop and return the finished file (nil when nothing usable was captured).
    @discardableResult
    func stop(discardFile: Bool = false) -> URL? {
        guard let recorder else { return nil }
        let url = recorder.url
        recorder.stop()
        self.recorder = nil
        Self.deactivateSession()
        if discardFile {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        self.currentURL = url
        return url
    }

    /// Normalised 0…1 input power, sampled for the orb animation.
    func normalizedPower() -> Double {
        guard let recorder, recorder.isRecording else { return 0 }
        recorder.updateMeters()
        let decibels = Double(recorder.averagePower(forChannel: 0))
        let clamped = min(0, max(-55, decibels))
        return (clamped + 55) / 55
    }

    func peakPower() -> Double {
        guard let recorder, recorder.isRecording else { return 0 }
        recorder.updateMeters()
        let decibels = Double(recorder.peakPower(forChannel: 0))
        let clamped = min(0, max(-55, decibels))
        return (clamped + 55) / 55
    }

    // MARK: - Interruptions

    /// `AVAudioRecorder` never tells its delegate that capture stopped because the
    /// session was deactivated (`AVAudioRecorder.h`: the delegate is only called when
    /// recording finishes on its own), so the session notifications are the only
    /// reliable signal.
    private func observeInterruptions() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default

        // Observed by name on purpose: the `AVAudioSession.didBecomeInactiveNotification`
        // symbol only exists in the watchOS 27 SDK, and this project also builds with
        // Xcode 26 (watchOS 26.5). The C constant's value is the string below, so this
        // compiles everywhere and still receives the notification on watchOS 27.
        observers.append(
            center.addObserver(
                forName: Self.sessionDidBecomeInactive,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.captureWasInterrupted()
            }
        )

        // Delivered on every watchOS this app supports. Deprecated in 27 in favour of
        // the notification above, but still the only one older systems emit.
        observers.append(
            center.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: nil,
                queue: .main
            ) { [weak self] note in
                let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                guard raw == AVAudioSession.InterruptionType.began.rawValue else { return }
                self?.captureWasInterrupted()
            }
        )
    }

    private func captureWasInterrupted() {
        guard let recorder, recorder.isRecording else { return }
        let url = recorder.url
        recorder.stop()
        self.recorder = nil
        self.currentURL = url
        Self.deactivateSession()
        onCaptureInterrupted?(url)
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Audio session

    /// Deactivate the shared session. Must run *after* the recorder is stopped — the session
    /// API requires all I/O to be stopped first (`AVAudioSession.h`, setActive discussion).
    /// `.notifyOthersOnDeactivation` lets whatever `.duckOthers` silenced resume full volume.
    private static func deactivateSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    // MARK: - Paths

    private static func newRecordingURL() throws -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let directory = documents.appendingPathComponent("InProgress", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime]
        let stamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        return directory.appendingPathComponent("voice-\(stamp).m4a")
    }

    /// Drop leftover takes so the watch does not accumulate audio.
    static func purgeOldRecordings(keepNewest: Int = 1) {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let directory = documents.appendingPathComponent("InProgress", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        let sorted = files.sorted { lhs, rhs in
            let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return l > r
        }
        for url in sorted.dropFirst(keepNewest) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - AVAudioRecorderDelegate

    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        if !flag {
            self.recorder = nil
        }
    }
}
