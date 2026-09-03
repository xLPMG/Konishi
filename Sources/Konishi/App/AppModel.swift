import SwiftUI
import Observation
import AppKit

@Observable
@MainActor
final class AppModel {
    // Persisted state
    var settings: AppSettings
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

    // Server info
    var models: [ModelInfo] = []
    var audioModels: [ModelInfo] = []
    var audioVoices: [String] = []
    var connectionOK: Bool?
    var discoveredModels: [LocalModels.Entry] = []

    let memoryStore = MemoryStore()
    let fileStore = FileStore()
    let documentStore = DocumentStore()
    let personaStore = PersonaStore()
    let runtime = Runtime()
    let voice = VoiceManager()
    let embeddingCache = EmbeddingCache()
    let languageStore = LanguageStore()
    let traceStore = TraceStore()
    var streamTask: Task<Void, Never>?
    /// Resumed with the tool result once the user answers a pending multiple-choice prompt.
    var interactionContinuation: CheckedContinuation<String, Never>?

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
        self.conversations = Self.loadConversations().sorted { $0.updatedAt > $1.updatedAt }
        self.languageProfiles = languageStore.allProfiles()
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

    var currentPersona: Persona { personaStore.persona(for: selectedConversation) }

    var currentAssistantName: String { personaStore.assistantName(for: currentPersona) }

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

    // MARK: - Trace

    var currentTrace: [TraceEntry] {
        selectedConversationID.flatMap { traceStore.traces[$0] } ?? []
    }

    func requestSummary(config: RequestConfig, wire: [WireMessage], tools: [ToolDef]?, memory: String, summary: String) -> String {
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
    func requestDetail(wire: [WireMessage]) -> String {
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

    func touch(_ idx: Int) {
        conversations[idx].updatedAt = .now
        ensureHydrated(conversations[idx].id)   // never persist an evicted (empty) body over the file
        save(conversations[idx])
    }

    // MARK: - Sending & streaming

    var canSend: Bool {
        (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draftImages.isEmpty || !draftAttachments.isEmpty) && !isStreaming
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
    private var ttsPending = ""
    private var ttsMessageID: UUID?
    private static let sentenceTerminators: Set<Character> = [".", "!", "?", "。", "！", "？", "…", "\n"]
    /// Serial server-TTS pipeline for streamed chat replies: sentences synthesized in order.
    private var speechSegCont: AsyncStream<String>.Continuation?
    private var speechSynthTask: Task<Void, Never>?
    /// True once we've surfaced a server-TTS failure this session, so we don't nag on every reply.
    /// Reset when TTS succeeds again or the audio endpoint/source changes.
    private var warnedServerTTSFailure = false

    private var nativeTTS: Bool { mode == .language || settings.ttsSource == .native }

    /// Speaks newly-completed sentences as the reply streams in (native and server TTS), so speech
    /// starts almost immediately instead of waiting for the whole message. Only the unspoken tail
    /// is scanned (via `ttsPending`), not the whole growing message.
    func streamSpeak(delta: String, assistantID: UUID) {
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
    func emitFinalSpeech(assistantID: UUID, content: String) {
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
    func resetSpeech() {
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

    // MARK: - Tool approval & execution

    /// Signatures (name+args) of tool calls in the current user turn, for dedupe + loop detection.
    var loopSignatures: [String] = []
    /// Web sources (search results / fetched pages) gathered this turn, attached to the reply.
    var turnSources: [Source] = []
    /// Read-only tools whose identical repeat within a turn can be skipped safely.
    static let readOnlyTools: Set<String> = [
        "memory_list", "memory_read", "file_read", "list_dir",
        "git_status", "git_diff", "git_log", "web_search", "web_fetch", "web_research",
        "search_deck", "get_due_items", "calculate"
    ]
    /// Tools whose OUTPUT the model must read to finish its reply, so a continuation turn is warranted.
    /// After fire-and-forget writes (e.g. banking a card) with a written reply, the turn is complete.
    static let continuationTools: Set<String> = [
        "get_due_items", "search_deck", "web_search", "web_fetch", "web_research", "file_read",
        "memory_list", "memory_read", "calculate", "python_exec", "ask_multiple_choice"
    ]

    /// How many trailing tool results are kept verbatim in the wire; older ones are stubbed.
    static let maxFullToolResults = 4

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
        languageProfiles = languageStore.allProfiles()
    }

    func saveLanguageProfile(_ profile: LanguageProfile, makeActive: Bool = false) {
        languageStore.upsertProfile(profile)
        reloadLanguageProfiles()
        if makeActive || settings.activeLanguageProfileID.isEmpty {
            settings.activeLanguageProfileID = profile.id.uuidString
        }
    }

    func deleteLanguageProfile(_ id: UUID) {
        languageStore.deleteProfile(id: id)
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
    func languageSystemPrompt(persona: Persona) -> String {
        var lines: [String] = []
        if let name = persona.assistantName?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
            lines.append("Your name is \(name).")
        }

        guard let p = activeLanguageProfile else {
            lines.append("You are a friendly, patient language tutor. No language profile is set up yet — ask the user which language they want to learn, their native language, and their rough level, then help them get started.")
            if settings.injectDateContext {
                lines.append("For context, it is currently \(DateContext.current()).")
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
            lines.append("For context, it is currently \(DateContext.current()).")
        }
        return lines.joined(separator: "\n\n")
    }

    /// Applies a Leitner review to a card and returns a short status for the model.
    func recordDeckReview(itemID: UUID, correct: Bool) -> String {
        guard var item = languageStore.item(id: itemID) else { return "Error: card not found" }
        item.recordReview(correct: correct)
        languageStore.upsert(item)
        languageDeckRevision &+= 1
        return "\(item.term): \(correct ? "correct" : "wrong"), now box \(item.box)/\(LearnItem.boxCount), due \(Self.dueString(item.dueDate))."
    }

    /// Adds a card to the active profile's deck (used by the add_vocab/add_grammar tools).
    func addDeckCard(_ item: LearnItem) {
        languageStore.upsert(item)
        languageDeckRevision &+= 1
    }

    /// Deletes a card from the deck.
    func deleteDeckItem(_ id: UUID) {
        languageStore.delete(id: id)
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
        let (s, tags) = languageStore.deckSummary(profileID: p.id)
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

    static func parseMCQuestions(_ raw: [ToolArguments.MultipleChoice.Question]) -> [MCQuestion] {
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

    /// Dynamic memory for this turn (attached to the latest user message, not the system prompt).
    func memoryContext(conversationID: UUID, persona: Persona, history: [ChatMessage]) async -> String {
        // Language sessions get a compact deck summary instead of personal memory (the deck is the memory).
        if isLanguageConversation(conversationID) { return languageDeckContext() }
        guard settings.injectMemory else { return "" }
        let scopes = [MemoryStore.globalScope, persona.memoryScope]
        let query = history.last(where: { $0.role == .user })?.content ?? ""
        return await retrieveMemory(conversationID: conversationID, scopes: scopes, query: query)
    }

    private struct ScoredMemoryChunk {
        // label is the memory chunk's identifier (scope/file), text is the content of the chunk.
        let chunk: (label: String, text: String)
        let score: Double
        let semanticScore: Double?
        let lexicalScore: Double
        let rawLexicalScore: Double
    }

    /// Injects the user's identity (global profile) in full plus the top-K bullets most relevant
    /// to the current query, so memory can grow large without flooding the context.  When an
    /// embeddings endpoint is available, lexical BM25 and semantic similarity are combined;
    /// otherwise BM25 remains a useful fully-local fallback.
    private func retrieveMemory(conversationID: UUID, scopes: [String], query: String) async -> String {
        let profileName = MemoryCategory.profile.fileName
        let profileScope = MemoryStore.globalScope
        let profileURL = Paths.memoryScope(profileScope).appendingPathComponent(profileName)
        let profileBody = memoryStore.read(MemoryStore.File(scope: profileScope, name: profileName, url: profileURL))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var sections: [String] = []
        if !profileBody.isEmpty { sections.append("## \(profileScope)/\(profileName)\n\(profileBody)") }

        // Every other bullet is a retrieval candidate.
        var chunks: [(label: String, text: String)] = []
        for scope in scopes {
            for file in memoryStore.files(in: scope) {
                if scope == profileScope, file.name == profileName { continue }
                for block in MemoryStore.blocks(memoryStore.read(file)) {
                    chunks.append((label: "\(scope)/\(file.name)", text: block))
                }
            }
        }
        guard !chunks.isEmpty, !query.isEmpty else { return sections.joined(separator: "\n\n") }
        let rawLexicalScores = MemoryRetrieval.bm25(query: query, documents: chunks.map(\.text))
        let lexicalScores = rawLexicalScores.map(MemoryRetrieval.boundedBM25)
        do {
            let (q, blockEmb) = try await embedWithCache(query: query, blocks: chunks.map(\.text), model: settings.embeddingModel)
            let semanticScores = blockEmb.map { (Self.cosine(q, $0) + 1.0) / 2.0 } // map cosine to [0, 1] range for comparison with BM25
            let scored = chunks.indices
                .map { index in
                    ScoredMemoryChunk(
                        chunk: chunks[index],
                        score: 0.7 * semanticScores[index] + 0.3 * lexicalScores[index],
                        semanticScore: semanticScores[index],
                        lexicalScore: lexicalScores[index],
                        rawLexicalScore: rawLexicalScores[index]
                    )
                }
                .filter { $0.score >= settings.memoryThreshold }
                .sorted { $0.score > $1.score }
                .prefix(max(1, settings.memoryTopK))
            appendMemorySections(Array(scored), to: &sections)
            traceStore.trace(
                conversationID: conversationID, kind: .memory,
                text: "memory retrieval: \(scored.count)/\(chunks.count) bullets ≥ \(String(format: "%.2f", settings.memoryThreshold)) injected",
                saveTraces: settings.saveTraces,
                detail: memoryRetrievalTraceDetail(Array(scored))
            )
        } catch {
            // An embeddings server is optional: retain targeted lexical retrieval when it is down.
            let scored = chunks.indices
                .map { index in
                    ScoredMemoryChunk(
                        chunk: chunks[index],
                        score: lexicalScores[index],
                        semanticScore: nil,
                        lexicalScore: lexicalScores[index],
                        rawLexicalScore: rawLexicalScores[index]
                    )
                }
                .filter { $0.score >= 0.2 } // magic number :)
                .sorted { $0.score > $1.score }
                .prefix(max(1, settings.memoryTopK))
            appendMemorySections(Array(scored), to: &sections)
            traceStore.trace(
                conversationID: conversationID, kind: .error,
                text: "memory embedding retrieval failed; BM25 fallback injected \(scored.count)/\(chunks.count) bullets: \(Self.embedErrorHint(error))",
                saveTraces: settings.saveTraces,
                detail: memoryRetrievalTraceDetail(Array(scored))
            )
        }
        return sections.joined(separator: "\n\n")
    }

    /// Group selected bullets by source file, preserving score order between files.
    private func appendMemorySections(_ scored: [ScoredMemoryChunk], to sections: inout [String]) {
        var order: [String] = []
        var byLabel: [String: [String]] = [:]
        for item in scored {
            if byLabel[item.chunk.label] == nil { order.append(item.chunk.label) }
            byLabel[item.chunk.label, default: []].append(item.chunk.text)
        }
        sections.append(contentsOf: order.map { "## \($0)\n\((byLabel[$0] ?? []).joined(separator: "\n"))" })
    }

    /// Trace details for the exact bullets injected this turn, in retrieval order.
    private func memoryRetrievalTraceDetail(_ scored: [ScoredMemoryChunk]) -> String {
        guard !scored.isEmpty else { return "No memory bullets met the retrieval criteria." }
        return scored.enumerated().map { rank, item in
            let scores: String
            if let semantic = item.semanticScore {
                scores = "hybrid \(String(format: "%.3f", item.score))  semantic \(String(format: "%.3f", semantic))  BM25 \(String(format: "%.3f", item.lexicalScore)) (raw \(String(format: "%.3f", item.rawLexicalScore)))"
            } else {
                scores = "BM25 \(String(format: "%.3f", item.score)) (raw \(String(format: "%.3f", item.rawLexicalScore)))"
            }
            return "\(rank + 1). \(scores)\n   \(item.chunk.label)\n   \(item.chunk.text)"
        }.joined(separator: "\n\n")
    }

    /// Describes an embedding failure, hinting at the common cause (server has no embeddings endpoint).
    static func embedErrorHint(_ error: Error) -> String {
        "\(error.localizedDescription) — needs a chat server exposing /v1/embeddings with an embedding model loaded"
    }

    // MARK: - Documents (RAG for large attachments)

    /// Indexed documents for the current conversation.
    var indexedDocuments: [StoredDocument] {
        selectedConversationID.map { documentStore.documents(for: $0) } ?? []
    }

    /// Inline small attachments; index large ones for retrieval. Returns true when indexed as RAG.
    @discardableResult
    func addDocument(name: String, text: String) -> Bool {
        if settings.ragThresholdChars > 0, text.count > settings.ragThresholdChars,
           let convoID = selectedConversationID {
            documentStore.add(name: name, text: text, conversationID: convoID)
            return true
        }
        draftAttachments.append(Attachment(name: name, text: text))
        return false
    }

    func removeIndexedDocument(_ id: UUID) {
        guard let convoID = selectedConversationID else { return }
        documentStore.delete(id: id, conversationID: convoID)
    }

    /// Retrieve the most relevant passages from this conversation's indexed documentStore.
    func documentContext(conversationID: UUID, history: [ChatMessage]) async -> String {
        let docs = documentStore.documents(for: conversationID)
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
            traceStore.trace(
                conversationID: conversationID, kind: .error,
                text: "document retrieval failed: \(Self.embedErrorHint(error))",
                saveTraces: settings.saveTraces)
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

    // MARK: - Compression

    var isCompressing = false

    // MARK: - Auto-title

    /// Conversations whose title is auto-generated (not user-renamed), so it may be refined.
    var autoTitledIDs: Set<UUID> = []

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
                traceStore.trace(
                    conversationID: convoID, kind: .info,
                    text: "backchannel classifier unavailable or disabled; using interruption fallback",
                    saveTraces: settings.saveTraces)
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
                    traceStore.trace(
                        conversationID: convoID, kind: .info,
                        text: "backchannel classifier (ANE): BACKCHANNEL in \(elapsed)ms; assistant continued",
                        saveTraces: settings.saveTraces)
                }
                self.dismissBackchannel()
            } else {
                if let convoID {
                    let outcome = unchanged ? "INTERRUPT" : "transcript changed"
                    traceStore.trace(
                        conversationID: convoID, kind: .info,
                        text: "backchannel classifier (ANE): \(outcome) in \(elapsed)ms",
                        saveTraces: settings.saveTraces)
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
                traceStore.trace(
                    conversationID: convoID, kind: .info,
                    text: "backchannel classifier (ANE): timed out after 1000ms; treating as interruption",
                    saveTraces: settings.saveTraces)
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
            traceStore.trace(
                conversationID: convoID, kind: .info,
                text: "barge-in detected; cancelled reply and resumed listening",
                saveTraces: settings.saveTraces)
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
        let persona = personaStore.persona(for: conversations[idx])
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
            let systemText = personaStore.stableSystemPrompt(persona: persona, injectDateContext: settings.injectDateContext, mode: mode)
            let memoryText = await self.memoryContext(conversationID: convoID, persona: persona, history: history)
            let documentText = await self.documentContext(conversationID: convoID, history: history)
            guard !Task.isCancelled, generation == self.conversationGeneration, self.conversationActive else { return }
            let wire = self.buildWire(systemText: systemText, summary: summary, memoryText: memoryText, documentText: documentText, history: history)
            // The voice-only hang-up tool is offered on every conversational turn.
            let tools = [Tools.endConversationDef]
            traceStore.trace(
                conversationID: convoID, kind: .request,
                text: self.requestSummary(config: config, wire: wire, tools: tools, memory: memoryText, summary: summary),
                saveTraces: settings.saveTraces,
                detail: self.requestDetail(wire: wire))
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
            traceStore.trace(
                conversationID: convoID, kind: .tool,
                text: "end_conversation() — hanging up after this reply",
                saveTraces: settings.saveTraces)
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
            traceStore.trace(
                conversationID: convoID, kind: .error,
                text: "conversational reply failed: \(error.localizedDescription)",
                saveTraces: settings.saveTraces)
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
            traceStore.trace(
                conversationID: convoID, kind: .reasoning,
                text: reasoning,
                saveTraces: settings.saveTraces)
        }
        if !toolCalls.isEmpty { handleConversationalToolCalls(toolCalls, convoID: convoID) }
        traceStore.trace(
            conversationID: convoID, kind: .finish,
            text: "reply in \(Int(Date().timeIntervalSince(start) * 1000))ms, chars=\(reply.count)",
            saveTraces: settings.saveTraces)
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
            traceStore.trace(
                conversationID: convoID, kind: .error,
                text: "conversational reply failed: \(error.localizedDescription)",
                saveTraces: settings.saveTraces)
        }
        guard !Task.isCancelled, generation == conversationGeneration else { return }
        let tail = stripper.finish()
        reasoning += tail.reasoning
        full += tail.visible
        conversationReplyDraft = full
        buffer += tail.visible
        if !reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            traceStore.trace(
                conversationID: convoID, kind: .reasoning,
                text: reasoning,
                saveTraces: settings.saveTraces)
        }
        let rest = buffer.strippedForSpeech
        if !rest.isEmpty { segCont.yield(rest) }
        segCont.finish()
        conversationSegmentContinuation = nil
        if !toolCalls.isEmpty { handleConversationalToolCalls(toolCalls, convoID: convoID) }
        traceStore.trace(
            conversationID: convoID, kind: .finish,
            text: "reply in \(Int(Date().timeIntervalSince(start) * 1000))ms, chars=\(full.count)",
            saveTraces: settings.saveTraces)
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
    func updateMemoryIfNeeded(conversationID: UUID) {
        guard settings.autoMemory, !settings.pauseMemoryWrites, !isMemorizing, !isReflecting,
              let idx = conversationIndex(conversationID) else { return }
        let convo = conversations[idx]
        guard convo.isLanguage != true else { return }   // language chats never feed personal memory
        let start = min(convo.memorizedCount ?? 0, convo.messages.count)
        let fresh = Array(convo.messages[start...])
        let newUserTurns = fresh.filter { $0.role == .user && !$0.content.isEmpty }.count
        guard newUserTurns >= max(1, settings.autoMemoryEvery) else { return }
        let scope = personaStore.persona(for: convo).memoryScope
        let bullets = memoryStore.bulletCount(in: MemoryStore.globalScope) + memoryStore.bulletCount(in: scope)
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
        let persona = personaStore.persona(for: conversations[idx])
        let personaScope = persona.memoryScope
        let globalScope = MemoryStore.globalScope
        let transcript = messages
            .filter { ($0.role == .user || $0.role == .assistant) && !$0.content.isEmpty }
            .map { "\($0.role == .user ? "USER" : "ASSISTANT"): \($0.content)" }
            .joined(separator: "\n\n")
        guard !transcript.isEmpty else { return }

        let snapshot = MemoryProfile.snapshot(store: memoryStore, global: globalScope, persona: personaScope)
        let beforeMemory = Dictionary(uniqueKeysWithValues: MemoryProfile.contents(store: memoryStore, global: globalScope, persona: personaScope))
        let extra = settings.reflectionCustomPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let assistant = personaStore.assistantName(for: persona)
        let now = DateContext.current()
        let instruction = consolidate
            ? MemoryProfile.consolidatePrompt(current: snapshot, transcript: transcript, extra: extra, assistantName: assistant, now: now)
            : MemoryProfile.maintainerPrompt(current: snapshot, transcript: transcript, extra: extra, assistantName: assistant, now: now)
        // Gemma/Qwen-style thinking is wasteful for this mechanical rewrite: disable it and cap output.
        var config = settings.requestConfig(modelOverride: persona.model)
        if settings.disableThinkingForTasks { config.enableThinking = false }
        config.maxTokens = min(config.maxTokens ?? 2000, 2000)

        isReflecting = true
        isMemorizing = true
        traceStore.trace(
            conversationID: conversationID, kind: .memory,
            text: consolidate
                ? "consolidating memory (\(personaScope))…"
                : "auto memory: updating (\(personaScope))…",
            saveTraces: settings.saveTraces)
        Task { [weak self] in
            guard let self else { return }
            defer { self.isReflecting = false; self.isMemorizing = false }
            let result: String?
            do {
                result = try await ChatService.completeStreaming(config: config, messages: [WireMessage(role: Role.user.rawValue, text: instruction)])
            } catch {
                traceStore.trace(
                    conversationID: conversationID, kind: .error,
                    text: "\(consolidate ? "memory cleanup" : "auto memory") failed: \(error.localizedDescription)",
                    saveTraces: settings.saveTraces)
                return
            }
            guard let result, !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                traceStore.trace(
                    conversationID: conversationID, kind: .error,
                    text: "memory update produced no output (model returned an empty reply)",
                    saveTraces: settings.saveTraces)
                return
            }
            var traceDetail: String?
            var operationSummary = ""
            if consolidate {
                let sections = MemoryProfile.parse(result)
                guard !sections.isEmpty else {
                    traceStore.trace(
                        conversationID: conversationID, kind: .error,
                        text: "memory consolidation skipped: could not parse category sections from output",
                        saveTraces: settings.saveTraces)
                    return
                }
                if let backupURL = self.memoryStore.backup(scopes: [globalScope, personaScope]) {
                    traceStore.trace(
                        conversationID: conversationID, kind: .memory,
                        text: "backed up memory before cleanup → \(backupURL.lastPathComponent)",
                        saveTraces: settings.saveTraces)
                }
                var lintFixes: [String] = []
                for cat in MemoryCategory.allCases {
                    let target = cat.targetScope(global: globalScope, persona: personaScope)
                    let raw = (sections[cat] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    let clean = MemoryProfile.canonical(raw)
                    if clean.isEmpty {
                        self.memoryStore.delete(scope: target, name: cat.fileName)
                    } else {
                        if clean != raw { lintFixes.append(cat.header) }
                        self.memoryStore.write(scope: target, name: cat.fileName, content: clean)
                    }
                }
                if !lintFixes.isEmpty { operationSummary = "; fixed formatting (\(lintFixes.joined(separator: ", ")))" }
                let afterMemory = Dictionary(uniqueKeysWithValues: MemoryProfile.contents(store: self.memoryStore, global: globalScope, persona: personaScope))
                let changes = MemoryProfile.diff(before: beforeMemory, after: afterMemory)
                traceDetail = changes.isEmpty ? "(no file changes)" : changes
            } else {
                guard let delta = MemoryProfile.parseDelta(result) else {
                    traceStore.trace(
                        conversationID: conversationID, kind: .error,
                        text: "memory update skipped: could not parse typed operations from output",
                        saveTraces: settings.saveTraces)
                    return
                }
                let application = MemoryProfile.apply(delta, store: self.memoryStore, global: globalScope, persona: personaScope)
                for (cat, body) in application.changedBodies {
                    let target = cat.targetScope(global: globalScope, persona: personaScope)
                    if body.isEmpty {
                        self.memoryStore.delete(scope: target, name: cat.fileName)
                    } else {
                        self.memoryStore.write(scope: target, name: cat.fileName, content: body)
                    }
                }
                operationSummary = "; \(application.appliedCount) applied, \(application.skippedCount) skipped"
                traceDetail = application.detail
            }
            if let i = self.ensureHydratedIndex(conversationID) {
                self.conversations[i].memorizedCount = min(upTo, self.conversations[i].messages.count)
                self.touch(i)
            }
            if consolidate { self.lastConsolidatedBullets[personaScope] = self.memoryStore.bulletCount(in: globalScope) + self.memoryStore.bulletCount(in: personaScope) }
            let how = consolidate ? "cleaned up" : "updated"
            traceStore.trace(
                conversationID: conversationID, kind: .memory,
                text: "\(how) long-term memory (\(personaScope)) from \(messages.count) messages\(operationSummary)",
                saveTraces: settings.saveTraces,
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

    func deletePersona(_ id: UUID) {
        guard let fallback = personaStore.deletePersona(id) else { return }
        let affectedConversationIDs = conversations.compactMap { conversation in
            conversation.personaID == id ? conversation.id : nil
        }
        for conversationID in affectedConversationIDs {
            ensureHydrated(conversationID)
            guard let index = conversationIndex(conversationID) else { continue }
            conversations[index].personaID = fallback
            save(conversations[index])
        }
    }
}
