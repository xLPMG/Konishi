import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var showFiles = false
    @State private var showConversation = false

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        } detail: {
            if model.selectedConversationID != nil {
                if model.mode == .language {
                    LanguageView()
                } else {
                    ChatView()
                }
            } else {
                ContentUnavailableView(
                    model.mode == .language ? "No Session" : "No Conversation",
                    systemImage: model.mode == .language ? "character.book.closed" : "bubble.left.and.bubble.right"
                )
            }
        }
        .sheet(isPresented: $showFiles) {
            FilesView()
                .environment(model)
                .frame(width: 720, height: 520)
        }
        .sheet(isPresented: $showConversation) {
            ConversationView()
                .environment(model)
        }
        .sheet(item: $model.pendingInteraction) { interaction in
            MultipleChoiceView(interaction: interaction)
                .environment(model)
        }
        .onChange(of: model.pendingInteraction?.id) { _, id in
            // A pending question needs its own sheet; macOS won't present it over another one.
            if id != nil { showFiles = false }
        }
        .onChange(of: model.mode) { _, newMode in
            model.syncSelectionToMode()
            if newMode == .conversational { showConversation = true }
        }
        .onChange(of: showConversation) { _, shown in
            if !shown, model.mode == .conversational { model.mode = .chat }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Picker("Mode", selection: $model.mode) {
                    ForEach(AppMode.allCases) { Label($0.label, systemImage: $0.icon).tag($0) }
                }
                .pickerStyle(.segmented)
                .help("Chat, hands-free Voice, or Learn mode")
            }
            ToolbarItemGroup(placement: .principal) {
                PersonaPicker()
            }
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 10) {
                    ConnectionDot()

                    Menu {
                        Button { openWindow(id: "memory") } label: {
                            Label("Open Memory…", systemImage: "tray.full")
                        }
                        Button { model.reflect() } label: {
                            Label("Update Memory", systemImage: "brain.head.profile")
                        }
                        .disabled(model.selectedConversation?.messages.isEmpty ?? true)
                        Button { model.consolidateMemory() } label: {
                            Label("Clean Up Memory", systemImage: "wand.and.stars")
                        }
                        .disabled(model.selectedConversation?.messages.isEmpty ?? true)
                        Divider()
                        Button { model.settings.pauseMemoryWrites.toggle() } label: {
                            Label(model.settings.pauseMemoryWrites ? "Resume New Memories" : "Pause New Memories",
                                  systemImage: model.settings.pauseMemoryWrites ? "play.circle" : "pause.circle")
                        }
                    } label: {
                        Image(systemName: model.settings.pauseMemoryWrites ? "brain.head.profile.fill" : "brain.head.profile")
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .foregroundStyle(model.settings.pauseMemoryWrites ? .orange : .primary)
                    .help(model.settings.pauseMemoryWrites
                        ? "Memory — new memories are paused (existing memory still used)."
                        : "Open memory, update it now, or pause saving new memories.")

                    Menu {
                        Button { showFiles = true } label: {
                            Label("Files…", systemImage: "folder")
                        }
                        Button { openWindow(id: "trace") } label: {
                            Label("Trace…", systemImage: "list.bullet.rectangle")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("Files and request trace")

                    Button { openWindow(id: "settings") } label: {
                        Image(systemName: "gearshape")
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(",", modifiers: .command)
                    .help("Settings")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(.white.opacity(0.08)))
            }
        }
    }
}

private struct PersonaPicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            ForEach(model.personaStore.personas) { persona in
                Button {
                    if let id = model.selectedConversationID {
                        model.setPersona(persona.id, for: id)
                    }
                } label: {
                    Label(persona.name, systemImage: persona.iconSymbol)
                }
            }
        } label: {
            Label(model.currentPersona.name, systemImage: model.currentPersona.iconSymbol)
        }
        .help("Persona (system prompt + memory)")
    }
}

private struct ConnectionDot: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let color: Color = switch model.connectionOK {
        case .some(true): .green
        case .some(false): .red
        case .none: .yellow
        }
        Button {
            model.refreshServerInfo()
        } label: {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .help(model.connectionOK == true ? "Connected" : "Not connected")
    }
}
