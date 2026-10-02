import AppKit
import Observation
import SwiftUI

@Observable
@MainActor
final class StreamPresentation {
    private(set) var conversationID: UUID?
    private(set) var assistantID: UUID?
    var content = ""
    var reasoning = ""

    func begin(conversationID: UUID, assistantID: UUID) {
        self.conversationID = conversationID
        self.assistantID = assistantID
        clearText()
    }

    func matches(conversationID: UUID, assistantID: UUID) -> Bool {
        self.conversationID == conversationID && self.assistantID == assistantID
    }

    func clearText() {
        content = ""
        reasoning = ""
    }

    func clear() {
        conversationID = nil
        assistantID = nil
        clearText()
    }
}

@Observable
@MainActor
final class AppModel {
    // Persisted state
    var settings: AppSettings
    var conversations: [Conversation]

    // Selection & transient UI state
    var selectedConversationID: UUID? {
        didSet {
            if let id = selectedConversationID, id != oldValue {
                ensureHydrated(id)
                restorePendingApproval(for: id)
                scheduleSleepPass(after: .seconds(20))
            }
        }
    }
    var draft: String = ""
    var draftImages: [String] = []  // base64 data URLs pending send
    var draftAttachments: [Attachment] = []  // extracted-text documents pending send
    var isStreaming = false
    var errorMessage: String?
    var isReflecting = false
    var searchText: String = "" {
        didSet { if searchText != oldValue { scheduleSearch() } }
    }
    var pendingApproval: PendingToolBatch?
    var pendingWorkGate: PendingWorkGate?
    var queuedTextInterrupt: QueuedTextInterrupt?
    @ObservationIgnored
    var workSession: AgentWorkSession?
    var isAutopilotActive = false
    var autopilotPermissionDenials = 0
    var autopilotBlockedCapabilities: [String] = []
    var autopilotRunConversationID: UUID?
    var pendingToolStopNotice: UUID?
    var isStoppingWork = false
    var autopilotArmed = false
    /// A paused turn waiting on the user to answer an `ask_multiple_choice` prompt.
    var pendingInteraction: PendingInteraction?
    var mode: AppMode = .chat
    /// Language-learning profiles (loaded from the SQLite deck store).
    var languageProfiles: [LanguageProfile] = []
    /// Bumped on any deck write so views recompute stats (LanguageStore isn't Observable).
    var languageDeckRevision = 0
    /// Transient config for the current language session (topic, difficulty, study/practice/free).
    var languageSession = LanguageSession()
    /// In Learn mode, whether the mic dictates in the target language (true) or the base language.
    var languageInputTarget = true
    /// Ephemeral one-line status for tool activity (e.g. "Thinking…", "Calling web_search…").
    var activity: String?

    // Server info
    var models: [ModelInfo] = []
    var audioModels: [ModelInfo] = []
    var audioVoices: [String] = []
    var connectionOK: Bool?
    var discoveredModels: [LocalModels.Entry] = []
    var discoveredEndpoints: [DetectedEndpoint] = []

    let memoryStore = MemoryStore()
    let stm = STMStore()
    let fileStore = FileStore()
    let documentStore = DocumentStore()
    let vaultStore = VaultStore()
    let calendarStore = AppleCalendarStore()
    let personaStore = PersonaStore()
    let runtime = Runtime()
    let voice = VoiceManager()
    let embeddingCache = EmbeddingCache()
    let languageStore = LanguageStore()
    let traceStore = TraceStore()
    var streamTask: Task<Void, Never>?
    let streamPresentation = StreamPresentation()
    /// Resumed with the tool result once the user answers a pending multiple-choice prompt.
    var interactionContinuation: CheckedContinuation<String, Never>?

    struct PendingToolBatch: Identifiable {
        let id = UUID()
        let conversationID: UUID
        let calls: [ToolCall]
        var permissionEvaluations: [String: ToolPermissionEvaluation] = [:]
        var permissionMode: AppMode?
        /// Whether the model needs another turn to act on a tool's output.
        var continueAfter: Bool = true
        var continuationNote: String?
    }

    struct PendingWorkGate: Identifiable {
        let id = UUID()
        let conversationID: UUID
        let reason: AgentWorkPauseReason
        var batch: PendingToolBatch?
    }

    struct QueuedTextInterrupt: Sendable {
        let conversationID: UUID
        let content: String
        let images: [String]
        let attachments: [Attachment]
    }

    init() {
        Paths.ensure()
        self.settings = AppSettings()
        self.conversations = Self.loadConversations().sorted { $0.updatedAt > $1.updatedAt }
        let searchIndex = ConversationSearchIndex()
        Persistence.ioQueue.async {
            try? searchIndex.rebuildIfNeeded(conversationsDirectory: Paths.conversations)
        }
        self.languageProfiles = languageStore.allProfiles()
        self.selectedConversationID = conversations.first(where: { $0.isLanguage != true })?.id
        VoiceManager.warmVoices()  // preload the slow system voice catalog off-main
        if conversations.isEmpty {
            newConversation()
        } else if let id = selectedConversationID {
            ensureHydrated(id)  // property observers don't fire during init
            restorePendingApproval(for: id)
        }
        // Ensure the last queued disk writes are flushed before the process exits.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in Self.flushPendingWrites() }
    }

    // MARK: - Derived

    var selectedConversation: Conversation? {
        guard let id = selectedConversationID else { return nil }
        return conversations.first { $0.id == id }
    }

    var canCreateConversation: Bool {
        guard let conversation = selectedConversation,
            (conversation.isLanguage == true) == (mode == .language)
        else { return true }
        return !conversation.messages.isEmpty
    }

    var currentPersona: Persona { personaStore.persona(for: selectedConversation) }

    var currentAssistantName: String { personaStore.assistantName(for: currentPersona) }

    var currentPalette: ThemePalette { settings.theme.palette }

    var currentAccent: Color {
        if let hex = currentPersona.accentColorHex { return Color(hex: hex) }
        return Color(hex: settings.accentColorHex)
    }

    private var contextConfigCache: [String: Int] = [:]

    var contextWindow: Int? {
        if settings.contextWindowOverride > 0 { return settings.contextWindowOverride }
        let modelID =
            currentPersona.model?.isEmpty == false ? currentPersona.model! : settings.model
        if let info = (models.first { $0.id == modelID } ?? models.first),
            let ctx = info.loadedContextLength ?? info.maxContextLength
        {
            return ctx
        }
        // mlx-lm reports the model as a local path; read its config.json.
        return contextFromConfig(modelID)
    }

    private func contextFromConfig(_ modelID: String) -> Int? {
        let path = (modelID as NSString).expandingTildeInPath
        if let cached = contextConfigCache[path] { return cached }
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let url = URL(fileURLWithPath: path).appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: url),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let ctx =
            (obj["max_position_embeddings"] as? Int)
            ?? (obj["text_config"] as? [String: Any])?["max_position_embeddings"] as? Int
        if let ctx { contextConfigCache[path] = ctx }
        return ctx
    }

    /// True when the server reports per-model load state (LM Studio).
    var hasLoadState: Bool {
        models.contains { $0.isLoaded != nil }
    }

    var loadedModels: [ModelInfo] {
        models.filter { $0.isLoaded == true }
    }

    var unloadedModels: [ModelInfo] {
        models.filter { $0.isLoaded != true }
    }

    /// Tools currently advertised to the model (0 when tool calling is off).
    var activeToolNames: [String] {
        guard mode != .conversational, let conversationID = selectedConversationID else { return [] }
        let surface: PermissionSurface = workSession?.autopilot == true ? .unattended : .interactive
        return ToolPermissions.visibleTools(
            context: toolPermissionContext(conversationID: conversationID, surface: surface)
        ).map(\.name)
    }

    /// Heuristic model shortlists for the embedding / audio pickers (fall back to all).
    var embeddingCandidates: [ModelInfo] {
        let e = models.filter {
            ($0.type ?? "").lowercased().contains("embed") || $0.id.lowercased().contains("embed")
        }
        return e.isEmpty ? models : e
    }
    var sttCandidates: [ModelInfo] {
        let s = audioModels.filter {
            let t = ($0.type ?? "").lowercased()
            let id = $0.id.lowercased()
            return t.contains("whisper") || t.contains("stt") || t.contains("transcri")
                || t.contains("parakeet") || id.contains("whisper") || id.contains("parakeet")
        }
        return s.isEmpty ? audioModels : s
    }
    var ttsCandidates: [ModelInfo] {
        let t = audioModels.filter {
            let ty = ($0.type ?? "").lowercased()
            let id = $0.id.lowercased()
            return ty.contains("tts") || id.contains("tts") || id.contains("kokoro")
                || id.contains("piper") || id.contains("speech")
        }
        return t.isEmpty ? audioModels : t
    }

    var filteredConversations: [Conversation] {
        // Learn mode lists only language sessions; other modes list only normal chats.
        let inMode = conversations.filter { ($0.isLanguage == true) == (mode == .language) }
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return inMode }
        return inMode.filter { convo in
            convo.title.lowercased().contains(q) || contentMatchIDs.contains(convo.id)
        }
    }

    // MARK: - Documents

    func documentContext(conversationID: UUID, history: [ChatMessage]) async -> String {
        guard let query = history.last(where: { $0.role == .user })?.content, !query.isEmpty else {
            return ""
        }
        let result = await documentStore.context(
            for: conversationID, query: query, cache: embeddingCache,
            topK: settings.ragTopK,
            requestConfig: settings.requestConfig(modelOverride: nil))
        traceRetrievalFallback(result, source: "Document", conversationID: conversationID)
        return result.text
    }

    // MARK: - Research vault

    /// Vault passages injected into the prompt — only for personas granted vault access, so vault
    /// content never reaches everyday chats.
    func vaultContext(conversationID: UUID, persona: Persona, history: [ChatMessage]) async -> String {
        guard persona.vaultAccessEnabled, !settings.vaultPath.isEmpty else { return "" }
        guard let query = history.last(where: { $0.role == .user })?.content, !query.isEmpty else {
            return ""
        }
        let result = await vaultStore.context(
            vaultPath: settings.vaultPath, query: query, cache: embeddingCache,
            topK: settings.vaultTopK, requestConfig: settings.requestConfig(modelOverride: nil))
        traceRetrievalFallback(result, source: "Vault", conversationID: conversationID)
        return result.text
    }

    func traceRetrievalFallback(
        _ result: HybridRetrieval.Context, source: String, conversationID: UUID
    ) {
        guard let failure = result.failure else { return }
        traceStore.trace(
            conversationID: conversationID, kind: .error,
            text:
                "\(source) embedding retrieval failed; BM25 fallback selected \(result.scored.count)/\(result.candidateCount) passages: \(failure)",
            saveTraces: settings.saveTraces,
            detail: HybridRetrieval.traceDetail(result.scored))
    }

    // MARK: - Lazy conversation bodies

    /// Conversations whose message bodies are resident in RAM. Everything else keeps only metadata
    /// (title, dates, summary); bodies live on disk and are paged in on demand.
    var hydratedIDs: Set<UUID> = []
    /// Least-recently-used order of hydrated conversations (front = oldest).
    var hydrationOrder: [UUID] = []
    static let maxHydrated = 3
    /// The conversation a turn is actively writing to; protected from eviction across its tool loop.
    var streamingConversationID: UUID?

    // MARK: - Conversation search (async, disk-backed)

    /// Ids whose message body matched the current query (found via an off-main disk scan).
    var contentMatchIDs: Set<UUID> = []
    var searchTask: Task<Void, Never>?

    // MARK: - Sending & streaming

    var canBeginAgentTask: Bool {
        AgentTaskEntry.isAvailable(
            isStreaming: isStreaming,
            awaitingToolApproval: pendingApproval != nil,
            awaitingWorkDecision: pendingWorkGate != nil,
            finishingToolOperation: isStoppingWork)
    }

    var canInterruptWithText: Bool {
        isStreaming && streamTask != nil && toolExecutionTask == nil
            && pendingApproval == nil && pendingWorkGate == nil && !isStoppingWork
            && streamingConversationID == selectedConversationID
    }

    var canQueueTextInterrupt: Bool {
        isStreaming && toolExecutionTask != nil && queuedTextInterrupt == nil
            && pendingApproval == nil && pendingWorkGate == nil && !isStoppingWork
            && streamingConversationID == selectedConversationID
    }

    var canSend: Bool {
        (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draftImages.isEmpty
            || !draftAttachments.isEmpty)
            && (canBeginAgentTask || canInterruptWithText || canQueueTextInterrupt)
    }

    // Streamed tokens are buffered and flushed on a timer so the UI re-renders (and re-parses
    // markdown) a few times per second instead of once per token.
    var deltaBuffer = ""
    var flushTask: Task<Void, Never>?
    /// Buffered reasoning tokens, flushed on the same cadence as content so the disclosure updates
    /// a few times per second instead of once per token.
    var reasoningBuffer = ""
    var reasoningFlushTask: Task<Void, Never>?
    /// Streaming TTS: text of the current assistant message not yet flushed to the speaker.
    /// Only the unspoken tail is held, so we never rescan the whole (growing) message each flush.
    var ttsPending = ""
    var ttsMessageID: UUID?
    static let sentenceTerminators: Set<Character> = [".", "!", "?", "。", "！", "？", "…", "\n"]
    /// Serial server-TTS pipeline for streamed chat replies: sentences synthesized in order.
    var speechSegCont: AsyncStream<String>.Continuation?
    var speechSynthTask: Task<Void, Never>?
    var toolExecutionTask: Task<Void, Never>?
    /// True once we've surfaced a server-TTS failure this session, so we don't nag on every reply.
    /// Reset when TTS succeeds again or the audio endpoint/source changes.
    var warnedServerTTSFailure = false

    // MARK: - Tool approval & execution

    /// Signatures (name+args) of tool calls in the current user turn, for dedupe + loop detection.
    var loopSignatures: [String] = []
    /// Web sources (search results / fetched pages) gathered this turn, attached to the reply.
    var turnSources: [Source] = []
    /// Read-only tools whose identical repeat within a turn can be skipped safely.
    static let readOnlyTools: Set<String> = [
        "memory_list", "memory_read", "file_read", "list_dir",
        "git_status", "git_diff", "git_log", "web_search", "web_fetch", "web_research",
        "search_deck", "get_due_items", "calculate",
        "vault_search", "vault_read", "vault_list",
        "conversation_search", "conversation_list", "conversation_read",
        "calendar_events", "reminders_list",
    ]
    /// Tools whose OUTPUT the model must read to finish its reply, so a continuation turn is warranted.
    /// After fire-and-forget writes (e.g. banking a card) with a written reply, the turn is complete.
    static let continuationTools: Set<String> = [
        "get_due_items", "search_deck", "web_search", "web_fetch", "web_research", "file_read", "file_write",
        "memory_list", "memory_read", "calculate", "python_exec", "run_shell", "ask_multiple_choice",
        "vault_search", "vault_read", "vault_list",
        "conversation_search", "conversation_list", "conversation_read",
        "calendar_events", "reminders_list",
    ]

    /// How many trailing tool results are kept verbatim in the wire; older ones are stubbed.
    static let maxFullToolResults = 4

    /// Compact deck overview injected each turn so the model has cheap progress awareness.
    /// Cached by (profile, deck revision) since it's rebuilt on every turn but only changes on a write.
    var deckContextCache: (key: String, text: String)?

    // MARK: - Compression

    var isCompressing = false

    // MARK: - Auto-title

    /// Conversations whose title is auto-generated (not user-renamed), so it may be refined.
    var autoTitledIDs: Set<UUID> = []

    // MARK: - Conversational mode

    enum VoiceState: Equatable { case idle, listening, thinking, speaking }
    var voiceState: VoiceState = .idle
    var conversationActive = false
    var liveTranscript = ""
    var conversationEndpointTask: Task<Void, Never>?
    var bargeInConfirmationTask: Task<Void, Never>?
    var bargeInClassificationTask: Task<Void, Never>?
    var bargeInFallbackTask: Task<Void, Never>?
    var conversationResponseTask: Task<Void, Never>?
    var conversationSynthesisTask: Task<Void, Never>?
    var conversationSegmentContinuation: AsyncStream<String>.Continuation?
    var inFlightSynthTasks: [Task<Data, any Error>] = []
    var conversationGeneration = 0
    var conversationSessionID: UUID?
    var bargeInCandidate = ""
    var bargeInCandidateFinal = false
    var bargeInTranscriptBaseline = ""
    var bargeInLatestTranscript = ""
    var bargeInDecisionID: UUID?
    var conversationReplyDraft = ""
    var conversationReplyMessageID: UUID?
    static let bargeInConfirmationMilliseconds = 300
    static let backchannelClassificationTimeoutMilliseconds = 1_000
    /// Set when the model calls `end_conversation`; the turn finishes speaking, then hangs up
    /// instead of resuming listening.
    var endConversationRequested = false

    // MARK: Speculative dispatch
    /// Timer that fires the speculative LLM request after a short initial silence.
    var speculativeFireTask: Task<Void, Never>?
    /// The in-flight speculative LLM + TTS task (cancelled if the user resumes speaking).
    var speculativeResponseTask: Task<Void, Never>?
    /// Audio clips synthesized speculatively (native-TTS path), held until the turn is confirmed.
    var speculativeAudioBuffer: [Data] = []
    /// Text segments accumulated speculatively (server-TTS path), held until confirmed.
    var speculativeSegmentBuffer: [String] = []
    /// Full reply text built speculatively; committed to history on confirmation.
    var speculativeReplyDraft = ""
    var speculativeRequestTrace: (summary: String, detail: String)?
    /// Tool calls accumulated during the speculative request.
    var speculativeToolCalls: [ToolCall] = []
    /// The transcript text the speculative request was fired for (stale-result guard).
    var speculativeText = ""

    // MARK: - Long-term memory (structured, auto-updating)

    var isMemorizing = false
    /// Background promotion / digest / cleanup pass (idle, conversation switch, launch).
    var sleepTask: Task<Void, Never>?
    /// When the pending sleep pass is due; nil when none is scheduled.
    var sleepFireDate: Date?
    var isSleeping = false
}
