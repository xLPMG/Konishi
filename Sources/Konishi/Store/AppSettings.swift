import SwiftUI
import Observation

/// Where speech input/output is processed.
enum AudioSource: String, CaseIterable, Codable, Sendable, Identifiable {
    case native
    case server
    var id: String { rawValue }
    var label: String {
        self == .native ? "Native (Apple)" : "Server (OpenAI-compatible)"
    }
}

/// What the Reflect action distills from a conversation into memory.
enum ReflectionStyle: String, CaseIterable, Codable, Sendable, Identifiable {
    case preferences
    case balanced
    case detailed
    var id: String { rawValue }
    var label: String {
        switch self {
        case .preferences: "Preferences only"
        case .balanced: "Preferences + key topics"
        case .detailed: "Preferences + topics + facts"
        }
    }
    var guidance: String {
        switch self {
        case .preferences:
            return "durable user preferences, decisions, and stable personal context"
        case .balanced:
            return "durable user preferences and decisions, plus the important topics or subjects explored (kept brief)"
        case .detailed:
            return "durable user preferences and decisions, the key topics explored, and any notable facts or conclusions worth remembering later"
        }
    }
}

/// Global, app-wide configuration persisted to `UserDefaults` (except the token → Keychain).
@Observable
@MainActor
final class AppSettings {
    var baseURL: String {
        didSet { defaults.set(baseURL, forKey: Keys.baseURL) }
    }
    /// Global default model, used when a persona has no override.
    var model: String {
        didSet { defaults.set(model, forKey: Keys.model) }
    }
    var temperature: Double {
        didSet { defaults.set(temperature, forKey: Keys.temperature) }
    }
    var topP: Double {
        didSet { defaults.set(topP, forKey: Keys.topP) }
    }
    var maxTokens: Int {
        didSet { defaults.set(maxTokens, forKey: Keys.maxTokens) }
    }
    /// Manual context-window size (0 = auto-detect from server or config.json).
    var contextWindowOverride: Int {
        didSet { defaults.set(contextWindowOverride, forKey: Keys.contextWindowOverride) }
    }
    /// Summarize old turns instead of dropping them when history exceeds the budget.
    var compressionEnabled: Bool {
        didSet { defaults.set(compressionEnabled, forKey: Keys.compressionEnabled) }
    }
    /// Token budget for verbatim history; older turns get folded into a summary.
    var compressionBudget: Int {
        didSet { defaults.set(compressionBudget, forKey: Keys.compressionBudget) }
    }
    /// Use the (larger, more accurate) server model to write summaries instead of the on-device model.
    var compressionUseServer: Bool {
        didSet { defaults.set(compressionUseServer, forKey: Keys.compressionUseServer) }
    }
    /// How often streamed tokens are flushed to the UI (ms). Higher = fewer re-renders while streaming.
    var streamFlushMs: Int {
        didSet { defaults.set(streamFlushMs, forKey: Keys.streamFlushMs) }
    }
    var injectMemory: Bool {
        didSet { defaults.set(injectMemory, forKey: Keys.injectMemory) }
    }
    /// Give the model rough temporal awareness by noting today's date in the system prompt.
    var injectDateContext: Bool {
        didSet { defaults.set(injectDateContext, forKey: Keys.injectDateContext) }
    }
    var fontSize: Double {
        didSet { defaults.set(fontSize, forKey: Keys.fontSize) }
    }
    var accentColorHex: String {
        didSet { defaults.set(accentColorHex, forKey: Keys.accentColorHex) }
    }
    /// Stored in Keychain, not UserDefaults.
    var apiToken: String {
        didSet { Keychain.set(apiToken, for: Keys.apiToken) }
    }

    // Local mlx-lm server launcher
    var serverCommand: String {
        didSet { defaults.set(serverCommand, forKey: Keys.serverCommand) }
    }
    var serverModelPath: String {
        didSet { defaults.set(serverModelPath, forKey: Keys.serverModelPath) }
    }
    var serverPort: Int {
        didSet { defaults.set(serverPort, forKey: Keys.serverPort) }
    }
    /// Kill managed servers when the app quits (off = leave them running).
    var stopServersOnQuit: Bool {
        didSet { defaults.set(stopServersOnQuit, forKey: Keys.stopServersOnQuit) }
    }

    // Advanced generation
    var stopSequences: String {
        didSet { defaults.set(stopSequences, forKey: Keys.stopSequences) }
    }
    var seed: Int {
        didSet { defaults.set(seed, forKey: Keys.seed) }
    }
    var presencePenalty: Double {
        didSet { defaults.set(presencePenalty, forKey: Keys.presencePenalty) }
    }
    var frequencyPenalty: Double {
        didSet { defaults.set(frequencyPenalty, forKey: Keys.frequencyPenalty) }
    }

    // Features
    var autoTitle: Bool {
        didSet { defaults.set(autoTitle, forKey: Keys.autoTitle) }
    }
    /// Persist each conversation's request/response trace to disk so it survives restarts.
    var saveTraces: Bool {
        didSet { defaults.set(saveTraces, forKey: Keys.saveTraces) }
    }
    var reflectionStyle: ReflectionStyle {
        didSet { defaults.set(reflectionStyle.rawValue, forKey: Keys.reflectionStyle) }
    }
    var reflectionCustomPrompt: String {
        didSet { defaults.set(reflectionCustomPrompt, forKey: Keys.reflectionCustomPrompt) }
    }
    /// Build structured long-term memory automatically as the user chats.
    var autoMemory: Bool {
        didSet { defaults.set(autoMemory, forKey: Keys.autoMemory) }
    }
    /// Run the memory maintainer after this many new user messages.
    var autoMemoryEvery: Int {
        didSet { defaults.set(autoMemoryEvery, forKey: Keys.autoMemoryEvery) }
    }
    /// Pause automatically writing new memories. Existing memory is still injected/retrieved and
    /// the manual Reflect button still extracts on demand.
    var pauseMemoryWrites: Bool {
        didSet { defaults.set(pauseMemoryWrites, forKey: Keys.pauseMemoryWrites) }
    }
    /// Let memory self-consolidate: once it grows large, the periodic auto pass does a full
    /// dedup/reorganize rewrite instead of a cheap incremental merge.
    var autoConsolidate: Bool {
        didSet { defaults.set(autoConsolidate, forKey: Keys.autoConsolidate) }
    }
    /// Bullet count in a memory scope that triggers an automatic consolidation pass.
    var autoConsolidateThreshold: Int {
        didSet { defaults.set(autoConsolidateThreshold, forKey: Keys.autoConsolidateThreshold) }
    }
    /// Ask the server to disable model "thinking" for background tasks (reflect, summaries).
    var disableThinkingForTasks: Bool {
        didSet { defaults.set(disableThinkingForTasks, forKey: Keys.disableThinkingForTasks) }
    }
    /// Number of new messages before updating the chat title.
    var messageThresholdForTitleUpdate: Int {
        didSet { defaults.set(messageThresholdForTitleUpdate, forKey: Keys.messageThresholdForTitleUpdate) }
    }
    /// Let the chat model "think" (chain-of-thought) before answering. Off = faster replies.
    var reasoningEnabled: Bool {
        didSet { defaults.set(reasoningEnabled, forKey: Keys.reasoningEnabled) }
    }
    /// Index attached files larger than this many characters for retrieval instead of inlining them.
    var ragThresholdChars: Int {
        didSet { defaults.set(ragThresholdChars, forKey: Keys.ragThresholdChars) }
    }
    /// Number of document passages retrieved per turn.
    var ragTopK: Int {
        didSet { defaults.set(ragTopK, forKey: Keys.ragTopK) }
    }
    /// Master switch for tool calling. Individual tools are toggled via `enabledTools`.
    var toolsEnabled: Bool {
        didSet { defaults.set(toolsEnabled, forKey: Keys.toolsEnabled) }
    }
    /// Per-mode enabled tools (keyed by AppMode.rawValue). Absent entry = that mode's defaults.
    var enabledToolsByMode: [String: Set<String>] = [:]
    /// Per-mode auto-approved tools (keyed by AppMode.rawValue). Absent entry = that mode's defaults.
    var autoApproveByMode: [String: Set<String>] = [:]
    /// Per-mode executable names that may bypass run_shell's general approval requirement.
    var shellAutoApproveCommandsByMode: [String: String] = [:]

    /// Tools enabled for a mode; falls back to that mode's defaults until customised.
    func enabledTools(for mode: AppMode) -> Set<String> {
        enabledToolsByMode[mode.rawValue] ?? Tools.modeEnabledDefaults(mode)
    }
    func autoApproveTools(for mode: AppMode) -> Set<String> {
        autoApproveByMode[mode.rawValue] ?? Tools.modeAutoApproveDefaults(mode)
    }
    func setToolEnabled(_ name: String, _ on: Bool, for mode: AppMode) {
        var set = enabledTools(for: mode)
        if on { set.insert(name) } else { set.remove(name) }
        enabledToolsByMode[mode.rawValue] = set
        defaults.set(Array(set), forKey: Keys.enabledToolsKey(mode))
        if !on { setAutoApprove(name, false, for: mode) }   // disabling drops auto-approve too
    }
    func setAutoApprove(_ name: String, _ on: Bool, for mode: AppMode) {
        var set = autoApproveTools(for: mode)
        if on { set.insert(name) } else { set.remove(name) }
        autoApproveByMode[mode.rawValue] = set
        defaults.set(Array(set), forKey: Keys.autoApproveKey(mode))
    }
    func shellAutoApproveCommands(for mode: AppMode) -> String {
        shellAutoApproveCommandsByMode[mode.rawValue] ?? ""
    }
    func setShellAutoApproveCommands(_ commands: String, for mode: AppMode) {
        shellAutoApproveCommandsByMode[mode.rawValue] = commands
        defaults.set(commands, forKey: Keys.shellAutoApproveCommandsKey(mode))
    }

    /// Only simple invocations can bypass approval. Shell composition and substitutions must
    /// still be reviewed, even when the executable itself is listed.
    func shellCommandIsAutoApproved(_ command: String, for mode: AppMode) -> Bool {
        let allowed = Set(shellAutoApproveCommands(for: mode)
            .split(whereSeparator: \Character.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty })
        guard !allowed.isEmpty else { return false }

        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let unsafeSyntax = CharacterSet(charactersIn: "\n\r;&|<>`$()")
        guard !trimmed.isEmpty, trimmed.rangeOfCharacter(from: unsafeSyntax) == nil,
              let first = trimmed.split(whereSeparator: \Character.isWhitespace).first else { return false }
        let executable = String(first)
        let validName = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._/+"))
        guard executable.unicodeScalars.allSatisfy(validName.contains) else { return false }
        let name = URL(fileURLWithPath: executable).lastPathComponent
        guard allowed.contains(executable) || allowed.contains(name) else { return false }

        if name == "find" {
            let mutatingActions = ["-delete", "-exec", "-execdir", "-ok", "-okdir", "-fprint", "-fprint0", "-fprintf", "-fls"]
            let arguments = trimmed.split(whereSeparator: \Character.isWhitespace).dropFirst().map(String.init)
            guard !arguments.contains(where: { mutatingActions.contains($0.lowercased()) }) else { return false }
        }
        return true
    }
    /// Send attached/generated images to the model. Needs a vision-capable server (mlx-vlm or
    /// LM Studio with a vision model); mlx_lm.server is text-only and rejects image content.
    var sendImagesToModel: Bool {
        didSet { defaults.set(sendImagesToModel, forKey: Keys.sendImagesToModel) }
    }
    /// Route cheap auxiliary tasks (summaries, reflection) to Apple's on-device model.
    var useOnDeviceModel: Bool {
        didSet { defaults.set(useOnDeviceModel, forKey: Keys.useOnDeviceModel) }
    }
    var embeddingModel: String {
        didSet { defaults.set(embeddingModel, forKey: Keys.embeddingModel) }
    }
    var memoryTopK: Int {
        didSet { defaults.set(memoryTopK, forKey: Keys.memoryTopK) }
    }
    /// Minimum cosine similarity for a memory chunk to be injected (0 = always).
    var memoryThreshold: Double {
        didSet { defaults.set(memoryThreshold, forKey: Keys.memoryThreshold) }
    }

    // Voice
    var autoSpeak: Bool {
        didSet { defaults.set(autoSpeak, forKey: Keys.autoSpeak) }
    }
    var voiceIdentifier: String {
        didSet { defaults.set(voiceIdentifier, forKey: Keys.voiceIdentifier) }
    }
    var speechRate: Double {
        didSet { defaults.set(speechRate, forKey: Keys.speechRate) }
    }
    var conversationBargeIn: Bool {
        didSet { defaults.set(conversationBargeIn, forKey: Keys.conversationBargeIn) }
    }
    var conversationBackchannelANE: Bool {
        didSet { defaults.set(conversationBackchannelANE, forKey: Keys.conversationBackchannelANE) }
    }
    var sttSource: AudioSource {
        didSet { defaults.set(sttSource.rawValue, forKey: Keys.sttSource) }
    }
    var ttsSource: AudioSource {
        didSet { defaults.set(ttsSource.rawValue, forKey: Keys.ttsSource) }
    }
    var sttModel: String {
        didSet { defaults.set(sttModel, forKey: Keys.sttModel) }
    }
    var ttsModel: String {
        didSet { defaults.set(ttsModel, forKey: Keys.ttsModel) }
    }
    var ttsVoice: String {
        didSet { defaults.set(ttsVoice, forKey: Keys.ttsVoice) }
    }
    /// Separate endpoint for audio (STT/TTS); empty = reuse baseURL. LM Studio can't do audio.
    var audioBaseURL: String {
        didSet { defaults.set(audioBaseURL, forKey: Keys.audioBaseURL) }
    }
    /// Separate endpoint for embeddings; empty = reuse baseURL. Lets a dedicated embeddings
    /// server (e.g. infinity) run alongside an mlx chat server that has no /v1/embeddings.
    var embeddingBaseURL: String {
        didSet { defaults.set(embeddingBaseURL, forKey: Keys.embeddingBaseURL) }
    }

    /// The active language-learning profile (UUID string; empty = none selected yet).
    var activeLanguageProfileID: String {
        didSet { defaults.set(activeLanguageProfileID, forKey: Keys.activeLanguageProfileID) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.baseURL = defaults.string(forKey: Keys.baseURL) ?? "http://127.0.0.1:1234"
        self.model = defaults.string(forKey: Keys.model) ?? "gemma-4-26b-a4b-it-qat-mlx-4bit"
        self.temperature = defaults.object(forKey: Keys.temperature) as? Double ?? 0.7
        self.topP = defaults.object(forKey: Keys.topP) as? Double ?? 1.0
        self.maxTokens = defaults.object(forKey: Keys.maxTokens) as? Int ?? -1
        self.contextWindowOverride = defaults.object(forKey: Keys.contextWindowOverride) as? Int ?? 0
        self.compressionEnabled = defaults.object(forKey: Keys.compressionEnabled) as? Bool ?? true
        self.compressionBudget = defaults.object(forKey: Keys.compressionBudget) as? Int ?? 16000
        self.compressionUseServer = defaults.object(forKey: Keys.compressionUseServer) as? Bool ?? true
        self.streamFlushMs = defaults.object(forKey: Keys.streamFlushMs) as? Int ?? 40
        self.injectMemory = defaults.object(forKey: Keys.injectMemory) as? Bool ?? true
        self.injectDateContext = defaults.object(forKey: Keys.injectDateContext) as? Bool ?? true
        self.fontSize = defaults.object(forKey: Keys.fontSize) as? Double ?? 14
        self.accentColorHex = defaults.string(forKey: Keys.accentColorHex) ?? "#6C8CFF"
        self.apiToken = Keychain.get(Keys.apiToken)
        self.serverCommand = defaults.string(forKey: Keys.serverCommand) ?? "mlx_lm.server"
        self.serverModelPath = defaults.string(forKey: Keys.serverModelPath)
            ?? "~/.lmstudio/models/lmstudio-community/gemma-4-26B-A4B-it-QAT-MLX-4bit"
        self.serverPort = defaults.object(forKey: Keys.serverPort) as? Int ?? 8080
        self.stopServersOnQuit = defaults.object(forKey: Keys.stopServersOnQuit) as? Bool ?? true
        self.stopSequences = defaults.string(forKey: Keys.stopSequences) ?? ""
        self.seed = defaults.object(forKey: Keys.seed) as? Int ?? -1
        self.presencePenalty = defaults.object(forKey: Keys.presencePenalty) as? Double ?? 0
        self.frequencyPenalty = defaults.object(forKey: Keys.frequencyPenalty) as? Double ?? 0
        self.autoTitle = defaults.object(forKey: Keys.autoTitle) as? Bool ?? true
        self.saveTraces = defaults.object(forKey: Keys.saveTraces) as? Bool ?? true
        self.reflectionStyle = ReflectionStyle(rawValue: defaults.string(forKey: Keys.reflectionStyle) ?? "") ?? .balanced
        self.reflectionCustomPrompt = defaults.string(forKey: Keys.reflectionCustomPrompt) ?? ""
        self.autoMemory = defaults.object(forKey: Keys.autoMemory) as? Bool ?? true
        self.autoMemoryEvery = defaults.object(forKey: Keys.autoMemoryEvery) as? Int ?? 2
        self.pauseMemoryWrites = defaults.object(forKey: Keys.pauseMemoryWrites) as? Bool ?? false
        self.autoConsolidate = defaults.object(forKey: Keys.autoConsolidate) as? Bool ?? true
        self.autoConsolidateThreshold = defaults.object(forKey: Keys.autoConsolidateThreshold) as? Int ?? 40
        self.disableThinkingForTasks = defaults.object(forKey: Keys.disableThinkingForTasks) as? Bool ?? true
        self.messageThresholdForTitleUpdate = defaults.object(forKey: Keys.messageThresholdForTitleUpdate) as? Int ?? 6
        self.reasoningEnabled = defaults.object(forKey: Keys.reasoningEnabled) as? Bool ?? true
        self.ragThresholdChars = defaults.object(forKey: Keys.ragThresholdChars) as? Int ?? 12000
        self.ragTopK = defaults.object(forKey: Keys.ragTopK) as? Int ?? 6
        self.toolsEnabled = defaults.object(forKey: Keys.toolsEnabled) as? Bool ?? false
        var enabledByMode: [String: Set<String>] = [:]
        var autoByMode: [String: Set<String>] = [:]
        // Legacy flat sets applied to chat AND voice before tools went per-mode; migrate into both.
        let legacyModes: Set<AppMode> = [.chat, .conversational]
        for m in AppMode.allCases {
            if let arr = defaults.stringArray(forKey: Keys.enabledToolsKey(m)) {
                enabledByMode[m.rawValue] = Set(arr)
            } else if legacyModes.contains(m), let old = defaults.stringArray(forKey: Keys.enabledTools) {
                enabledByMode[m.rawValue] = Set(old)   // migrate legacy flat set
            }
            if let arr = defaults.stringArray(forKey: Keys.autoApproveKey(m)) {
                autoByMode[m.rawValue] = Set(arr)
            } else if legacyModes.contains(m), let old = defaults.stringArray(forKey: Keys.autoApproveTools) {
                autoByMode[m.rawValue] = Set(old)
            }
        }
        if defaults.integer(forKey: Keys.settingsVersion) < 3 {
            for mode in [AppMode.chat, .conversational] {
                var enabled = enabledByMode[mode.rawValue] ?? Tools.modeEnabledDefaults(mode)
                enabled.insert("calculate")
                enabledByMode[mode.rawValue] = enabled
                defaults.set(Array(enabled), forKey: Keys.enabledToolsKey(mode))

                var approved = autoByMode[mode.rawValue] ?? Tools.modeAutoApproveDefaults(mode)
                approved.insert("calculate")
                autoByMode[mode.rawValue] = approved
                defaults.set(Array(approved), forKey: Keys.autoApproveKey(mode))
            }
            defaults.set(3, forKey: Keys.settingsVersion)
        }
        self.enabledToolsByMode = enabledByMode
        self.autoApproveByMode = autoByMode
        self.shellAutoApproveCommandsByMode = Dictionary(uniqueKeysWithValues: AppMode.allCases.compactMap { mode in
            defaults.string(forKey: Keys.shellAutoApproveCommandsKey(mode)).map { (mode.rawValue, $0) }
        })
        self.sendImagesToModel = defaults.object(forKey: Keys.sendImagesToModel) as? Bool ?? false
        self.useOnDeviceModel = defaults.object(forKey: Keys.useOnDeviceModel) as? Bool ?? true
        self.embeddingModel = defaults.string(forKey: Keys.embeddingModel) ?? "text-embedding-nomic-embed-text-v1.5"
        self.memoryTopK = defaults.object(forKey: Keys.memoryTopK) as? Int ?? 10
        self.memoryThreshold = defaults.object(forKey: Keys.memoryThreshold) as? Double ?? 0.4
        self.autoSpeak = defaults.object(forKey: Keys.autoSpeak) as? Bool ?? false
        self.voiceIdentifier = defaults.string(forKey: Keys.voiceIdentifier) ?? ""
        self.speechRate = defaults.object(forKey: Keys.speechRate) as? Double ?? 0.5
        self.conversationBargeIn = defaults.object(forKey: Keys.conversationBargeIn) as? Bool ?? true
        self.conversationBackchannelANE = defaults.object(forKey: Keys.conversationBackchannelANE) as? Bool ?? true
        self.sttSource = AudioSource(rawValue: defaults.string(forKey: Keys.sttSource) ?? "") ?? .native
        self.ttsSource = AudioSource(rawValue: defaults.string(forKey: Keys.ttsSource) ?? "") ?? .native
        self.sttModel = defaults.string(forKey: Keys.sttModel) ?? "mlx-community/whisper-large-v3-turbo-asr-fp16"
        self.ttsModel = defaults.string(forKey: Keys.ttsModel) ?? "mlx-community/Kokoro-82M-bf16"
        self.ttsVoice = defaults.string(forKey: Keys.ttsVoice) ?? "af_heart"
        self.audioBaseURL = defaults.string(forKey: Keys.audioBaseURL) ?? ""
        self.embeddingBaseURL = defaults.string(forKey: Keys.embeddingBaseURL) ?? ""
        self.activeLanguageProfileID = defaults.string(forKey: Keys.activeLanguageProfileID) ?? ""
    }

    /// `maxTokens <= 0` means "let the server decide".
    var effectiveMaxTokens: Int? {
        maxTokens > 0 ? maxTokens : nil
    }

    private func url(path: String) -> URL? {
        urlFrom(base: baseURL, path: path)
    }

    private func urlFrom(base: String, path: String) -> URL? {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let clean = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
        return URL(string: clean + path)
    }

    /// Audio endpoint base: dedicated audioBaseURL when set, otherwise baseURL.
    private var audioBase: String {
        audioBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? baseURL : audioBaseURL
    }

    /// Embeddings endpoint base: dedicated embeddingBaseURL when set, otherwise baseURL.
    private var embeddingBase: String {
        embeddingBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? baseURL : embeddingBaseURL
    }

    var chatCompletionsURL: URL? { url(path: "/v1/chat/completions") }
    var modelsURL: URL? { url(path: "/v1/models") }
    /// LM Studio's native endpoint that reports per-model load state.
    var apiModelsURL: URL? { url(path: "/api/v0/models") }
    var embeddingsURL: URL? { urlFrom(base: embeddingBase, path: "/v1/embeddings") }
    var transcriptionsURL: URL? { urlFrom(base: audioBase, path: "/v1/audio/transcriptions") }
    var speechURL: URL? { urlFrom(base: audioBase, path: "/v1/audio/speech") }
    var audioModelsURL: URL? { urlFrom(base: audioBase, path: "/v1/models") }
    var audioVoicesURL: URL? { urlFrom(base: audioBase, path: "/v1/audio/voices") }

    private var parsedStop: [String]? {
        let items = stopSequences
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return items.isEmpty ? nil : items
    }

    /// Snapshot of everything the networking layer needs, as Sendable values.
    func requestConfig(modelOverride: String?) -> RequestConfig {
        RequestConfig(
            chatURL: chatCompletionsURL,
            modelsURL: modelsURL,
            apiModelsURL: apiModelsURL,
            embeddingsURL: embeddingsURL,
            transcriptionsURL: transcriptionsURL,
            speechURL: speechURL,
            audioModelsURL: audioModelsURL,
            audioVoicesURL: audioVoicesURL,
            model: (modelOverride?.isEmpty == false ? modelOverride! : model),
            temperature: temperature,
            topP: topP == 1.0 ? nil : topP,
            maxTokens: effectiveMaxTokens,
            stop: parsedStop,
            seed: seed >= 0 ? seed : nil,
            presencePenalty: presencePenalty == 0 ? nil : presencePenalty,
            frequencyPenalty: frequencyPenalty == 0 ? nil : frequencyPenalty,
            token: apiToken.trimmingCharacters(in: .whitespacesAndNewlines),
            embeddingModel: embeddingModel,
            sttModel: sttModel,
            ttsModel: ttsModel,
            ttsVoice: ttsVoice
        )
    }

    private enum Keys {
        static let baseURL = "konishi.baseURL"
        static let model = "konishi.model"
        static let temperature = "konishi.temperature"
        static let topP = "konishi.topP"
        static let maxTokens = "konishi.maxTokens"
        static let contextWindowOverride = "konishi.contextWindowOverride"
        static let compressionEnabled = "konishi.compressionEnabled"
        static let compressionBudget = "konishi.compressionBudget"
        static let compressionUseServer = "konishi.compressionUseServer"
        static let streamFlushMs = "konishi.streamFlushMs"
        static let injectMemory = "konishi.injectMemory"
        static let injectDateContext = "konishi.injectDateContext"
        static let fontSize = "konishi.fontSize"
        static let accentColorHex = "konishi.accentColorHex"
        static let apiToken = "konishi.apiToken"
        static let serverCommand = "konishi.serverCommand"
        static let serverModelPath = "konishi.serverModelPath"
        static let serverPort = "konishi.serverPort"
        static let stopServersOnQuit = "konishi.stopServersOnQuit"
        static let stopSequences = "konishi.stopSequences"
        static let seed = "konishi.seed"
        static let presencePenalty = "konishi.presencePenalty"
        static let frequencyPenalty = "konishi.frequencyPenalty"
        static let autoTitle = "konishi.autoTitle"
        static let saveTraces = "konishi.saveTraces"
        static let reflectionStyle = "konishi.reflectionStyle"
        static let reflectionCustomPrompt = "konishi.reflectionCustomPrompt"
        static let autoMemory = "konishi.autoMemory"
        static let autoMemoryEvery = "konishi.autoMemoryEvery"
        static let pauseMemoryWrites = "konishi.pauseMemoryWrites"
        static let autoConsolidate = "konishi.autoConsolidate"
        static let autoConsolidateThreshold = "konishi.autoConsolidateThreshold"
        static let disableThinkingForTasks = "konishi.disableThinkingForTasks"
        static let messageThresholdForTitleUpdate = "konishi.messageThresholdForTitleUpdate"
        static let reasoningEnabled = "konishi.reasoningEnabled"
        static let ragThresholdChars = "konishi.ragThresholdChars"
        static let ragTopK = "konishi.ragTopK"
        static let toolsEnabled = "konishi.toolsEnabled"
        static let enabledTools = "konishi.enabledTools"
        static let autoApproveTools = "konishi.autoApproveTools"
        static func enabledToolsKey(_ mode: AppMode) -> String { "konishi.enabledTools." + mode.rawValue }
        static func autoApproveKey(_ mode: AppMode) -> String { "konishi.autoApprove." + mode.rawValue }
        static func shellAutoApproveCommandsKey(_ mode: AppMode) -> String { "konishi.shellAutoApproveCommands." + mode.rawValue }
        static let sendImagesToModel = "konishi.sendImagesToModel"
        static let useOnDeviceModel = "konishi.useOnDeviceModel"
        static let settingsVersion = "konishi.settingsVersion"
        static let embeddingModel = "konishi.embeddingModel"
        static let memoryTopK = "konishi.memoryTopK"
        static let memoryThreshold = "konishi.memoryThreshold"
        static let autoSpeak = "konishi.autoSpeak"
        static let voiceIdentifier = "konishi.voiceIdentifier"
        static let speechRate = "konishi.speechRate"
        static let conversationBargeIn = "konishi.conversationBargeIn"
        static let conversationBackchannelANE = "konishi.conversationBackchannelANE"
        static let sttSource = "konishi.sttSource"
        static let ttsSource = "konishi.ttsSource"
        static let sttModel = "konishi.sttModel"
        static let ttsModel = "konishi.ttsModel"
        static let ttsVoice = "konishi.ttsVoice"
        static let audioBaseURL = "konishi.audioBaseURL"
        static let embeddingBaseURL = "konishi.embeddingBaseURL"
        static let activeLanguageProfileID = "konishi.activeLanguageProfileID"
    }
}
