import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.colorScheme) private var colorScheme
    @State private var showInspector = false
    @State private var sidebarWanted = true
    @State private var windowWidth: CGFloat = 1200
    @State private var inspectorWidth: CGFloat = Self.minInspectorWidth
    @State private var inspectorDragStart: CGFloat?
    @State private var showConversation = false
    @State private var showAutopilotPreflight = false

    var body: some View {
        @Bindable var model = model
        let layout = panelLayout
        NavigationSplitView(columnVisibility: columnVisibility) {
            Group {
                if model.mode == .language {
                    LanguageSidebarView(workspace: model.languageWorkspace)
                } else {
                    SidebarView()
                }
            }
            .navigationSplitViewColumnWidth(min: Self.minSidebarWidth, ideal: 260, max: Self.maxSidebarWidth)
        } detail: {
            if model.mode == .language {
                LanguageWorkspaceView(workspace: model.languageWorkspace)
            } else {
                HStack(spacing: 0) {
                    detailPane
                        .frame(minWidth: Self.minChatWidth, maxWidth: .infinity, maxHeight: .infinity)
                    if let width = layout.inspectorWidth {
                        inspectorHandle
                        ConversationInspectorView()
                            .environment(model)
                            .frame(minWidth: 0, maxWidth: width)
                            .frame(maxHeight: .infinity)
                    }
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { windowWidth = $0 }
        .background(model.currentPalette.canvas)
        .sheet(isPresented: $showConversation) {
            ConversationView()
                .environment(model)
        }
        .onChange(of: model.mode) { _, newMode in
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
                if model.mode != .language { PersonaPicker() }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if model.mode != .language {
                    Button {
                        model.refreshServerInfo()
                    } label: {
                        Label {
                            Text(connectionStatusText)
                                .foregroundStyle(.primary)
                        } icon: {
                            Image(systemName: "circle.fill")
                                .font(.system(size: 7))
                                .foregroundStyle(connectionStatusColor)
                        }
                        .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 8)
                    .help("Refresh server connection status")

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
                        Divider()
                        Text(model.sleepStatusText)
                    } label: {
                        Label(
                            "Memory",
                            systemImage: model.settings.pauseMemoryWrites ? "brain.head.profile.fill" : "brain.head.profile")
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .foregroundStyle(model.settings.pauseMemoryWrites ? .orange : .primary)
                    .help(model.settings.pauseMemoryWrites
                        ? "Memory — new memories are paused (existing memory still used)."
                        : "Open memory, update it now, or pause saving new memories.")
                }

                if model.mode != .language {
                    Button {
                        model.autopilotArmed.toggle()
                        showAutopilotPreflight = true
                    } label: {
                        Label(
                            model.autopilotArmed ? "Autopilot: On" : "Autopilot: Off",
                            systemImage: "infinity")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(model.autopilotArmed ? AnyShapeStyle(model.currentAccent) : AnyShapeStyle(.secondary))
                    .opacity(model.autopilotArmed ? 1 : 0.55)
                    .disabled(model.isStreaming || model.workSession != nil || model.pendingApproval != nil
                        || model.pendingWorkGate != nil)
                    .help("Arm Autopilot for the next task and preview its permissions.")
                    .popover(isPresented: $showAutopilotPreflight, arrowEdge: .bottom) {
                        AutopilotPermissionSummary()
                            .frame(width: 360)
                    }
                }

                if model.mode != .language {
                    Button { showInspector.toggle() } label: {
                        Label("Inspector", systemImage: "folder.badge.gearshape")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(showInspector ? model.currentAccent : .primary)
                    .help(showInspector ? "Hide conversation sidebar" : "Show conversation sidebar")
                }

                Button { openWindow(id: "settings") } label: {
                    Image(systemName: "gearshape")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(",", modifiers: .command)
                .help("Settings")
            }
        }
        .toolbarBackground(.hidden, for: .windowToolbar)
        .toolbarColorScheme(colorScheme, for: .windowToolbar)
    }

    private static let minSidebarWidth: CGFloat = 220
    private static let maxSidebarWidth: CGFloat = 300
    private static let minChatWidth: CGFloat = 360
    private static let minInspectorWidth: CGFloat = 300
    private static let maxInspectorWidth: CGFloat = 800

    /// Chat keeps its minimum width; the inspector gets room next, then the sidebar. Whatever doesn't fit collapses.
    private var panelLayout: (sidebar: Bool, inspectorWidth: CGFloat?) {
        let room = windowWidth - Self.minChatWidth
        var sidebar = sidebarWanted
        var inspector = showInspector
        if inspector, sidebar, room < Self.maxSidebarWidth + Self.minInspectorWidth { sidebar = false }
        if inspector, room < Self.minInspectorWidth { inspector = false }
        if sidebar, room < Self.maxSidebarWidth { sidebar = false }
        let sidebarSpace = sidebar ? Self.maxSidebarWidth : 0
        let width = min(Self.maxInspectorWidth, max(Self.minInspectorWidth, min(inspectorWidth, room - sidebarSpace)))
        return (sidebar, inspector ? width : nil)
    }

    private var columnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { panelLayout.sidebar ? .all : .detailOnly },
            set: { newValue in
                sidebarWanted = newValue != .detailOnly
                // Showing the sidebar explicitly wins over an inspector that has no room beside it.
                let needed = Self.maxSidebarWidth + Self.minInspectorWidth + Self.minChatWidth
                if sidebarWanted, showInspector, windowWidth < needed { showInspector = false }
            }
        )
    }

    private var inspectorHandle: some View {
        model.currentPalette.border
            .ignoresSafeArea(edges: .top)
            .frame(width: 1)
            .padding(.horizontal, 3)
            .contentShape(Rectangle())
            .pointerStyle(.columnResize)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = inspectorDragStart ?? inspectorWidth
                        inspectorDragStart = start
                        inspectorWidth = min(Self.maxInspectorWidth, max(Self.minInspectorWidth, start - value.translation.width))
                    }
                    .onEnded { _ in inspectorDragStart = nil }
            )
    }

    @ViewBuilder
    private var detailPane: some View {
        if model.selectedConversationID != nil {
            ChatView()
        } else {
            ContentUnavailableView("No Conversation", systemImage: "bubble.left.and.bubble.right")
        }
    }

    private var connectionStatusText: String {
        switch model.connectionOK {
        case .some(true): "Connected"
        case .some(false): "Offline"
        case .none: "Checking…"
        }
    }

    private var connectionStatusColor: Color {
        switch model.connectionOK {
        case .some(true): .green
        case .some(false): .red
        case .none: .yellow
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
            HStack(spacing: 6) {
                Image(systemName: model.currentPersona.iconSymbol)
                Text(model.currentPersona.name)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        // Wrapped in a styled container so the toolbar treats it as a custom view and keeps the title.
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        // .background(.ultraThinMaterial, in: Capsule())
        // .overlay(Capsule().stroke(.white.opacity(0.08)))
        .help("Persona (system prompt + memory)")
    }
}

