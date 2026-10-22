import SwiftUI
import WatchKit

/// One screen, one job: talk to the Mac mini and read what came back.
///
/// Layout is three bands — optical target, copy, action — so the button can never be
/// pushed off a 40 mm face by a long answer. The answer itself is never silently
/// truncated: anything that does not fit opens in a scrollable detail sheet, and the
/// transcript is always visible so a misrecognition can be spotted.
struct ContentView: View {
    @State private var controller = AssistantController.shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showDetails = false
    @State private var showFullAnswer = false

    var body: some View {
        // A single screen with three bands: optical target, copy, action. The copy
        // flexes; the orb and the button never do.
        VStack(spacing: 2) {
            orbButton
            // The copy band scrolls inside a fixed slice: a long answer can always be
            // read, and it can never push the button off the screen.
            ScrollView {
                statusBlock.padding(.vertical, 1)
            }
            .scrollIndicators(.hidden)
            .layoutPriority(1)
            .frame(minHeight: 54, maxHeight: .infinity)
            actionButton
        }
        .padding(.horizontal, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.background.ignoresSafeArea())
        .dynamicTypeSize(.xSmall ... .accessibility1)
        .onChange(of: scenePhase) { _, newPhase in
            controller.handleScenePhase(newPhase == .active)
        }
        .onAppear {
            controller.handleScenePhase(scenePhase == .active)
            #if DEBUG
            let arguments = ProcessInfo.processInfo.arguments
            if let index = arguments.firstIndex(of: "-WPDemoPhase"), index + 1 < arguments.count {
                controller.applyDemoPhase(arguments[index + 1])
            }
            if arguments.contains("-WPLiveSmoke") {
                Task { await controller.runLiveSmokeTest() }
            }
            if arguments.contains("-WPNoNotifications") {
                controller.suppressPermissionPrompt = true
            }
            if let index = arguments.firstIndex(of: "-WPAttachTask"), index + 1 < arguments.count {
                controller.attachToTask(arguments[index + 1])
            }
            #endif
        }
        .sheet(isPresented: $showDetails) { SessionDetailsView() }
        .sheet(isPresented: $showFullAnswer) { AnswerDetailView() }
    }

    // MARK: - Orb

    private var orbButton: some View {
        Button(action: { controller.toggleRecording() }) {
            AssistantAvatar(phase: controller.phase, isReduceMotion: reduceMotion)
                .frame(width: 96, height: 92)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(controller.phase.isRecording ? "Enviar comando" : "Gravar comando de voz"))
        .accessibilityHint(Text(controller.phase.hint))
        .disabled(controller.phase.isBusy)
    }

    // MARK: - Copy

    private var statusBlock: some View {
        VStack(spacing: 2) {
            Text(controller.phase.headline)
                .font(.system(.footnote, design: .rounded, weight: .semibold))
                .foregroundStyle(headlineColor)
                .multilineTextAlignment(.center)
                .lineLimit(controller.phase.isBusy ? 3 : 4)
                .minimumScaleFactor(0.8)
                .fixedSize(horizontal: false, vertical: true)

            if let spoken = transcriptLine {
                Text(spoken)
                    .font(.system(.caption2, design: .rounded))
                    .foregroundStyle(Palette.muted)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(footnote)
                .font(.system(.caption2, design: .rounded))
                .foregroundStyle(Palette.muted.opacity(0.85))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 4)
        .animation(.easeInOut(duration: 0.2), value: controller.phase)
    }

    /// What the hub heard — shown as soon as it exists, so a bad transcription is
    /// visible instead of quietly becoming a confident wrong answer.
    private var transcriptLine: String? {
        let transcript = controller.lastTranscript
        guard !transcript.isEmpty else { return nil }
        switch controller.phase {
        case .waiting, .answering:
            return "Ouvi: “\(transcript)”"
        default:
            return nil
        }
    }

    private var footnote: String {
        switch controller.phase {
        case .answering:
            if let latency = controller.lastLatencyMilliseconds {
                let backend = controller.usedBackend ?? "hub"
                let duration = latency >= 1000
                    ? String(format: "%.1f s", Double(latency) / 1000)
                    : "\(latency) ms"
                return "\(backend) · \(duration)"
            }
            return "Resposta do Mac mini"
        case .failed:
            return controller.hasPendingTask
                ? "O comando pode ter continuado no Mac"
                : "Toca para tentar de novo"
        default:
            return controller.phase.hint
        }
    }

    private var headlineColor: Color {
        switch controller.phase {
        case .idle: return Palette.ink
        case .listening: return Palette.pink
        case .uploading: return Palette.amber
        case .waiting: return Palette.violet
        case .answering: return Palette.mint
        case .failed: return Palette.red
        }
    }

    // MARK: - Action

    private var actionButton: some View {
        Button(action: primaryAction) {
            HStack(spacing: 4) {
                Image(systemName: primaryIcon)
                    .font(.system(size: 12, weight: .semibold))
                Text(primaryTitle)
                    .font(.system(.footnote, design: .rounded, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
        }
        .buttonStyle(.borderedProminent)
        .tint(primaryTint)
        .accessibilityHint(Text(accessibilityHint))
    }

    private var primaryTitle: String {
        if !controller.pairingReady { return "Emparelhar" }
        switch controller.phase {
        case .listening: return "Enviar"
        case .uploading, .waiting: return "Cancelar"
        case .failed: return controller.hasPendingTask ? "Ver estado" : "Tentar de novo"
        case .answering: return "Ver tudo"
        case .idle: return "Gravar voz"
        }
    }

    private var primaryIcon: String {
        if !controller.pairingReady { return "lock.fill" }
        switch controller.phase {
        case .listening: return "arrow.up.circle.fill"
        case .uploading, .waiting: return "xmark.circle"
        case .failed: return "arrow.clockwise"
        case .answering: return "doc.text"
        case .idle: return "mic.fill"
        }
    }

    private var primaryTint: Color {
        if !controller.pairingReady { return Palette.amber }
        switch controller.phase {
        case .listening: return Palette.pink
        case .uploading, .waiting: return Palette.blue
        case .failed: return Palette.red
        case .answering: return Palette.mint
        default: return Palette.blue
        }
    }

    private var accessibilityHint: String {
        if !controller.pairingReady { return "Abre as instruções de emparelhamento" }
        switch controller.phase {
        case .uploading, .waiting: return "Cancela este comando"
        case .answering: return "Abre a resposta completa e a transcrição"
        case .failed: return controller.hasPendingTask ? "Volta a consultar o Mac mini" : "Grava um novo comando"
        default: return "Grava um comando de voz"
        }
    }

    private func primaryAction() {
        if !controller.pairingReady {
            showDetails = true
            return
        }
        switch controller.phase {
        case .uploading, .waiting:
            controller.cancelCurrent()
        case .answering:
            showFullAnswer = true
        case .failed:
            // Retry the network round trip when there is still a task; otherwise
            // start a fresh recording. Never destroy state on the user's behalf.
            if controller.hasPendingTask {
                controller.retryLastTask()
            } else {
                controller.toggleRecording()
            }
        case .listening, .idle:
            controller.toggleRecording()
        }
    }
}

/// The full answer plus provenance. This is the route to text the summary screen
/// deliberately does not take.
struct AnswerDetailView: View {
    @State private var controller = AssistantController.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(controller.lastReply)
                    .font(.system(.body, design: .rounded))
                    .fixedSize(horizontal: false, vertical: true)

                if !controller.lastTranscript.isEmpty {
                    let transcript = controller.lastTranscript
                    divider
                    label("Ouvi")
                    Text(transcript)
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                divider
                if let latency = controller.lastLatencyMilliseconds {
                    label("Tempo")
                    Text(latencyText(latency))
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(Palette.muted)
                }
                label("Onde correu")
                Text(controller.usedBackend ?? "Mac mini")
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(Palette.muted)

                Button("Fechar") { dismiss() }
                    .font(.system(.footnote, design: .rounded, weight: .medium))
                    .tint(Palette.blue)
                    .padding(.top, 6)
            }
            .padding(.horizontal, 4)
        }
    }

    private func latencyText(_ milliseconds: Int) -> String {
        milliseconds >= 1000
            ? String(format: "%.1f segundos", Double(milliseconds) / 1000)
            : "\(milliseconds) milissegundos"
    }

    private var divider: some View {
        Rectangle().fill(Palette.surface).frame(height: 1)
    }

    private func label(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .semibold, design: .rounded))
            .foregroundStyle(Palette.muted)
    }
}

/// Pairing and diagnostics: the hub address, where the secret came from, and the
/// one action that fixes an unpaired watch.
struct SessionDetailsView: View {
    @State private var controller = AssistantController.shared
    @Environment(\.dismiss) private var dismiss
    @State private var manualSecret = ""
    @State private var feedback = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("Sessão").font(.system(.headline, design: .rounded))

                row("Hub", Bundle.main.object(forInfoDictionaryKey: "WPHubBaseURL") as? String ?? "—")
                row("Segredo", controller.pairingReady ? "no Keychain" : "em falta")
                row("Tarefa", controller.activeTaskID ?? "nenhuma")

                if !controller.pairingReady {
                    Text("Cola o segredo do Mac (o mesmo que aparece em scripts/wp.py pair).")
                        .font(.system(.caption2, design: .rounded))
                        .foregroundStyle(Palette.muted)
                    TextField("segredo base32", text: $manualSecret)
                        .font(.system(.caption2, design: .monospaced))
                    Button("Guardar") {
                        if controller.savePairingSecret(manualSecret) {
                            feedback = "Emparelhado."
                            dismiss()
                        } else {
                            feedback = "Segredo inválido."
                        }
                    }
                    .font(.system(.footnote, design: .rounded, weight: .medium))
                    .tint(Palette.mint)
                    if !feedback.isEmpty {
                        Text(feedback)
                            .font(.system(.caption2, design: .rounded))
                            .foregroundStyle(Palette.amber)
                    }
                }

                Button(controller.hasPendingTask ? "Esquecer tarefa" : "Fechar") {
                    controller.resetSession()
                    dismiss()
                }
                .font(.system(.footnote, design: .rounded, weight: .medium))
                .tint(controller.hasPendingTask ? Palette.red : Palette.blue)
                .padding(.top, 4)
            }
            .padding(.horizontal, 4)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(Palette.muted)
            Text(value)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(Palette.ink)
                .lineLimit(2)
        }
    }
}

#Preview("Assistente") {
    ContentView()
}
