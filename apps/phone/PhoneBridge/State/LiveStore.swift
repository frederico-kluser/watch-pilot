import Foundation
import Observation

/// Live view of the agent floor: who is working, who is not, and what each is
/// typing — fed by the hub's SSE stream (snapshot + events), with a polling
/// fallback so the picture is never stale.
@MainActor
@Observable
final class LiveStore {
    struct Agent: Identifiable, Equatable {
        let id: String
        let name: String
        let state: String
        let line: String
        let workspace: String

        var isWorking: Bool { state == "running" }
    }

    struct Launch: Identifiable, Equatable {
        let id: String
        let prompt: String
        let project: String
        let newStory: Bool
        let status: String
        let detail: String
        let worktreePath: String
    }

    private(set) var agents: [Agent] = []
    private(set) var launches: [Launch] = []
    private(set) var connected = false
    private(set) var lastEventAt: Date?

    private let client: HubClient
    private let stream: StreamClient
    private var streamTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?

    init(client: HubClient = .live()) {
        self.client = client
        self.stream = StreamClient(client: client)
    }

    func start() {
        streamTask?.cancel()
        streamTask = Task { [weak self] in
            guard let self else { return }
            await self.stream.run { [weak self] event in
                Task { @MainActor [weak self] in
                    self?.apply(event)
                }
            }
        }
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: 20_000_000_000)
            }
        }
    }

    func stop() {
        streamTask?.cancel()
        pollTask?.cancel()
        Task { await stream.stop() }
    }

    /// Polling fallback: same picture as the stream, from plain GETs.
    func refresh() async {
        if let payload = try? await client.activity(),
           let data = try? JSONSerialization.data(withJSONObject: payload["sessions"] ?? []),
           let sessions = try? JSONDecoder().decode([WireAgent].self, from: data) {
            agents = sessions.map {
                Agent(id: $0.id, name: $0.name, state: $0.state, line: $0.line, workspace: $0.workspace)
            }
        }
        connected = true
        lastEventAt = Date()
    }

    private func apply(_ event: StreamClient.Event) {
        // Activity events are ~1 Hz; log only the rarer kinds.
        if event.kind != "activity" { NSLog("STREAM-EVENT: %@", event.kind) }
        connected = true
        lastEventAt = Date()
        switch event.kind {
        case "snapshot":
            if let activity = event.payload["activity"] as? [String: Any],
               let data = try? JSONSerialization.data(withJSONObject: activity["sessions"] ?? []),
               let sessions = try? JSONDecoder().decode([WireAgent].self, from: data) {
                agents = sessions.map {
                    Agent(id: $0.id, name: $0.name, state: $0.state, line: $0.line, workspace: $0.workspace)
                }
            }
            if let pending = event.payload["pending_launches"] as? [[String: Any]] {
                launches = pending.map(wireLaunch)
            }
        case "activity":
            if let data = try? JSONSerialization.data(withJSONObject: event.payload["sessions"] ?? []),
               let sessions = try? JSONDecoder().decode([WireAgent].self, from: data) {
                agents = sessions.map {
                    Agent(id: $0.id, name: $0.name, state: $0.state, line: $0.line, workspace: $0.workspace)
                }
            }
        case "launch":
            let launch = wireLaunch(event.payload)
            if let index = launches.firstIndex(where: { $0.id == launch.id }) {
                launches[index] = launch
            } else {
                launches.insert(launch, at: 0)
            }
        default:
            break
        }
    }

    private func wireLaunch(_ raw: [String: Any]) -> Launch {
        Launch(
            id: raw["launch_id"] as? String ?? UUID().uuidString,
            prompt: raw["prompt"] as? String ?? "",
            project: raw["project"] as? String ?? "",
            newStory: raw["new_story"] as? Bool ?? true,
            status: raw["status"] as? String ?? "pending",
            detail: raw["detail"] as? String ?? "",
            worktreePath: raw["worktree_path"] as? String ?? ""
        )
    }

    private struct WireAgent: Codable {
        let id: String
        let name: String
        let state: String
        let line: String
        let workspace: String
    }
}
