import SwiftUI
import Observation
import AppKit

@Observable
@MainActor
final class AppModel {
    // Persisted state
    var settings: AppSettings
    var personas: [Persona]
    var conversations: [Conversation]

    // Selection & transient UI state
    var selectedConversationID: UUID? {
        didSet {
            if let id = selectedConversationID, id != oldValue { ensureHydrated(id) }
        }
    }
    var draft: String = ""
    var draftImages: [String] = []          // base64 data URLs pending send
    var draftAttachments: [Attachment] = [] // extracted-text documents pending send
    var isStreaming = false
    var errorMessage: String?
    var isReflecting = false
    var searchText: String = "" {
        didSet { if searchText != oldValue { scheduleSearch() } }
    }
    var pendingApproval: PendingToolBatch?
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
    /// Live request/response trace per conversation (in-memory, cleared with the chat).
    var traces: [UUID: [TraceEntry]] = [:]

    // Server info
    var models: [ModelInfo] = []
    var audioModels: [ModelInfo] = []
    var audioVoices: [String] = []
    var connectionOK: Bool?
    var discoveredModels: [LocalModels.Entry] = []

    let memory = MemoryStore()
    let files = FileStore()
    let documents = DocumentStore()
    let runtime = Runtime()
    let voice = VoiceManager()
    let embeddingCache = EmbeddingCache()
    let language = LanguageStore()
    private var streamTask: Task<Void, Never>?
    /// Resumed with the tool result once the user answers a pending multiple-choice prompt.
    private var interactionContinuation: CheckedContinuation<String, Never>?

    struct PendingToolBatch: Identifiable {
        let id = UUID()
        let conversationID: UUID
        let calls: [ToolCall]
        /// Whether the model needs another turn to act on a tool's output.
        var continueAfter: Bool = true
    }

    init() {
        Paths.ensure()
        self.settings = AppSettings()
        self.personas = Self.loadPersonas()
        self.conversations = Self.loadConversations().sorted { $0.updatedAt > $1.updatedAt }
        self.languageProfiles = language.allProfiles()
        self.selectedConversationID = conversations.first(where: { $0.isLanguage != true })?.id
        VoiceManager.warmVoices()   // preload the slow system voice catalog off-main
        if conversations.isEmpty {
            newConversation()
        } else if let id = selectedConversationID {
            ensureHydrated(id)   // property observers don't fire during init
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

    func persona(for conversation: Conversation?) -> Persona {
        if let pid = conversation?.personaID, let p = personas.first(where: { $0.id == pid }) {
            return p
        }
        return personas.first ?? Persona.defaults[0]
    }

    var currentPersona: Persona { persona(for: selectedConversation) }

    /// The assistant's display name: its own name if set, else the persona/mode label.
    func assistantName(for persona: Persona) -> String {
        if let n = persona.assistantName?.trimmingCharacters(in: .whitespaces), !n.isEmpty { return n }
        return persona.name
    }
    var currentAssistantName: String { assistantName(for: currentPersona) }

    var currentAccent: Color {
        if let hex = currentPersona.accentColorHex { return Color(hex: hex) }
        return Color(hex: settings.accentColorHex)
    }

    private var contextConfigCache: [String: Int] = [:]

    var contextWindow: Int? {
        if settings.contextWindowOverride > 0 { return settings.contextWindowOverride }
        let modelID = currentPersona.model?.isEmpty == false ? currentPersona.model! : settings.model
        if let info = (models.first { $0.id == modelID } ?? models.first),
           let ctx = info.loadedContextLength ?? info.maxContextLength {
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
        let ctx = (obj["max_position_embeddings"] as? Int)
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
        if mode == .language { return Tools.names(enabled: settings.enabledTools(for: .language)) }
        return settings.toolsEnabled ? Tools.names(enabled: settings.enabledTools(for: mode)) : []
    }

    /// Heuristic model shortlists for the embedding / audio pickers (fall back to all).
    var embeddingCandidates: [ModelInfo] {
        let e = models.filter { ($0.type ?? "").lowercased().contains("embed") || $0.id.lowercased().contains("embed") }
        return e.isEmpty ? models : e
    }
    var sttCandidates: [ModelInfo] {
        let s = audioModels.filter {
            let t = ($0.type ?? "").lowercased(), id = $0.id.lowercased()
            return t.contains("whisper") || t.contains("stt") || t.contains("transcri") || t.contains("parakeet") || id.contains("whisper") || id.contains("parakeet")
        }
        return s.isEmpty ? audioModels : s
    }
    var ttsCandidates: [ModelInfo] {
        let t = audioModels.filter {
            let ty = ($0.type ?? "").lowercased(), id = $0.id.lowercased()
            return ty.contains("tts") || id.contains("tts") || id.contains("kokoro") || id.contains("piper") || id.contains("speech")
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

    private func conversationIndex(_ id: UUID) -> Int? {
        conversations.firstIndex { $0.id == id }
    }

    // MARK: - Lazy conversation bodies

    /// Conversations whose message bodies are resident in RAM. Everything else keeps only metadata
    /// (title, dates, summary); bodies live on disk and are paged in on demand.
    private var hydratedIDs: Set<UUID> = []
    /// Least-recently-used order of hydrated conversations (front = oldest).
    private var hydrationOrder: [UUID] = []
    private static let maxHydrated = 3
    /// The conversation a turn is actively writing to; protected from eviction across its tool loop.
    private var streamingConversationID: UUID?

    /// Load a conversation's messages into RAM if absent, and cap the working set.
    private func ensureHydrated(_ id: UUID) {
        guard let idx = conversations.firstIndex(where: { $0.id == id }) else { return }
        if !hydratedIDs.contains(id) {
            if let body = Self.loadConversationBody(id) {
                conversations[idx].messages = body.messages
            }
            hydratedIDs.insert(id)
        }
        hydrationOrder.removeAll { $0 == id }
        hydrationOrder.append(id)
        evictHydrated()
    }

    /// Hydrate (if needed) then return the index — for use after an `await`, when the body may have
    /// been evicted while the task ran.
    @discardableResult
    private func ensureHydratedIndex(_ id: UUID) -> Int? {
        ensureHydrated(id)
        return conversationIndex(id)
    }

    /// Drop message bodies of the least-recently-used conversations beyond the cap. Bodies are always
    /// on disk (save-through), so eviction is lossless. Selected / streaming / pending-approval chats
    /// are never evicted.
    private func evictHydrated() {
        while hydrationOrder.count > Self.maxHydrated {
            guard let victim = hydrationOrder.first(where: {
                $0 != selectedConversationID
                    && $0 != streamingConversationID
                    && $0 != pendingApproval?.conversationID
            }) else { break }
            hydrationOrder.removeAll { $0 == victim }
            hydratedIDs.remove(victim)
            if let idx = conversations.firstIndex(where: { $0.id == victim }) {
                conversations[idx].messages = []
            }
        }
    }

    // MARK: - Conversation search (async, disk-backed)

    /// Ids whose message body matched the current query (found via an off-main disk scan).
    private var contentMatchIDs: Set<UUID> = []
    private var searchTask: Task<Void, Never>?

    private func scheduleSearch() {
        searchTask?.cancel()
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard q.count >= 2 else { contentMatchIDs = []; return }
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            let ids = await Task.detached { Self.searchDisk(query: q) }.value
            guard !Task.isCancelled else { return }
            self?.contentMatchIDs = ids
        }
    }

    // MARK: - Conversation management

    func newConversation(personaID: UUID? = nil) {
        let pid = personaID ?? currentPersonaIDForNewChat()
        let convo = Conversation(personaID: pid, isLanguage: mode == .language ? true : nil)
        conversations.insert(convo, at: 0)
        hydratedIDs.insert(convo.id)
        hydrationOrder.append(convo.id)
        selectedConversationID = convo.id
        draft = ""
        errorMessage = nil
        save(convo)
    }

    private func currentPersonaIDForNewChat() -> UUID? {
        selectedConversation?.personaID ?? personas.first?.id
    }

    func deleteConversation(_ id: UUID) {
        conversations.removeAll { $0.id == id }
        hydratedIDs.remove(id)
        hydrationOrder.removeAll { $0 == id }
        if streamingConversationID == id { streamingConversationID = nil }
        traces[id] = nil
        traceSaveTasks[id]?.cancel()
        traceSaveTasks[id] = nil
        loadedTraceIDs.remove(id)
        Self.deleteTraceFile(id)
        documents.deleteAll(conversationID: id)
        Self.deleteConversationFile(id)
        try? FileManager.default.removeItem(at: Paths.conversationFiles(id))
        if selectedConversationID == id {
            selectedConversationID = conversations.first(where: { ($0.isLanguage == true) == (mode == .language) })?.id
        }
        if conversations.isEmpty { newConversation() }
    }

    func renameConversation(_ id: UUID, to title: String) {
        guard let idx = conversationIndex(id) else { return }
        conversations[idx].title = title.isEmpty ? "Untitled" : title
        autoTitledIDs.remove(id)   // user set it explicitly; never auto-refine over it
        touch(idx)
    }

    func setPersona(_ personaID: UUID, for conversationID: UUID) {
        guard let idx = conversationIndex(conversationID) else { return }
        conversations[idx].personaID = personaID
        touch(idx)
    }

    func clearCurrent() {
        guard let id = selectedConversationID, let idx = conversationIndex(id) else { return }
        stop()
        conversations[idx].messages.removeAll()
        reconcileFoldCounters(idx)
        traces[id] = nil
        Self.deleteTraceFile(id)
        errorMessage = nil
        touch(idx)
    }

    // MARK: - Trace

    /// Conversations whose persisted trace has already been pulled into `traces` this session.
    private var loadedTraceIDs: Set<UUID> = []
    /// Debounced per-conversation trace writers.
    private var traceSaveTasks: [UUID: Task<Void, Never>] = [:]

    var currentTrace: [TraceEntry] {
        selectedConversationID.flatMap { traces[$0] } ?? []
    }

    func clearTrace() {
        guard let id = selectedConversationID else { return }
        traces[id] = nil
        Self.deleteTraceFile(id)
    }

    /// Load a conversation's trace from disk on first view (traces from earlier sessions).
    func ensureTraceLoaded(_ id: UUID) {
        guard loadedTraceIDs.insert(id).inserted else { return }
        guard traces[id] == nil else { return }   // never clobber this session's in-memory trace
        let disk = Self.loadTrace(id)
        if !disk.isEmpty { traces[id] = disk }
    }

    private func trace(_ conversationID: UUID, _ kind: TraceEntry.Kind, _ text: String, detail: String? = nil) {
        ensureTraceLoaded(conversationID)   // merge with a prior session's trace before appending
        traces[conversationID, default: []].append(TraceEntry(kind: kind, text: text, detail: detail))
        if let count = traces[conversationID]?.count, count > 600 {
            traces[conversationID]?.removeFirst(count - 600)
        }
        scheduleTraceSave(conversationID)
    }

    /// Persist the trace shortly after the last event so streaming bursts coalesce into one write.
    private func scheduleTraceSave(_ id: UUID) {
        guard settings.saveTraces else { return }
        traceSaveTasks[id]?.cancel()
        let snapshot = traces[id] ?? []
        traceSaveTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1200))
            guard !Task.isCancelled else { return }
            await Task.detached { Self.saveTrace(id, snapshot) }.value
            self?.traceSaveTasks[id] = nil
        }
    }

    private func requestSummary(config: RequestConfig, wire: [WireMessage], tools: [ToolDef]?, memory: String, summary: String) -> String {
        let roles = wire.map { $0.role }.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
            .map { "\($0.key):\($0.value)" }.sorted().joined(separator: " ")
        var lines = ["model=\(config.model)  temp=\(config.temperature)  maxTokens=\(config.maxTokens.map(String.init) ?? "default")"]
        lines.append("messages=\(wire.count) [\(roles)]")
        if let tools, !tools.isEmpty { lines.append("tools=[\(tools.map(\.function.name).joined(separator: ", "))]") }
        if !summary.isEmpty { lines.append("summary injected (\(summary.count) chars)") }
        if !memory.isEmpty { lines.append("memory injected (\(memory.count) chars)") }
        return lines.joined(separator: "\n")
    }

    /// The full assembled request (every message, in order) for on-demand display in the Trace.
    private func requestDetail(wire: [WireMessage]) -> String {
        var out: [String] = []
        for msg in wire {
            out.append("── \(msg.role) ──")
            switch msg.content {
            case let .text(s):
                out.append(s)
            case let .parts(parts):
                for p in parts {
                    if p.type == "image_url" {
                        let u = p.imageUrl?.url ?? ""
                        out.append(u.hasPrefix("data:") ? "[image: \(u.prefix(30))… (\(u.count) chars)]" : "[image: \(u)]")
                    } else {
                        out.append(p.text ?? "")
                    }
                }
            case .none:
                break
            }
            if let calls = msg.toolCalls {
                for c in calls { out.append("→ tool_call \(c.function.name ?? "?")(\(c.function.arguments))") }
            }
            if let tid = msg.toolCallId { out.append("(tool_call_id: \(tid))") }
            out.append("")
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func touch(_ idx: Int) {
        conversations[idx].updatedAt = .now
        ensureHydrated(conversations[idx].id)   // never persist an evicted (empty) body over the file
        save(conversations[idx])
    }

    // MARK: - Sending & streaming

    var canSend: Bool {
        (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draftImages.isEmpty || !draftAttachments.isEmpty) && !isStreaming
    }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!text.isEmpty || !draftImages.isEmpty || !draftAttachments.isEmpty), !isStreaming,
              let convoID = selectedConversationID, let idx = conversationIndex(convoID)
        else { return }

        errorMessage = nil
        resetSpeech()
        let images = draftImages
        let attachments = draftAttachments
        draft = ""
        draftImages = []
        draftAttachments = []
        loopSignatures.removeAll()
        turnSources.removeAll()
        conversations[idx].messages.append(ChatMessage(role: .user, content: text, images: images, attachments: attachments))

        if conversations[idx].title == "New Chat", !text.isEmpty {
            conversations[idx].title = String(text.prefix(40))
        }
        touch(idx)
        startTurn(conversationID: convoID)
        maybeAutoTitle(conversationID: convoID)
    }

    func regenerate(messageID: UUID) {
        guard let convoID = selectedConversationID, let idx = conversationIndex(convoID),
              let msgIdx = conversations[idx].messages.firstIndex(where: { $0.id == messageID })
        else { return }
        conversations[idx].messages.removeSubrange(msgIdx...)
        reconcileFoldCounters(idx)
        loopSignatures.removeAll()
        turnSources.removeAll()
        resetSpeech()
        touch(idx)
        startTurn(conversationID: convoID)
    }

    func deleteMessage(_ id: UUID) {
        guard let convoID = selectedConversationID, let idx = conversationIndex(convoID) else { return }
        conversations[idx].messages.removeAll { $0.id == id }
        reconcileFoldCounters(idx)
        touch(idx)
    }

    /// Keep the compression/memory counters consistent after messages are removed. If the rolling
    /// summary now covers messages that no longer exist, drop it — otherwise `runStream` would fold
    /// away (and skip) the live messages while re-injecting a stale summary.
    private func reconcileFoldCounters(_ idx: Int) {
        let count = conversations[idx].messages.count
        if let s = conversations[idx].summarizedCount, s > count {
            conversations[idx].summary = nil
            conversations[idx].summarizedCount = nil
        }
        if let m = conversations[idx].memorizedCount, m > count {
            conversations[idx].memorizedCount = count
        }
    }

    func branch(fromMessage id: UUID) {
        guard let convo = selectedConversation,
              let mIdx = convo.messages.firstIndex(where: { $0.id == id })
        else { return }
        let copy = Conversation(
            title: convo.title + " (branch)",
            personaID: convo.personaID,
            messages: Array(convo.messages.prefix(mIdx + 1))
        )
        conversations.insert(copy, at: 0)
        hydratedIDs.insert(copy.id)
        hydrationOrder.append(copy.id)
        selectedConversationID = copy.id
        save(copy)
    }

    private func startTurn(conversationID: UUID) {
        guard let idx = conversationIndex(conversationID) else { return }
        streamingConversationID = conversationID
        let assistant = ChatMessage(role: .assistant, content: "")
        conversations[idx].messages.append(assistant)
        runStream(conversationID: conversationID, assistantID: assistant.id)
    }

    private func runStream(conversationID: UUID, assistantID: UUID) {
        guard let idx = conversationIndex(conversationID) else { return }
        let persona = persona(for: conversations[idx])
        let allHistory = conversations[idx].messages.filter { $0.id != assistantID }
        let folded = min(conversations[idx].summarizedCount ?? 0, allHistory.count)
        let history = Array(allHistory.dropFirst(folded))
        let summary = conversations[idx].summary ?? ""
        var config = settings.requestConfig(modelOverride: persona.model)
        config.enableThinking = settings.reasoningEnabled
        let tools: [ToolDef]?
        if mode == .language {
            tools = Tools.definitions(enabled: settings.enabledTools(for: .language))
        } else if settings.toolsEnabled {
            tools = Tools.definitions(enabled: settings.enabledTools(for: mode))
        } else {
            tools = nil
        }

        isStreaming = true
        activity = "Thinking…"
        streamTask?.cancel()   // never run two loops against one conversation
        let start = Date()

        streamTask = Task { [weak self] in
            guard let self else { return }
            let systemText = self.mode == .language
                ? self.languageSystemPrompt(persona: persona)
                : self.stableSystemPrompt(persona: persona)
            let memoryText = await self.memoryContext(conversationID: conversationID, persona: persona, history: history)
            let documentText = await self.documentContext(conversationID: conversationID, history: history)
            let wire = self.buildWire(systemText: systemText, summary: summary, memoryText: memoryText, documentText: documentText, history: history)

            self.trace(conversationID, .request, self.requestSummary(config: config, wire: wire, tools: tools, memory: memoryText, summary: summary), detail: self.requestDetail(wire: wire))

            var firstTokenAt: Date?
            var charCount = 0
            var deltaCount = 0
            var reasoning = ""
            var answer = ""
            var finishReason: String?
            var usage: Usage?
            var toolCalls: [ToolCall]?
            var caughtError = false
            var stripper = ThinkStripper()   // strip inline chain-of-thought some models emit as content
            do {
                for try await event in ChatService.stream(config: config, messages: wire, tools: tools, toolChoice: nil) {
                    switch event {
                    case let .delta(d):
                        if firstTokenAt == nil {
                            firstTokenAt = Date()
                            self.activity = nil
                            self.trace(conversationID, .token, String(format: "First token after %.0f ms", Date().timeIntervalSince(start) * 1000))
                        }
                        let out = stripper.consume(d)
                        if !out.reasoning.isEmpty {
                            reasoning += out.reasoning
                            self.appendReasoning(out.reasoning, conversationID: conversationID, assistantID: assistantID)
                        }
                        if !out.visible.isEmpty {
                            deltaCount += 1
                            charCount += out.visible.count
                            answer += out.visible
                            self.appendDelta(out.visible, conversationID: conversationID, assistantID: assistantID)
                        }
                    case let .reasoning(r):
                        reasoning += r
                        self.appendReasoning(r, conversationID: conversationID, assistantID: assistantID)
                    case let .usage(u):
                        usage = u
                        self.trace(conversationID, .usage, "prompt=\(u.promptTokens ?? 0), completion=\(u.completionTokens ?? 0), total=\(u.totalTokens ?? 0)")
                    case let .toolCalls(calls):
                        toolCalls = calls
                        for c in calls {
                            self.trace(conversationID, .tool, "\(c.function.name ?? "tool")(\(c.function.arguments))")
                        }
                    case let .finish(reason):
                        finishReason = reason
                        self.trace(conversationID, .finish, "finish_reason=\(reason ?? "nil"), deltas=\(deltaCount), chars=\(charCount)")
                    }
                }
                let tail = stripper.finish()
                if !tail.reasoning.isEmpty { reasoning += tail.reasoning }
                if !tail.visible.isEmpty {
                    deltaCount += 1
                    charCount += tail.visible.count
                    answer += tail.visible
                    self.appendDelta(tail.visible, conversationID: conversationID, assistantID: assistantID)
                }
                if !reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.trace(conversationID, .reasoning, reasoning)
                }
                if !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.trace(conversationID, .result, answer)
                }
                if deltaCount == 0 && (toolCalls?.isEmpty ?? true) {
                    if finishReason == "length" {
                        let hint = "The model hit the token limit while reasoning and produced no answer. Raise Max tokens in Settings › Generation."
                        self.trace(conversationID, .info, hint)
                        self.errorMessage = hint
                    } else {
                        self.trace(conversationID, .info, "No content received (empty reply). finish_reason=\(finishReason ?? "nil").")
                    }
                }
            } catch {
                caughtError = true
                self.errorMessage = error.localizedDescription
                self.trace(conversationID, .error, error.localizedDescription)
            }
            self.finishStream(
                conversationID: conversationID,
                assistantID: assistantID,
                start: start,
                firstTokenAt: firstTokenAt,
                charCount: charCount,
                usage: usage,
                toolCalls: toolCalls,
                failed: caughtError
            )
        }
    }

    // Streamed tokens are buffered and flushed on a timer so the UI re-renders (and re-parses
    // markdown) a few times per second instead of once per token.
    private var deltaBuffer = ""
    private var flushTask: Task<Void, Never>?
    /// Buffered reasoning tokens, flushed on the same cadence as content so the disclosure updates
    /// a few times per second instead of once per token.
    private var reasoningBuffer = ""
    private var reasoningFlushTask: Task<Void, Never>?
    /// Streaming TTS: text of the current assistant message not yet flushed to the speaker.
    /// Only the unspoken tail is held, so we never rescan the whole (growing) message each flush.
    private var ttsPending = ""
    private var ttsMessageID: UUID?
    private static let sentenceTerminators: Set<Character> = [".", "!", "?", "。", "！", "？", "…", "\n"]
    /// Serial server-TTS pipeline for streamed chat replies: sentences synthesized in order.
    private var speechSegCont: AsyncStream<String>.Continuation?
    private var speechSynthTask: Task<Void, Never>?
    /// True once we've surfaced a server-TTS failure this session, so we don't nag on every reply.
    /// Reset when TTS succeeds again or the audio endpoint/source changes.
    private var warnedServerTTSFailure = false

    private func appendDelta(_ delta: String, conversationID: UUID, assistantID: UUID) {
        deltaBuffer += delta
        let interval = settings.streamFlushMs
        if interval <= 0 {
            flushDeltas(conversationID: conversationID, assistantID: assistantID)
            return
        }
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(interval))
            guard let self, !Task.isCancelled else { return }
            self.flushTask = nil
            self.flushDeltas(conversationID: conversationID, assistantID: assistantID)
        }
    }

    /// Apply the buffered tokens to the assistant message in a single mutation.
    private func flushDeltas(conversationID: UUID, assistantID: UUID) {
        guard !deltaBuffer.isEmpty else { return }
        let pending = deltaBuffer
        deltaBuffer = ""
        guard let idx = conversationIndex(conversationID),
              let mIdx = conversations[idx].messages.firstIndex(where: { $0.id == assistantID })
        else { return }
        conversations[idx].messages[mIdx].content += pending
        streamSpeak(delta: pending, assistantID: assistantID)
    }

    private func appendReasoning(_ chunk: String, conversationID: UUID, assistantID: UUID) {
        reasoningBuffer += chunk
        let interval = settings.streamFlushMs
        if interval <= 0 {
            flushReasoning(conversationID: conversationID, assistantID: assistantID)
            return
        }
        guard reasoningFlushTask == nil else { return }
        reasoningFlushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(interval))
            guard let self, !Task.isCancelled else { return }
            self.reasoningFlushTask = nil
            self.flushReasoning(conversationID: conversationID, assistantID: assistantID)
        }
    }

    private func flushReasoning(conversationID: UUID, assistantID: UUID) {
        guard !reasoningBuffer.isEmpty else { return }
        let pending = reasoningBuffer
        reasoningBuffer = ""
        guard let idx = conversationIndex(conversationID),
              let mIdx = conversations[idx].messages.firstIndex(where: { $0.id == assistantID })
        else { return }
        conversations[idx].messages[mIdx].reasoning = (conversations[idx].messages[mIdx].reasoning ?? "") + pending
    }

    private var nativeTTS: Bool { mode == .language || settings.ttsSource == .native }

    /// Speaks newly-completed sentences as the reply streams in (native and server TTS), so speech
    /// starts almost immediately instead of waiting for the whole message. Only the unspoken tail
    /// is scanned (via `ttsPending`), not the whole growing message.
    private func streamSpeak(delta: String, assistantID: UUID) {
        guard settings.autoSpeak else { return }
        if ttsMessageID != assistantID { ttsMessageID = assistantID; ttsPending = "" }
        ttsPending += delta
        guard let cut = ttsPending.lastIndex(where: { Self.sentenceTerminators.contains($0) }) else { return }
        let chunk = String(ttsPending[...cut])
        ttsPending = String(ttsPending[ttsPending.index(after: cut)...])
        enqueueSpeech(chunk)
    }

    /// At end of stream: speak whatever sentence tail wasn't already streamed. Works for both
    /// native and server TTS (server sentences flow through the same serial synth pipeline).
    private func emitFinalSpeech(assistantID: UUID, content: String) {
        guard settings.autoSpeak else { return }
        // If streaming never accumulated this message (e.g. auto-speak toggled on late), speak it whole.
        if ttsMessageID != assistantID { ttsMessageID = assistantID; ttsPending = content }
        let tail = ttsPending
        ttsPending = ""
        guard !tail.isEmpty else { return }
        enqueueSpeech(tail)
    }

    private func enqueueSpeech(_ text: String) {
        let clean = text.strippedForSpeech
        guard !clean.isEmpty else { return }
        if mode == .language, let p = activeLanguageProfile {
            voice.enqueueBilingual(clean, targetLocale: p.targetLocale, baseLocale: p.baseLocale,
                                   targetVoiceID: p.targetVoiceID, baseVoiceID: p.baseVoiceID, rate: settings.speechRate)
        } else if nativeTTS {
            voice.enqueueNative(clean, voiceID: settings.voiceIdentifier, rate: settings.speechRate)
        } else {
            beginServerSpeechIfNeeded()
            speechSegCont?.yield(clean)
        }
    }

    /// Lazily starts the serial server-TTS pipeline for the current reply: each sentence is
    /// synthesized in order and its audio queued for gapless playback.
    private func beginServerSpeechIfNeeded() {
        guard speechSegCont == nil else { return }
        voice.startOutputKeepAlive()   // keep the device warm so the first sentence isn't clipped
        voice.beginAudioStream()
        let ttsConfig = settings.requestConfig(modelOverride: nil)
        let (segs, cont) = AsyncStream.makeStream(of: String.self)
        speechSegCont = cont
        speechSynthTask = Task { [weak self] in
            for await seg in segs {
                guard let self else { break }
                do {
                    let data = try await ChatService.speech(config: ttsConfig, text: seg)
                    self.warnedServerTTSFailure = false
                    self.voice.enqueueAudioData(data)
                } catch {
                    self.warnServerTTSFailure(error)
                    break   // audio endpoint unreachable — stop hammering it
                }
            }
            self?.voice.sealAudioStream()
        }
    }

    /// Stops any current speech and resets streaming-TTS progress for a fresh reply.
    private func resetSpeech() {
        voice.stopSpeaking()
        speechSegCont?.finish()
        speechSegCont = nil
        speechSynthTask?.cancel()
        speechSynthTask = nil
        if !conversationActive { voice.stopOutputKeepAlive() }
        ttsMessageID = nil
        ttsPending = ""
    }

    /// Surfaces a server-TTS failure only the first time this session; afterwards it stays silent
    /// (audio is just skipped) so the banner doesn't reappear on every reply once you've seen it.
    private func warnServerTTSFailure(_ error: Error) {
        guard !warnedServerTTSFailure else { return }
        warnedServerTTSFailure = true
        voice.lastError = "Server TTS unavailable — replies won't be spoken this session. \(error.localizedDescription)"
    }

    private func finishStream(
        conversationID: UUID,
        assistantID: UUID,
        start: Date,
        firstTokenAt: Date?,
        charCount: Int,
        usage: Usage?,
        toolCalls: [ToolCall]?,
        failed: Bool = false
    ) {
        streamTask = nil
        flushTask?.cancel()
        flushTask = nil
        flushDeltas(conversationID: conversationID, assistantID: assistantID)
        reasoningFlushTask?.cancel()
        reasoningFlushTask = nil
        flushReasoning(conversationID: conversationID, assistantID: assistantID)
        guard let idx = conversationIndex(conversationID),
              let mIdx = conversations[idx].messages.firstIndex(where: { $0.id == assistantID })
        else { isStreaming = false; streamingConversationID = nil; return }

        let hasTools = !(toolCalls?.isEmpty ?? true)
        let hasReasoning = !(conversations[idx].messages[mIdx].reasoning?.isEmpty ?? true)
        if conversations[idx].messages[mIdx].content.isEmpty, !hasTools, !hasReasoning {
            conversations[idx].messages.remove(at: mIdx)
            touch(idx)
            activity = nil
            isStreaming = false
            streamingConversationID = nil
            return
        }

        conversations[idx].messages[mIdx].stats = makeStats(
            start: start, firstTokenAt: firstTokenAt, charCount: charCount, usage: usage
        )

        if let toolCalls, hasTools {
            conversations[idx].messages[mIdx].toolCalls = toolCalls
            touch(idx)
            let content = conversations[idx].messages[mIdx].content
            emitFinalSpeech(assistantID: assistantID, content: content)
            // Only loop back for another turn if the model must act on a tool's OUTPUT. A written
            // reply plus fire-and-forget writes (e.g. banking a card) is already a complete answer.
            let hasContent = !content.trimmingCharacters(in: .whitespaces).isEmpty
            let needsMore = !hasContent || toolCalls.contains { Self.continuationTools.contains($0.function.name ?? "") }
            let batch = PendingToolBatch(conversationID: conversationID, calls: toolCalls, continueAfter: needsMore)
            let names = toolCalls.compactMap { $0.function.name }
            if !names.isEmpty && toolCalls.allSatisfy({ toolCallIsAutoApproved($0, mode: mode) }) {
                activity = "Calling \(names.joined(separator: ", "))…"
                executeAndContinue(batch: batch, approved: true)   // auto-approved: keeps streaming
            } else {
                activity = nil
                isStreaming = false
                streamingConversationID = nil
                pendingApproval = batch
            }
            return
        }

        touch(idx)
        if !turnSources.isEmpty {
            conversations[idx].messages[mIdx].sources = turnSources
            turnSources.removeAll()
            touch(idx)
        }
        activity = nil
        isStreaming = false
        streamingConversationID = nil
        compressIfNeeded(conversationID: conversationID)
        updateMemoryIfNeeded(conversationID: conversationID)
        maybeRefineTitle(conversationID: conversationID)
        emitFinalSpeech(assistantID: assistantID, content: conversations[idx].messages[mIdx].content)
    }

    private func makeStats(start: Date, firstTokenAt: Date?, charCount: Int, usage: Usage?) -> MessageStats {
        let end = Date()
        let duration = end.timeIntervalSince(start)
        let ttft = firstTokenAt?.timeIntervalSince(start)
        let completion = usage?.completionTokens
        let genSeconds = firstTokenAt.map { end.timeIntervalSince($0) } ?? duration
        let tps: Double? = {
            if let completion, genSeconds > 0 { return Double(completion) / genSeconds }
            if genSeconds > 0 { return (Double(charCount) / 4.0) / genSeconds }
            return nil
        }()
        return MessageStats(
            timeToFirstToken: ttft,
            tokensPerSecond: tps,
            promptTokens: usage?.promptTokens,
            completionTokens: completion,
            totalTokens: usage?.totalTokens,
            duration: duration
        )
    }

    func stop() {
        streamTask?.cancel()
        streamTask = nil
        cancelInteraction()   // resume/clear any paused multiple-choice prompt
        resetSpeech()
        flushTask?.cancel()
        flushTask = nil
        deltaBuffer = ""
        reasoningFlushTask?.cancel()
        reasoningFlushTask = nil
        reasoningBuffer = ""
        streamingConversationID = nil
        activity = nil
        isStreaming = false
    }

    // MARK: - Tool approval & execution

    /// Signatures (name+args) of tool calls in the current user turn, for dedupe + loop detection.
    private var loopSignatures: [String] = []
    /// Web sources (search results / fetched pages) gathered this turn, attached to the reply.
    private var turnSources: [Source] = []
    /// Read-only tools whose identical repeat within a turn can be skipped safely.
    private static let readOnlyTools: Set<String> = [
        "memory_list", "memory_read", "file_read", "list_dir",
        "git_status", "git_diff", "git_log", "web_search", "web_fetch", "web_research",
        "search_deck", "get_due_items", "calculate"
    ]
    /// Tools whose OUTPUT the model must read to finish its reply, so a continuation turn is warranted.
    /// After fire-and-forget writes (e.g. banking a card) with a written reply, the turn is complete.
    private static let continuationTools: Set<String> = [
        "get_due_items", "search_deck", "web_search", "web_fetch", "web_research", "file_read",
        "memory_list", "memory_read", "calculate", "python_exec", "ask_multiple_choice"
    ]

    private func toolCallIsAutoApproved(_ call: ToolCall, mode: AppMode) -> Bool {
        guard let name = call.function.name else { return false }
        if settings.autoApproveTools(for: mode).contains(name) { return true }
        guard name == "run_shell", let args: ToolArguments.Shell = Self.decodeToolArgs(call) else { return false }
        return settings.shellCommandIsAutoApproved(args.command, for: mode)
    }

    func approveTools() {
        guard let batch = pendingApproval else { return }
        pendingApproval = nil
        executeAndContinue(batch: batch, approved: true)
    }

    func denyTools() {
        guard let batch = pendingApproval else { return }
        pendingApproval = nil
        executeAndContinue(batch: batch, approved: false)
    }

    private func executeAndContinue(batch: PendingToolBatch, approved: Bool) {
        isStreaming = true
        streamingConversationID = batch.conversationID   // protect across the tool loop
        Task { [weak self] in
            guard let self else { return }
            for call in batch.calls {
                let name = call.function.name ?? "tool"
                self.activity = "Calling \(name)…"
                let sig = name + ":" + call.function.arguments
                let repeats = self.loopSignatures.reversed().prefix(while: { $0 == sig }).count
                let toolStart = Date()
                let result: String
                if !approved {
                    result = "User denied execution of \(name)."
                } else if repeats >= 2 {
                    // Third identical call in a row — break the loop instead of running it again.
                    result = "You have called `\(name)` with identical arguments \(repeats + 1) times in a row without making progress. Stop repeating it: try different arguments, a different tool, or give the user your answer based on what you already have."
                } else if Self.readOnlyTools.contains(name), self.loopSignatures.contains(sig) {
                    result = "[identical `\(name)` call already ran this turn; the result is unchanged — reuse the earlier output instead of calling it again]"
                } else {
                    result = await self.executeTool(call, conversationID: batch.conversationID)
                }
                self.loopSignatures.append(sig)
                self.trace(batch.conversationID, .result, "\(name) → \(result.prefix(400))")
                if let i = self.ensureHydratedIndex(batch.conversationID) {
                    self.conversations[i].messages.append(
                        ChatMessage(role: .tool, content: result, toolCallId: call.id, toolName: call.function.name)
                    )
                    if name == "python_exec" {
                        self.attachNewPlots(conversationID: batch.conversationID, since: toolStart)
                    }
                }
                self.activity = "Received result."
            }
            if let i = self.conversationIndex(batch.conversationID) { self.touch(i) }
            if approved && !batch.continueAfter {
                self.finishToolTurn(conversationID: batch.conversationID)   // fire-and-forget: turn done
            } else {
                self.startTurn(conversationID: batch.conversationID)
            }
        }
    }

    /// Ends a tool turn that needs no continuation (writes already confirmed, reply already given).
    private func finishToolTurn(conversationID: UUID) {
        activity = nil
        isStreaming = false
        streamingConversationID = nil
        compressIfNeeded(conversationID: conversationID)
        updateMemoryIfNeeded(conversationID: conversationID)
        maybeRefineTitle(conversationID: conversationID)
    }

    /// Attach images a python_exec run created in the conversation's files folder, so the vision
    /// model sees them next turn and the user sees them inline. Scans the folder (whatever the
    /// model named its file) rather than parsing stdout.
    private func attachNewPlots(conversationID: UUID, since: Date) {
        let dir = Paths.conversationFiles(conversationID)
        let imageExt: Set<String> = ["png", "jpg", "jpeg", "gif", "webp"]
        let cutoff = since.addingTimeInterval(-1)   // filesystem mtime granularity slack
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        )) ?? []
        let fresh = files
            .filter { imageExt.contains($0.pathExtension.lowercased()) }
            .compactMap { url -> (URL, Date)? in
                guard let d = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                      d >= cutoff else { return nil }
                return (url, d)
            }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
        var urls: [String] = []
        var seen = Set<Int>()
        for url in fresh.prefix(4) {
            guard let data = try? Data(contentsOf: url), seen.insert(data.hashValue).inserted else { continue }
            let ext = url.pathExtension.lowercased()
            let mime = (ext == "jpg" || ext == "jpeg") ? "image/jpeg"
                : (ext == "gif" ? "image/gif" : (ext == "webp" ? "image/webp" : "image/png"))
            urls.append("data:\(mime);base64,\(data.base64EncodedString())")
        }
        guard !urls.isEmpty, let i = conversationIndex(conversationID) else { return }
        conversations[i].messages.append(
            ChatMessage(role: .user, content: "Plot(s) generated:", images: urls)
        )
        touch(i)
    }

    /// A tool is runnable when tool calling is on and the tool is enabled.
    private func toolEnabled(_ name: String) -> Bool {
        guard Tools.spec(name) != nil else { return false }
        // Learn mode needs its tools even when the global master switch is off.
        if mode == .language { return settings.enabledTools(for: .language).contains(name) }
        guard settings.toolsEnabled else { return false }
        return settings.enabledTools(for: mode).contains(name)
    }

    private func executeTool(_ call: ToolCall, conversationID: UUID) async -> String {
        let persona = persona(for: selectedConversation)
        switch call.function.name {
        case "memory_list":
            let scopes = [MemoryStore.globalScope, persona.memoryScope]
            let list = scopes.flatMap { s in memory.files(in: s).map { "\(s)/\($0.name)" } }
            return list.isEmpty ? "(no memory notes)" : list.joined(separator: "\n")
        case "memory_read":
            guard let args: ToolArguments.MemoryRead = Self.decodeToolArgs(call) else {
                return "Error: missing or invalid name"
            }
            let scope = args.scope ?? persona.memoryScope
            let file = MemoryStore.File(scope: scope, name: args.name, url: Paths.memoryScope(scope).appendingPathComponent(args.name))
            let content = memory.read(file)
            return content.isEmpty ? "(empty or not found)" : content
        case "memory_write":
            guard let args: ToolArguments.MemoryWrite = Self.decodeToolArgs(call) else {
                return "Error: missing name/content"
            }
            let scope = args.scope ?? persona.memoryScope
            let content = MemoryCategory.isCategoryFile(args.name) ? MemoryProfile.canonical(args.content) : args.content
            memory.write(scope: scope, name: args.name, content: content)
            return "Saved \(scope)/\(args.name)."
        case "memory_append":
            guard let args: ToolArguments.MemoryWrite = Self.decodeToolArgs(call) else {
                return "Error: missing name/content"
            }
            let scope = args.scope ?? persona.memoryScope
            if MemoryCategory.isCategoryFile(args.name) {
                let existing = memory.read(MemoryStore.File(scope: scope, name: args.name, url: Paths.memoryScope(scope).appendingPathComponent(args.name)))
                let merged = existing.isEmpty ? args.content : existing + "\n" + args.content
                memory.write(scope: scope, name: args.name, content: MemoryProfile.canonical(merged))
            } else {
                memory.append(scope: scope, name: args.name, content: args.content)
            }
            return "Appended to \(scope)/\(args.name)."
        case "file_read":
            guard toolEnabled("file_read"), let args: ToolArguments.FileRead = Self.decodeToolArgs(call) else {
                return "Error: file_read is disabled or missing path"
            }
            let resolved = (args.path as NSString).expandingTildeInPath
            guard let s = try? String(contentsOfFile: resolved, encoding: .utf8) else {
                return "Error: could not read \(args.path)"
            }
            return Self.readSlice(s, offset: args.offset, limit: args.limit)
        case "web_fetch":
            guard toolEnabled("web_fetch"), let args: ToolArguments.URLValue = Self.decodeToolArgs(call),
                  let url = URL(string: args.url) else {
                return "Error: web_fetch is disabled or bad URL"
            }
            addTurnSource(title: url.host ?? args.url, url: args.url)
            return await WebResearch.fetch(url)
        case "web_search":
            guard toolEnabled("web_search"), let args: ToolArguments.Query = Self.decodeToolArgs(call), !args.query.isEmpty else {
                return "Error: web_search is disabled or missing query"
            }
            let result = await WebResearch.search(args.query)
            for source in result.sources { addTurnSource(title: source.title, url: source.url) }
            return result.text
        case "web_research":
            guard toolEnabled("web_research"), let args: ToolArguments.Research = Self.decodeToolArgs(call),
                  !args.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return "Error: web_research is disabled or missing query"
            }
            let result = await WebResearch.research(args.query, maxSources: args.maxSources ?? 3)
            for source in result.sources { addTurnSource(title: source.title, url: source.url) }
            return result.text
        case "calculate":
            guard toolEnabled("calculate"), let args: ToolArguments.Calculation = Self.decodeToolArgs(call) else {
                return "Error: calculate is disabled or missing expression"
            }
            do {
                return "\(args.expression) = \(Calculator.format(try Calculator.evaluate(args.expression)))"
            } catch {
                return "Error: \(error.localizedDescription)"
            }
        case "python_exec":
            guard toolEnabled("python_exec") else {
                return "Error: python_exec is disabled (enable it in Settings › Tools)"
            }
            guard let args: ToolArguments.Python = Self.decodeToolArgs(call),
                  !args.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return "Error: missing code"
            }
            let workdir = Paths.conversationFiles(conversationID)
            let (status, out) = await runtime.runPythonCapture(args.code, workdir: workdir)
            let body = out.isEmpty ? "(no output — remember to print() results)" : String(out.prefix(12_000))
            return "exit \(status)\n\(body)"
        case "run_shell":
            guard toolEnabled("run_shell") else {
                return "Error: run_shell is disabled (enable it in Settings › Tools)"
            }
            guard let args: ToolArguments.Shell = Self.decodeToolArgs(call),
                  !args.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return "Error: missing command"
            }
            let (status, output) = await runtime.runShellCapture(
                args.command,
                workingDirectory: args.workingDirectory,
                timeoutSeconds: args.timeoutSeconds ?? 120
            )
            return "exit \(status)\n\(output.isEmpty ? "(no output)" : output)"
        case "add_vocab", "add_grammar":
            guard toolEnabled(call.function.name ?? "") else { return "Error: tool disabled" }
            guard let profile = activeLanguageProfile else { return "Error: no active language profile" }
            let isGrammar = call.function.name == "add_grammar"
            let kind: LearnKind = isGrammar ? .grammar : .vocab
            let vocab: ToolArguments.AddVocabulary? = isGrammar ? nil : Self.decodeToolArgs(call)
            let grammar: ToolArguments.AddGrammar? = isGrammar ? Self.decodeToolArgs(call) : nil
            guard vocab != nil || grammar != nil else { return "Error: missing or invalid card fields" }
            let term = grammar?.point ?? vocab?.term ?? ""
            let translation = grammar?.explanation ?? vocab?.translation ?? ""
            guard !term.trimmingCharacters(in: .whitespaces).isEmpty else { return "Error: missing \(isGrammar ? "point" : "term")" }
            let example = grammar?.example ?? vocab?.example
            let notes = grammar?.notes ?? vocab?.notes
            let tags = grammar?.tags ?? vocab?.tags
            // Dedup: update an existing card of the same kind/term, keeping its schedule + counts.
            if var existing = language.findByTerm(profileID: profile.id, kind: kind, term: term) {
                if !translation.isEmpty { existing.translation = translation }
                if let r = vocab?.reading, !r.isEmpty { existing.reading = r }
                if let pos = vocab?.partOfSpeech, !pos.isEmpty { existing.partOfSpeech = pos }
                if let reg = vocab?.register, !reg.isEmpty { existing.register = reg }
                if let notes, !notes.isEmpty { existing.notes = notes }
                if let ex = example, !ex.isEmpty, !existing.examples.contains(ex) { existing.examples.append(ex) }
                if let tags { existing.tags = Array(Set(existing.tags + tags)) }
                addDeckCard(existing)
                return "Already in deck (updated): \(term)"
            }
            let item = LearnItem(
                profileID: profile.id,
                kind: kind,
                term: term,
                reading: vocab?.reading ?? "",
                translation: translation,
                partOfSpeech: vocab?.partOfSpeech ?? "",
                register: vocab?.register ?? "",
                notes: notes ?? "",
                examples: example.map { [$0] } ?? [],
                tags: tags ?? [],
                sourceConversationID: conversationID
            )
            addDeckCard(item)
            return "Added \(item.kind.rawValue): \(term)\(translation.isEmpty ? "" : " — \(translation)")"
        case "search_deck":
            guard toolEnabled("search_deck") else { return "Error: tool disabled" }
            guard let profile = activeLanguageProfile else { return "Error: no active language profile" }
            guard let args: ToolArguments.Query = Self.decodeToolArgs(call) else { return "Error: missing query" }
            let results = language.search(profileID: profile.id, query: args.query)
            if results.isEmpty { return "No matching cards." }
            return results.map { "\($0.id.uuidString) | \($0.term) — \($0.translation) [box \($0.box)]" }.joined(separator: "\n")
        case "get_due_items":
            guard toolEnabled("get_due_items") else { return "Error: tool disabled" }
            guard let profile = activeLanguageProfile else { return "Error: no active language profile" }
            let args: ToolArguments.DueItems? = Self.decodeToolArgs(call)
            let due = language.dueItems(profileID: profile.id, limit: args?.limit ?? 10)
            if due.isEmpty { return "Nothing is due for review." }
            return due.map { "\($0.id.uuidString) | \($0.kind.rawValue): \($0.term) — \($0.translation)" }.joined(separator: "\n")
        case "record_review":
            guard toolEnabled("record_review") else { return "Error: tool disabled" }
            guard let args: ToolArguments.Review = Self.decodeToolArgs(call) else { return "Error: missing/invalid id or correct" }
            return recordDeckReview(itemID: args.id, correct: args.correct)
        case "ask_multiple_choice":
            guard toolEnabled("ask_multiple_choice") else { return "Error: tool disabled" }
            guard let args: ToolArguments.MultipleChoice = Self.decodeToolArgs(call) else { return "Error: invalid questions" }
            let questions = Self.parseMCQuestions(args.questions)
            guard !questions.isEmpty else { return "Error: no valid questions provided" }
            return await withCheckedContinuation { cont in
                self.interactionContinuation = cont
                self.activity = "Waiting for your answer…"
                self.pendingInteraction = PendingInteraction(conversationID: conversationID, questions: questions)
            }
        default:
            return "Unknown tool."
        }
    }

    private static func decodeToolArgs<T: Decodable>(_ call: ToolCall) -> T? {
        guard let data = call.function.arguments.data(using: .utf8) else { return nil }
        return try? Wire.decoder.decode(T.self, from: data)
    }

    /// How many trailing tool results are kept verbatim in the wire; older ones are stubbed.
    private static let maxFullToolResults = 4

    private static func stubToolResult(_ msg: ChatMessage) -> String {
        let head = msg.content.prefix(100).replacingOccurrences(of: "\n", with: " ")
        return "[earlier \(msg.toolName ?? "tool") result trimmed to save context — \(head)…]"
    }

    /// Returns a line range of a file with a header, so large files don't flood the context.
    private static func readSlice(_ content: String, offset: Int?, limit: Int?) -> String {
        let lines = content.components(separatedBy: "\n")
        let total = lines.count
        let start = max(0, (offset ?? 1) - 1)
        guard start < total else { return "(file has \(total) lines; offset \(offset ?? 1) is past the end)" }
        let count = min(max(1, limit ?? 400), total - start)
        let end = start + count
        var body = lines[start..<end].joined(separator: "\n")
        var truncated = false
        if body.count > 8_000 { body = String(body.prefix(8_000)); truncated = true }
        var out = "// \(total) lines total, showing \(start + 1)–\(end)\n" + body
        if truncated { out += "\n… (truncated at 8000 chars — narrow the range with offset/limit)" }
        else if end < total { out += "\n… \(total - end) more lines (continue with offset=\(end + 1))" }
        return out
    }

    private func addTurnSource(title: String, url: String) {
        guard !url.isEmpty, !turnSources.contains(where: { $0.url == url }) else { return }
        turnSources.append(Source(title: title.isEmpty ? url : title, url: url))
    }

    // MARK: - Prompt building, memory retrieval, budgeting

    /// Stable across turns for a persona → keeps the server's prompt/KV prefix cache valid.
    private func stableSystemPrompt(persona: Persona) -> String {
        var text = persona.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if let name = persona.assistantName?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
            text = "Your name is \(name).\n\n" + text
        }
        if settings.injectDateContext {
            text += (text.isEmpty ? "" : "\n\n") + "For context, it is currently \(Self.dateContext())."
        }
        if mode == .conversational {
            text += (text.isEmpty ? "" : "\n\n") + "This is a spoken voice conversation. Keep replies natural and concise. When the user clearly wants to stop (says goodbye, 'that's all', 'we're done'), say a brief farewell and call the end_conversation tool to hang up."
        }
        return text
    }

    // MARK: - Language learning

    /// The active language profile, or the first one if the stored id is stale/empty.
    var activeLanguageProfile: LanguageProfile? {
        if let id = UUID(uuidString: settings.activeLanguageProfileID),
           let p = languageProfiles.first(where: { $0.id == id }) {
            return p
        }
        return languageProfiles.first
    }

    func reloadLanguageProfiles() {
        languageProfiles = language.allProfiles()
    }

    func saveLanguageProfile(_ profile: LanguageProfile, makeActive: Bool = false) {
        language.upsertProfile(profile)
        reloadLanguageProfiles()
        if makeActive || settings.activeLanguageProfileID.isEmpty {
            settings.activeLanguageProfileID = profile.id.uuidString
        }
    }

    func deleteLanguageProfile(_ id: UUID) {
        language.deleteProfile(id: id)
        reloadLanguageProfiles()
        if settings.activeLanguageProfileID == id.uuidString {
            settings.activeLanguageProfileID = languageProfiles.first?.id.uuidString ?? ""
        }
    }

    func setActiveLanguageProfile(_ id: UUID) {
        settings.activeLanguageProfileID = id.uuidString
    }

    /// System prompt for language mode: pedagogy + profile + session config.
    /// (Deck/tool instructions are appended once the language tools land.)
    private func languageSystemPrompt(persona: Persona) -> String {
        var lines: [String] = []
        if let name = persona.assistantName?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
            lines.append("Your name is \(name).")
        }

        guard let p = activeLanguageProfile else {
            lines.append("You are a friendly, patient language tutor. No language profile is set up yet — ask the user which language they want to learn, their native language, and their rough level, then help them get started.")
            if settings.injectDateContext {
                lines.append("For context, it is currently \(Self.dateContext()).")
            }
            return lines.joined(separator: "\n\n")
        }

        let level = languageSession.difficulty ?? p.level
        lines.append("You are a friendly, patient language tutor helping the user learn \(p.targetName). Give explanations in \(p.baseName).")
        lines.append("The user's self-rated level is \(level.code) (\(level.label)). Calibrate to it when the deck is sparse, but rely on what the user already knows (their deck) and their accuracy as the primary guide.")
        lines.append(p.romanization.guidance)
        if !p.scriptNotes.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.append("Script notes: \(p.scriptNotes.trimmingCharacters(in: .whitespaces)).")
        }
        if !p.goals.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.append("The user's goals: \(p.goals.trimmingCharacters(in: .whitespaces)).")
        }
        lines.append("Register: use a natural, appropriate register — you may choose it freely. Do not drill turning formal grammar into informal; the user finds that trivial. When a specific word is inherently formal, honorific, casual, or slang, mention it briefly.")

        let topic = languageSession.topic.trimmingCharacters(in: .whitespaces)
        lines.append(languageSession.kind.guidance)
        lines.append("Topic: \(topic.isEmpty ? "the user's choice" : topic).")
        lines.append("You maintain a spaced-repetition deck of the words, grammar points, and phrases the user has learned.")

        if settings.injectDateContext {
            lines.append("For context, it is currently \(Self.dateContext()).")
        }
        return lines.joined(separator: "\n\n")
    }

    /// Applies a Leitner review to a card and returns a short status for the model.
    func recordDeckReview(itemID: UUID, correct: Bool) -> String {
        guard var item = language.item(id: itemID) else { return "Error: card not found" }
        item.recordReview(correct: correct)
        language.upsert(item)
        languageDeckRevision &+= 1
        return "\(item.term): \(correct ? "correct" : "wrong"), now box \(item.box)/\(LearnItem.boxCount), due \(Self.dueString(item.dueDate))."
    }

    /// Adds a card to the active profile's deck (used by the add_vocab/add_grammar tools).
    func addDeckCard(_ item: LearnItem) {
        language.upsert(item)
        languageDeckRevision &+= 1
    }

    /// Deletes a card from the deck.
    func deleteDeckItem(_ id: UUID) {
        language.delete(id: id)
        languageDeckRevision &+= 1
    }

    /// Keep the selected conversation consistent with the current mode's sidebar list.
    func syncSelectionToMode() {
        let wantLanguage = (mode == .language)
        if let sel = selectedConversation, (sel.isLanguage == true) == wantLanguage { return }
        if let match = conversations.first(where: { ($0.isLanguage == true) == wantLanguage }) {
            selectedConversationID = match.id
        } else {
            newConversation()
        }
    }

    private func isLanguageConversation(_ id: UUID) -> Bool {
        conversations.first(where: { $0.id == id })?.isLanguage == true
    }

    /// Compact deck overview injected each turn so the model has cheap progress awareness.
    /// Cached by (profile, deck revision) since it's rebuilt on every turn but only changes on a write.
    private var deckContextCache: (key: String, text: String)?
    private func languageDeckContext() -> String {
        guard let p = activeLanguageProfile else { return "" }
        let key = "\(p.id.uuidString)#\(languageDeckRevision)"
        if let c = deckContextCache, c.key == key { return c.text }
        let (s, tags) = language.deckSummary(profileID: p.id)
        let text: String
        if s.total == 0 {
            text = "# Learner's deck\nThe deck is empty — introduce and bank new words and grammar."
        } else {
            var head = "\(s.total) cards"
            let kinds = LearnKind.allCases.compactMap { k -> String? in
                let n = s.perKind[k] ?? 0
                return n > 0 ? "\(n) \(k.rawValue)" : nil
            }
            if !kinds.isEmpty { head += " (\(kinds.joined(separator: ", ")))" }
            var line = "\(head); \(s.due) due for review; \(s.mastered) mastered."
            if !tags.isEmpty { line += " Topics: \(tags.joined(separator: ", "))." }
            text = "# Learner's deck\n" + line
        }
        deckContextCache = (key, text)
        return text
    }

    /// Called by the multiple-choice UI when the user finishes answering. Grades card-linked
    /// questions deterministically, records those reviews, and resumes the paused turn.
    func submitInteraction(_ choices: [Int]) {
        guard let pending = pendingInteraction else { return }
        var lines: [String] = []
        for (i, q) in pending.questions.enumerated() {
            let choice = i < choices.count ? choices[i] : -1
            let chosen = (choice >= 0 && choice < q.options.count) ? q.options[choice] : "(no answer)"
            var line = "Q: \(q.prompt)\nA: \(chosen)"
            if let ci = q.correctIndex {
                let correct = choice == ci
                let answer = (ci >= 0 && ci < q.options.count) ? q.options[ci] : "?"
                line += correct ? " (correct)" : " (incorrect; correct answer: \(answer))"
                if let itemID = q.itemID { _ = recordDeckReview(itemID: itemID, correct: correct) }
            }
            lines.append(line)
        }
        pendingInteraction = nil
        let cont = interactionContinuation
        interactionContinuation = nil
        cont?.resume(returning: lines.joined(separator: "\n\n"))
    }

    /// User dismissed the questions without answering — resume the turn with a note.
    func cancelInteraction() {
        guard interactionContinuation != nil else { return }
        pendingInteraction = nil
        let cont = interactionContinuation
        interactionContinuation = nil
        cont?.resume(returning: "User dismissed the questions without answering.")
    }

    private static func parseMCQuestions(_ raw: [ToolArguments.MultipleChoice.Question]) -> [MCQuestion] {
        raw.compactMap { question in
            guard !question.prompt.isEmpty, !question.options.isEmpty else { return nil }
            return MCQuestion(
                id: UUID(), prompt: question.prompt, options: question.options,
                correctIndex: question.correctIndex, itemID: question.itemID
            )
        }
    }

    private static func dueString(_ date: Date) -> String {
        let days = Calendar.current.dateComponents([.day], from: Date(), to: date).day ?? 0
        if days <= 0 { return "today" }
        if days == 1 { return "tomorrow" }
        return "in \(days) days"
    }

    /// A rough, cache-friendly "now" for background awareness: weekday, date, and part of day.
    /// Deliberately day/part-of-day granular (not exact clock time) so the system prompt stays
    /// stable within a session and doesn't invalidate the server's prefix cache every turn.
    static func dateContext(_ date: Date = Date()) -> String {
        let hour = Calendar.current.component(.hour, from: date)
        let part: String
        // The small hours (past midnight, before dawn) are still colloquially the PREVIOUS
        // day's night — at 00:30 on Friday it's "Thursday night", not "Friday night".
        var dayDate = date
        switch hour {
        case 5..<12: part = "morning"
        case 12..<17: part = "afternoon"
        case 17..<21: part = "evening"
        case 21...23: part = "night"
        default:      part = "night"; dayDate = Calendar.current.date(byAdding: .day, value: -1, to: date) ?? date
        }
        return "\(dateContextFormatter.string(from: dayDate)) (\(part))"
    }

    private static let dateContextFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE, d MMMM yyyy"
        return f
    }()

    /// Dynamic memory for this turn (attached to the latest user message, not the system prompt).
    private func memoryContext(conversationID: UUID, persona: Persona, history: [ChatMessage]) async -> String {
        // Language sessions get a compact deck summary instead of personal memory (the deck is the memory).
        if isLanguageConversation(conversationID) { return languageDeckContext() }
        guard settings.injectMemory else { return "" }
        let scopes = [MemoryStore.globalScope, persona.memoryScope]
        let query = history.last(where: { $0.role == .user })?.content ?? ""
        return await retrieveMemory(conversationID: conversationID, scopes: scopes, query: query)
    }

    /// Single-entry cache of `memory.combined(scopes:)`, invalidated when any file's mtime changes.
    /// Avoids re-reading every memory file from disk on the main actor before each request.
    private var memoryCache: (scopes: [String], signature: String, text: String)?

    private func combinedMemoryCached(scopes: [String]) -> String {
        let sig = memory.signature(scopes: scopes)
        if let c = memoryCache, c.scopes == scopes, c.signature == sig { return c.text }
        let text = memory.combined(scopes: scopes)
        memoryCache = (scopes, sig, text)
        return text
    }

    /// Injects the user's identity (global profile) in full plus the top-K bullets most relevant
    /// to the current query, so memory can grow large without flooding the context.
    private func retrieveMemory(conversationID: UUID, scopes: [String], query: String) async -> String {
        let profileName = MemoryCategory.profile.fileName
        let profileScope = MemoryStore.globalScope
        let profileURL = Paths.memoryScope(profileScope).appendingPathComponent(profileName)
        let profileBody = memory.read(MemoryStore.File(scope: profileScope, name: profileName, url: profileURL))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var sections: [String] = []
        if !profileBody.isEmpty { sections.append("## \(profileScope)/\(profileName)\n\(profileBody)") }

        // Every other bullet is a retrieval candidate.
        var chunks: [(label: String, text: String)] = []
        for scope in scopes {
            for file in memory.files(in: scope) {
                if scope == profileScope, file.name == profileName { continue }
                for block in MemoryStore.blocks(memory.read(file)) {
                    chunks.append((label: "\(scope)/\(file.name)", text: block))
                }
            }
        }
        guard !chunks.isEmpty, !query.isEmpty else { return sections.joined(separator: "\n\n") }
        do {
            let (q, blockEmb) = try await embedWithCache(query: query, blocks: chunks.map(\.text), model: settings.embeddingModel)
            let scored = zip(chunks, blockEmb)
                .map { (chunk: $0.0, score: Self.cosine(q, $0.1)) }
                .filter { $0.score >= settings.memoryThreshold }
                .sorted { $0.score > $1.score }
                .prefix(max(1, settings.memoryTopK))
            // Group retrieved bullets under one header per file (keeping best-scoring files first).
            var order: [String] = []
            var byLabel: [String: [String]] = [:]
            for item in scored {
                if byLabel[item.chunk.label] == nil { order.append(item.chunk.label) }
                byLabel[item.chunk.label, default: []].append(item.chunk.text)
            }
            sections.append(contentsOf: order.map { "## \($0)\n\((byLabel[$0] ?? []).joined(separator: "\n"))" })
            trace(conversationID, .memory, "memory retrieval: \(scored.count)/\(chunks.count) bullets ≥ \(String(format: "%.2f", settings.memoryThreshold)) injected")
        } catch {
            // Embedding endpoint unavailable: fall back to injecting everything so memory isn't lost.
            trace(conversationID, .error, "memory retrieval failed, injecting all: \(Self.embedErrorHint(error))")
            return combinedMemoryCached(scopes: scopes)
        }
        return sections.joined(separator: "\n\n")
    }

    /// Describes an embedding failure, hinting at the common cause (server has no embeddings endpoint).
    static func embedErrorHint(_ error: Error) -> String {
        "\(error.localizedDescription) — needs a chat server exposing /v1/embeddings with an embedding model loaded"
    }

    // MARK: - Documents (RAG for large attachments)

    /// Indexed documents for the current conversation.
    var indexedDocuments: [StoredDocument] {
        selectedConversationID.map { documents.documents(for: $0) } ?? []
    }

    /// Inline small attachments; index large ones for retrieval. Returns true when indexed as RAG.
    @discardableResult
    func addDocument(name: String, text: String) -> Bool {
        if settings.ragThresholdChars > 0, text.count > settings.ragThresholdChars,
           let convoID = selectedConversationID {
            documents.add(name: name, text: text, conversationID: convoID)
            return true
        }
        draftAttachments.append(Attachment(name: name, text: text))
        return false
    }

    func removeIndexedDocument(_ id: UUID) {
        guard let convoID = selectedConversationID else { return }
        documents.delete(id: id, conversationID: convoID)
    }

    /// Retrieve the most relevant passages from this conversation's indexed documents.
    private func documentContext(conversationID: UUID, history: [ChatMessage]) async -> String {
        let docs = documents.documents(for: conversationID)
        guard !docs.isEmpty, let query = history.last(where: { $0.role == .user })?.content else { return "" }
        var chunks: [(label: String, text: String)] = []
        for doc in docs {
            for chunk in doc.chunks {
                let t = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
                if t.count >= 3 { chunks.append((label: doc.name, text: t)) }
            }
        }
        guard !chunks.isEmpty else { return "" }
        do {
            let (q, blockEmb) = try await embedWithCache(query: query, blocks: chunks.map(\.text), model: settings.embeddingModel)
            let scored = zip(chunks, blockEmb)
                .map { (chunk: $0.0, score: Self.cosine(q, $0.1)) }
                .sorted { $0.score > $1.score }
            return scored.prefix(max(1, settings.ragTopK))
                .map { "## \($0.chunk.label)\n\($0.chunk.text)" }
                .joined(separator: "\n\n")
        } catch {
            trace(conversationID, .error, "document retrieval failed: \(Self.embedErrorHint(error))")
            return ""
        }
    }

    /// Embeds the query plus only the memory blocks not already cached (blocks are stable).
    private func embedWithCache(query: String, blocks: [String], model: String) async throws -> (query: [Double], blocks: [[Double]]) {
        var blockEmb = [[Double]?](repeating: nil, count: blocks.count)
        var missing: [Int] = []
        for (i, b) in blocks.enumerated() {
            if let e = embeddingCache.get(model: model, text: b) { blockEmb[i] = e } else { missing.append(i) }
        }
        let inputs = [query] + missing.map { blocks[$0] }
        let config = settings.requestConfig(modelOverride: nil)
        let result = try await ChatService.embed(config: config, inputs: inputs)
        guard result.count == inputs.count else { throw ChatServiceError.invalidURL }
        for (k, idx) in missing.enumerated() {
            let e = result[k + 1]
            blockEmb[idx] = e
            embeddingCache.set(model: model, text: blocks[idx], embedding: e)
        }
        embeddingCache.save()
        return (result[0], blockEmb.map { $0 ?? [] })
    }

    private static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in a.indices { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        let denom = na.squareRoot() * nb.squareRoot()
        return denom == 0 ? 0 : dot / denom
    }

    private func buildWire(
        systemText: String,
        summary: String,
        memoryText: String,
        documentText: String = "",
        history: [ChatMessage]
    ) -> [WireMessage] {
        var wire: [WireMessage] = []
        if !systemText.isEmpty {
            wire.append(WireMessage(role: Role.system.rawValue, text: systemText))
        }
        let summaryText = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !summaryText.isEmpty {
            wire.append(WireMessage(role: Role.system.rawValue, text: "# Summary of earlier conversation\n\(summaryText)"))
        }
        let budgeted = budget(history: history)
        let memory = memoryText.trimmingCharacters(in: .whitespacesAndNewlines)
        let retrievedDocs = documentText.trimmingCharacters(in: .whitespacesAndNewlines)
        let lastUserIdx = budgeted.lastIndex(where: { $0.role == .user })
        // Keep only the most recent tool outputs verbatim; older ones are re-sent every
        // turn otherwise, so collapse them to a stub to save context.
        let keepFullTool = Set(budgeted.indices.filter { budgeted[$0].role == .tool }.suffix(Self.maxFullToolResults))
        for (i, msg) in budgeted.enumerated() {
            switch msg.role {
            case .system:
                continue
            case .tool:
                let content = keepFullTool.contains(i) ? msg.content : Self.stubToolResult(msg)
                wire.append(.toolResult(id: msg.toolCallId ?? "", name: msg.toolName ?? "tool", content: content))
            case .assistant:
                let assistantText = msg.interrupted
                    ? msg.content + "\n\n[Response interrupted by the user.]"
                    : msg.content
                if let calls = msg.toolCalls, !calls.isEmpty {
                    wire.append(WireMessage(
                        role: "assistant",
                        content: assistantText.isEmpty ? nil : .text(assistantText),
                        toolCalls: calls
                    ))
                } else {
                    wire.append(WireMessage(role: "assistant", text: assistantText))
                }
            case .user:
                // Attach memory to the latest user turn only → stable prefix, cache-friendly.
                var text = msg.content
                if !msg.attachments.isEmpty {
                    let docs = msg.attachments
                        .map { "# Attached file: \($0.name)\n\($0.text)" }
                        .joined(separator: "\n\n")
                    text = text.isEmpty ? docs : docs + "\n\n---\n\n" + text
                }
                if i == lastUserIdx, !retrievedDocs.isEmpty {
                    text = "# Relevant excerpts from attached documents\n\(retrievedDocs)\n\n---\n\n" + text
                }
                if i == lastUserIdx, !memory.isEmpty {
                    text = "# Relevant memory\n\(memory)\n\n---\n\n" + text
                }
                if msg.images.isEmpty || !settings.sendImagesToModel {
                    wire.append(WireMessage(role: "user", text: text))
                } else {
                    var parts: [ContentPart] = []
                    if !text.isEmpty { parts.append(.text(text)) }
                    parts.append(contentsOf: msg.images.map { .image($0) })
                    wire.append(WireMessage(role: "user", parts: parts))
                }
            }
        }
        return wire
    }

    /// Keep the most recent turns that fit the model's context window.
    private func budget(history: [ChatMessage]) -> [ChatMessage] {
        guard let window = contextWindow else { return history }
        let reserve = max(settings.effectiveMaxTokens ?? 1024, 512)
        let budgetTokens = max(1000, window - reserve - 256)
        var total = 0
        var kept: [ChatMessage] = []
        for msg in history.reversed() {
            let est = msg.content.utf8.count / 4 + msg.attachmentBytes / 4 + msg.images.count * 600
            if total + est > budgetTokens, !kept.isEmpty { break }
            total += est
            kept.insert(msg, at: 0)
        }
        // Never start the window on an orphaned tool result: its assistant `tool_calls` parent may
        // have been dropped, and servers reject a `tool` message with no preceding `tool_calls`.
        while let first = kept.first, first.role == .tool {
            kept.removeFirst()
        }
        return kept
    }

    // MARK: - Compression (rolling summary of old turns)

    private var isCompressing = false

    private func estimateTokens(_ msgs: [ChatMessage]) -> Int {
        msgs.reduce(0) { $0 + $1.content.utf8.count / 4 + $1.attachmentBytes / 4 + $1.images.count * 600 }
    }

    /// Runs a short background task on Apple's on-device model (ANE), falling back to the server
    /// when it's unavailable. Used by the "On-device" choice of a per-task model picker, so it is
    /// intentionally independent of the titles/triage on-device toggle.
    private func onDeviceComplete(prompt: String, config: RequestConfig, temperature: Double? = nil) async -> String? {
        if OnDeviceLLM.isAvailable,
           let out = await OnDeviceLLM.complete(prompt: prompt, temperature: temperature) {
            return out
        }
        return try? await ChatService.complete(config: config, messages: [WireMessage(role: Role.user.rawValue, text: prompt)])
    }

    private func compressIfNeeded(conversationID: UUID) {
        guard settings.compressionEnabled, !isCompressing,
              let idx = conversationIndex(conversationID)
        else { return }

        let msgs = conversations[idx].messages
        let start = min(conversations[idx].summarizedCount ?? 0, msgs.count)
        let recent = Array(msgs[start...])
        guard estimateTokens(recent) > settings.compressionBudget else { return }
        guard let lastUserRel = recent.lastIndex(where: { $0.role == .user }) else { return }

        // Walk back from the end; keep whole turns that fit, fold the rest at a user boundary.
        var keepFromRel = lastUserRel
        var acc = 0
        var i = recent.count - 1
        while i >= 0 {
            acc += estimateTokens([recent[i]])
            if acc > settings.compressionBudget { break }
            if recent[i].role == .user { keepFromRel = i }
            i -= 1
        }
        let foldEnd = start + min(keepFromRel, lastUserRel)
        guard foldEnd > start else { return }

        let toFold = Array(msgs[start..<foldEnd])
        guard !toFold.isEmpty else { return }

        let persona = persona(for: conversations[idx])
        let existing = conversations[idx].summary ?? ""
        let transcript = toFold
            .filter { !$0.content.isEmpty }
            .map { "\($0.role.rawValue.uppercased()): \($0.content)" }
            .joined(separator: "\n\n")
        let instruction = """
        \(MemoryProfile.contentPolicy)

        You maintain a running summary of a long conversation so older turns can be dropped from context. \
        Rewrite the EXISTING SUMMARY together with the NEW MESSAGES into one tighter summary.

        Rules:
        - Synthesize in your own words. NEVER quote or reproduce message text, code, commands, or markdown formatting.
        - Keep only durable, reusable information: facts about the user, decisions made, stated preferences, \
        names/identifiers, and unresolved questions or open threads.
        - Drop pleasantries, meta-talk, and restatements. Merge duplicates and compress older points harder as it grows.
        - Write terse plain-text bullet points. No headings, no code blocks, one short line each.
        - Be brief: aim for well under 300 words total.

        Output ONLY the updated summary.

        EXISTING SUMMARY:
        \(existing.isEmpty ? "(none)" : existing)

        NEW MESSAGES:
        \(transcript)
        """
        // The summary is re-sent every turn, so cap it well below the live budget (≈¼) — otherwise
        // folding stops saving space and a rolling summary can grow unbounded.
        let summaryCap = max(256, settings.compressionBudget / 4)
        var config = settings.requestConfig(modelOverride: persona.model)
        config.maxTokens = min(config.maxTokens ?? summaryCap, summaryCap)
        if settings.disableThinkingForTasks { config.enableThinking = false }
        let useServer = settings.compressionUseServer

        isCompressing = true
        Task { [weak self] in
            defer { self?.isCompressing = false }
            guard let self else { return }
            let result: String?
            if useServer {
                result = try? await ChatService.complete(config: config, messages: [WireMessage(role: Role.user.rawValue, text: instruction)])
            } else {
                result = await self.onDeviceComplete(prompt: instruction, config: config)
            }
            guard let result else { return }
            let clean = result.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty, let i = self.ensureHydratedIndex(conversationID) else { return }
            self.conversations[i].summary = clean
            self.conversations[i].summarizedCount = foldEnd
            let detail = """
            ── folded messages (\(toFold.count)) ──
            \(transcript)

            ── previous summary ──
            \(existing.isEmpty ? "(none)" : existing)

            ── new summary ──
            \(clean)
            """
            self.trace(conversationID, .compress, "folded \(toFold.count) old messages into summary (\(clean.count) chars); \(self.conversations[i].messages.count - foldEnd) kept live", detail: detail)
            self.touch(i)
        }
    }

    // MARK: - Auto-title

    /// Conversations whose title is auto-generated (not user-renamed), so it may be refined.
    private var autoTitledIDs: Set<UUID> = []

    private func maybeAutoTitle(conversationID: UUID) {
        guard settings.autoTitle, let idx = conversationIndex(conversationID) else { return }
        let convo = conversations[idx]
        guard convo.messages.filter({ $0.role == .user }).count == 1,
              let firstUser = convo.messages.first(where: { $0.role == .user })?.content,
              !firstUser.isEmpty
        else { return }
        // Instant heuristic title (first line) so the sidebar isn't blank…
        let firstLine = firstUser
            .components(separatedBy: .newlines)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? firstUser
        let clean = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        conversations[idx].title = clean.count > 48
            ? String(clean.prefix(48)).trimmingCharacters(in: .whitespaces) + "…"
            : clean
        autoTitledIDs.insert(conversationID)
        touch(idx)

        // …then refine it with the on-device model (ANE), if available.
        guard settings.useOnDeviceModel, OnDeviceLLM.isAvailable else { return }
        let placeholder = conversations[idx].title
        let source = String(firstUser.prefix(1000))
        Task { [weak self] in
            let prompt = """
            Write a concise chat title (3–6 words, Title Case, no quotes or trailing punctuation) \
            for a conversation that starts with this message:

            \(source)
            """
            guard let raw = await OnDeviceLLM.complete(prompt: prompt, temperature: 0.2) else { return }
            var title = raw
                .components(separatedBy: .newlines).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }?
                .trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'.")) ?? ""
            // Small on-device models sometimes ignore "Title Case" and SHOUT — normalize all-caps.
            if title == title.uppercased(), title != title.lowercased() {
                title = title.capitalized
            }
            guard let self, title.count >= 2, title.count <= 60,
                  let i = self.conversationIndex(conversationID),
                  // Only replace the placeholder if the user hasn't renamed it since.
                  self.conversations[i].title == placeholder
            else { return }
            self.conversations[i].title = title
            self.touch(i)
        }
    }


    /// Refines the title, potentially multiple times, but only after a significant change in context.
    /// - Parameter conversationID: The UUID of the chat.
    /// - Parameter messageThreshold: How many new messages must occur before we re-title.
    private func maybeRefineTitle(conversationID: UUID, messageThreshold: Int = 6) {
        guard settings.autoTitle, settings.useOnDeviceModel, OnDeviceLLM.isAvailable,
            let idx = conversationIndex(conversationID) else { return }
        
        let currentMsgs = conversations[idx].messages.filter {
            ($0.role == .user || $0.role == .assistant) && !$0.content.isEmpty
        }
        
        // have enough messages passed since the last successful title update?
        guard currentMsgs.count >= (conversations[idx].lastTitledMessageCount + messageThreshold) else { return }
        
        let contextWindow = 8 // TODO: extract this as a setting or use messageThreshold?
        let transcript = currentMsgs.suffix(contextWindow) // last messages
            .map { "\($0.role == .user ? "User" : "Assistant"): \($0.content.prefix(300))" }
            .joined(separator: "\n")
        
        let currentTitle = conversations[idx].title
        
        Task { [weak self] in
            let prompt = """
            Write a concise chat title (3–6 words, Title Case, no quotes or trailing punctuation) \
            that captures the subject of the most recent messages:

            \(transcript)
            """
            
            guard let raw = await OnDeviceLLM.complete(prompt: prompt, temperature: 0.3) else { return }
            
            var title = raw
                .components(separatedBy: .newlines).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }?
                .trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'.")) ?? ""
            
            if title == title.uppercased() && title != title.lowercased() { title = title.capitalized }
            
            guard let self, title.count >= 2, title.count <= 60, // check that title length is reasonable
                let i = self.conversationIndex(conversationID),  // revalidate conversation id 
                self.conversations[i].title == currentTitle      // check that the user didnt manually change the title
            else { return }
            
            // Update the title and the tracking counter
            self.conversations[i].title = title
            self.conversations[i].lastTitledMessageCount = currentMsgs.count
            self.touch(i)
            trace(conversationID, .info, "refined conversation title")
        }
    }

    // MARK: - Export

    func exportMarkdown(_ conversation: Conversation) -> String {
        // Sidebar may export a non-selected chat whose body isn't resident; read it from disk.
        let convo = hydratedIDs.contains(conversation.id)
            ? conversation
            : (Self.loadConversationBody(conversation.id) ?? conversation)
        let persona = persona(for: convo)
        var out = "# \(convo.title)\n\n"
        for m in convo.messages {
            switch m.role {
            case .user: out += "**You:** \(m.content)\n\n"
            case .assistant where !m.content.isEmpty: out += "**\(persona.name):** \(m.content)\n\n"
            case .assistant: break
            case .tool: out += "> _tool `\(m.toolName ?? "")`_: \(m.content)\n\n"
            case .system: break
            }
        }
        return out
    }

    // MARK: - Voice

    func speak(_ text: String) {
        let clean = text.strippedForSpeech
        guard !clean.isEmpty else { return }
        voice.lastError = nil
        // Language practice: native voices switch per language; server TTS can't do the target language well.
        if mode == .language, let p = activeLanguageProfile {
            voice.speakBilingual(clean, targetLocale: p.targetLocale, baseLocale: p.baseLocale,
                                 targetVoiceID: p.targetVoiceID, baseVoiceID: p.baseVoiceID, rate: settings.speechRate)
            return
        }
        if settings.ttsSource == .server {
            let config = settings.requestConfig(modelOverride: nil)
            Task { [weak self] in
                guard let self else { return }
                do {
                    let data = try await ChatService.speech(config: config, text: clean)
                    self.voice.playAudioData(data)
                } catch {
                    self.voice.lastError = "Server TTS failed: \(error.localizedDescription)"
                }
            }
        } else {
            voice.speakNative(clean, voiceID: settings.voiceIdentifier, rate: settings.speechRate)
        }
    }

    func toggleDictation() {
        if voice.isListening {
            if settings.sttSource == .server {
                let config = settings.requestConfig(modelOverride: nil)
                Task { [weak self] in
                    guard let self else { return }
                    if let text = await self.voice.stopRecordingAndTranscribe(config: config) {
                        self.draft = self.draft.isEmpty ? text : self.draft + " " + text
                    }
                }
            } else {
                voice.stopDictation()
            }
        } else {
            if settings.sttSource == .server {
                voice.startRecording()
            } else {
                voice.startNativeDictation(locale: languageDictationLocale()) { [weak self] update in
                    self?.draft = update.text
                }
            }
        }
    }

    /// Locale for native dictation: the chosen practice language in Learn mode, else English.
    func languageDictationLocale() -> String {
        guard mode == .language, let p = activeLanguageProfile else { return "en-US" }
        return languageInputTarget ? p.targetLocale : p.baseLocale
    }

    // MARK: - Conversational mode

    enum VoiceState: Equatable { case idle, listening, thinking, speaking }
    var voiceState: VoiceState = .idle
    var conversationActive = false
    var liveTranscript = ""
    private var conversationEndpointTask: Task<Void, Never>?
    private var bargeInConfirmationTask: Task<Void, Never>?
    private var bargeInClassificationTask: Task<Void, Never>?
    private var bargeInFallbackTask: Task<Void, Never>?
    private var conversationResponseTask: Task<Void, Never>?
    private var conversationSynthesisTask: Task<Void, Never>?
    private var conversationSegmentContinuation: AsyncStream<String>.Continuation?
    private var conversationGeneration = 0
    private var conversationSessionID: UUID?
    private var bargeInCandidate = ""
    private var bargeInCandidateFinal = false
    private var bargeInTranscriptBaseline = ""
    private var bargeInLatestTranscript = ""
    private var bargeInDecisionID: UUID?
    private var conversationReplyDraft = ""
    private var conversationReplyMessageID: UUID?
    private static let bargeInConfirmationMilliseconds = 300
    private static let backchannelClassificationTimeoutMilliseconds = 1_000
    /// Set when the model calls `end_conversation`; the turn finishes speaking, then hangs up
    /// instead of resuming listening.
    private var endConversationRequested = false

    func startConversation() {
        guard !conversationActive, let selectedConversationID else { return }
        conversationActive = true
        conversationSessionID = selectedConversationID
        endConversationRequested = false
        voice.lastError = nil
        voice.startOutputKeepAlive()
        if settings.conversationBackchannelANE { OnDeviceLLM.startBackchannelClassifier() }
        beginListening()
    }

    func stopConversation() {
        conversationActive = false
        OnDeviceLLM.stopBackchannelClassifier()
        conversationGeneration &+= 1
        conversationEndpointTask?.cancel(); conversationEndpointTask = nil
        bargeInConfirmationTask?.cancel(); bargeInConfirmationTask = nil
        cancelBackchannelDecision()
        conversationResponseTask?.cancel(); conversationResponseTask = nil
        conversationSynthesisTask?.cancel(); conversationSynthesisTask = nil
        conversationSegmentContinuation?.finish(); conversationSegmentContinuation = nil
        voice.onFinishSpeaking = nil
        voice.stopDictation()
        voice.stopSpeaking()
        voice.stopOutputKeepAlive()
        voiceState = .idle
        conversationSessionID = nil
        liveTranscript = ""
        bargeInCandidate = ""
        bargeInTranscriptBaseline = ""
        bargeInLatestTranscript = ""
        conversationReplyDraft = ""
        conversationReplyMessageID = nil
    }

    private func beginListening(seed: String = "") {
        guard conversationActive else { return }
        bargeInConfirmationTask?.cancel(); bargeInConfirmationTask = nil
        cancelBackchannelDecision()
        bargeInCandidate = ""
        bargeInCandidateFinal = false
        bargeInTranscriptBaseline = ""
        bargeInLatestTranscript = ""
        liveTranscript = seed
        voiceState = .listening
        ensureConversationDictation()
        if !seed.isEmpty { scheduleConversationEndpoint(text: seed, isFinal: false) }
    }

    private func ensureConversationDictation() {
        guard conversationActive, !voice.isListening else { return }
        voice.startNativeDictation { [weak self] update in
            self?.onConversationDictation(update)
        }
    }

    private func onConversationDictation(_ update: VoiceManager.DictationUpdate) {
        guard conversationActive else { return }
        switch voiceState {
        case .listening:
            onConversationPartial(update)
        case .thinking, .speaking:
            onBargeInPartial(update)
        case .idle:
            break
        }
    }

    private func onConversationPartial(_ update: VoiceManager.DictationUpdate) {
        let text = update.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        liveTranscript = text
        scheduleConversationEndpoint(text: text, isFinal: update.isFinal)
        if update.isFinal { resumeConversationDictation(after: text) }
    }

    /// Apple can finalize a recognition task during a natural mid-sentence pause. Start a fresh
    /// task while retaining the transcript, so continued speech extends the same user turn.
    private func resumeConversationDictation(after prefix: String) {
        Task { [weak self] in
            await Task.yield()   // VoiceManager stops the finalized recognition task after its callback.
            guard let self, self.conversationActive, self.voiceState == .listening,
                  self.liveTranscript == prefix, !self.voice.isListening else { return }
            self.voice.startNativeDictation { [weak self] update in
                guard let self else { return }
                let continuation = update.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let combined = continuation.isEmpty ? prefix : prefix + " " + continuation
                self.onConversationDictation(.init(text: combined, isFinal: update.isFinal))
            }
        }
    }

    private func scheduleConversationEndpoint(text: String, isFinal: Bool) {
        conversationEndpointTask?.cancel()
        let delay = Self.conversationEndpointMilliseconds(text: text, isFinal: isFinal)
        conversationEndpointTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(delay))
            guard !Task.isCancelled else { return }
            guard let self, self.conversationActive, self.voiceState == .listening,
                  self.liveTranscript == text else { return }
            self.endUserTurn()
        }
    }

    private static func conversationEndpointMilliseconds(text: String, isFinal: Bool) -> Int {
        if isFinal { return 1_800 }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let last = trimmed.last, ".!?…。！？".contains(last) { return 1_800 }
        if let last = trimmed.last, ",;:—-".contains(last) { return 2_500 }
        let finalWord = trimmed.split(whereSeparator: { $0.isWhitespace }).last?.lowercased() ?? ""
        let continuationWords: Set<String> = ["and", "but", "because", "or", "so", "then", "if", "when", "um", "uh"]
        if continuationWords.contains(finalWord) { return 2_800 }
        return 2_000
    }

    private func onBargeInPartial(_ update: VoiceManager.DictationUpdate) {
        let transcript = update.text.trimmingCharacters(in: .whitespacesAndNewlines)
        bargeInLatestTranscript = transcript
        let text = Self.transcriptSuffix(transcript, after: bargeInTranscriptBaseline)
        guard !text.isEmpty else { return }
        bargeInCandidate = text
        bargeInCandidateFinal = update.isFinal
        guard bargeInConfirmationTask == nil else { return }
        bargeInConfirmationTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Self.bargeInConfirmationMilliseconds))
            guard !Task.isCancelled, let self, self.conversationActive,
                  (self.voiceState == .thinking || self.voiceState == .speaking),
                  !self.bargeInCandidate.isEmpty else { return }
            self.bargeInConfirmationTask = nil
            self.classifyBargeInOrFallback()
        }
    }

    private static func transcriptSuffix(_ transcript: String, after baseline: String) -> String {
        guard !baseline.isEmpty, transcript.hasPrefix(baseline) else { return transcript }
        return transcript.dropFirst(baseline.count).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func classifyBargeInOrFallback() {
        let text = bargeInCandidate
        guard !text.isEmpty else { return }
        let generation = conversationGeneration
        let convoID = conversationSessionID
        guard settings.conversationBackchannelANE, OnDeviceLLM.isAvailable else {
            if let convoID {
                trace(convoID, .info, "backchannel classifier unavailable or disabled; using interruption fallback")
            }
            confirmBargeIn(expectedGeneration: generation, convoID: convoID)
            return
        }

        let decisionID = UUID()
        let startedAt = Date()
        bargeInDecisionID = decisionID
        bargeInClassificationTask = Task { [weak self] in
            let isBackchannelAnswer = await OnDeviceLLM.classifyBackchannel(text)
            guard let self, !Task.isCancelled, self.bargeInDecisionID == decisionID,
                self.conversationGeneration == generation,
                  self.conversationActive,
                  (self.voiceState == .thinking || self.voiceState == .speaking) else { return }
            self.bargeInFallbackTask?.cancel(); self.bargeInFallbackTask = nil
            self.bargeInClassificationTask = nil
            self.bargeInDecisionID = nil
            let elapsed = Int(Date().timeIntervalSince(startedAt) * 1_000)
            let unchanged = self.bargeInCandidate == text
            let isBackchannel = unchanged && isBackchannelAnswer == true
            if isBackchannel {
                if let convoID {
                    self.trace(convoID, .info, "backchannel classifier (ANE): BACKCHANNEL in \(elapsed)ms; assistant continued")
                }
                self.dismissBackchannel()
            } else {
                if let convoID {
                    let outcome = unchanged ? "INTERRUPT" : "transcript changed"
                    self.trace(convoID, .info, "backchannel classifier (ANE): \(outcome) in \(elapsed)ms")
                }
                self.confirmBargeIn(expectedGeneration: generation, convoID: convoID)
            }
        }

        bargeInFallbackTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Self.backchannelClassificationTimeoutMilliseconds))
            guard !Task.isCancelled, let self, self.bargeInDecisionID == decisionID,
                self.conversationGeneration == generation,
                  self.conversationActive,
                  (self.voiceState == .thinking || self.voiceState == .speaking) else { return }
            self.bargeInDecisionID = nil
            self.bargeInClassificationTask?.cancel(); self.bargeInClassificationTask = nil
            self.bargeInFallbackTask = nil
            if let convoID {
                self.trace(convoID, .info, "backchannel classifier (ANE): timed out after 1000ms; treating as interruption")
            }
            self.confirmBargeIn(expectedGeneration: generation, convoID: convoID)
        }
    }

    private func dismissBackchannel() {
        bargeInConfirmationTask?.cancel(); bargeInConfirmationTask = nil
        cancelBackchannelDecision()
        bargeInCandidate = ""
        bargeInCandidateFinal = false
        if voice.isListening {
            bargeInTranscriptBaseline = bargeInLatestTranscript
        } else {
            bargeInTranscriptBaseline = ""
            bargeInLatestTranscript = ""
            ensureConversationDictation()
        }
    }

    private func cancelBackchannelDecision() {
        bargeInClassificationTask?.cancel(); bargeInClassificationTask = nil
        bargeInFallbackTask?.cancel(); bargeInFallbackTask = nil
        bargeInDecisionID = nil
    }

    private func confirmBargeIn(expectedGeneration: Int, convoID: UUID?) {
        guard conversationGeneration == expectedGeneration else { return }
        let text = bargeInCandidate
        let isFinal = bargeInCandidateFinal
        guard !text.isEmpty else { return }
        conversationGeneration &+= 1
        conversationResponseTask?.cancel(); conversationResponseTask = nil
        conversationSynthesisTask?.cancel(); conversationSynthesisTask = nil
        conversationSegmentContinuation?.finish(); conversationSegmentContinuation = nil
        conversationEndpointTask?.cancel(); conversationEndpointTask = nil
        bargeInConfirmationTask?.cancel(); bargeInConfirmationTask = nil
        cancelBackchannelDecision()
        voice.onFinishSpeaking = nil
        voice.stopSpeaking()
        endConversationRequested = false
        if let convoID {
            markConversationReplyInterrupted(convoID: convoID)
            trace(convoID, .info, "barge-in detected; cancelled reply and resumed listening")
        }
        bargeInCandidate = ""
        bargeInCandidateFinal = false
        bargeInTranscriptBaseline = ""
        bargeInLatestTranscript = ""
        liveTranscript = text
        voiceState = .listening
        scheduleConversationEndpoint(text: text, isFinal: isFinal)
        if isFinal {
            resumeConversationDictation(after: text)
        } else {
            ensureConversationDictation()
        }
    }

    private func endUserTurn() {
        conversationEndpointTask?.cancel(); conversationEndpointTask = nil
        let text = liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        voice.stopDictation()
        guard conversationActive else { return }
        guard !text.isEmpty else { beginListening(); return }
        liveTranscript = ""
        voiceState = .thinking
        respond(to: text)
    }

    private func respond(to text: String) {
        guard let convoID = conversationSessionID, let idx = conversationIndex(convoID) else { return }
        conversations[idx].messages.append(ChatMessage(role: .user, content: text))
        touch(idx)
        maybeAutoTitle(conversationID: convoID)
        let persona = persona(for: conversations[idx])
        let allHistory = conversations[idx].messages
        let folded = min(conversations[idx].summarizedCount ?? 0, allHistory.count)
        let history = Array(allHistory.dropFirst(folded))
        let summary = conversations[idx].summary ?? ""
        let config = settings.requestConfig(modelOverride: persona.model)
        conversationGeneration &+= 1
        let generation = conversationGeneration
        conversationResponseTask?.cancel()
        conversationSynthesisTask?.cancel()
        conversationSegmentContinuation?.finish(); conversationSegmentContinuation = nil
        conversationReplyDraft = ""
        conversationReplyMessageID = nil

        conversationResponseTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == self.conversationGeneration { self.conversationResponseTask = nil }
            }
            let systemText = self.stableSystemPrompt(persona: persona)
            let memoryText = await self.memoryContext(conversationID: convoID, persona: persona, history: history)
            let documentText = await self.documentContext(conversationID: convoID, history: history)
            guard !Task.isCancelled, generation == self.conversationGeneration, self.conversationActive else { return }
            let wire = self.buildWire(systemText: systemText, summary: summary, memoryText: memoryText, documentText: documentText, history: history)
            // The voice-only hang-up tool is offered on every conversational turn.
            let tools = [Tools.endConversationDef]
            self.trace(convoID, .request, self.requestSummary(config: config, wire: wire, tools: tools, memory: memoryText, summary: summary), detail: self.requestDetail(wire: wire))
            // Server TTS streams sentence-by-sentence so speech starts before the whole reply lands;
            // native TTS still speaks the completed reply.
            if self.settings.ttsSource == .server {
                await self.respondStreamingServerTTS(convoID: convoID, config: config, wire: wire, tools: tools, generation: generation)
            } else {
                await self.respondBuffered(convoID: convoID, config: config, wire: wire, tools: tools, generation: generation)
            }
        }
        beginInterruptionMonitoring()
    }

    private func beginInterruptionMonitoring() {
        guard conversationActive, settings.conversationBargeIn else { return }
        bargeInCandidate = ""
        bargeInCandidateFinal = false
        bargeInTranscriptBaseline = ""
        bargeInLatestTranscript = ""
        bargeInConfirmationTask?.cancel(); bargeInConfirmationTask = nil
        cancelBackchannelDecision()
        ensureConversationDictation()
    }

    /// Acts on a tool call from a conversational turn. Only `end_conversation` is supported here
    /// (the voice path has no general tool loop); returns true if the session should hang up.
    private func handleConversationalToolCalls(_ calls: [ToolCall], convoID: UUID) {
        for call in calls where call.function.name == "end_conversation" {
            trace(convoID, .tool, "end_conversation() — hanging up after this reply")
            endConversationRequested = true
        }
    }

    private func respondBuffered(convoID: UUID, config: RequestConfig, wire: [WireMessage], tools: [ToolDef], generation: Int) async {
        let start = Date()
        var reply = ""
        var reasoning = ""
        var toolCalls: [ToolCall] = []
        var stripper = ThinkStripper()
        do {
            for try await event in ChatService.stream(config: config, messages: wire, tools: tools) {
                guard !Task.isCancelled, generation == conversationGeneration, conversationActive else { return }
                switch event {
                case let .delta(chunk):
                    let out = stripper.consume(chunk)
                    reply += out.visible
                    reasoning += out.reasoning
                    conversationReplyDraft = reply
                case let .reasoning(chunk): reasoning += chunk
                case let .toolCalls(calls): toolCalls = calls
                default: break
                }
            }
        } catch {
            guard !Task.isCancelled, generation == conversationGeneration else { return }
            self.trace(convoID, .error, "conversational reply failed: \(error.localizedDescription)")
            guard self.conversationActive else { return }
            self.speakThenListen("", generation: generation)
            return
        }
        guard !Task.isCancelled, generation == conversationGeneration else { return }
        let tail = stripper.finish()
        reply += tail.visible
        reasoning += tail.reasoning
        conversationReplyDraft = reply
        if !reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            trace(convoID, .reasoning, reasoning)
        }
        if !toolCalls.isEmpty { handleConversationalToolCalls(toolCalls, convoID: convoID) }
        self.trace(convoID, .finish, "reply in \(Int(Date().timeIntervalSince(start) * 1000))ms, chars=\(reply.count)")
        guard self.conversationActive else { return }
        self.finishConversationTurn(convoID: convoID, reply: reply)
        self.speakThenListen(reply, generation: generation)
    }

    /// Streams the LLM reply and synthesizes each finished sentence via server TTS as it arrives,
    /// so playback starts while the model is still writing. Listening resumes when the last clip ends.
    private func respondStreamingServerTTS(convoID: UUID, config: RequestConfig, wire: [WireMessage], tools: [ToolDef], generation: Int) async {
        guard conversationActive else { return }
        // Stay in .thinking until the first audio clip is ready; only then flip to .speaking,
        // so the orb reflects the real (often long) generation time instead of jumping to green.
        voice.beginAudioStream()
        voice.onFinishSpeaking = { [weak self] in
            guard let self, self.conversationActive, generation == self.conversationGeneration else { return }
            self.voice.onFinishSpeaking = nil
            self.conversationReplyMessageID = nil
            // The model asked to hang up: stop after the farewell finishes playing.
            if self.endConversationRequested { self.stopConversation() } else { self.beginListening() }
        }

        let ttsConfig = settings.requestConfig(modelOverride: nil)
        let (segments, segCont) = AsyncStream.makeStream(of: String.self)
        conversationSegmentContinuation = segCont
        // Synthesize segments serially so clips are enqueued in spoken order.
        conversationSynthesisTask = Task { [weak self] in
            var started = false
            for await seg in segments {
                guard let self, self.conversationActive, generation == self.conversationGeneration,
                      !Task.isCancelled else { break }
                do {
                    let data = try await ChatService.speech(config: ttsConfig, text: seg)
                    guard generation == self.conversationGeneration, !Task.isCancelled else { break }
                    self.warnedServerTTSFailure = false
                    if !started { started = true; self.voiceState = .speaking }
                    self.voice.enqueueAudioData(data)
                } catch {
                    self.warnServerTTSFailure(error)
                    break
                }
            }
            guard let self, generation == self.conversationGeneration, !Task.isCancelled else { return }
            self.conversationSynthesisTask = nil
            self.voice.sealAudioStream()
        }

        let start = Date()
        var full = ""
        var buffer = ""
        var reasoning = ""
        var toolCalls: [ToolCall] = []
        var stripper = ThinkStripper()
        do {
            for try await event in ChatService.stream(config: config, messages: wire, tools: tools) {
                guard !Task.isCancelled, generation == conversationGeneration, conversationActive else { return }
                switch event {
                case let .delta(chunk):
                    let out = stripper.consume(chunk)
                    reasoning += out.reasoning
                    full += out.visible
                    conversationReplyDraft = full
                    buffer += out.visible
                    while let seg = Self.popSpeakableSegment(&buffer) {
                        let clean = seg.strippedForSpeech
                        if !clean.isEmpty { segCont.yield(clean) }
                    }
                case let .toolCalls(calls):
                    toolCalls = calls
                case let .reasoning(chunk):
                    reasoning += chunk
                default:
                    break
                }
            }
        } catch {
            guard !Task.isCancelled, generation == conversationGeneration else { return }
            trace(convoID, .error, "conversational reply failed: \(error.localizedDescription)")
        }
        guard !Task.isCancelled, generation == conversationGeneration else { return }
        let tail = stripper.finish()
        reasoning += tail.reasoning
        full += tail.visible
        conversationReplyDraft = full
        buffer += tail.visible
        if !reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            trace(convoID, .reasoning, reasoning)
        }
        let rest = buffer.strippedForSpeech
        if !rest.isEmpty { segCont.yield(rest) }
        segCont.finish()
        conversationSegmentContinuation = nil
        if !toolCalls.isEmpty { handleConversationalToolCalls(toolCalls, convoID: convoID) }
        trace(convoID, .finish, "reply in \(Int(Date().timeIntervalSince(start) * 1000))ms, chars=\(full.count)")
        guard conversationActive else { return }
        finishConversationTurn(convoID: convoID, reply: full)
    }

    private func finishConversationTurn(convoID: UUID, reply: String) {
        guard let i = ensureHydratedIndex(convoID) else { return }
        let message = ChatMessage(role: .assistant, content: reply)
        conversations[i].messages.append(message)
        conversationReplyMessageID = message.id
        conversationReplyDraft = ""
        touch(i)
        compressIfNeeded(conversationID: convoID)
        updateMemoryIfNeeded(conversationID: convoID)
        maybeRefineTitle(conversationID: convoID)
    }

    private func markConversationReplyInterrupted(convoID: UUID) {
        guard let i = ensureHydratedIndex(convoID) else { return }
        if let messageID = conversationReplyMessageID,
           let m = conversations[i].messages.firstIndex(where: { $0.id == messageID }) {
            conversations[i].messages[m].interrupted = true
            touch(i)
        } else {
            let partial = conversationReplyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            if !partial.isEmpty {
                conversations[i].messages.append(ChatMessage(role: .assistant, content: partial, interrupted: true))
                touch(i)
            }
        }
        conversationReplyDraft = ""
        conversationReplyMessageID = nil
    }

    /// Pops the next complete sentence from `buffer` (up to `.`/`!`/`?`/`…`/newline followed by
    /// whitespace), or nil if none has finished yet. Keeps segments from being split mid-number.
    private static func popSpeakableSegment(_ buffer: inout String) -> String? {
        let chars = Array(buffer)
        let minLen = 12
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\n" {
                let seg = String(chars[0...i])
                buffer = String(chars[(i + 1)...])
                return seg
            }
            if c == "." || c == "!" || c == "?" || c == "…" {
                let nextIsBreak = i + 1 < chars.count && chars[i + 1].isWhitespace
                if nextIsBreak && (i + 1) >= minLen {
                    let seg = String(chars[0...i])
                    buffer = String(chars[(i + 1)...])
                    return seg
                }
            }
            i += 1
        }
        return nil
    }


    private func speakThenListen(_ text: String, generation: Int) {
        guard conversationActive else { return }
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Nothing to say: hang up now if the model asked to, otherwise keep listening.
        guard !clean.isEmpty else {
            if endConversationRequested { stopConversation() } else { beginListening() }
            return
        }
        voiceState = .speaking
        voice.onFinishSpeaking = { [weak self] in
            guard let self, self.conversationActive, generation == self.conversationGeneration else { return }
            self.voice.onFinishSpeaking = nil
            self.conversationReplyMessageID = nil
            if self.endConversationRequested { self.stopConversation() } else { self.beginListening() }
        }
        speak(clean)
    }



    // MARK: - Long-term memory (structured, auto-updating)

    private var isMemorizing = false
    /// Bullet count of each scope at its last consolidation, to avoid re-consolidating repeatedly.
    private var lastConsolidatedBullets: [String: Int] = [:]

    /// After a completed turn, fold new messages into memory once enough fresh user turns
    /// have accumulated. The extractor itself decides whether anything is worth saving (it
    /// returns no operations when nothing is durable). Escalates to a full consolidation once
    /// the memory has grown large, so it stays deduped and compact without manual effort.
    private func updateMemoryIfNeeded(conversationID: UUID) {
        guard settings.autoMemory, !settings.pauseMemoryWrites, !isMemorizing, !isReflecting,
              let idx = conversationIndex(conversationID) else { return }
        let convo = conversations[idx]
        guard convo.isLanguage != true else { return }   // language chats never feed personal memory
        let start = min(convo.memorizedCount ?? 0, convo.messages.count)
        let fresh = Array(convo.messages[start...])
        let newUserTurns = fresh.filter { $0.role == .user && !$0.content.isEmpty }.count
        guard newUserTurns >= max(1, settings.autoMemoryEvery) else { return }
        let scope = persona(for: convo).memoryScope
        let bullets = memory.bulletCount(in: MemoryStore.globalScope) + memory.bulletCount(in: scope)
        let consolidate = settings.autoConsolidate
            && bullets >= max(10, settings.autoConsolidateThreshold)
            && bullets > (lastConsolidatedBullets[scope] ?? 0)
        runMemoryMaintenance(conversationID: conversationID, messages: fresh, upTo: convo.messages.count, consolidate: consolidate)
    }

    /// Manual "Update Memory": extract durable facts from the whole conversation using the
    /// same safe, additive delta path as the automatic pass (no full rewrite).
    func reflect() {
        guard let convo = selectedConversation, !convo.messages.isEmpty,
              !isReflecting, !isMemorizing else { return }
        runMemoryMaintenance(conversationID: convo.id, messages: convo.messages, upTo: convo.messages.count, consolidate: false)
    }

    /// Manual "Clean Up Memory": a full dedup/reorganize rewrite of the whole memory, backed up
    /// first so it is reversible.
    func consolidateMemory() {
        guard let convo = selectedConversation, !convo.messages.isEmpty,
              !isReflecting, !isMemorizing else { return }
        runMemoryMaintenance(conversationID: convo.id, messages: convo.messages, upTo: convo.messages.count, consolidate: true)
    }

    /// Merge `messages` into the persona's categorized memory files.
    /// Consolidation rewrites the full profile; incremental maintenance applies typed deltas.
    private func runMemoryMaintenance(conversationID: UUID, messages: [ChatMessage], upTo: Int, consolidate: Bool) {
        guard let idx = conversationIndex(conversationID) else { return }
        let persona = persona(for: conversations[idx])
        let personaScope = persona.memoryScope
        let globalScope = MemoryStore.globalScope
        let transcript = messages
            .filter { ($0.role == .user || $0.role == .assistant) && !$0.content.isEmpty }
            .map { "\($0.role == .user ? "USER" : "ASSISTANT"): \($0.content)" }
            .joined(separator: "\n\n")
        guard !transcript.isEmpty else { return }

        let snapshot = MemoryProfile.snapshot(store: memory, global: globalScope, persona: personaScope)
        let beforeMemory = Dictionary(uniqueKeysWithValues: MemoryProfile.contents(store: memory, global: globalScope, persona: personaScope))
        let extra = settings.reflectionCustomPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let assistant = assistantName(for: persona)
        let now = Self.dateContext()
        let instruction = consolidate
            ? MemoryProfile.consolidatePrompt(current: snapshot, transcript: transcript, extra: extra, assistantName: assistant, now: now)
            : MemoryProfile.maintainerPrompt(current: snapshot, transcript: transcript, extra: extra, assistantName: assistant, now: now)
        // Gemma/Qwen-style thinking is wasteful for this mechanical rewrite: disable it and cap output.
        var config = settings.requestConfig(modelOverride: persona.model)
        if settings.disableThinkingForTasks { config.enableThinking = false }
        config.maxTokens = min(config.maxTokens ?? 2000, 2000)

        isReflecting = true
        isMemorizing = true
        trace(conversationID, .memory, consolidate
            ? "consolidating memory (\(personaScope))…"
            : "auto memory: updating (\(personaScope))…")
        Task { [weak self] in
            guard let self else { return }
            defer { self.isReflecting = false; self.isMemorizing = false }
            let result: String?
            do {
                result = try await ChatService.completeStreaming(config: config, messages: [WireMessage(role: Role.user.rawValue, text: instruction)])
            } catch {
                self.trace(conversationID, .error, "\(consolidate ? "memory cleanup" : "auto memory") failed: \(error.localizedDescription)")
                return
            }
            guard let result, !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                self.trace(conversationID, .error, "memory update produced no output (model returned an empty reply)")
                return
            }
            var traceDetail: String?
            var operationSummary = ""
            if consolidate {
                let sections = MemoryProfile.parse(result)
                guard !sections.isEmpty else {
                    self.trace(conversationID, .error, "memory consolidation skipped: could not parse category sections from output")
                    return
                }
                if let backupURL = self.memory.backup(scopes: [globalScope, personaScope]) {
                    self.trace(conversationID, .memory, "backed up memory before cleanup → \(backupURL.lastPathComponent)")
                }
                var lintFixes: [String] = []
                for cat in MemoryCategory.allCases {
                    let target = cat.targetScope(global: globalScope, persona: personaScope)
                    let raw = (sections[cat] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    let clean = MemoryProfile.canonical(raw)
                    if clean.isEmpty {
                        self.memory.delete(scope: target, name: cat.fileName)
                    } else {
                        if clean != raw { lintFixes.append(cat.header) }
                        self.memory.write(scope: target, name: cat.fileName, content: clean)
                    }
                }
                if !lintFixes.isEmpty { operationSummary = "; fixed formatting (\(lintFixes.joined(separator: ", ")))" }
                let afterMemory = Dictionary(uniqueKeysWithValues: MemoryProfile.contents(store: self.memory, global: globalScope, persona: personaScope))
                let changes = MemoryProfile.diff(before: beforeMemory, after: afterMemory)
                traceDetail = changes.isEmpty ? "(no file changes)" : changes
            } else {
                guard let delta = MemoryProfile.parseDelta(result) else {
                    self.trace(conversationID, .error, "memory update skipped: could not parse typed operations from output")
                    return
                }
                let application = MemoryProfile.apply(delta, store: self.memory, global: globalScope, persona: personaScope)
                for (cat, body) in application.changedBodies {
                    let target = cat.targetScope(global: globalScope, persona: personaScope)
                    if body.isEmpty {
                        self.memory.delete(scope: target, name: cat.fileName)
                    } else {
                        self.memory.write(scope: target, name: cat.fileName, content: body)
                    }
                }
                operationSummary = "; \(application.appliedCount) applied, \(application.skippedCount) skipped"
                traceDetail = application.detail
            }
            if let i = self.ensureHydratedIndex(conversationID) {
                self.conversations[i].memorizedCount = min(upTo, self.conversations[i].messages.count)
                self.touch(i)
            }
            if consolidate { self.lastConsolidatedBullets[personaScope] = self.memory.bulletCount(in: globalScope) + self.memory.bulletCount(in: personaScope) }
            let how = consolidate ? "cleaned up" : "updated"
            self.trace(
                conversationID, .memory,
                "\(how) long-term memory (\(personaScope)) from \(messages.count) messages\(operationSummary)",
                detail: traceDetail
            )
        }
    }

    // MARK: - Server info

    func refreshServerInfo() {
        let config = settings.requestConfig(modelOverride: nil)
        Task { [weak self] in
            do {
                let list = try await ChatService.fetchModels(config: config)
                self?.models = list
                self?.connectionOK = true
            } catch {
                self?.connectionOK = false
            }
        }
    }

    func refreshAudioModels() {
        let config = settings.requestConfig(modelOverride: nil)
        Task { [weak self] in
            if let list = try? await ChatService.fetchAudioModels(config: config) {
                self?.audioModels = list
            }
        }
        refreshVoices()
    }

    /// Ask the audio server which voices the current TTS model ships.
    func refreshVoices() {
        let config = settings.requestConfig(modelOverride: nil)
        let model = settings.ttsModel
        guard !model.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        Task { [weak self] in
            if let v = try? await ChatService.fetchVoices(config: config, model: model), !v.isEmpty {
                self?.audioVoices = v
            }
        }
    }

    func scanLocalModels() {
        Task { [weak self] in
            let found = await Task.detached { LocalModels.discover() }.value
            self?.discoveredModels = found
        }
    }

    // MARK: - Managed servers (Runtime)

    /// Start a managed server; auto-point the matching endpoint at it by role.
    func startServer(_ server: ManagedServer) {
        runtime.start(server)
        switch server.role {
        case .chat: pointChat(at: server)
        case .audio: pointAudio(at: server)
        case .embedding: pointEmbedding(at: server)
        case .none: break
        }
    }

    /// Start every managed server (quick start). Adopts anything already alive instead of
    /// relaunching, so it never spawns a duplicate.
    func startAllServers() {
        Task {
            for server in runtime.servers {
                await runtime.ensureRunning(server)
                if server.role == .chat { pointChat(at: server) }
                else if server.role == .audio { pointAudio(at: server) }
                else if server.role == .embedding { pointEmbedding(at: server) }
            }
        }
    }

    func stopAllServers() {
        runtime.stopAll()
    }

    /// Called at launch: start servers flagged autostart. Reconciles first (so an orphan from a
    /// previous session is adopted, not duplicated), then ensures each is running.
    func autostartServers() {
        Task {
            runtime.rescan()
            for server in runtime.servers where server.autostart == true {
                await runtime.ensureRunning(server)
                if server.role == .chat { pointChat(at: server) }
                else if server.role == .audio { pointAudio(at: server) }
                else if server.role == .embedding { pointEmbedding(at: server) }
            }
        }
    }

    private func pointChat(at server: ManagedServer) {
        settings.baseURL = "http://127.0.0.1:\(server.port)"
        settings.apiToken = ""
        refreshServerInfo()
    }

    private func pointAudio(at server: ManagedServer) {
        settings.audioBaseURL = "http://127.0.0.1:\(server.port)"
        refreshAudioModels()
    }

    private func pointEmbedding(at server: ManagedServer) {
        settings.embeddingBaseURL = "http://127.0.0.1:\(server.port)"
    }

    /// Point the chat endpoint at a locally-running managed server.
    func useForChat(_ server: ManagedServer) {
        settings.baseURL = "http://127.0.0.1:\(server.port)"
        settings.apiToken = ""
        refreshServerInfo()
    }

    /// Point the audio (STT/TTS) endpoint at a locally-running managed server.
    func useForAudio(_ server: ManagedServer) {
        settings.audioBaseURL = "http://127.0.0.1:\(server.port)"
        refreshAudioModels()
    }

    /// Point the embeddings endpoint at a locally-running managed server.
    func useForEmbeddings(_ server: ManagedServer) {
        settings.embeddingBaseURL = "http://127.0.0.1:\(server.port)"
    }

    // MARK: - Persona management

    func addPersona() {
        let p = Persona(
            name: "New Persona",
            systemPrompt: "",
            memoryScope: "persona-\(UUID().uuidString.prefix(8))"
        )
        personas.append(p)
        savePersonas()
    }

    func updatePersona(_ persona: Persona) {
        guard let idx = personas.firstIndex(where: { $0.id == persona.id }) else { return }
        personas[idx] = persona
        savePersonas()
    }

    func deletePersona(_ id: UUID) {
        guard personas.count > 1 else { return }
        personas.removeAll { $0.id == id }
        for i in conversations.indices where conversations[i].personaID == id {
            conversations[i].personaID = personas.first?.id
        }
        savePersonas()
    }

    // MARK: - Persistence

    /// Reused across all persistence calls (allocating a coder per write is wasteful).
    private static let jsonEncoder = JSONEncoder()
    private static let jsonDecoder = JSONDecoder()
    private static let isoFormatter = ISO8601DateFormatter()
    /// Serial queue for disk writes: encode on the main actor (correct snapshot), write off-main
    /// in submission order so the UI never stalls on JSON I/O and saves/deletes stay consistent.
    nonisolated private static let ioQueue = DispatchQueue(label: "konishi.persistence", qos: .utility)

    /// Block until all queued writes have flushed (called on app termination).
    nonisolated private static func flushPendingWrites() {
        ioQueue.sync {}
    }

    private func save(_ conversation: Conversation) {
        // Only hydrated conversations hold a real body; skip so we never clobber a file with empties.
        guard hydratedIDs.contains(conversation.id) else { return }
        Self.saveConversation(conversation)
    }

    func savePersonas() {
        guard let data = try? Self.jsonEncoder.encode(personas) else { return }
        Self.ioQueue.async { try? data.write(to: Paths.personasFile, options: .atomic) }
    }

    private static func loadPersonas() -> [Persona] {
        guard let data = try? Data(contentsOf: Paths.personasFile),
              let decoded = try? jsonDecoder.decode([Persona].self, from: data),
              !decoded.isEmpty
        else {
            let defaults = Persona.defaults
            if let data = try? jsonEncoder.encode(defaults) {
                try? data.write(to: Paths.personasFile, options: .atomic)
            }
            return defaults
        }
        return decoded
    }

    /// Load only metadata for every conversation at launch; bodies are paged in on demand.
    private static func loadConversations() -> [Conversation] {
        let urls = ((try? FileManager.default.contentsOfDirectory(
            at: Paths.conversations,
            includingPropertiesForKeys: nil
        )) ?? []).filter { $0.pathExtension == "json" }
        guard !urls.isEmpty else { return [] }
        // Decode files in parallel (per-thread decoder; JSONDecoder isn't safe to share across threads).
        var slots = [Conversation?](repeating: nil, count: urls.count)
        slots.withUnsafeMutableBufferPointer { buffer in
            // Each iteration writes a distinct index, so the distinct-offset writes don't race.
            nonisolated(unsafe) let base = buffer.baseAddress!
            DispatchQueue.concurrentPerform(iterations: urls.count) { i in
                guard let data = try? Data(contentsOf: urls[i]),
                      let meta = try? JSONDecoder().decode(ConversationMeta.self, from: data)
                else { return }
                (base + i).pointee = meta.asConversation()
            }
        }
        return slots.compactMap { $0 }
    }

    /// Read one conversation's full body (messages) from disk.
    private static func loadConversationBody(_ id: UUID) -> Conversation? {
        let url = Paths.conversations.appendingPathComponent("\(id.uuidString).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? jsonDecoder.decode(Conversation.self, from: data)
    }

    /// Off-main content search across all conversation files; returns ids whose body matches.
    nonisolated private static func searchDisk(query q: String) -> Set<UUID> {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: Paths.conversations, includingPropertiesForKeys: nil
        )) ?? []
        let decoder = JSONDecoder()
        var ids: Set<UUID> = []
        for url in urls where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let convo = try? decoder.decode(Conversation.self, from: data) else { continue }
            if convo.messages.contains(where: { $0.content.lowercased().contains(q) }) {
                ids.insert(convo.id)
            }
        }
        return ids
    }

    private static func saveConversation(_ conversation: Conversation) {
        let url = Paths.conversations.appendingPathComponent("\(conversation.id.uuidString).json")
        guard let data = try? jsonEncoder.encode(conversation) else { return }
        ioQueue.async { try? data.write(to: url, options: .atomic) }
    }

    private static func deleteConversationFile(_ id: UUID) {
        let url = Paths.conversations.appendingPathComponent("\(id.uuidString).json")
        // Same serial queue as saves so a delete never races ahead of a queued write for this id.
        ioQueue.async { try? FileManager.default.removeItem(at: url) }
    }

    nonisolated private static func saveTrace(_ id: UUID, _ entries: [TraceEntry]) {
        let url = Paths.traceFile(id)
        if entries.isEmpty { try? FileManager.default.removeItem(at: url); return }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: url, options: .atomic)
    }

    nonisolated private static func loadTrace(_ id: UUID) -> [TraceEntry] {
        let url = Paths.traces.appendingPathComponent("\(id.uuidString).json")
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([TraceEntry].self, from: data)
        else { return [] }
        return decoded
    }

    nonisolated private static func deleteTraceFile(_ id: UUID) {
        let url = Paths.traces.appendingPathComponent("\(id.uuidString).json")
        try? FileManager.default.removeItem(at: url)
    }
}
