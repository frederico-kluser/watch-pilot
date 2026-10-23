import AVFoundation
import Foundation

/// Plays the assistant's reply — the hub's synthesised speech — and reports the
/// **real** voice level while it plays.
///
/// The level comes out normalised 0…1 at ~30 Hz through `onLevel`, using the same
/// curve as `VoiceRecorder.normalizedPower()` (clamp −55…0 dB → 0…1) so the T-800's
/// jaw follows the actual voice instead of an invented cadence. The audio session is
/// `.playback`: activated before playing, deactivated with
/// `.notifyOthersOnDeactivation` when playback ends or is stopped.
final class ReplyPlayer: NSObject, AVAudioPlayerDelegate {
    enum Failure: LocalizedError {
        case session(String)
        case player(String)

        var errorDescription: String? {
            switch self {
            case .session(let detail): return "Áudio indisponível: \(detail)"
            case .player(let detail): return "Não consegui tocar a resposta: \(detail)"
            }
        }
    }

    /// Real speech level, 0…1, emitted ~30 times per second during playback.
    var onLevel: ((Double) -> Void)?

    /// Fires when the audio finishes on its own (never on `stop()`).
    var onFinish: (() -> Void)?

    private var player: AVAudioPlayer?
    private var meteringTask: Task<Void, Never>?

    var isPlaying: Bool { player?.isPlaying ?? false }

    /// Start playing `data`, replacing any previous playback.
    func play(_ data: Data) throws {
        stop()

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true, options: [])
        } catch {
            throw Failure.session(error.localizedDescription)
        }

        do {
            let player = try AVAudioPlayer(data: data)
            player.delegate = self
            player.isMeteringEnabled = true
            guard player.play() else {
                throw Failure.player("o sistema recusou a reprodução")
            }
            self.player = player
            startMetering()
        } catch let failure as Failure {
            // Never leave the session active when playback could not start.
            Self.deactivateSession()
            throw failure
        } catch {
            Self.deactivateSession()
            throw Failure.player(error.localizedDescription)
        }
    }

    /// Stop playback and release the audio session. Does **not** fire `onFinish`.
    func stop() {
        meteringTask?.cancel()
        meteringTask = nil
        guard let player else { return }
        player.stop()
        self.player = nil
        Self.deactivateSession()
    }

    // MARK: - Metering

    /// Samples the output level at ~30 Hz while the audio runs — the same curve as
    /// `VoiceRecorder.normalizedPower()`, so capture and speech read alike.
    private func startMetering() {
        meteringTask?.cancel()
        meteringTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let player = self.player else { return }
                if player.isPlaying {
                    player.updateMeters()
                    self.onLevel?(Self.normalizedPower(player.averagePower(forChannel: 0)))
                }
                try? await Task.sleep(nanoseconds: 33_000_000)  // ~30 Hz
            }
        }
    }

    /// Clamp −55…0 dB → 0…1 (identical to `VoiceRecorder.normalizedPower()`).
    private static func normalizedPower(_ decibels: Float) -> Double {
        let clamped = min(0, max(-55, Double(decibels)))
        return (clamped + 55) / 55
    }

    // MARK: - Audio session

    /// `.notifyOthersOnDeactivation` lets whatever the playback interrupted resume.
    private static func deactivateSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    // MARK: - AVAudioPlayerDelegate

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        meteringTask?.cancel()
        meteringTask = nil
        self.player = nil
        Self.deactivateSession()
        onFinish?()
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        stop()
    }
}
