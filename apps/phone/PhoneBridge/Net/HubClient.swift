import Foundation

/// The iPhone side of the Watch Pilot bridge: everything the phone needs to talk
/// to the Mac mini hub and to prove the public routes are alive.
///
/// Every hub call carries a freshly generated `X-Watch-TOTP` code — the shared
/// secret never leaves the device after pairing. The two public probes
/// (`watch.kluser.me`, `mac.kluser.me`) are unauthenticated health checks and are
/// the only calls that touch the internet edge.
struct HubClient {
    enum Failure: LocalizedError {
        case notPaired
        case unauthorized(reason: String)
        case transport(String)
        case server(Int, String)
        case decoding(String)

        var errorDescription: String? {
            switch self {
            case .notPaired: return "Sem segredo TOTP — emparelha a ponte com o Mac mini."
            case .unauthorized(let reason): return "Código TOTP recusado (\(reason))."
            case .transport(let detail): return "Hub inacessível: \(detail)"
            case .server(let code, let detail): return "O hub respondeu \(code): \(detail)"
            case .decoding(let detail): return "Resposta inesperada do hub: \(detail)"
            }
        }
    }

    /// Ordered candidates: the public tunnel first (works anywhere), then LAN.
    let baseURLs: [URL]
    /// Public health probes: the two kluser.me routes the bridge must watch.
    let probes: [(name: String, url: URL)]
    private let session: URLSession

    init(baseURLs: [URL], probes: [(String, URL)], session: URLSession = .shared) {
        self.baseURLs = baseURLs
        self.probes = probes.map { (name: $0.0, url: $0.1) }
        self.session = session
    }

    static func live() -> HubClient {
        HubClient(
            baseURLs: [
                URL(string: "https://watch.kluser.me")!,
                URL(string: "http://127.0.0.1:8765")!,
            ],
            probes: [
                ("watch.kluser.me", URL(string: "https://watch.kluser.me/__health")!),
                ("mac.kluser.me", URL(string: "https://mac.kluser.me/__cfx-health")!),
            ]
        )
    }

    // MARK: - Public probes (no auth: these prove the edge is up)

    struct ProbeResult: Identifiable, Equatable {
        let id: String
        let name: String
        let online: Bool
        let latencyMS: Int
        let detail: String
        let checkedAt: Date
    }

    func probe(_ endpoint: (name: String, url: URL)) async -> ProbeResult {
        let started = Date()
        var request = URLRequest(url: endpoint.url)
        request.timeoutInterval = 8
        request.setValue("WatchPilotBridge/0.1 (iOS)", forHTTPHeaderField: "User-Agent")
        do {
            let (_, response) = try await session.data(for: request)
            let ms = Int(-started.timeIntervalSinceNow * 1000)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            return ProbeResult(
                id: endpoint.name, name: endpoint.name,
                online: (200..<400).contains(code),
                latencyMS: ms,
                detail: "HTTP \(code)",
                checkedAt: Date()
            )
        } catch {
            return ProbeResult(
                id: endpoint.name, name: endpoint.name,
                online: false, latencyMS: Int(-started.timeIntervalSinceNow * 1000),
                detail: error.localizedDescription, checkedAt: Date()
            )
        }
    }

    func probeAll() async -> [ProbeResult] {
        await withTaskGroup(of: ProbeResult.self) { group in
            for endpoint in probes {
                group.addTask { await self.probe(endpoint) }
            }
            return await group.reduce(into: []) { $0.append($1) }
                .sorted { $0.name < $1.name }
        }
    }

    // MARK: - Hub API (TOTP)

    struct InboxItem: Identifiable, Codable, Equatable {
        let id: String
        let title: String
        let body: String
        let createdAt: Double
        let taskID: String?
        let kind: String?

        enum CodingKeys: String, CodingKey {
            case id, title, body, kind
            case createdAt = "created_at"
            case taskID = "task_id"
        }
    }

    struct TaskSummary: Identifiable, Codable, Equatable {
        let taskID: String
        let status: String
        let transcript: String?
        let aiReply: String?
        let stepDescription: String?

        var id: String { taskID }

        enum CodingKeys: String, CodingKey {
            case taskID = "task_id"
            case status, transcript
            case aiReply = "ai_reply"
            case stepDescription = "step_description"
        }
    }

    func health() async throws -> [String: Any] {
        try await performJSON(path: "__health", authenticated: false)
    }

    func status() async throws -> [String: Any] {
        try await performJSON(path: "api/v1/status")
    }

    func tasks(limit: Int = 8) async throws -> [TaskSummary] {
        let payload = try await performJSON(path: "api/v1/tasks?limit=\(limit)")
        let data = try JSONSerialization.data(withJSONObject: payload["items"] ?? [])
        return try JSONDecoder().decode([TaskSummary].self, from: data)
    }

    /// The notification endpoint: the bridge "hits it when needed" to pull the inbox.
    func inbox(limit: Int = 30) async throws -> [InboxItem] {
        let payload = try await performJSON(path: "api/v1/inbox?limit=\(limit)")
        let data = try JSONSerialization.data(withJSONObject: payload["items"] ?? [])
        return try JSONDecoder().decode([InboxItem].self, from: data)
    }

    @discardableResult
    func notify(title: String, body: String, taskID: String = "") async throws -> InboxItem {
        var payload: [String: Any] = ["title": title, "body": body]
        if !taskID.isEmpty { payload["task_id"] = taskID }
        let raw = try await performJSON(method: "POST", path: "api/v1/notify", body: payload)
        let data = try JSONSerialization.data(withJSONObject: raw)
        return try JSONDecoder().decode(InboxItem.self, from: data)
    }

    /// Send one voice memo to the hub (the "start" of a turn) and get the task back.
    func uploadAudio(_ data: Data) async throws -> String {
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"audio_file\"; filename=\"voice_cmd.m4a\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/mp4\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var lastError: Error = Failure.transport("sem candidatos")
        for candidate in baseURLs {
            guard var components = URLComponents(url: candidate, resolvingAgainstBaseURL: false) else { continue }
            components.path = "/api/v1/assistant/audio"
            guard let url = components.url else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 120
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("WatchPilotBridge/0.1 (iOS)", forHTTPHeaderField: "User-Agent")
            do { request.setValue(try authHeader(), forHTTPHeaderField: "X-Watch-TOTP") }
            catch { throw error }
            do {
                let (data, response) = try await session.upload(for: request, from: body)
                guard let http = response as? HTTPURLResponse else { continue }
                switch http.statusCode {
                case 200..<300:
                    let payload = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
                    if let id = payload["task_id"] as? String { return id }
                    lastError = Failure.decoding("sem task_id")
                case 401:
                    throw Failure.unauthorized(reason: "401")
                default:
                    lastError = Failure.server(http.statusCode, String(data: data, encoding: .utf8) ?? "")
                }
            } catch let failure as Failure {
                if case .unauthorized = failure { throw failure }
                lastError = failure
            } catch {
                lastError = Failure.transport(error.localizedDescription)
            }
        }
        throw lastError
    }

    struct TaskProgress: Equatable {
        let status: String
        let progress: Double
        let transcript: String
        let aiReply: String
        let replyAudioURL: String
    }

    /// Poll one task until it settles (the middle of a turn).
    func progress(taskID: String) async throws -> TaskProgress {
        let payload = try await performJSON(path: "api/v1/assistant/progress/\(taskID)")
        return TaskProgress(
            status: payload["status"] as? String ?? "running",
            progress: payload["progress"] as? Double ?? 0,
            transcript: payload["transcript"] as? String ?? "",
            aiReply: payload["ai_reply"] as? String ?? "",
            replyAudioURL: payload["reply_audio_url"] as? String ?? ""
        )
    }

    /// The answer as *fala*: the synthesised speech of one finished task.
    func replyAudio(path: String) async throws -> Data {
        // `reply_audio_url` arrives as "/api/v1/assistant/reply/{id}" — do not
        // double the leading slash or the hub answers 404.
        let clean = path.hasPrefix("/") ? String(path.dropFirst()) : path
        for candidate in baseURLs {
            guard var components = URLComponents(url: candidate, resolvingAgainstBaseURL: false) else { continue }
            components.path = "/" + clean
            guard let url = components.url else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 60
            request.setValue("audio/*", forHTTPHeaderField: "Accept")
            request.setValue("WatchPilotBridge/0.1 (iOS)", forHTTPHeaderField: "User-Agent")
            do { request.setValue(try authHeader(), forHTTPHeaderField: "X-Watch-TOTP") }
            catch { throw error }
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { continue }
                if (200..<300).contains(http.statusCode), !data.isEmpty { return data }
            } catch {
                continue
            }
        }
        throw Failure.transport("fala da resposta indisponível")
    }

    // MARK: - Plumbing

    private func authHeader() throws -> String {
        guard let secret = SecretStore.secret else { throw Failure.notPaired }
        return try TotpGenerator(base32: secret).code()
    }

    private func performJSON(
        method: String = "GET",
        path: String,
        body: [String: Any]? = nil,
        authenticated: Bool = true
    ) async throws -> [String: Any] {
        var lastError: Error = Failure.transport("sem candidatos")
        for candidate in baseURLs {
            guard var components = URLComponents(url: candidate, resolvingAgainstBaseURL: false) else { continue }
            // `path` may carry a query string ("api/v1/tasks?limit=5"); URLComponents
            // would percent-encode the "?" into the path and the hub would 404.
            let parts = path.split(separator: "?", maxSplits: 1).map(String.init)
            components.path = "/" + parts[0]
            if parts.count > 1 { components.query = parts[1] }
            guard let url = components.url else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.timeoutInterval = 20
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("WatchPilotBridge/0.1 (iOS)", forHTTPHeaderField: "User-Agent")
            if authenticated {
                do { request.setValue(try authHeader(), forHTTPHeaderField: "X-Watch-TOTP") }
                catch { throw error }
            }
            if let body {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
            }
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { continue }
                switch http.statusCode {
                case 200..<300:
                    return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
                case 401:
                    throw Failure.unauthorized(reason: http.value(forHTTPHeaderField: "X-Auth-Reason") ?? "401")
                default:
                    lastError = Failure.server(http.statusCode, String(data: data, encoding: .utf8) ?? "")
                }
            } catch let failure as Failure {
                if case .unauthorized = failure { throw failure }
                lastError = failure
            } catch {
                lastError = Failure.transport(error.localizedDescription)
            }
        }
        throw lastError
    }
}
