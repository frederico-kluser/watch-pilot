import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// On-device Apple Intelligence for the bridge (iPhone 16e · Apple Foundation Model).
///
/// The phone is the place where "things get processed": every voice turn that comes
/// back from the Mac mini (transcript + answer) is turned here into a short
/// operational briefing, and a batch of notifications is condensed into one line —
/// all on-device, no network, no extra cost.
///
/// When Apple Intelligence is not available (simulator, older device, model still
/// downloading) the engine degrades to a deterministic local summary so the bridge
/// keeps working and the UI can say exactly why.
@MainActor
@Observable
final class AppleIntelligence {
    enum Availability: Equatable {
        case available
        case unavailable(String)

        var label: String {
            switch self {
            case .available: return "Apple Intelligence pronto"
            case .unavailable(let reason): return "Apple Intelligence indisponível · \(reason)"
            }
        }
    }

    private(set) var availability: Availability = .unavailable("não verificado")
    private(set) var lastOutput: String = ""
    private(set) var thinking = false

    func checkAvailability() {
        #if canImport(FoundationModels)
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            availability = .available
        case .unavailable(.deviceNotEligible):
            availability = .unavailable("dispositivo não elegível")
        case .unavailable(.modelNotReady):
            availability = .unavailable("modelo ainda a preparar")
        case .unavailable:
            availability = .unavailable("razão desconhecida")
        }
        #else
        availability = .unavailable("framework FoundationModels indisponível")
        #endif
    }

    /// Turn one voice turn into a briefing: what was asked, what the assistant
    /// answered, and what to do next.
    func process(transcript: String, reply: String) async -> String {
        let fallback = Self.fallbackBriefing(transcript: transcript, reply: reply)
        #if canImport(FoundationModels)
        guard case .available = availability else {
            lastOutput = fallback
            return fallback
        }
        thinking = true
        defer { thinking = false }
        do {
            let session = LanguageModelSession(instructions: """
                És a ponte de um assistente de voz (Apple Watch → Mac mini). \
                Recebes a transcrição do comando do utilizador e a resposta do assistente. \
                Escreve UM briefing curto em português (máx. 3 frases): o que foi pedido, \
                o que foi feito/dito e a próxima ação concreta, se houver. Sem preâmbulos.
                """)
            let response = try await session.respond(
                to: "Transcrição: \(transcript)\nResposta: \(reply)"
            )
            let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            lastOutput = text.isEmpty ? fallback : text
        } catch {
            lastOutput = fallback
        }
        return lastOutput
        #else
        lastOutput = fallback
        return fallback
        #endif
    }

    /// Condense a batch of notifications into a single spoken line.
    func summarize(notifications: [(title: String, body: String)]) async -> String {
        guard !notifications.isEmpty else { return "" }
        let joined = notifications.map { "\($0.title): \($0.body)" }.joined(separator: "\n")
        #if canImport(FoundationModels)
        guard case .available = availability else { return Self.fallbackSummary(notifications) }
        thinking = true
        defer { thinking = false }
        do {
            let session = LanguageModelSession(instructions: """
                Resume as notificações seguintes numa única linha curta em português, \
                começando pelo que é mais urgente. Máx. 20 palavras.
                """)
            let response = try await session.respond(to: joined)
            let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? Self.fallbackSummary(notifications) : text
        } catch {
            return Self.fallbackSummary(notifications)
        }
        #else
        return Self.fallbackSummary(notifications)
        #endif
    }

    // MARK: - Deterministic fallback (no model required)

    static func fallbackBriefing(transcript: String, reply: String) -> String {
        let asked = transcript.isEmpty ? "(sem transcrição)" : transcript
        let answered = reply.isEmpty ? "(sem resposta)" : reply
        return "Pedido: \(asked)\nResposta: \(answered)"
    }

    static func fallbackSummary(_ notifications: [(title: String, body: String)]) -> String {
        guard let first = notifications.first else { return "" }
        let extra = notifications.count - 1
        return extra > 0
            ? "\(first.title): \(first.body) (+\(extra))"
            : "\(first.title): \(first.body)"
    }
}
