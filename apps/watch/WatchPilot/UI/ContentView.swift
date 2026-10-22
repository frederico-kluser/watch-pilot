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
        // O visor do T-800 ocupa o ecrã INTEIRO: o HUD é o botão (a ação depende
        // do estado) e por cima flutuam a barra de topo e a legenda.
        ZStack {
            hudButton
            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                statusBlock
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Full-bleed, como o visor da referência: o "T-800" partilha a linha do
        // relógio do sistema e o HUD usa o ecrã todo.
        .ignoresSafeArea(.container, edges: [.top, .bottom])
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

    // MARK: - Barra de topo

    /// "T-800" à esquerda, com ● vermelho enquanto grava. A hora já vive na barra
    /// de status do watchOS (canto superior direito), como no visor da Cyberdyne.
    private var topBar: some View {
        HStack(spacing: 4) {
            if controller.phase.isRecording {
                Circle()
                    .fill(Palette.crimson)
                    .frame(width: 5, height: 5)
            }
            Text("T-800")
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(Palette.muted)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.top, 4)
    }

    // MARK: - HUD

    /// O visor inteiro é o botão: tocar no HUD executa a ação do estado (gravar,
    /// enviar, cancelar, abrir a resposta). O crânio desenha-se num espaço de
    /// 190×231 pt e escala pela largura do relógio que o hospeda.
    private var hudButton: some View {
        Button(action: primaryAction) {
            GeometryReader { geo in
                AssistantAvatar(phase: controller.phase, isReduceMotion: reduceMotion)
                    .frame(width: 190, height: 231)
                    .scaleEffect(geo.size.width / 190)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(hudAccessibilityLabel))
        .accessibilityHint(Text(controller.phase.hint))
    }

    private var hudAccessibilityLabel: String {
        if !controller.pairingReady { return "Emparelhar" }
        switch controller.phase {
        case .listening: return "Enviar comando"
        case .uploading, .waiting: return "Cancelar comando"
        case .answering: return "Abrir a resposta completa"
        case .failed: return "Tentar de novo"
        case .idle: return "Gravar comando de voz"
        }
    }

    // MARK: - Copy

    /// A legenda do visor, por cima do scrim escuro no fim do canvas. A resposta
    /// do hub pode crescer (scroll) sem nunca empurrar nada do sítio.
    private var statusBlock: some View {
        ScrollView {
            VStack(spacing: 1) {
                Text(controller.phase.headline)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(headlineColor)
                    .textCase(isShortStatus ? .uppercase : nil)
                    .multilineTextAlignment(.center)
                    .lineLimit(isShortStatus ? 1 : 4)
                    .minimumScaleFactor(0.85)
                    .fixedSize(horizontal: false, vertical: true)

                if let spoken = transcriptLine {
                    Text(spoken)
                        .font(.system(size: 8.5, design: .rounded))
                        .foregroundStyle(Palette.muted)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text(footnote)
                    .font(.system(size: 8.5, design: .rounded))
                    .foregroundStyle(Palette.muted.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 10)
            .padding(.vertical, 1)
        }
        .scrollIndicators(.hidden)
        .frame(maxHeight: isShortStatus ? 42 : 62)
        .padding(.bottom, 4)
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

    /// A resposta do hub é texto corrido; os estados curtos leem-se como o visor:
    /// em maiúsculas, tipo terminal.
    private var isShortStatus: Bool {
        if case .answering = controller.phase { return false }
        return true
    }

    private var headlineColor: Color {
        switch controller.phase {
        case .idle: return Palette.ink
        case .listening: return Palette.crimson
        case .uploading: return Palette.amber
        case .waiting: return Palette.muted
        case .answering: return Palette.ink
        case .failed: return Palette.crimson
        }
    }

    // MARK: - Action

    /// A única ação do visor — o HUD inteiro é o botão e o que acontece depende
    /// do estado: gravar, enviar, cancelar, abrir a resposta, tentar de novo.
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
