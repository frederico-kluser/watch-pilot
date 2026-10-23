import Foundation
import Observation

/// The bridge's brain: keeps the two kluser.me routes and the T-800 link under
/// watch, and re-checks them on a timer and on demand.
///
/// "T-800 link" means the assistant pipeline that lives behind `watch.kluser.me`:
/// the phone reads the hub's recent tasks (transcript → answer) and reports the
/// state of the last voice turn, so the whole chain can be seen from the wrist
/// work to the Mac mini processing and back.
@MainActor
@Observable
final class StatusMonitor {
    struct Link: Equatable {
        var paired: Bool = false
        var lastTranscript: String = ""
        var lastReply: String = ""
        var lastStatus: String = "sem tarefas"
        var hubModel: String = "—"
        var checkedAt: Date?
        var error: String = ""
    }

    private(set) var probes: [HubClient.ProbeResult] = []
    private(set) var link = Link()
    private(set) var refreshing = false

    private let client: HubClient
    private var timer: Task<Void, Never>?

    init(client: HubClient = .live()) {
        self.client = client
    }

    func start(interval: TimeInterval = 30) {
        timer?.cancel()
        timer = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// One full check: the two public routes plus the T-800 pipeline state.
    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }

        probes = await client.probeAll()

        var next = link
        next.paired = SecretStore.secret != nil
        next.checkedAt = Date()
        defer { link = next }

        do {
            let status = try await client.status()
            next.hubModel = (status["model"] as? String) ?? "—"
            next.error = ""
        } catch {
            next.error = error.localizedDescription
        }

        do {
            let tasks = try await client.tasks(limit: 5)
            if let last = tasks.first {
                next.lastTranscript = last.transcript ?? ""
                next.lastReply = last.aiReply ?? ""
                next.lastStatus = "\(last.status) · \(last.stepDescription ?? "")"
            }
        } catch {
            if next.error.isEmpty { next.error = error.localizedDescription }
        }
    }
}
