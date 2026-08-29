import SwiftUI
import AVFoundation

struct SettingsView: View {
    var body: some View {
        TabView {
            ServerSettings().tabItem { Label("Endpoints", systemImage: "server.rack") }
            RuntimeSettings().tabItem { Label("Local Servers", systemImage: "shippingbox") }
            GenerationSettings().tabItem { Label("Generation", systemImage: "slider.horizontal.3") }
            MemorySettings().tabItem { Label("Memory", systemImage: "brain") }
            ToolsSettings().tabItem { Label("Tools", systemImage: "wrench.and.screwdriver") }
            VoiceSettings().tabItem { Label("Voice", systemImage: "waveform") }
            PersonaSettings().tabItem { Label("Personas", systemImage: "person.2") }
            AppearanceSettings().tabItem { Label("Appearance", systemImage: "paintpalette") }
        }
        .frame(
            minWidth: 620, idealWidth: 680, maxWidth: .infinity,
            minHeight: 500, idealHeight: 560, maxHeight: .infinity
        )
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
                NumberField("Max tokens", value: $settings.maxTokens, range: -1...1_048_576, step: 128)
                Text("-1 or 0 = server default (mlx-lm defaults to 512 — raise for reasoning models).")
                    .font(.caption).foregroundStyle(.secondary)
                NumberField("Seed", value: $settings.seed, range: -1...9_999_999, step: 1)
                Text("-1 = random.").font(.caption).foregroundStyle(.secondary)
                TextField("Stop sequences (comma-separated)", text: $settings.stopSequences)
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
                Toggle("Disable server thinking for these tasks", isOn: $settings.disableThinkingForTasks)
                Text("Chat titles and the quick “is this worth remembering?” check run on Apple's on-device model (ANE), off-loading the GPU. When set to Basic, titles use a simple heuristic and the memory check is skipped. Summaries and memory extraction choose their own model (above, and in the Memory tab). “Disable server thinking” turns off reasoning for these mechanical server tasks via chat_template_kwargs (Gemma 3/4, Qwen 3) — turn off if your server rejects it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
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
                    Picker("Extract with", selection: $settings.autoMemoryUseServer) {
                        Text("Server model (accurate)").tag(true)
                        Text("On-device model (fast)").tag(false)
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
                Text("Konishi keeps a structured profile about you (profile, preferences, projects, facts, people & terms). The server model is more accurate; a quick on-device check first decides whether a turn is worth extracting, so the GPU only runs when there's something to save. Once memory passes the note count above, an automatic pass dedupes and reorganizes it so it stays compact. The Reflect button (brain icon) rewrites the whole memory on the server.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Long-term Memory") {
                Toggle("Inject memory into system prompt", isOn: $settings.injectMemory)
                Toggle("Tell the model today's date", isOn: $settings.injectDateContext)
                Toggle("Retrieve relevant memory via embeddings", isOn: $settings.useEmbeddingMemory)
                if settings.useEmbeddingMemory {
                    ModelSelectField(title: "Embedding model", selection: $settings.embeddingModel, models: model.embeddingCandidates)
                    Stepper(value: $settings.memoryTopK, in: 1...20) {
                        LabeledContent("Max chunks", value: "\(settings.memoryTopK)")
                    }
                    VStack(alignment: .leading) {
                        HStack {
                            Text("Match threshold")
                            Spacer()
                            Text(settings.memoryThreshold, format: .number.precision(.fractionLength(2)))
                                .foregroundStyle(.secondary).monospacedDigit()
                        }
                        Slider(value: $settings.memoryThreshold, in: 0...0.9, step: 0.05)
                    }
                }
            }
            Section("Attached documents (RAG)") {
                Stepper(value: $settings.ragThresholdChars, in: 2000...100000, step: 2000) {
                    LabeledContent("Index files over", value: "\(settings.ragThresholdChars) chars")
                }
                Stepper(value: $settings.ragTopK, in: 1...20) {
                    LabeledContent("Passages per turn", value: "\(settings.ragTopK)")
                }
                Text("Files larger than the threshold are chunked, embedded, and stored with the conversation; each turn only the most relevant passages are retrieved (needs an embedding model). Smaller files are inlined into the message as before.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct ToolsSettings: View {
    @Environment(AppModel.self) private var model
    @State private var toolMode: AppMode = .chat

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                Toggle("Enable tool calling", isOn: $settings.toolsEnabled)
                Text("Master switch. Configure which tools each mode may use below.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Picker("Mode", selection: $toolMode) {
                    ForEach(AppMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            } footer: {
                Text("Tool availability and auto-approval are set separately for each mode.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(ToolGroup.allCases) { group in
                let specs = Tools.all.filter { $0.group == group }
                if !specs.isEmpty {
                    Section {
                        ForEach(specs) { spec in
                            ToolRow(spec: spec, mode: toolMode, settings: settings)
                        }
                    } header: {
                        HStack(spacing: 0) {
                            Text(group.label)
                            Spacer(minLength: 12)
                            Text("On").frame(width: toolColumnWidth)
                            Text("Auto").frame(width: toolColumnWidth)
                        }
                    }
                    .disabled(!settings.toolsEnabled)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private let toolColumnWidth: CGFloat = 52

private struct ToolRow: View {
    let spec: ToolSpec
    let mode: AppMode
    @Bindable var settings: AppSettings

    private var enabled: Bool { settings.enabledTools(for: mode).contains(spec.name) }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(spec.name).font(.body.monospaced())
                    if spec.mutating {
                        Image(systemName: "pencil.circle.fill")
                            .font(.caption2).foregroundStyle(.orange)
                            .help("Writes or executes — review before auto-approving.")
                    }
                }
                Text(spec.summary).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Toggle("Enabled", isOn: Binding(
                get: { enabled },
                set: { settings.setToolEnabled(spec.name, $0, for: mode) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .frame(width: toolColumnWidth)
            Toggle("Auto-approve", isOn: Binding(
                get: { settings.autoApproveTools(for: mode).contains(spec.name) },
                set: { settings.setAutoApprove(spec.name, $0, for: mode) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .frame(width: toolColumnWidth)
            .disabled(!enabled)
            .help("Run without asking for approval.")
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
    }
}

private struct PersonaSettings: View {
    @Environment(AppModel.self) private var model
    @State private var selection: UUID?

    var body: some View {
        HSplitView {
            List(selection: $selection) {
                ForEach(model.personas) { persona in
                    Label(persona.name, systemImage: persona.iconSymbol).tag(persona.id)
                }
            }
            .frame(minWidth: 150, idealWidth: 190, maxWidth: 240)
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 4) {
                    Button { model.addPersona() } label: {
                        Image(systemName: "plus").frame(width: 24, height: 24).contentShape(Rectangle())
                    }
                    Button {
                        if let id = selection { model.deletePersona(id); selection = nil }
                    } label: {
                        Image(systemName: "minus").frame(width: 24, height: 24).contentShape(Rectangle())
                    }
                    .disabled(selection == nil || model.personas.count <= 1)
                    Spacer()
                }
                .buttonStyle(.borderless).padding(6)
            }

            Group {
                if let id = selection ?? model.personas.first?.id,
                   let persona = model.personas.first(where: { $0.id == id }) {
                    PersonaEditorView(persona: persona).id(persona.id)
                } else {
                    Text("Select a persona").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { if selection == nil { selection = model.personas.first?.id } }
    }
}

private struct AppearanceSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Form {
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
    }
}

/// A directly-typable integer field with a stepper for nudging.
private struct NumberField: View {
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
