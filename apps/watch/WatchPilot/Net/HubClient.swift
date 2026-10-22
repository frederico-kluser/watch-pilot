import Foundation

/// Everything the watch needs to talk to the Mac mini hub.
///
/// Every request carries a freshly generated `X-Watch-TOTP` code — the shared
/// secret never leaves the watch after pairing.
struct HubClient {
    enum Failure: LocalizedError {
        case notPaired
        case badURL
        case unauthorized(reason: String)
        case transport(String)
        case server(Int, String)
        case decoding(String)

        var errorDescription: String? {
            switch self {
            case .notPaired: return "Relógio sem segredo TOTP — emparelha no Mac."
            case .badURL: return "Endereço do hub inválido."
            case .unauthorized(let reason): return "Código TOTP recusado (\(reason))."
            case .transport(let detail): return "Mac mini inacessível: \(detail)"
            case .server(let code, let detail): return "Hub respondeu \(code): \(detail)"
            case .decoding(let detail): return "Resposta inesperada do hub: \(detail)"
            }
        }
    }

    /// Ordered candidates: the tunnel first (works anywhere), then the LAN name.
    let baseURLs: [URL]
    private let session: URLSession

    init(baseURLs: [URL], session: URLSession = .shared) {
        self.baseURLs = baseURLs
        self.session = session
    }

    static func fromBundle() -> HubClient {
        var candidates: [URL] = []
        let info = Bundle.main.infoDictionary ?? [:]
        if let remote = info["WPHubBaseURL"] as? String, let url = URL(string: remote) {
            candidates.append(url)
        }
        if let local = info["WPHubLocalURL"] as? String, let url = URL(string: local) {
            candidates.append(url)
        }
        #if targetEnvironment(simulator)
        // The simulator shares the host loopback, so reach the hub directly.
        if let sim = info["WPHubSimulatorURL"] as? String, let url = URL(string: sim) {
            candidates.insert(url, at: 0)
        }
        #endif
        return HubClient(baseURLs: candidates)
    }

    var pollInterval: TimeInterval {
        let value = Bundle.main.object(forInfoDictionaryKey: "WPPollIntervalSeconds") as? Int
        return TimeInterval(value ?? 3)
    }

    // MARK: - Requests

    func upload(audioAt url: URL) async throws -> TaskStatus {
        let audio = try Data(contentsOf: url)
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"audio_file\"; filename=\"voice_cmd.m4a\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/mp4\r\n\r\n".data(using: .utf8)!)
        body.append(audio)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var request = URLRequest(url: try base())
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120
        return try await perform(request, body: body)
    }

    func progress(taskID: String) async throws -> TaskStatus {
        var request = URLRequest(url: try base().appendingPathComponent("api/v1/assistant/progress/\(taskID)"))
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        return try await perform(request, body: nil)
    }

    /// The answer as synthesised speech: raw m4a/mp3 bytes from
    /// `GET /api/v1/assistant/reply/{task_id}` (same TOTP auth as every request).
    func replyAudio(taskID: String) async throws -> Data {
        var request = URLRequest(url: try base().appendingPathComponent("api/v1/assistant/reply/\(taskID)"))
        request.httpMethod = "GET"
        request.timeoutInterval = 60
        return try await performRaw(request, body: nil)
    }

    func notify(title: String, body: String, taskID: String = "") async throws {
        var request = URLRequest(url: try base().appendingPathComponent("api/v1/notify"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = ["title": title, "body": body, "task_id": taskID]
        _ = try? await performRaw(request, body: try JSONSerialization.data(withJSONObject: payload))
    }

    func registerDeviceToken(_ token: String) async throws {
        var request = URLRequest(url: try base().appendingPathComponent("api/v1/register-device"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = ["device_token": token, "platform": "watchos"]
        _ = try? await performRaw(request, body: try JSONSerialization.data(withJSONObject: payload))
    }

    func status() async throws -> [String: Any] {
        var request = URLRequest(url: try base().appendingPathComponent("api/v1/status"))
        request.httpMethod = "GET"
        let (data, _) = try await send(request, body: nil)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    // MARK: - Plumbing

    private func base() throws -> URL {
        guard let first = baseURLs.first else { throw Failure.badURL }
        return first
    }

    private func authHeader() throws -> String {
        guard let secret = SecretStore.secret else { throw Failure.notPaired }
        let generator = try TotpGenerator(base32: secret)
        return generator.code()
    }

    private func send(_ request: URLRequest, body: Data?) async throws -> (Data, HTTPURLResponse) {
        var request = request
        request.setValue(try authHeader(), forHTTPHeaderField: "X-Watch-TOTP")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        // Try each candidate base URL in order; the first transport success wins.
        var lastError: Error = Failure.badURL
        let paths: [String] = baseURLs.map { _ in "" }
        _ = paths
        for candidate in baseURLs {
            var attempt = request
            if var components = URLComponents(url: attempt.url ?? candidate, resolvingAgainstBaseURL: false) {
                components.scheme = candidate.scheme
                components.host = candidate.host
                components.port = candidate.port
                attempt.url = components.url
            }
            do {
                let (data, response) = try await session.upload(for: attempt, from: body ?? Data())
                guard let http = response as? HTTPURLResponse else {
                    throw Failure.transport("resposta sem HTTP")
                }
                switch http.statusCode {
                case 200..<300:
                    return (data, http)
                case 401:
                    let reason = http.value(forHTTPHeaderField: "X-Auth-Reason")
                        ?? String(data: data, encoding: .utf8)?.prefix(120).description
                        ?? "sem detalhe"
                    throw Failure.unauthorized(reason: reason)
                default:
                    let detail = String(data: data, encoding: .utf8)?.prefix(160).description ?? ""
                    throw Failure.server(http.statusCode, detail)
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

    private func perform(_ request: URLRequest, body: Data?) async throws -> TaskStatus {
        let (data, _) = try await send(request, body: body)
        do {
            return try JSONDecoder().decode(TaskStatus.self, from: data)
        } catch {
            throw Failure.decoding(error.localizedDescription)
        }
    }

    private func performRaw(_ request: URLRequest, body: Data?) async throws -> Data {
        try await send(request, body: body).0
    }
}
