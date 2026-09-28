import Foundation

extension AppModel {
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
        conversationEndpointTask?.cancel()
        conversationEndpointTask = nil
        bargeInConfirmationTask?.cancel()
        bargeInConfirmationTask = nil
        cancelBackchannelDecision()
        conversationResponseTask?.cancel()
        conversationResponseTask = nil
        conversationSynthesisTask?.cancel()
        conversationSynthesisTask = nil
        conversationSegmentContinuation?.finish()
        conversationSegmentContinuation = nil
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
        bargeInConfirmationTask?.cancel()
        bargeInConfirmationTask = nil
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
            await Task.yield()  // VoiceManager stops the finalized recognition task after its callback.
            guard let self, self.conversationActive, self.voiceState == .listening,
                self.liveTranscript == prefix, !self.voice.isListening
            else { return }
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
                self.liveTranscript == text
            else { return }
            self.endUserTurn()
        }
    }

    private static func conversationEndpointMilliseconds(text: String, isFinal: Bool) -> Int {
        if isFinal { return 1_800 }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let last = trimmed.last, ".!?…。！？".contains(last) { return 1_800 }
        if let last = trimmed.last, ",;:—-".contains(last) { return 2_500 }
        let finalWord = trimmed.split(whereSeparator: { $0.isWhitespace }).last?.lowercased() ?? ""
        let continuationWords: Set<String> = [
            "and", "but", "because", "or", "so", "then", "if", "when", "um", "uh",
        ]
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
                self.voiceState == .thinking || self.voiceState == .speaking,
                !self.bargeInCandidate.isEmpty
            else { return }
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
                    text:
                        "backchannel classifier unavailable or disabled; using interruption fallback",
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
                self.voiceState == .thinking || self.voiceState == .speaking
            else { return }
            self.bargeInFallbackTask?.cancel()
            self.bargeInFallbackTask = nil
            self.bargeInClassificationTask = nil
            self.bargeInDecisionID = nil
            let elapsed = Int(Date().timeIntervalSince(startedAt) * 1_000)
            let unchanged = self.bargeInCandidate == text
            let isBackchannel = unchanged && isBackchannelAnswer == true
            if isBackchannel {
                if let convoID {
                    traceStore.trace(
                        conversationID: convoID, kind: .info,
                        text:
                            "backchannel classifier (ANE): BACKCHANNEL in \(elapsed)ms; assistant continued",
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
            try? await Task.sleep(
                for: .milliseconds(Self.backchannelClassificationTimeoutMilliseconds))
            guard !Task.isCancelled, let self, self.bargeInDecisionID == decisionID,
                self.conversationGeneration == generation,
                self.conversationActive,
                self.voiceState == .thinking || self.voiceState == .speaking
            else { return }
            self.bargeInDecisionID = nil
            self.bargeInClassificationTask?.cancel()
            self.bargeInClassificationTask = nil
            self.bargeInFallbackTask = nil
            if let convoID {
                traceStore.trace(
                    conversationID: convoID, kind: .info,
                    text:
                        "backchannel classifier (ANE): timed out after 1000ms; treating as interruption",
                    saveTraces: settings.saveTraces)
            }
            self.confirmBargeIn(expectedGeneration: generation, convoID: convoID)
        }
    }

    private func dismissBackchannel() {
        bargeInConfirmationTask?.cancel()
        bargeInConfirmationTask = nil
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
        bargeInClassificationTask?.cancel()
        bargeInClassificationTask = nil
        bargeInFallbackTask?.cancel()
        bargeInFallbackTask = nil
        bargeInDecisionID = nil
    }

    private func confirmBargeIn(expectedGeneration: Int, convoID: UUID?) {
        guard conversationGeneration == expectedGeneration else { return }
        let text = bargeInCandidate
        let isFinal = bargeInCandidateFinal
        guard !text.isEmpty else { return }
        conversationGeneration &+= 1
        conversationResponseTask?.cancel()
        conversationResponseTask = nil
        conversationSynthesisTask?.cancel()
        conversationSynthesisTask = nil
        conversationSegmentContinuation?.finish()
        conversationSegmentContinuation = nil
        conversationEndpointTask?.cancel()
        conversationEndpointTask = nil
        bargeInConfirmationTask?.cancel()
        bargeInConfirmationTask = nil
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
        conversationEndpointTask?.cancel()
        conversationEndpointTask = nil
        let text = liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        voice.stopDictation()
        guard conversationActive else { return }
        guard !text.isEmpty else {
            beginListening()
            return
        }
        liveTranscript = ""
        voiceState = .thinking
        respond(to: text)
    }

    private func respond(to text: String) {
        guard let convoID = conversationSessionID, let idx = conversationIndex(convoID) else {
            return
        }
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
        conversationSegmentContinuation?.finish()
        conversationSegmentContinuation = nil
        conversationReplyDraft = ""
        conversationReplyMessageID = nil

        conversationResponseTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == self.conversationGeneration { self.conversationResponseTask = nil }
            }
            let systemText = personaStore.stableSystemPrompt(
                persona: persona, injectDateContext: settings.injectDateContext, mode: mode,
                vaultConfigured: !settings.vaultPath.isEmpty)
            let memoryText = await self.memoryContext(
                conversationID: convoID, persona: persona, history: history)
            let documentText = await self.documentContext(conversationID: convoID, history: history)
            let vaultText = await self.vaultContext(
                conversationID: convoID, persona: persona, history: history)
            guard !Task.isCancelled, generation == self.conversationGeneration,
                self.conversationActive
            else { return }
            let wire = self.buildWire(
                systemText: systemText, summary: summary, memoryText: memoryText,
                documentText: documentText, vaultText: vaultText, history: history)
            // The voice-only hang-up tool is offered on every conversational turn.
            let tools = [Tools.endConversationDef]
            traceStore.trace(
                conversationID: convoID, kind: .request,
                text: self.requestSummary(
                    config: config, wire: wire, tools: tools, memory: memoryText, summary: summary),
                saveTraces: settings.saveTraces,
                detail: self.requestDetail(wire: wire))
            // Server TTS streams sentence-by-sentence so speech starts before the whole reply lands;
            // native TTS still speaks the completed reply.
            if self.settings.ttsSource == .server {
                await self.respondStreamingServerTTS(
                    convoID: convoID, config: config, wire: wire, tools: tools,
                    generation: generation)
            } else {
                await self.respondBuffered(
                    convoID: convoID, config: config, wire: wire, tools: tools,
                    generation: generation)
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
        bargeInConfirmationTask?.cancel()
        bargeInConfirmationTask = nil
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

    private func respondBuffered(
        convoID: UUID, config: RequestConfig, wire: [WireMessage], tools: [ToolDef], generation: Int
    ) async {
        let start = Date()
        var reply = ""
        var reasoning = ""
        var toolCalls: [ToolCall] = []
        var stripper = ThinkStripper()
        do {
            for try await event in ChatService.stream(config: config, messages: wire, tools: tools)
            {
                guard !Task.isCancelled, generation == conversationGeneration, conversationActive
                else { return }
                switch event {
                case .delta(let chunk):
                    let out = stripper.consume(chunk)
                    reply += out.visible
                    reasoning += out.reasoning
                    conversationReplyDraft = reply
                case .reasoning(let chunk): reasoning += chunk
                case .toolCalls(let calls): toolCalls = calls
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
    private func respondStreamingServerTTS(
        convoID: UUID, config: RequestConfig, wire: [WireMessage], tools: [ToolDef], generation: Int
    ) async {
        guard conversationActive else { return }
        // Stay in .thinking until the first audio clip is ready; only then flip to .speaking,
        // so the orb reflects the real (often long) generation time instead of jumping to green.
        voice.beginAudioStream()
        voice.onFinishSpeaking = { [weak self] in
            guard let self, self.conversationActive, generation == self.conversationGeneration
            else { return }
            self.voice.onFinishSpeaking = nil
            self.conversationReplyMessageID = nil
            // The model asked to hang up: stop after the farewell finishes playing.
            if self.endConversationRequested {
                self.stopConversation()
            } else {
                self.beginListening()
            }
        }

        let ttsConfig = settings.requestConfig(modelOverride: nil)
        let (segments, segCont) = AsyncStream.makeStream(of: String.self)
        conversationSegmentContinuation = segCont
        // Synthesize segments serially so clips are enqueued in spoken order.
        conversationSynthesisTask = Task { [weak self] in
            var started = false
            for await seg in segments {
                guard let self, self.conversationActive, generation == self.conversationGeneration,
                    !Task.isCancelled
                else { break }
                do {
                    let data = try await ChatService.speech(config: ttsConfig, text: seg)
                    guard generation == self.conversationGeneration, !Task.isCancelled else {
                        break
                    }
                    self.warnedServerTTSFailure = false
                    if !started {
                        started = true
                        self.voiceState = .speaking
                    }
                    self.voice.enqueueAudioData(data)
                } catch {
                    self.warnServerTTSFailure(error)
                    break
                }
            }
            guard let self, generation == self.conversationGeneration, !Task.isCancelled else {
                return
            }
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
            for try await event in ChatService.stream(config: config, messages: wire, tools: tools)
            {
                guard !Task.isCancelled, generation == conversationGeneration, conversationActive
                else { return }
                switch event {
                case .delta(let chunk):
                    let out = stripper.consume(chunk)
                    reasoning += out.reasoning
                    full += out.visible
                    conversationReplyDraft = full
                    buffer += out.visible
                    while let seg = Self.popSpeakableSegment(&buffer) {
                        let clean = seg.strippedForSpeech
                        if !clean.isEmpty { segCont.yield(clean) }
                    }
                case .toolCalls(let calls):
                    toolCalls = calls
                case .reasoning(let chunk):
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
            let m = conversations[i].messages.firstIndex(where: { $0.id == messageID })
        {
            conversations[i].messages[m].interrupted = true
            touch(i)
        } else {
            let partial = conversationReplyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            if !partial.isEmpty {
                conversations[i].messages.append(
                    ChatMessage(role: .assistant, content: partial, interrupted: true))
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
            guard let self, self.conversationActive, generation == self.conversationGeneration
            else { return }
            self.voice.onFinishSpeaking = nil
            self.conversationReplyMessageID = nil
            if self.endConversationRequested {
                self.stopConversation()
            } else {
                self.beginListening()
            }
        }
        speak(clean)
    }
}
