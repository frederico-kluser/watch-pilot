import SwiftUI

/// Create one task and send it to the floor: pick the project by browsing the
/// server's folders, write the prompt, and decide **new story or not** (a fresh
/// named worktree, or the project as it stands).
struct LaunchView: View {
    @Bindable var live: LiveStore
    let client: HubClient

    @State private var folder: HubClient.FolderListing?
    @State private var projectPath = ""
    @State private var prompt = ""
    @State private var newStory = true
    @State private var storyName = ""
    @State private var busy = false
    @State private var note = ""

    var body: some View {
        NavigationStack {
            List {
                Section("Projeto · navegar as pastas do Mac") {
                    HStack {
                        Button {
                            Task { await browse(folder?.parent ?? "~") }
                        } label: {
                            Image(systemName: "arrow.up")
                        }
                        .disabled(folder == nil)
                        Text(folder?.path ?? "~")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Palette.muted)
                            .lineLimit(1)
                    }
                    ForEach(folder?.entries.filter(\.isDir) ?? []) { entry in
                        Button {
                            if entry.path == projectPath {
                                projectPath = ""
                            } else {
                                projectPath = entry.path
                            }
                        } label: {
                            HStack {
                                Image(systemName: entry.path == projectPath ? "checkmark.circle.fill" : "folder")
                                    .foregroundStyle(entry.path == projectPath ? Palette.mint : Palette.blue)
                                Text(entry.name)
                                    .foregroundStyle(Palette.ink)
                                Spacer()
                            }
                        }
                    }
                }

                Section("Tarefa") {
                    TextField("O que tem de ser feito?", text: $prompt, axis: .vertical)
                        .lineLimit(3...6)
                    Toggle(isOn: $newStory) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Nova história").font(.system(.subheadline, design: .rounded))
                            Text(newStory ? "worktree nova e nomeada" : "no projeto como está")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Palette.muted)
                        }
                    }
                    .tint(Palette.crimson)
                    if newStory {
                        TextField("Nome da história (opcional)", text: $storyName)
                            .font(.system(size: 12, design: .monospaced))
                    }
                }

                Section {
                    Button {
                        Task { await send() }
                    } label: {
                        HStack {
                            Spacer()
                            if busy { ProgressView().controlSize(.mini) }
                            Text(busy ? "A lançar…" : "Lançar no DSH")
                                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                            Spacer()
                        }
                    }
                    .disabled(busy || prompt.trimmingCharacters(in: .whitespaces).isEmpty || projectPath.isEmpty)
                    if !note.isEmpty {
                        Text(note)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Palette.mint)
                    }
                }
            }
            .navigationTitle("Lançar tarefa")
            .task { await browse("~") }
        }
        .tint(Palette.crimson)
    }

    private func browse(_ path: String) async {
        folder = try? await client.folder(at: path)
    }

    private func send() async {
        busy = true
        defer { busy = false }
        do {
            let project = projectPath.split(separator: "/").last.map(String.init) ?? projectPath
            let result = try await client.launch(
                prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
                project: project,
                newStory: newStory,
                storyName: storyName.trimmingCharacters(in: .whitespaces)
            )
            note = "\(result.status) · \(result.launchID.prefix(8)) · \(project)"
            prompt = ""
            await live.refresh()
        } catch {
            note = error.localizedDescription
        }
    }
}

/// The live floor: who works, who does not, and what each is typing right now.
struct ActivityView: View {
    @Bindable var live: LiveStore

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        metric(live.agents.filter(\.isWorking).count, "a trabalhar", Palette.crimson)
                        metric(live.agents.filter { !$0.isWorking }.count, "parados", Palette.muted)
                        if let at = live.lastEventAt {
                            metric(Int(-at.timeIntervalSinceNow), "s desde evento", Palette.blue)
                        }
                    }
                    .listRowBackground(Palette.surface)
                }

                Section("Agentes") {
                    if live.agents.isEmpty {
                        Text("Sem sessões ativas.")
                            .foregroundStyle(Palette.muted)
                    }
                    ForEach(live.agents) { agent in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Circle()
                                    .fill(agent.isWorking ? Palette.crimson : Palette.muted)
                                    .frame(width: 7, height: 7)
                                Text(agent.name)
                                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                                Spacer()
                                Text(agent.isWorking ? "a trabalhar" : "parado")
                                    .font(.system(size: 10, weight: .bold, design: .rounded))
                                    .foregroundStyle(agent.isWorking ? Palette.crimson : Palette.muted)
                            }
                            if !agent.line.isEmpty {
                                Text(agent.line)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(Palette.ink)
                            }
                            if !agent.workspace.isEmpty {
                                Text(agent.workspace)
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(Palette.muted)
                                    .lineLimit(1)
                            }
                        }
                    }
                }

                if !live.launches.isEmpty {
                    Section("Tarefas") {
                        ForEach(live.launches) { launch in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(launch.project)
                                        .font(.system(.footnote, design: .rounded).weight(.semibold))
                                    Spacer()
                                    Text(launch.status)
                                        .font(.system(size: 10, weight: .bold, design: .rounded))
                                        .foregroundStyle(color(for: launch.status))
                                }
                                Text(launch.prompt)
                                    .font(.system(size: 11, design: .rounded))
                                    .foregroundStyle(Palette.muted)
                                    .lineLimit(2)
                                if !launch.worktreePath.isEmpty {
                                    Text(launch.worktreePath)
                                        .font(.system(size: 9, design: .monospaced))
                                        .foregroundStyle(Palette.muted)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Atividade")
            .refreshable { await live.refresh() }
        }
    }

    private func metric(_ value: Int, _ label: String, _ color: Color) -> some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(color)
            Text(label)
                .font(.system(size: 9, design: .rounded))
                .foregroundStyle(Palette.muted)
        }
        .frame(maxWidth: .infinity)
    }

    private func color(for status: String) -> Color {
        switch status {
        case "completed": return Palette.mint
        case "failed": return Palette.crimson
        case "running": return Palette.blue
        default: return Palette.amber
        }
    }
}
