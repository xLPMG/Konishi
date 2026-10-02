import SwiftUI
import AVFoundation
import AppKit
import Speech

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: SettingsSection? = .endpoints

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Connection") { sectionRows(group: "Connection") }
                Section("Assistant") { sectionRows(group: "Assistant") }
                Section("Personalization") { sectionRows(group: "Personalization") }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background(model.currentPalette.sidebar.ignoresSafeArea())
            .overlay(alignment: .trailing) {
                Rectangle()
                    .fill(model.currentPalette.border)
                    .frame(width: 1)
                    .ignoresSafeArea(edges: .vertical)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 195, max: 230)
        } detail: {
            selectedContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(model.currentPalette.canvas)
        }
        .navigationTitle("Settings - \(selectedSection.title)")
        .navigationSplitViewStyle(.balanced)
        .background(model.currentPalette.canvas.ignoresSafeArea())
        .toolbarBackground(model.currentPalette.surface, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .frame(
            minWidth: 860, idealWidth: 980, maxWidth: .infinity,
            minHeight: 560, idealHeight: 680, maxHeight: .infinity
        )
    }

    private var selectedSection: SettingsSection { selection ?? .endpoints }

    @ViewBuilder
    private func sectionRows(group: String) -> some View {
        ForEach(SettingsSection.allCases.filter { $0.group == group }) { section in
            Label(section.title, systemImage: section.symbol).tag(section)
        }
    }

    @ViewBuilder
    private var selectedContent: some View {
        switch selectedSection {
        case .endpoints: ServerSettings()
        case .localServers: RuntimeSettings()
        case .generation: GenerationSettings()
        case .memory: MemorySettings()
        case .vault: VaultSettings()
        case .tools: ToolsSettings()
        case .voice: VoiceSettings()
        case .personas: PersonaSettings()
        case .appearance: AppearanceSettings()
        }
    }
}

private enum SettingsSection: String, CaseIterable, Identifiable {
    case endpoints = "Endpoints"
    case localServers = "Local Servers"
    case generation = "Generation"
    case memory = "Memory"
    case vault = "Vault"
    case tools = "Tools"
    case voice = "Voice"
    case personas = "Personas"
    case appearance = "Appearance"

    var id: String { rawValue }
    var title: String { rawValue }

    var group: String {
        switch self {
        case .endpoints, .localServers: "Connection"
        case .generation, .memory, .tools, .voice: "Assistant"
        case .vault, .personas, .appearance: "Personalization"
        }
    }

    var symbol: String {
        switch self {
        case .endpoints: "server.rack"
        case .localServers: "shippingbox"
        case .generation: "slider.horizontal.3"
        case .memory: "brain"
        case .vault: "books.vertical"
        case .tools: "wrench.and.screwdriver"
        case .voice: "waveform"
        case .personas: "person.2"
        case .appearance: "paintpalette"
        }
    }
}

private struct ServerSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section("Chat Endpoint") {
                TextField("Base URL", text: $settings.baseURL, prompt: Text("http://127.0.0.1:1234"))
                SecureField("API Token", text: $settings.apiToken, prompt: Text("Stored in Keychain — required if auth is on"))
                HStack {
                    Button("Test Connection") { model.refreshServerInfo() }
                    if let ok = model.connectionOK {
                        Label(ok ? "Connected" : "Failed", systemImage: ok ? "checkmark.circle" : "xmark.circle")
                            .foregroundStyle(ok ? .green : .red)
                    }
                }
            }
            Section("Audio Endpoint") {
                TextField("Audio Base URL", text: $settings.audioBaseURL, prompt: Text("blank = same as chat"))
                Button("Scan Audio Models") { model.refreshAudioModels() }
                Text("LM Studio can't serve audio — point this at an mlx-audio / Whisper / Piper server (see the Local Servers tab).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Embedding Endpoint") {
                TextField("Embedding Base URL", text: $settings.embeddingBaseURL, prompt: Text("blank = same as chat"))
                Text("mlx_lm.server has no /v1/embeddings. Point this at a dedicated embeddings server (the 'mlx embeddings' preset in the Local Servers tab, or LM Studio) so RAG and semantic memory work while mlx serves chat.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Default Model") {
                if model.models.isEmpty {
                    TextField("Model", text: $settings.model)
                } else {
                    Picker("Model", selection: $settings.model) {
                        ForEach(model.models) { info in
                            Text(info.isLoaded == true ? "● \(info.id)" : info.id).tag(info.id)
                        }
                    }
                }
                if model.hasLoadState {
                    Text("● = currently loaded in the server").font(.caption).foregroundStyle(.secondary)
                }
                if let ctx = model.contextWindow {
                    LabeledContent("Context window", value: "\(ctx) tokens")
                }
            }
        }
        .formStyle(.grouped)
        .themedFormBackground(model.currentPalette.canvas)
    }
}

private struct GenerationSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section("Sampling") {
                slider("Temperature", value: $settings.temperature, range: 0...2, step: 0.05)
                slider("Top-p", value: $settings.topP, range: 0...1, step: 0.05)
                slider("Presence penalty", value: $settings.presencePenalty, range: -2...2, step: 0.1)
                slider("Frequency penalty", value: $settings.frequencyPenalty, range: -2...2, step: 0.1)
                NumberField("Seed", value: $settings.seed, range: -1...9_999_999, step: 1)
                Text("-1 = random.").font(.caption).foregroundStyle(.secondary)
                TextField("Stop sequences (comma-separated)", text: $settings.stopSequences)
            }
            Section("Agent work limits") {
                NumberField("Output tokens before asking", value: $settings.workOutputTokenLimit, range: 0...1_048_576, step: 512)
                NumberField("Model turns before asking", value: $settings.workTurnLimit, range: 0...100, step: 1)
                NumberField("Tool calls before asking", value: $settings.workToolCallLimit, range: 0...500, step: 1)
                Text("Soft limits apply across one task. Output tokens are estimated from streamed text; Continue adds another allowance. 0 disables a limit. Konishi does not set a per-response token cap, though a server may impose its own.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Context") {
                NumberField("Window override", value: $settings.contextWindowOverride, range: 0...2_097_152, step: 1024)
                if let ctx = model.contextWindow {
                    LabeledContent("Detected", value: "\(ctx) tokens")
                }
                Text("0 = auto-detect from the server or the model's config.json. Override if your server doesn't report it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Compression") {
                Toggle("Summarize old turns (keeps prompts small)", isOn: $settings.compressionEnabled)
                NumberField("History budget", value: $settings.compressionBudget, range: 500...400_000, step: 500)
                    .disabled(!settings.compressionEnabled)
                Picker("Summarize with", selection: $settings.compressionUseServer) {
                    Text("Server model (accurate)").tag(true)
                    Text("On-device model (fast)").tag(false)
                }
                .disabled(!settings.compressionEnabled)
                Text("Older turns beyond the budget are folded into a rolling summary instead of dropped — preserves facts while keeping the prompt (and prefill) fast. The server model writes better summaries and runs in the background after each reply; on-device is faster and off-loads the GPU.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Streaming") {
                NumberField("UI flush interval (ms)", value: $settings.streamFlushMs, range: 0...500, step: 10)
                Text("Streamed tokens are batched and drawn every N ms instead of one-by-one, cutting re-renders and markdown re-parsing during long replies. 0 = draw every token (highest CPU).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Vision") {
                Toggle("Send images to the model", isOn: $settings.sendImagesToModel)
                Text("Sends attached and generated images (e.g. plots) to the model. Requires a vision-capable server — mlx-vlm or LM Studio with a vision model. mlx_lm.server is text-only and returns \"Only 'text' content type is supported.\" Images always display in chat regardless of this setting.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Background tasks") {
                Picker("Chat titles & memory checks", selection: $settings.useOnDeviceModel) {
                    Text("On-device model").tag(true)
                    Text("Basic (no model)").tag(false)
                }
                Label(OnDeviceLLM.status, systemImage: OnDeviceLLM.isAvailable ? "checkmark.seal" : "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(OnDeviceLLM.isAvailable ? .green : .secondary)
                NumberField("Number of new messages before updating the title", value: $settings.messageThresholdForTitleUpdate, range: 0...25, step: 1)
                Toggle("Disable server thinking for these tasks", isOn: $settings.disableThinkingForTasks)
                Text("Chat title auto generation runs on Apple's on-device model (ANE), off-loading the GPU. When set to Basic, titles use a simple heuristic and the memory check is skipped. Summaries and memory extraction choose their own model (above, and in the Memory tab). “Disable server thinking” turns off reasoning for these mechanical server tasks via chat_template_kwargs (Gemma 3/4, Qwen 3) — turn off if your server rejects it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .themedFormBackground(model.currentPalette.canvas)
    }

    private func slider(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double) -> some View {
        VStack(alignment: .leading) {
            HStack {
                Text(label)
                Spacer()
                Text(value.wrappedValue, format: .number.precision(.fractionLength(2)))
                    .foregroundStyle(.secondary).monospacedDigit()
            }
            Slider(value: value, in: range, step: step)
        }
    }
}

private struct MemorySettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section("Conversations") {
                Toggle("Auto-title new chats", isOn: $settings.autoTitle)
                Toggle("Save request/response trace with each chat", isOn: $settings.saveTraces)
            }
            Section("Automatic memory") {
                Toggle("Build memory automatically as you chat", isOn: $settings.autoMemory)
                if settings.autoMemory {
                    Stepper(value: $settings.autoMemoryEvery, in: 1...10) {
                        LabeledContent("Update every",
                                       value: "\(settings.autoMemoryEvery) message\(settings.autoMemoryEvery == 1 ? "" : "s")")
                    }
                    TextField("Extra memory instruction (optional)", text: $settings.reflectionCustomPrompt, axis: .vertical)
                        .lineLimit(1...3)
                    Toggle("Self-consolidate when memory grows", isOn: $settings.autoConsolidate)
                    if settings.autoConsolidate {
                        Stepper(value: $settings.autoConsolidateThreshold, in: 10...200, step: 5) {
                            LabeledContent("Consolidate over", value: "\(settings.autoConsolidateThreshold) notes")
                        }
                    }
                }
                Text("Konishi keeps a structured profile about you (profile, preferences, projects, people, history, rapport). Every few messages it extracts durable facts on the server model and keeps a short summary of the chat so later chats can recall it. New facts are usable right away (see Recent in the Memory window); when idle, on chat switch, and after launch, the ones that matter are moved into long-term memory and the rest fade. Once memory passes the note count above, an automatic pass dedupes and reorganizes it. Update Memory extracts from the current chat; Clean Up Memory does a full backed-up reorganize.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Long-term Memory") {
                Toggle("Inject memory into system prompt", isOn: $settings.injectMemory)
                Toggle("Tell the model today's date", isOn: $settings.injectDateContext)
                if settings.injectMemory {
                    ModelSelectField(title: "Embedding model", selection: $settings.embeddingModel, models: model.embeddingCandidates)
                    Stepper(value: $settings.memoryTopK, in: 1...50) {
                        LabeledContent("Facts per turn", value: "\(settings.memoryTopK)")
                    }
                    VStack(alignment: .leading) {
                        HStack {
                            Text("Hybrid match threshold")
                            Spacer()
                            Text(settings.memoryThreshold, format: .number.precision(.fractionLength(2)))
                                .foregroundStyle(.secondary).monospacedDigit()
                        }
                        Slider(value: $settings.memoryThreshold, in: 0...1.0, step: 0.05)
                    }
                    Text("Your identity profile is always included. With embeddings, semantic and BM25 relevance are blended and filtered by this threshold; without them, the top lexical (BM25) matches are used. Retrieved memory is attached to the latest user turn, so memory can grow without flooding the stable system prompt.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Attached documents (RAG)") {
                Stepper(value: $settings.ragThresholdChars, in: 2000...100000, step: 2000) {
                    LabeledContent("Index files over", value: "\(settings.ragThresholdChars) chars")
                }
                Stepper(value: $settings.ragTopK, in: 1...20) {
                    LabeledContent("Passages per turn", value: "\(settings.ragTopK)")
                }
                Text("Files larger than the threshold are chunked and stored with the conversation; each turn retrieves relevant passages using embeddings when available, with lexical matching as a fallback. Smaller files are inlined into the message as before.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .themedFormBackground(model.currentPalette.canvas)
    }
}

private struct VaultSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section("Research vault") {
                HStack {
                    TextField("Vault folder", text: $settings.vaultPath, prompt: Text("~/Documents/MyVault"))
                    Button("Choose…") { chooseFolder(settings) }
                }
                if !settings.vaultPath.isEmpty, VaultStore.vaultURL(settings.vaultPath) == nil {
                    Label("That folder doesn't exist.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange).font(.caption)
                }
                Stepper(value: $settings.vaultTopK, in: 1...20) {
                    LabeledContent("Passages per turn", value: "\(settings.vaultTopK)")
                }
                Text("Point Konishi at an Obsidian vault (a folder of Markdown notes). Only personas with “Research vault access” retrieve from it or can read and write notes, so vault content never leaks into your everyday chats. Retrieval uses embeddings when available and lexical matching as a fallback.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .themedFormBackground(model.currentPalette.canvas)
    }

    private func chooseFolder(_ settings: AppSettings) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Vault"
        if panel.runModal() == .OK, let url = panel.url { settings.vaultPath = url.path }
    }
}

private struct ToolsSettings: View {
    @Environment(AppModel.self) private var model
    @State private var toolMode: AppMode = .chat
    @State private var pendingHighRiskCapability: Capability?
    @State private var confirmingHighRisk = false

    var body: some View {
        Form {
            Section("Apple Calendar & Reminders") {
                LabeledContent("Calendar", value: model.calendarStore.calendarAccess.label)
                Button("Connect Calendar") {
                    Task { await model.calendarStore.requestCalendarAccess() }
                }
                .disabled(model.calendarStore.calendarAccess == .fullAccess || model.calendarStore.requestingCalendarAccess)

                LabeledContent("Reminders", value: model.calendarStore.remindersAccess.label)
                Button("Connect Reminders") {
                    Task { await model.calendarStore.requestRemindersAccess() }
                }
                .disabled(model.calendarStore.remindersAccess == .fullAccess || model.calendarStore.requestingRemindersAccess)

                if let error = model.calendarStore.accessError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                Text("Access is requested separately for each app. Event and reminder details are sent to the configured chat model when a tool runs. Personal-data writes default to Ask and follow the selected mode policy.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Enable tool calling", isOn: Binding(
                    get: { model.settings.toolsEnabled(for: toolMode) },
                    set: { model.settings.setToolsEnabled($0, for: toolMode) }
                ))
                Text("Master switch for \(toolMode.label). Learn mode starts enabled on new installs.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Picker("Mode", selection: $toolMode) {
                    ForEach(AppMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            } footer: {
                Text("Set capability policy, then choose which tools this mode can see.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(capabilityGroups.indices, id: \.self) { index in
                let group = capabilityGroups[index]
                Section(group.0) {
                    ForEach(group.1, id: \.self) { capability in
                        let evaluation = permissionEvaluation(for: capability)
                        let override = model.settings.permissionPolicy(for: toolMode).rules.first {
                            $0.capability == capability && $0.scope == .any
                        }
                        CapabilityPolicySettingsRow(
                            capability: capability,
                            decision: evaluation.verdict,
                            source: evaluation.source.label(for: toolMode),
                            hasOverride: override != nil,
                            onChange: { decision in requestDecision(decision, for: capability) },
                            onReset: { setDecision(capability.defaultDecision(for: toolMode), for: capability) })
                    }
                }
            }
            ForEach(ToolGroup.allCases) { group in
                let specs = Tools.all.filter { $0.group == group }
                if !specs.isEmpty {
                    Section {
                        ForEach(specs) { spec in
                            ToolSettingsRow(spec: spec, mode: toolMode, settings: model.settings)
                        }
                    } header: { Text(group.label) }
                    .disabled(!model.settings.toolsEnabled(for: toolMode))
                    if group == .system { shellAllowlistSection }
                }
            }
            Section("Remembered locations") {
                let rules = model.settings.permissionPolicy(for: toolMode).rules.filter {
                    if case .pathPrefix = $0.scope { true } else { false }
                }
                if rules.isEmpty {
                    Text("None")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(rules) { rule in
                        if case let .pathPrefix(path) = rule.scope {
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(rule.capability.label).font(.caption)
                                    Text("\(rule.decision.rawValue.capitalized) · \(path)")
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                        .textSelection(.enabled)
                                }
                                Spacer(minLength: 4)
                                Button(role: .destructive) {
                                    removeRule(rule.id)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .help("Remove remembered location")
                            }
                        }
                    }
                }
            }
            Section {
                Button("Reset to Defaults", role: .destructive) {
                    model.settings.resetToolSettings(for: toolMode)
                }
            }
        }
        .formStyle(.grouped)
        .themedFormBackground(model.currentPalette.canvas)
        .onAppear { model.calendarStore.refreshAuthorizationStatus() }
        .confirmationDialog(
            "Allow \(pendingHighRiskCapability?.label ?? "this capability") anywhere?",
            isPresented: $confirmingHighRisk, titleVisibility: .visible
        ) {
            Button("Allow Anywhere") {
                if let capability = pendingHighRiskCapability {
                    setDecision(.allow, for: capability)
                }
                pendingHighRiskCapability = nil
            }
            Button("Cancel", role: .cancel) { pendingHighRiskCapability = nil }
        } message: {
            Text("This high-risk capability will be allowed at any location or scope. Protected locations still require one-time approval.")
        }
    }

    private var capabilityGroups: [(String, [Capability])] {
        let grouped = Dictionary(grouping: Capability.allCases, by: \.groupLabel)
        let order = [
            "Workspace", "External", "Memory", "Conversation history", "Vault",
            "Personal data", "Language deck", "Web", "Code", "Interaction",
        ]
        return order.compactMap { name in grouped[name].map { (name, $0) } }
    }

    private var shellAllowlistSection: some View {
        Section("Shell allowlist") {
            TextEditor(text: Binding(
                get: { model.settings.shellAllowlist(for: toolMode) },
                set: { model.settings.setShellAllowlist($0, for: toolMode) }
            ))
            .font(.body.monospaced())
            .frame(height: 72)
            .disabled(!model.settings.toolsEnabled(for: toolMode)
                || !model.settings.enabledTools(for: toolMode).contains("run_shell"))
            Text("One executable per line. Simple, listed invocations use the allowlisted-command capability; composed or unlisted commands require code execution permission.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func permissionEvaluation(for capability: Capability) -> ToolPermissionEvaluation {
        let workspace = Paths.filesRoot.appendingPathComponent("__settings_preview__", isDirectory: true)
        let path: String?
        switch capability {
        case .workspaceRead, .workspaceWrite:
            path = workspace.appendingPathComponent("sample.txt").path
        case .externalRead, .externalWrite:
            path = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Documents/sample.txt").path
        default:
            path = nil
        }
        let allowlist = Set(model.settings.shellAllowlist(for: toolMode)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty })
        let context = ToolPermissionContext(
            mode: toolMode, workspace: workspace, enabledTools: Set(Tools.all.map(\.name)),
            vaultAccessEnabled: true, shellAllowlist: allowlist,
            modePolicy: model.settings.permissionPolicy(for: toolMode))
        return ToolPermissions.evaluate([PermissionEffect(capability, path: path)], context: context)
    }

    private func requestDecision(_ decision: PermissionDecision, for capability: Capability) {
        if decision == .allow, capability.risk == .high {
            pendingHighRiskCapability = capability
            confirmingHighRisk = true
        } else {
            setDecision(decision, for: capability)
        }
    }

    private func setDecision(_ decision: PermissionDecision, for capability: Capability) {
        var policy = model.settings.permissionPolicy(for: toolMode)
        policy.rules.removeAll { $0.capability == capability && $0.scope == .any }
        if decision != capability.defaultDecision(for: toolMode) {
            policy.rules.append(PermissionRule(capability: capability, decision: decision))
        }
        model.settings.setPermissionPolicy(policy, for: toolMode)
    }

    private func removeRule(_ id: UUID) {
        var policy = model.settings.permissionPolicy(for: toolMode)
        policy.rules.removeAll { $0.id == id }
        model.settings.setPermissionPolicy(policy, for: toolMode)
    }
}

private struct CapabilityPolicySettingsRow: View {
    let capability: Capability
    let decision: PermissionDecision
    let source: String
    let hasOverride: Bool
    let onChange: @MainActor (PermissionDecision) -> Void
    let onReset: @MainActor () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: riskSymbol)
                .foregroundStyle(riskColor)
                .help("\(capability.risk.rawValue.capitalized) risk")
            VStack(alignment: .leading, spacing: 2) {
                Text(capability.label).font(.caption)
                Text("\(decision.rawValue.capitalized) · \(source)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 6)
            Picker(capability.label, selection: Binding(
                get: { decision }, set: { onChange($0) }
            )) {
                Text("Allow").tag(PermissionDecision.allow)
                Text("Ask").tag(PermissionDecision.ask)
                Text("Deny").tag(PermissionDecision.deny)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .disabled(capability == .userInput)
            Button(action: onReset) {
                Image(systemName: "arrow.counterclockwise")
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.borderless)
            .help("Reset mode override")
            .disabled(!hasOverride || capability == .userInput)
        }
        .padding(.vertical, 3)
    }

    private var riskSymbol: String {
        switch capability.risk {
        case .low: "checkmark.circle"
        case .medium: "exclamationmark.circle"
        case .high: "exclamationmark.triangle.fill"
        }
    }

    private var riskColor: Color {
        switch capability.risk {
        case .low: .secondary
        case .medium: .orange
        case .high: .red
        }
    }
}

private struct ToolSettingsRow: View {
    let spec: ToolSpec
    let mode: AppMode
    @Bindable var settings: AppSettings

    private var enabled: Bool { settings.enabledTools(for: mode).contains(spec.name) }
    private var capabilities: [Capability] { ToolPermissions.possibleCapabilities(for: spec.name) }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Toggle("Tool enabled", isOn: Binding(
                get: { enabled }, set: { settings.setToolEnabled(spec.name, $0, for: mode) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .help(enabled ? "Hide this tool from the model" : "Show this tool to the model")
            VStack(alignment: .leading, spacing: 2) {
                Text(spec.name).font(.body.monospaced())
                Text(spec.summary).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    if capabilities.isEmpty {
                        Text("No policy capability").font(.caption2).foregroundStyle(.secondary)
                    }
                    ForEach(capabilities, id: \.self) { capability in
                        Label(capability.label, systemImage: capabilitySymbol(capability))
                            .font(.caption2)
                            .foregroundStyle(capability.risk == .high ? .red : .secondary)
                            .help("\(capability.label) · \(capability.risk.rawValue) risk")
                    }
                }
            }
            .frame(maxWidth: 210, alignment: .trailing)
        }
    }

    private func capabilitySymbol(_ capability: Capability) -> String {
        switch capability.kind {
        case .read: "eye"
        case .write: "pencil"
        case .execute: "terminal"
        case .interact: "hand.tap"
        }
    }
}

private struct VoiceSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section("Sources") {
                Picker("Speech-to-Text", selection: $settings.sttSource) {
                    ForEach(AudioSource.allCases) { Text($0.label).tag($0) }
                }
                Picker("Text-to-Speech", selection: $settings.ttsSource) {
                    ForEach(AudioSource.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Auto-speak assistant replies", isOn: $settings.autoSpeak)
                HStack {
                    Button("Scan for models") { model.refreshServerInfo(); model.refreshAudioModels() }
                    Spacer()
                    if let ok = model.connectionOK {
                        Label(ok ? "\(model.audioModels.isEmpty ? model.models.count : model.audioModels.count) found" : "no server",
                              systemImage: ok ? "checkmark.circle" : "xmark.circle")
                            .font(.caption).foregroundStyle(ok ? .green : .secondary)
                    }
                }
            }

            Section("Conversation") {
                Picker("Recognition language", selection: $settings.conversationSpeechLocale) {
                    ForEach(speechLocales, id: \.identifier) { locale in
                        Text(speechLocaleLabel(locale)).tag(locale.identifier)
                    }
                }
                Text("Voice conversations use Apple live recognition with this language. The Speech-to-Text source above applies to dictation.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Allow spoken interruptions", isOn: $settings.conversationBargeIn)
                if settings.conversationBargeIn {
                    Toggle("Distinguish acknowledgements on device", isOn: $settings.conversationBackchannelANE)
                    Text(OnDeviceLLM.status)
                        .font(.caption).foregroundStyle(OnDeviceLLM.isAvailable ? .green : .secondary)
                }
                Text("Keeps the microphone active while the assistant responds. Use headphones to prevent its voice from being recognized as an interruption.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if settings.sttSource == .server {
                Section("Server STT") {
                    ModelSelectField(title: "Model", selection: $settings.sttModel, models: model.sttCandidates)
                    Text("Needs /v1/audio/transcriptions (e.g. a Whisper server).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if settings.ttsSource == .server {
                Section("Server TTS") {
                    ModelSelectField(title: "Model", selection: $settings.ttsModel, models: model.ttsCandidates)
                    HStack {
                        TextField("Voice", text: $settings.ttsVoice)
                        Menu("Voices") {
                            if !model.audioVoices.isEmpty {
                                Section("From server") {
                                    ForEach(model.audioVoices, id: \.self) { voice in
                                        Button(voice) { settings.ttsVoice = voice }
                                    }
                                }
                            } else {
                                ForEach(KokoroVoices.groups, id: \.name) { group in
                                    Section(group.name) {
                                        ForEach(group.voices, id: \.self) { voice in
                                            Button(voice) { settings.ttsVoice = voice }
                                        }
                                    }
                                }
                            }
                            Divider()
                            Button("Refresh from server") { model.refreshVoices() }
                        }
                        .fixedSize()
                        Button("Preview") { model.speak("Hello, I am an AI assistant. How may I help you?") }
                    }
                    if let err = model.voice.lastError {
                        Text(err).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    }
                    Text("Voices from the server when available, else the built-in Kokoro list. Other models (Voxtral, Piper…) use their own names.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .onAppear { model.refreshVoices() }
            }

            if settings.ttsSource == .native {
                Section("Native Voice") {
                    Picker("Voice", selection: $settings.voiceIdentifier) {
                        Text("System default").tag("")
                        ForEach(VoiceManager.voices(), id: \.identifier) { voice in
                            Text("\(voice.name) (\(voice.language))").tag(voice.identifier)
                        }
                    }
                    VStack(alignment: .leading) {
                        LabeledContent("Rate", value: String(format: "%.2f", settings.speechRate))
                        Slider(value: $settings.speechRate, in: 0...1, step: 0.05)
                    }
                    Button("Preview") { model.speak("Hello, I am an AI assistant. How may I help you?") }
                }
            }

            if settings.sttSource == .native {
                Section {
                    Text("Native speech-to-text uses on-device Apple dictation — no model needed. Conversation mode always uses it for smooth live listening.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .themedFormBackground(model.currentPalette.canvas)
    }

    private var speechLocales: [Locale] {
        var locales = SFSpeechRecognizer.supportedLocales()
        locales.insert(Locale(identifier: model.settings.conversationSpeechLocale))
        return locales.sorted {
            speechLocaleLabel($0).localizedStandardCompare(speechLocaleLabel($1)) == .orderedAscending
        }
    }

    private func speechLocaleLabel(_ locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }
}

private struct PersonaSettings: View {
    @Environment(AppModel.self) private var model
    @State private var selection: UUID?

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack {
                    Text("PERSONAS")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(action: addPersona) {
                        Image(systemName: "plus")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: 30, height: 30)
                            .background(model.currentPalette.surface, in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .help("Add persona")
                    .accessibilityLabel("Add persona")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

                List(selection: $selection) {
                    ForEach(model.personaStore.personas) { persona in
                        Label(persona.name, systemImage: persona.iconSymbol).tag(persona.id)
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)

                Rectangle()
                    .fill(model.currentPalette.border)
                    .frame(height: 1)

                HStack {
                    Text("\(model.personaStore.personas.count) personas")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(role: .destructive, action: deleteSelectedPersona) {
                        Label("Delete", systemImage: "trash")
                    }
                    .buttonStyle(.borderless)
                    .disabled(selection == nil || model.personaStore.personas.count <= 1)
                    .help("Delete selected persona")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .frame(width: 210)
            .background(model.currentPalette.sidebar)

            Rectangle()
                .fill(model.currentPalette.border)
                .frame(width: 1)

            Group {
                if let id = selection ?? model.personaStore.personas.first?.id,
                   let persona = model.personaStore.personas.first(where: { $0.id == id }) {
                    PersonaEditorView(persona: persona).id(persona.id)
                } else {
                    Text("Select a persona").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(.top, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(model.currentPalette.canvas)
        }
        .background(model.currentPalette.canvas)
        .onAppear { if selection == nil { selection = model.personaStore.personas.first?.id } }
    }

    private func addPersona() {
        model.personaStore.addPersona()
        selection = model.personaStore.personas.last?.id
    }

    private func deleteSelectedPersona() {
        guard let selection else { return }
        model.deletePersona(selection)
        self.selection = model.personaStore.personas.first?.id
    }
}

private struct AppearanceSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section("Theme") {
                Picker("Palette", selection: $settings.theme) {
                    ForEach(AppTheme.allCases) { theme in
                        Text(theme.title).tag(theme)
                    }
                }
                .pickerStyle(.segmented)
                Text(settings.theme.description)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Text") {
                VStack(alignment: .leading) {
                    LabeledContent("Font size", value: "\(Int(settings.fontSize)) pt")
                    Slider(value: $settings.fontSize, in: 11...22, step: 1)
                }
            }
            Section("Accent") {
                ColorPicker("Default accent", selection: Binding(
                    get: { Color(hex: settings.accentColorHex) },
                    set: { settings.accentColorHex = $0.hexString }
                ))
                Text("Per-persona accent colors override this in their conversations.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .themedFormBackground(model.currentPalette.canvas)
    }
}

/// A directly-typable integer field with a stepper for nudging.
/*private*/ struct NumberField: View {
    let title: String
    @Binding var value: Int
    var range: ClosedRange<Int> = 0...Int.max
    var step: Int = 1

    init(_ title: String, value: Binding<Int>, range: ClosedRange<Int> = 0...Int.max, step: Int = 1) {
        self.title = title
        self._value = value
        self.range = range
        self.step = step
    }

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            TextField(title, value: $value, format: .number)
                .labelsHidden()
                .frame(width: 100)
                .multilineTextAlignment(.trailing)
                .textFieldStyle(.roundedBorder)
            Stepper(title, value: $value, in: range, step: step).labelsHidden()
        }
    }
}

/// A model chooser that becomes a text field when no models are known,
/// and always keeps the current value selectable even if not in the list.
private struct ModelSelectField: View {
    let title: String
    @Binding var selection: String
    let models: [ModelInfo]

    var body: some View {
        if models.isEmpty {
            TextField(title, text: $selection)
        } else {
            Picker(title, selection: $selection) {
                if !selection.isEmpty, !models.contains(where: { $0.id == selection }) {
                    Text(selection).tag(selection)
                }
                ForEach(models) { Text($0.id).tag($0.id) }
            }
        }
    }
}
