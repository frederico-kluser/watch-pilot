import SwiftUI

/// The bridge, one screen at a time: the T-800 link first, then the notification
/// desk, then the system page with the two kluser.me routes and Apple Intelligence.
struct ContentView: View {
    @Environment(AppStore.self) private var store
    @State private var tab = StartTab.current

    enum StartTab: Hashable {
        case link, notifications, system

        /// Debug hook for screenshot scripts: `-WPStartTab notifications|system`.
        static var current: StartTab {
            let arguments = ProcessInfo.processInfo.arguments
            guard let index = arguments.firstIndex(of: "-WPStartTab"),
                  index + 1 < arguments.count else { return .link }
            switch arguments[index + 1] {
            case "notifications": return .notifications
            case "system": return .system
            default: return .link
            }
        }
    }

    var body: some View {
        TabView(selection: $tab) {
            T800LinkView(monitor: store.monitor, intelligence: store.intelligence, turn: store.turn)
                .tabItem { Label("T-800", systemImage: "waveform.path.ecg") }
                .badge(store.inbox.unreadCount)
                .tag(StartTab.link)

            NotificationsView(inbox: store.inbox)
                .tabItem { Label("Notificações", systemImage: "bell.badge") }
                .tag(StartTab.notifications)

            SystemView(monitor: store.monitor, intelligence: store.intelligence, inbox: store.inbox)
                .tabItem { Label("Sistema", systemImage: "antenna.radiowaves.left.and.right") }
                .tag(StartTab.system)
        }
        .tint(Palette.crimson)
    }
}

// MARK: - T-800

/// The page that matters: is the assistant chain alive, and what did it last say.
struct T800LinkView: View {
    @Bindable var monitor: StatusMonitor
    @Bindable var intelligence: AppleIntelligence
    @Bindable var turn: TurnController

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    turnCard
                    linkCard
                    briefingCard
                    HStack(spacing: 10) {
                        ForEach(monitor.probes) { probe in
                            EndpointCard(probe: probe)
                        }
                    }
                }
                .padding()
            }
            .background(Palette.background.ignoresSafeArea())
            .navigationTitle("T-800 BRIDGE")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await monitor.refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(monitor.refreshing)
                }
            }
        }
    }

    /// The start-to-finish path, on the phone: speak → hub → spoken reply.
    private var turnCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("TURNO DE VOZ · PONTE COMPLETA")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(Palette.muted)
                Spacer()
                Text(turn.phase.label)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(turnColor)
            }

            HStack(spacing: 16) {
                Button {
                    switch turn.phase {
                    case .idle, .finished:
                        turn.reset()
                        turn.startRecording()
                    case .recording:
                        turn.finishAndSend()
                    default:
                        break
                    }
                } label: {
                    ZStack {
                        Circle()
                            .fill(turn.isRecording ? Palette.blue : Palette.crimson)
                            .frame(width: 74, height: 74)
                            .shadow(color: (turn.isRecording ? Palette.blue : Palette.crimson).opacity(0.6), radius: 12)
                        Image(systemName: turn.isRecording ? "stop.fill" : "mic.fill")
                            .font(.system(size: 26, weight: .bold))
                            .foregroundStyle(Palette.background)
                    }
                }
                .buttonStyle(.plain)
                .disabled(turn.isBusy)

                VStack(alignment: .leading, spacing: 6) {
                    Text(turn.isRecording ? "Toca para enviar" : "Toca para falar com o T-800")
                        .font(.system(.footnote, design: .rounded).weight(.semibold))
                        .foregroundStyle(Palette.ink)
                    Text(turn.isSpeaking ? "fala a tocar · nível \(Int(turn.speakingLevel * 100))%" : "gravar → Mac mini → resposta falada")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Palette.muted)
                }
            }

            if !turn.transcript.isEmpty {
                Text("“\(turn.transcript)”")
                    .font(.system(.footnote, design: .rounded))
                    .foregroundStyle(Palette.ink)
            }
            if !turn.reply.isEmpty {
                Text(turn.reply)
                    .font(.system(.footnote, design: .rounded))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 16).fill(Palette.surface))
    }

    private var turnColor: Color {
        switch turn.phase {
        case .recording: return Palette.blue
        case .speaking: return Palette.crimson
        case .failed: return Palette.crimson
        case .finished: return Palette.mint
        default: return Palette.muted
        }
    }

    private var linkCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Circle()
                    .fill(monitor.link.paired ? Palette.mint : Palette.crimson)
                    .frame(width: 8, height: 8)
                Text(monitor.link.paired ? "T-800 EMPARELHADO" : "T-800 SEM PAREAMENTO")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(Palette.muted)
                Spacer()
                Text(monitor.link.hubModel)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Palette.muted)
            }

            Text("ÚLTIMO TURNO")
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(Palette.muted)
            Text(monitor.link.lastTranscript.isEmpty ? "—" : "“\(monitor.link.lastTranscript)”")
                .font(.system(.callout, design: .rounded))
                .foregroundStyle(Palette.ink)

            Text(monitor.link.lastReply.isEmpty ? "Sem resposta ainda." : monitor.link.lastReply)
                .font(.system(.footnote, design: .rounded))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)

            if let checked = monitor.link.checkedAt {
                Text("verificado \(checked.formatted(date: .omitted, time: .shortened)) · \(monitor.link.lastStatus)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Palette.muted)
            }
            if !monitor.link.error.isEmpty {
                Text(monitor.link.error)
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(Palette.crimson)
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 16).fill(Palette.surface))
    }

    private var briefingCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("BRIEFING · APPLE INTELLIGENCE")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(Palette.muted)
                Spacer()
                if intelligence.thinking { ProgressView().controlSize(.mini) }
            }
            Text(intelligence.lastOutput.isEmpty ? intelligence.availability.label : intelligence.lastOutput)
                .font(.system(.footnote, design: .rounded))
                .foregroundStyle(intelligence.lastOutput.isEmpty ? Palette.amber : Palette.ink)
                .fixedSize(horizontal: false, vertical: true)

            Button("Processar o último turno") {
                Task {
                    _ = await intelligence.process(
                        transcript: monitor.link.lastTranscript,
                        reply: monitor.link.lastReply
                    )
                }
            }
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .buttonStyle(.borderedProminent)
            .tint(Palette.crimson)
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 16).fill(Palette.surface))
    }
}

// MARK: - Notifications

/// The notification desk: the bridge checks the endpoint, manages what came in,
/// and can push a notification back through the hub.
struct NotificationsView: View {
    @Bindable var inbox: InboxStore
    @State private var draftTitle = "Watch Pilot"
    @State private var draftBody = ""

    var body: some View {
        NavigationStack {
            List {
                Section("Caixa de entrada") {
                    if inbox.items.isEmpty {
                        Text(inbox.lastError.isEmpty ? "Sem notificações." : inbox.lastError)
                            .foregroundStyle(Palette.muted)
                    }
                    ForEach(inbox.items) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Circle()
                                    .fill(item.read ? Palette.muted : Palette.crimson)
                                    .frame(width: 6, height: 6)
                                Text(item.title)
                                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                                Spacer()
                                Text(item.date.formatted(date: .abbreviated, time: .shortened))
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(Palette.muted)
                            }
                            Text(item.body)
                                .font(.system(.footnote, design: .rounded))
                                .foregroundStyle(Palette.ink)
                        }
                        .swipeActions(edge: .trailing) {
                            Button("Lida") { inbox.markRead(item.id) }
                                .tint(Palette.mint)
                        }
                    }
                }

                Section("Avisos no iPhone") {
                    Button("Ativar avisos no iPhone") {
                        Task { _ = await inbox.requestAuthorization() }
                    }
                    if inbox.unreadCount > 0 {
                        Button("Marcar todas como lidas") { inbox.markAllRead() }
                    }
                }

                Section("Enviar pelo hub") {
                    TextField("Título", text: $draftTitle)
                    TextField("Mensagem", text: $draftBody)
                    Button("Enviar notificação") {
                        let body = draftBody
                        draftBody = ""
                        Task { try? await inbox.send(title: draftTitle, body: body) }
                    }
                    .disabled(draftBody.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                if let last = inbox.lastFetch {
                    Section {
                        Text("última verificação \(last.formatted(date: .omitted, time: .shortened))")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(Palette.muted)
                    }
                }
            }
            .navigationTitle("Notificações")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await inbox.fetch() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(inbox.fetching)
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Todas lidas") { inbox.markAllRead() }
                        .disabled(inbox.unreadCount == 0)
                }
            }
        }
        .tint(Palette.crimson)
    }
}

// MARK: - System

struct SystemView: View {
    @Bindable var monitor: StatusMonitor
    @Bindable var intelligence: AppleIntelligence
    @Bindable var inbox: InboxStore

    var body: some View {
        NavigationStack {
            List {
                Section("Rotas públicas") {
                    ForEach(monitor.probes) { probe in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(probe.name).font(.system(.subheadline, design: .rounded))
                                Text(probe.detail)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(Palette.muted)
                            }
                            Spacer()
                            VStack(alignment: .trailing) {
                                Text(probe.online ? "ONLINE" : "OFFLINE")
                                    .font(.system(size: 11, weight: .bold, design: .rounded))
                                    .foregroundStyle(probe.online ? Palette.mint : Palette.crimson)
                                Text("\(probe.latencyMS) ms")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(Palette.muted)
                            }
                        }
                    }
                }

                Section("Inteligência") {
                    LabeledContent("Estado", value: intelligence.availability.label)
                    LabeledContent("Modelo do hub", value: monitor.link.hubModel)
                }

                Section("Ponte") {
                    LabeledContent("Segredo TOTP", value: SecretStore.secret == nil ? "em falta" : "presente")
                    LabeledContent("Notificações não lidas", value: "\(inbox.unreadCount)")
                    Button("Verificar tudo agora") {
                        Task {
                            await monitor.refresh()
                            await inbox.fetch()
                        }
                    }
                }
            }
            .navigationTitle("Sistema")
        }
    }
}

// MARK: - Cards

extension TurnController {
    var isRecording: Bool {
        if case .recording = phase { return true }
        return false
    }

    var isBusy: Bool {
        switch phase {
        case .uploading, .thinking, .speaking: return true
        default: return false
        }
    }

    var isSpeaking: Bool {
        if case .speaking = phase { return true }
        return false
    }
}

struct EndpointCard: View {
    let probe: HubClient.ProbeResult

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Circle()
                    .fill(probe.online ? Palette.mint : Palette.crimson)
                    .frame(width: 7, height: 7)
                Text(probe.name)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Text(probe.online ? "online" : "offline")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(probe.online ? Palette.mint : Palette.crimson)
            Text("\(probe.latencyMS) ms")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Palette.muted)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Palette.surface))
    }
}

#Preview {
    ContentView()
        .environment(AppStore())
}
