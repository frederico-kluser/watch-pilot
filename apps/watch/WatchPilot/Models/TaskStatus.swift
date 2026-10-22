import Foundation

/// One voice command, as reported by `GET /api/v1/assistant/progress/{id}`.
struct TaskStatus: Codable, Equatable {
    let taskID: String
    let status: String
    let progress: Double
    let stepDescription: String
    let transcript: String?
    let aiReply: String?
    let backend: String?
    let model: String?
    let reasoningTokens: Int?
    let timingsMS: [String: Int]?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case taskID = "task_id"
        case status
        case progress
        case stepDescription = "step_description"
        case transcript
        case aiReply = "ai_reply"
        case backend
        case model
        case reasoningTokens = "reasoning_tokens"
        case timingsMS = "timings_ms"
        case error
    }

    var isFinished: Bool { status == "completed" || status == "failed" || progress >= 1.0 }

    /// One line that fits a 40 mm watch face.
    var shortSummary: String {
        if let reply = aiReply, !reply.isEmpty { return reply }
        if let transcript, !transcript.isEmpty { return "“\(transcript)”" }
        return stepDescription
    }

    var totalMilliseconds: Int? { timingsMS?["total"] }
}

/// The visual state machine of the assistant orb.
enum AssistantPhase: Equatable {
    case idle
    case listening(power: Double)
    case uploading
    case waiting(progress: Double, step: String)
    case answering(reply: String)
    case failed(message: String)

    var isRecording: Bool {
        if case .listening = self { return true }
        return false
    }

    var isBusy: Bool {
        switch self {
        case .uploading, .waiting: return true
        default: return false
        }
    }

    /// Short headline shown under the orb.
    var headline: String {
        switch self {
        case .idle: return "Toca para falar"
        case .listening: return "A ouvir…"
        case .uploading: return "A enviar ao Mac mini…"
        case .waiting(let progress, let step):
            return progress > 0.02 ? "\(Int(progress * 100))% · \(step)" : step
        case .answering(let reply): return reply
        case .failed(let message): return message
        }
    }

    /// Secondary hint line (accessibility + honesty about what is happening).
    var hint: String {
        switch self {
        case .idle: return "Comando de voz para o Mac mini"
        case .listening: return "Toca outra vez para enviar"
        case .uploading: return "Áudio a caminho do Mac mini"
        case .waiting: return "Podes baixar o pulso — aviso quando terminar"
        case .answering: return "Resposta do Mac mini"
        case .failed: return "Toca para tentar de novo"
        }
    }
}
