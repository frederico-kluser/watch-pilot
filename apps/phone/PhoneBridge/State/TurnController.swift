import AVFoundation
import Foundation
import Observation

/// One full voice turn through the bridge: capture → hub → spoken reply → briefing.
///
/// This is the "start to finish" path of the product, running from the iPhone:
/// the phone records a command exactly like the watch does (16 kHz mono AAC),
/// uploads it to the Mac mini hub, follows the task, downloads the answer as
/// *fala*, plays it, and finally turns the whole turn into an Apple Intelligence
/// briefing.
@MainActor
@Observable
final class TurnController {
    enum Phase: Equatable {
        case idle
        case recording(startedAt: Date)
        case uploading
        case thinking(progress: Double, step: String)
        case speaking
        case finished
        case failed(String)

        var label: String {
            switch self {
            case .idle: return "Pronto para falar"
            case .recording: return "A gravar…"
            case .uploading: return "A enviar ao Mac mini…"
            case .thinking(let progress, let step):
                return progress > 0 ? "\(Int(progress * 100))% · \(step)" : step
            case .speaking: return "O T-800 está a falar…"
            case .finished: return "Turno concluído"
            case .failed(let message): return message
            }
        }
    }

    private(set) var phase: Phase = .idle
    private(set) var transcript: String = ""
    private(set) var reply: String = ""
    private(set) var briefing: String = ""
    private(set) var speakingLevel: Double = 0

    private let client: HubClient
    private let intelligence: AppleIntelligence
    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private var metering: Task<Void, Never>?

    init(client: HubClient = .live(), intelligence: AppleIntelligence) {
        self.client = client
        self.intelligence = intelligence
    }

    /// Clear the previous turn before starting a new one.
    func reset() {
        transcript = ""
        reply = ""
        briefing = ""
        speakingLevel = 0
        if case .finished = phase { phase = .idle }
        if case .failed = phase { phase = .idle }
    }

    // MARK: - Capture

    /// Start recording a command (the start of a turn).
    func startRecording() {
        guard case .idle = phase else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.duckOthers])
            try session.setActive(true)

            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("bridge-turn-\(UUID().uuidString).m4a")
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 16_000.0,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 48_000,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ]
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            guard recorder.prepareToRecord(), recorder.record() else {
                throw TurnFailure.capture
            }
            self.recorder = recorder
            phase = .recording(startedAt: Date())
        } catch {
            phase = .failed("Microfone indisponível: \(error.localizedDescription)")
        }
    }

    /// Stop capturing and run the whole turn.
    func finishAndSend() {
        guard let recorder else { return }
        let url = recorder.url
        recorder.stop()
        self.recorder = nil
        Task { await run(data: (try? Data(contentsOf: url)) ?? Data()) }
    }

    enum TurnFailure: Error { case capture }

    /// Run a turn from prepared audio (used by the capture path and by the
    /// `-WPTurnFile` debug hook, which emulates the microphone with a file).
    func run(data: AudioData) async {
        await run(data: data.raw)
    }

    func run(data: Data) async {
        guard !data.isEmpty else {
            phase = .failed("Sem áudio para enviar.")
            return
        }
        do {
            phase = .uploading
            let taskID = try await client.uploadAudio(data)

            var progress = 0.0
            while true {
                try await Task.sleep(nanoseconds: 1_500_000_000)
                let status = try await client.progress(taskID: taskID)
                switch status.status {
                case "completed":
                    transcript = status.transcript
                    reply = status.aiReply
                    if !status.replyAudioURL.isEmpty {
                        // The spoken reply is an enhancement: a failed download must
                        // not destroy a turn that already has text.
                        if let audio = try? await client.replyAudio(path: status.replyAudioURL) {
                            await speak(audio)
                        }
                    }
                    phase = .finished
                    await brief()
                    return
                case "failed":
                    phase = .failed("O hub não conseguiu processar o turno.")
                    return
                default:
                    progress = status.progress
                    phase = .thinking(progress: progress, step: "A trabalhar no Mac mini…")
                }
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    // MARK: - Spoken reply (the end of a turn)

    private func speak(_ data: Data) async {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            let player = try AVAudioPlayer(data: data)
            player.isMeteringEnabled = true
            self.player = player
            phase = .speaking
            player.play()

            metering = Task { [weak self] in
                while let self, self.player?.isPlaying == true {
                    self.player?.updateMeters()
                    let db = Double(self.player?.averagePower(forChannel: 0) ?? -55)
                    self.speakingLevel = min(1, max(0, (db + 55) / 55))
                    try? await Task.sleep(nanoseconds: 33_000_000)
                }
                self?.speakingLevel = 0
            }
            while player.isPlaying {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            metering?.cancel()
            speakingLevel = 0
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
            // A reply we cannot play is still a reply: keep the text, say so.
            phase = .finished
        }
    }

    // MARK: - Apple Intelligence

    private func brief() async {
        briefing = await intelligence.process(transcript: transcript, reply: reply)
        NSLog("TURN-BRIEFING: %@", briefing)
    }
}

/// Wrapper so the debug hook can hand over a file without exposing `Data` in UI code.
struct AudioData {
    let raw: Data
}
