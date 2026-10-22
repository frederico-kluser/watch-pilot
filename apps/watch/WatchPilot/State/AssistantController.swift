import Foundation
import Observation
import WatchKit

/// The assistant's brain on the wrist: recording, upload, progress and answers.
@MainActor
@Observable
final class AssistantController {
    static let shared = AssistantController()

    private(set) var phase: AssistantPhase = .idle
    private(set) var lastReply: String = ""
    private(set) var lastTranscript: String = ""
    private(set) var pairingReady: Bool = false
    private(set) var lastLatencyMilliseconds: Int?
    private(set) var usedBackend: String?

    /// Survives a suspend/resume cycle so the orb reattaches to a running task.
    private(set) var activeTaskID: String? {
        didSet { UserDefaults.standard.set(activeTaskID, forKey: Self.taskDefaultsKey) }
    }

    private static let taskDefaultsKey = "WPActiveTaskID"

    /// True while the hub may still be working on a command: retrying the round trip
    /// is meaningful, and the UI can say so instead of offering a dead end.
    var hasPendingTask: Bool { activeTaskID != nil }

    private let recorder = VoiceRecorder()
    private let client = HubClient.fromBundle()
    private var meteringTask: Task<Void, Never>?
    private var pollingTask: Task<Void, Never>?

    private init() {
        pairingReady = SecretStore.secret != nil
        activeTaskID = UserDefaults.standard.string(forKey: Self.taskDefaultsKey)
        RuntimeCoordinator.shared.onBackgroundPoll = { [weak self] in
            await self?.refreshActiveTask()
        }
        VoiceRecorder.purgeOldRecordings()

        // A wrist-down or a phone call can take the microphone away; ship what was
        // captured rather than showing "A ouvir…" over a dead input.
        recorder.onCaptureInterrupted = { [weak self] url in
            Task { @MainActor [weak self] in
                guard let self, self.phase.isRecording else { return }
                self.meteringTask?.cancel()
                self.meteringTask = nil
                self.phase = .uploading
                await self.send(fileURL: url)
            }
        }
    }

    // MARK: - User intent

    func toggleRecording() {
        if phase.isRecording {
            finishRecordingAndSend()
        } else if !phase.isBusy {
            beginRecording()
        }
    }

    func retryLastTask() {
        guard let taskID = activeTaskID else {
            phase = .idle
            return
        }
        phase = .waiting(progress: 0.05, step: "A consultar o Mac mini…")
        startPolling(taskID: taskID)
    }

    /// Walk away from a command without pretending it failed. The hub keeps working;
    /// the watch simply stops watching it.
    func cancelCurrent() {
        pollingTask?.cancel()
        pollingTask = nil
        meteringTask?.cancel()
        meteringTask = nil
        let pending = activeTaskID
        activeTaskID = nil
        phase = .idle
        WKInterfaceDevice.current().play(.click)
        RuntimeCoordinator.shared.stopExtendedRuntime()
        if pending != nil {
            lastReply = ""
            lastTranscript = ""
        }
    }

    // MARK: - Recording

    private func beginRecording() {
        guard SecretStore.secret != nil else {
            phase = .failed(message: "Emparelha o relógio com o Mac mini primeiro.")
            return
        }
        do {
            try recorder.start()
        } catch {
            phase = .failed(message: error.localizedDescription)
            WKInterfaceDevice.current().play(.failure)
            return
        }

        // The extended session has to be requested from the foreground.
        RuntimeCoordinator.shared.startExtendedRuntimeIfNeeded()
        WKInterfaceDevice.current().play(.start)
        phase = .listening(power: 0.1)

        meteringTask?.cancel()
        meteringTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let power = self.recorder.normalizedPower()
                if case .listening = self.phase {
                    self.phase = .listening(power: power)
                } else {
                    return
                }
                try? await Task.sleep(nanoseconds: 33_000_000)  // ~30 Hz
            }
        }
    }

    private func finishRecordingAndSend() {
        meteringTask?.cancel()
        meteringTask = nil
        guard let url = recorder.stop() else {
            phase = .idle
            return
        }
        WKInterfaceDevice.current().play(.stop)
        phase = .uploading
        Task { await send(fileURL: url) }
    }

    // MARK: - Network round trip

    private func send(fileURL: URL) async {
        do {
            let status = try await client.upload(audioAt: fileURL)
            activeTaskID = status.taskID
            apply(status)
            startPolling(taskID: status.taskID)
        } catch {
            phase = .failed(message: error.localizedDescription)
            WKInterfaceDevice.current().play(.failure)
        }
    }

    private func startPolling(taskID: String) {
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    let status = try await self.client.progress(taskID: taskID)
                    self.apply(status)
                    if status.isFinished { return }
                } catch {
                    // A single hiccup (edge route re-registration, sleep) is normal;
                    // keep trying until the task finishes or the app is suspended.
                    if case HubClient.Failure.unauthorized = error {
                        self.phase = .failed(message: error.localizedDescription)
                        return
                    }
                }
                try? await Task.sleep(nanoseconds: UInt64(self.client.pollInterval * 1_000_000_000))
            }
        }
    }

    /// Called by the background refresh task and on returning to the foreground.
    func refreshActiveTask() async {
        guard let taskID = activeTaskID else { return }
        if let status = try? await client.progress(taskID: taskID) {
            apply(status)
            if !status.isFinished {
                startPolling(taskID: taskID)
            }
        }
    }

    func handleScenePhase(_ isActive: Bool) {
        if isActive {
            Task { await refreshActiveTask() }
        } else if phase.isBusy {
            // The extended session keeps the contract; the scheduler gets a hint too.
            RuntimeCoordinator.shared.scheduleBackgroundRefresh(after: 90)
        }
    }

    // MARK: - Applying results

    func apply(_ status: TaskStatus) {
        if let transcript = status.transcript, !transcript.isEmpty {
            lastTranscript = transcript
        }
        switch status.status {
        case "completed":
            lastReply = status.aiReply ?? status.transcript ?? ""
            lastLatencyMilliseconds = status.totalMilliseconds
            usedBackend = status.backend
            phase = .answering(reply: lastReply)
            activeTaskID = nil
            WKInterfaceDevice.current().play(.success)
            RuntimeCoordinator.shared.stopExtendedRuntime()
            let coordinator = RuntimeCoordinator.shared
            Task {
                await coordinator.requestPermissionIfNeeded()
                coordinator.postLocalNotification(
                    title: "Watch Pilot",
                    body: String(lastReply.prefix(140))
                )
            }
        case "failed":
            phase = .failed(message: status.error ?? status.stepDescription)
            activeTaskID = nil
            WKInterfaceDevice.current().play(.failure)
        default:
            phase = .waiting(progress: status.progress, step: status.stepDescription)
        }
    }

    func registerDeviceToken(_ token: String) async {
        try? await client.registerDeviceToken(token)
    }

    /// Pairing from the watch itself (used by the debug row and after a reset).
    @discardableResult
    func savePairingSecret(_ secret: String) -> Bool {
        let saved = SecretStore.save(secret: secret)
        pairingReady = SecretStore.secret != nil
        if pairingReady {
            phase = .idle
        }
        return pairingReady
    }

    #if DEBUG
    /// Dev-only affordances used by `scripts/screenshot-states.sh`: freeze the orb
    /// in a state for design review, or prove the TOTP contract against the live hub.
    func applyDemoPhase(_ raw: String) {
        switch raw {
        case "listening":
            phase = .listening(power: 0.72)
        case "waiting":
            phase = .waiting(progress: 0.62, step: "A pensar com o MiMo 2.6 Pro…")
        case "answering":
            lastLatencyMilliseconds = 8_400
            usedBackend = "wtx-transcribe"
            lastReply = "Lembrete criado para amanhã às 09:00 e o calendário do Mac já está atualizado."
            phase = .answering(reply: lastReply)
        case "failed":
            phase = .failed(message: "Mac mini inacessível: ligação recusada")
        default:
            phase = .idle
        }
    }

    /// Real round trip: proves the watch-side TOTP + hub client inside watchOS.
    func runLiveSmokeTest() async {
        phase = .waiting(progress: 0.15, step: "A falar com o hub…")
        do {
            let payload = try await client.status()
            let model = payload["model"] as? String ?? "hub"
            let reasoning = payload["reasoning_effort"] as? String ?? "?"
            lastReply = "Ligado ao hub · \(model) · reasoning \(reasoning) · TOTP aceite"
            usedBackend = "hub"
            phase = .answering(reply: lastReply)
            WKInterfaceDevice.current().play(.success)
        } catch {
            phase = .failed(message: error.localizedDescription)
            WKInterfaceDevice.current().play(.failure)
        }
    }
    #endif

    func resetSession() {
        pollingTask?.cancel()
        meteringTask?.cancel()
        activeTaskID = nil
        phase = .idle
        lastReply = ""
        lastTranscript = ""
        RuntimeCoordinator.shared.stopExtendedRuntime()
    }
}
