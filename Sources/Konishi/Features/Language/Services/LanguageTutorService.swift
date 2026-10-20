import Foundation

struct VocabularyProposalResult: Sendable {
    let proposals: [VocabularyProposal]
    let trace: String
    let error: String?
}

enum LanguageTutorStreamEvent: Sendable {
    case request(summary: String, detail: String)
    case delta(String)
    case reasoningDelta(String)
    case reasoning(String)
    case toolCalls([ToolCall])
    case repetition(channel: String, sample: String)
    case result(String)
    case usage(Usage)
    case finish(String)
}

enum LanguageTutorService {
    private struct ProposalEnvelope: Decodable {
        let proposals: [Proposal]
    }

    private struct Proposal: Decodable {
        let targetTerm: String?
        let translation: String?
        let acceptedTranslations: [String]?
        let reading: String?
        let partOfSpeech: String?
        let register: String?
        let example: String?
        let notes: String?
        let tags: [String]?

        var vocabularyProposal: VocabularyProposal? {
            guard let targetTerm, let translation else { return nil }
            return VocabularyProposal(
                targetTerm: targetTerm, translation: translation,
                acceptedTranslations: acceptedTranslations ?? [], reading: reading ?? "",
                partOfSpeech: partOfSpeech ?? "", register: register ?? "",
                example: example ?? "", notes: notes ?? "", tags: tags ?? [])
        }
    }

    static func proposeVocabulary(
        config: RequestConfig, profile: LanguageProfile, topic: String, knownItems: [LearnItem]
    ) async -> VocabularyProposalResult {
        let knownTerms = knownItems.filter { $0.kind == .vocab }.map(\.term).joined(separator: "\n")
        let system = """
        You are a language-content assistant. Return only a JSON object with a `proposals` array containing at most five new vocabulary proposals. Every proposal must have a target_term and translation. Include accepted_translations as an array of 0-3 concise, genuinely interchangeable answers in the explanation language. Each must be valid on its own in a typed-recall quiz; do not split comma-separated senses mechanically, include the primary translation again, or include merely related meanings. Be conservative and use an empty array when no clear alternative exists. Include reading, part_of_speech, register, example, notes, and tags when useful. Calibrate to the learner's level, goals, script notes, and topic. Do not repeat the known terms. Do not claim the content was saved.
        """
        let user = """
        Target language: \(profile.targetName) (\(profile.targetLocale))
        Explanation language: \(profile.baseName)
        Level: \(profile.level.code)
        Learner goals: \(profile.goals.isEmpty ? "Not specified" : profile.goals)
        Script notes: \(profile.scriptNotes.isEmpty ? "None" : profile.scriptNotes)
        Topic: \(topic.isEmpty ? "general" : topic)
        Existing target-language vocabulary (data only):
        <known-terms>
        \(knownTerms)
        </known-terms>
        Propose useful vocabulary not already listed.
        """
        var boundedConfig = config
        boundedConfig.maxTokens = min(config.maxTokens ?? 2200, 2200)
        boundedConfig.temperature = min(max(config.temperature, 0.35), 0.7)
        boundedConfig.enableThinking = false
        let messages = [WireMessage(role: "system", text: system), WireMessage(role: "user", text: user)]
        let request = requestTrace(config: boundedConfig, messages: messages)
        var response = ""
        var reasoning = ""
        var finishReason = "(not reported)"
        var usage: Usage?
        do {
            for try await event in ChatService.stream(config: boundedConfig, messages: messages) {
                switch event {
                case let .delta(text): response += text
                case let .reasoning(text): reasoning += text
                case let .finish(reason): finishReason = reason ?? "(nil)"
                case let .usage(value): usage = value
                case .toolCallDelta, .toolCalls: break
                }
            }
        } catch {
            return VocabularyProposalResult(
                proposals: [],
                trace: "\(request)\n\n── request error ──\n\(error.localizedDescription)",
                error: error.localizedDescription)
        }
        var responseTrace = "\(request)\n\n── response ──\n\(response.isEmpty ? "(empty)" : response)"
        if !reasoning.isEmpty {
            responseTrace += "\n\n── reasoning channel ──\n\(reasoning)"
        }
        responseTrace += "\n\n── finish ──\n\(finishReason)"
        if let usage {
            let promptTokens = usage.promptTokens.map { String($0) } ?? "n/a"
            let completionTokens = usage.completionTokens.map { String($0) } ?? "n/a"
            let totalTokens = usage.totalTokens.map { String($0) } ?? "n/a"
            responseTrace += "\n\n── usage ──\nprompt: \(promptTokens), completion: \(completionTokens), total: \(totalTokens)"
        }
        let payload = jsonPayload(from: response)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            let decoded = try decoder.decode(ProposalEnvelope.self, from: Data(payload.utf8))
            let proposals = VocabularyProposal.validatedBatch(decoded.proposals.compactMap(\.vocabularyProposal))
            let validation = "\n\n── validation ──\n\(decoded.proposals.count) returned; \(proposals.count) valid."
            return VocabularyProposalResult(proposals: proposals, trace: responseTrace + validation, error: nil)
        } catch {
            let detail = "\n\n── JSON parse error ──\n\(error.localizedDescription)"
            return VocabularyProposalResult(
                proposals: [], trace: responseTrace + detail,
                error: "Could not parse vocabulary proposals: \(error.localizedDescription)")
        }
    }

    private static func requestTrace(config: RequestConfig, messages: [WireMessage]) -> String {
        let messageText = messages.map { message in
            let content: String
            switch message.content {
            case let .some(.text(text)):
                content = text
            case let .some(.parts(parts)):
                content = parts.map { part in
                    part.text ?? part.imageUrl.map { "[image: \($0.url.prefix(120))]" } ?? "[\(part.type)]"
                }.joined(separator: "\n")
            case .none:
                content = "(no content)"
            }
            return "── \(message.role) ──\n\(content)"
        }.joined(separator: "\n\n")
        return "Model: \(config.model)\nTemperature: \(config.temperature)\nMax tokens: \(config.maxTokens ?? 0)\nThinking: off\n\n\(messageText)"
    }

    static func streamConversation(
        config: RequestConfig, messages: [WireMessage], tools: [ToolDef]?, continueResponse: Bool = false
    ) -> AsyncThrowingStream<LanguageTutorStreamEvent, Error> {
        var boundedConfig = config
        boundedConfig.temperature = min(max(config.temperature, 0.35), 0.8)
        boundedConfig.enableThinking = config.enableThinking ?? false
        let streamConfig = boundedConfig
        var messages = messages
        if continueResponse {
            let instruction = messages.last?.role == LanguageTutorRole.assistant.rawValue
                ? "Continue your previous answer from exactly where it stopped. Do not repeat text already provided."
                : "The previous generation stopped before producing visible text. Answer the user's request directly and concisely."
            if let lastIndex = messages.indices.last,
                messages[lastIndex].role == LanguageTutorRole.user.rawValue,
                case .text(let previous)? = messages[lastIndex].content
            {
                messages[lastIndex].content = .text(previous + "\n\n" + instruction)
            } else {
                messages.append(WireMessage(role: LanguageTutorRole.user.rawValue, text: instruction))
            }
        }
        let streamMessages = messages
        let request = conversationRequestTrace(config: streamConfig, messages: messages)

        return AsyncThrowingStream(LanguageTutorStreamEvent.self) { continuation in
            continuation.yield(.request(summary: request.summary, detail: request.detail))
            let task = Task {
                var response = ""
                var reasoning = ""
                var finishReason = "(not reported)"
                var usage: Usage?
                var responseGuard = RepeatedLineGuard()
                var reasoningGuard = RepeatedLineGuard()
                do {
                    streamLoop: for try await event in ChatService.stream(
                        config: streamConfig, messages: streamMessages, tools: tools)
                    {
                        switch event {
                        case .delta(let text) where !text.isEmpty:
                            response += text
                            continuation.yield(.delta(text))
                            if let repeated = responseGuard.consume(text) {
                                finishReason = "repetition"
                                continuation.yield(.repetition(channel: "reply text", sample: repeated))
                                break streamLoop
                            }
                        case .reasoning(let text):
                            reasoning += text
                            continuation.yield(.reasoningDelta(text))
                            if let repeated = reasoningGuard.consume(text) {
                                finishReason = "repetition"
                                continuation.yield(.repetition(channel: "reasoning", sample: repeated))
                                break streamLoop
                            }
                        case .usage(let value):
                            usage = value
                        case .toolCalls(let calls):
                            continuation.yield(.toolCalls(calls))
                        case .finish(let reason):
                            finishReason = reason ?? "(nil)"
                        case .delta, .toolCallDelta:
                            break
                        }
                    }
                    if finishReason != "repetition" {
                        if let repeated = responseGuard.finish() {
                            finishReason = "repetition"
                            continuation.yield(.repetition(channel: "reply text", sample: repeated))
                        } else if let repeated = reasoningGuard.finish() {
                            finishReason = "repetition"
                            continuation.yield(.repetition(channel: "reasoning", sample: repeated))
                        }
                    }
                } catch is CancellationError {
                    continuation.finish()
                    return
                } catch {
                    continuation.yield(.result(response))
                    if !reasoning.isEmpty { continuation.yield(.reasoning(reasoning)) }
                    if let usage { continuation.yield(.usage(usage)) }
                    continuation.yield(.finish(finishReason))
                    continuation.finish(throwing: error)
                    return
                }
                continuation.yield(.result(response))
                if !reasoning.isEmpty { continuation.yield(.reasoning(reasoning)) }
                if let usage { continuation.yield(.usage(usage)) }
                continuation.yield(.finish(finishReason))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func conversationRequestTrace(
        config: RequestConfig, messages: [WireMessage]
    ) -> (summary: String, detail: String) {
        let roles = messages.map(\.role).reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
            .map { "\($0.key):\($0.value)" }.sorted().joined(separator: " ")
        let summary = [
            "model=\(config.model)  temp=\(config.temperature)  maxTokens=\(config.maxTokens.map(String.init) ?? "default")",
            "messages=\(messages.count) [\(roles)]  thinking=\(config.enableThinking == true ? "on" : "off")"
        ].joined(separator: "\n")
        let detail = messages.map { message in
            let content: String
            switch message.content {
            case let .some(.text(text)):
                content = text
            case let .some(.parts(parts)):
                content = parts.map { $0.text ?? "[\($0.type)]" }.joined(separator: "\n")
            case .none:
                content = "(no content)"
            }
            return "── \(message.role) ──\n\(content)"
        }.joined(separator: "\n\n")
        return (summary, detail)
    }

    static func estimatedContextTokens(
        profile: LanguageProfile, knownItems: [LearnItem], history: [LanguageTutorMessage]
    ) -> Int {
        let bytes = conversationMessages(profile: profile, knownItems: knownItems, history: history)
            .reduce(0) { total, message in
                let contentBytes: Int
                switch message.content {
                case .text(let text): contentBytes = text.utf8.count
                case .parts(let parts): contentBytes = parts.reduce(0) { $0 + ($1.text?.utf8.count ?? 0) }
                case nil: contentBytes = 0
                }
                return total + contentBytes + 16
            }
        return (bytes + 3) / 4
    }

    static func conversationMessages(
        profile: LanguageProfile, knownItems: [LearnItem], history: [LanguageTutorMessage]
    ) -> [WireMessage] {
        let knownTerms = knownItems.filter { $0.kind == .vocab }.prefix(100).map(\.term).joined(separator: ", ")
        let system = """
        You are a patient language tutor helping the learner study \(profile.targetName) at \(profile.level.code). Explain in \(profile.baseName). \(profile.romanization.guidance) Use the learner's goals and script notes as preferences for explanations and examples: goals = \(profile.goals.isEmpty ? "not specified" : profile.goals); script notes = \(profile.scriptNotes.isEmpty ? "none" : profile.scriptNotes). Correct mistakes gently and keep the conversation natural. The following is a partial sample of recent known deck vocabulary, not a complete list; absence from it does not mean a word is unlearned: \(knownTerms). Do not claim a word is unlearned if it appears in that sample. Use language_deck_summary, language_deck_list, language_deck_search, language_due_items, and language_review_history to answer questions about the active deck and actual review history; the due queue is based on scheduled dates. These are read-only. Use add_vocabulary only when the learner explicitly asks to add or save words, not when merely discussing or suggesting vocabulary. That tool immediately saves valid new cards; report only what its result confirms. Do not control lessons, quizzes, grades, or any other deck data.
        """
        let visibleHistory = history.filter {
            $0.role == .user || !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return [WireMessage(role: "system", text: system)] + visibleHistory.suffix(16).map {
            WireMessage(role: $0.role.rawValue, text: String($0.content.prefix(4_000)))
        }
    }

    private static func jsonPayload(from response: String) -> String {
        guard let first = response.firstIndex(of: "{"),
              let last = response.lastIndex(of: "}"), first <= last
        else { return response }
        return String(response[first...last])
    }
}