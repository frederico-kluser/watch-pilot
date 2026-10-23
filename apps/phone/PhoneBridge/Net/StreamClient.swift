import Foundation

/// SSE consumer for the hub's live stream — the notification/telemetry pattern
/// chosen by the architecture research (one server→client HTTP stream per
/// device, no third parties).
///
/// The stream sends a `snapshot` frame first, then typed events (`notify`,
/// `launch`, `activity`) with monotonic ids; on reconnect the client sends
/// `Last-Event-ID` and gets exactly what it missed. Reconnection is ours
/// (Foundation has no EventSource): exponential backoff with jitter.
actor StreamClient {
    struct Event: Equatable {
        let id: Int?
        let kind: String
        let payload: [String: Any]

        static func == (lhs: Event, rhs: Event) -> Bool {
            lhs.id == rhs.id && lhs.kind == rhs.kind
        }
    }

    private let client: HubClient
    private var lastEventID: Int = 0
    private var running = false

    init(client: HubClient = .live()) {
        self.client = client
    }

    /// Run the stream until cancelled, invoking `onEvent` per frame.
    func run(onEvent: @escaping @Sendable (Event) -> Void) async {
        guard !running else { return }
        running = true
        var backoff = 1.0
        while !Task.isCancelled && running {
            do {
                for try await event in events() {
                    backoff = 1.0
                    if let id = event.id { lastEventID = max(lastEventID, id) }
                    onEvent(event)
                }
            } catch {
                // The network always wins eventually: keep the socket warm with
                // a growing (jittered) pause, and resume from the last id.
                try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
                backoff = min(backoff * 2, 30)
            }
        }
        running = false
    }

    func stop() {
        running = false
    }

    /// One connection: the frames the hub sends, in order.
    private func events() -> AsyncThrowingStream<Event, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let url = try self.client.streamURL()
                    NSLog("STREAM-CONNECT: %@", url.absoluteString)
                    var request = try self.client.signed(URLRequest(url: url))
                    request.timeoutInterval = 300
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    // Compression is the classic SSE killer: URLSession asks for
                    // gzip by default and an intermediary may buffer the stream
                    // until the compressed block fills. Identity, always.
                    request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                    request.setValue(String(self.lastEventID), forHTTPHeaderField: "Last-Event-ID")
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                        throw URLError(.badServerResponse)
                    }
                    var id: Int? = nil
                    var kind = "message"
                    var dataLines: [String] = []
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        if line.isEmpty {
                            if !dataLines.isEmpty {
                                let payload = (try? JSONSerialization.jsonObject(
                                    with: Data(dataLines.joined().utf8),
                                ) as? [String: Any]) ?? [:]
                                continuation.yield(Event(id: id, kind: kind, payload: payload))
                            }
                            id = nil
                            kind = "message"
                            dataLines = []
                            continue
                        }
                        if line.hasPrefix(":") { continue }  // keepalive comment
                        // Blank-line dispatch is the spec, but some line
                        // sequences drop the empty lines: flush at the next
                        // frame boundary too, so no event is ever lost.
                        if line.hasPrefix("id: ") || line.hasPrefix("event: ") {
                            if !dataLines.isEmpty {
                                let payload = (try? JSONSerialization.jsonObject(
                                    with: Data(dataLines.joined().utf8),
                                ) as? [String: Any]) ?? [:]
                                continuation.yield(Event(id: id, kind: kind, payload: payload))
                                id = nil
                                kind = "message"
                                dataLines = []
                            }
                        }
                        if line.hasPrefix("id: ") { id = Int(line.dropFirst(4)) }
                        else if line.hasPrefix("event: ") { kind = String(line.dropFirst(7)) }
                        else if line.hasPrefix("data: ") { dataLines.append(String(line.dropFirst(6))) }
                    }
                    if !dataLines.isEmpty {
                        let payload = (try? JSONSerialization.jsonObject(
                            with: Data(dataLines.joined().utf8),
                        ) as? [String: Any]) ?? [:]
                        continuation.yield(Event(id: id, kind: kind, payload: payload))
                    }
                    continuation.finish()
                } catch {
                    NSLog("STREAM-ERRO: %@", error.localizedDescription)
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

}
