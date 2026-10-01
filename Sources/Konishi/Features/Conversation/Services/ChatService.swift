import Foundation

/// Sendable snapshot of the settings the networking layer needs.
struct RequestConfig: Sendable {
    var chatURL: URL?
    var modelsURL: URL?
    var apiModelsURL: URL?
    var embeddingsURL: URL?
    var transcriptionsURL: URL?
    var speechURL: URL?
    var audioModelsURL: URL?
    var audioVoicesURL: URL?
    var model: String
    var temperature: Double
    var topP: Double?
    var maxTokens: Int?
    var stop: [String]?
    var seed: Int?
    var presencePenalty: Double?
    var frequencyPenalty: Double?
    var token: String
    var embeddingModel: String
    var sttModel: String
    var ttsModel: String
    var ttsVoice: String
    /// When set, passed as chat_template_kwargs.enable_thinking (Gemma thinking toggle).
    var enableThinking: Bool? = nil
}

enum ChatServiceError: LocalizedError {
    case invalidURL
    case badStatus(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "The base URL is invalid. Check it in Settings (⌘,)."
        case let .badStatus(code, body):
            let detail = body.isEmpty ? "" : "\n\(body.prefix(500))"
            return "Server returned HTTP \(code).\(detail)"
        }
    }
}

/// Stateless client for an OpenAI-compatible server (LM Studio / mlx_lm.server).
enum ChatService {

    // MARK: Streaming chat

    static func stream(
        config: RequestConfig,
        messages: [WireMessage],
        tools: [ToolDef]? = nil,
        toolChoice: String? = nil
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream(StreamEvent.self) { continuation in
            let task = Task {
                do {
                    try await runStream(config: config, messages: messages, tools: tools, toolChoice: toolChoice, continuation: continuation)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func runStream(
        config: RequestConfig,
        messages: [WireMessage],
        tools: [ToolDef]?,
        toolChoice: String? = nil,
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
    ) async throws {
        guard let url = config.chatURL else { throw ChatServiceError.invalidURL }

        let payload = makeRequest(config: config, messages: messages, tools: tools, toolChoice: toolChoice, stream: true)
        let request = try makeURLRequest(url: url, token: config.token, body: payload)
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        try await checkStatus(response, bytes: bytes)

        var toolAccum: [Int: (id: String, name: String, args: String)] = [:]
        var finishReason: String?

        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let data = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if data == "[DONE]" { break }
            guard let chunkData = data.data(using: .utf8),
                  let chunk = try? Wire.decoder.decode(ChatCompletionChunk.self, from: chunkData)
            else { continue }

            let delta = chunk.choices?.first?.delta
            if let content = delta?.content, !content.isEmpty {
                continuation.yield(.delta(content))
            }
            if let reasoning = delta?.reasoningContent ?? delta?.reasoning, !reasoning.isEmpty {
                continuation.yield(.reasoning(reasoning))
            }
            if let calls = delta?.toolCalls {
                for call in calls {
                    var entry = toolAccum[call.index] ?? (id: call.id ?? "", name: "", args: "")
                    var generated = ""
                    if let id = call.id { entry.id = id }
                    if let name = call.function?.name {
                        entry.name += name
                        generated += name
                    }
                    if let args = call.function?.arguments {
                        entry.args += args
                        generated += args
                    }
                    toolAccum[call.index] = entry
                    if !generated.isEmpty { continuation.yield(.toolCallDelta(generated)) }
                }
            }
            if let reason = chunk.choices?.first?.finishReason { finishReason = reason }
            if let usage = chunk.usage {
                continuation.yield(.usage(usage))
            }
        }

        if !toolAccum.isEmpty {
            let calls = toolAccum.sorted { $0.key < $1.key }.map { _, v in
                ToolCall(id: v.id.isEmpty ? UUID().uuidString : v.id,
                         type: "function",
                         function: FunctionCall(name: v.name, arguments: v.args))
            }
            continuation.yield(.toolCalls(calls))
        }
        continuation.yield(.finish(finishReason))
    }

    // MARK: Non-streaming completion (reflect / auto-title)

    /// Accumulates a full reply over the SSE stream. Streaming keeps the connection alive as tokens
    /// arrive, so slow generations (reflect/consolidation on a big model) don't hit a request timeout.
    static func completeStreaming(config: RequestConfig, messages: [WireMessage]) async throws -> String {
        var text = ""
        for try await event in stream(config: config, messages: messages) {
            if case let .delta(chunk) = event { text += chunk }
        }
        return text
    }

    static func complete(config: RequestConfig, messages: [WireMessage]) async throws -> String {
        guard let url = config.chatURL else { throw ChatServiceError.invalidURL }
        let payload = makeRequest(config: config, messages: messages, tools: nil, toolChoice: nil, stream: false)
        var request = try makeURLRequest(url: url, token: config.token, body: payload)
        request.timeoutInterval = 300   // non-streamed generation on a big model (reflect/compaction) can be slow
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw ChatServiceError.badStatus(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        let decoded = try Wire.decoder.decode(ChatCompletionResponse.self, from: data)
        return decoded.choices.first?.message.content ?? ""
    }

    // MARK: Embeddings

    static func embed(config: RequestConfig, inputs: [String]) async throws -> [[Double]] {
        guard let primary = config.embeddingsURL else { throw ChatServiceError.invalidURL }
        // Different servers mount the route differently (LM Studio: /v1/embeddings, infinity: /embeddings).
        // Try the configured path, then the alternate on a 404.
        let candidates = embedCandidates(primary)
        // Embed in small batches: a single huge request makes the server run one padded forward
        // pass whose peak memory grows with the batch size, and MLX caches those buffers instead
        // of freeing them — so a whole-vault embed would pin gigabytes. Batching keeps it bounded.
        var out: [[Double]] = []
        out.reserveCapacity(inputs.count)
        for start in stride(from: 0, to: inputs.count, by: maxEmbedBatch) {
            let slice = Array(inputs[start..<min(start + maxEmbedBatch, inputs.count)])
            out.append(contentsOf: try await embedSlice(candidates: candidates, config: config, inputs: slice))
        }
        return out
    }

    /// Max inputs per embedding request; caps the server's peak forward-pass memory.
    private static let maxEmbedBatch = 16

    private static func embedSlice(candidates: [URL], config: RequestConfig, inputs: [String]) async throws -> [[Double]] {
        var lastError: Error = ChatServiceError.invalidURL
        for url in candidates {
            do {
                return try await embedRequest(url: url, config: config, inputs: inputs)
            } catch {
                lastError = error
                if case ChatServiceError.badStatus(404, _) = error { continue }
                throw error
            }
        }
        throw lastError
    }

    private static func embedRequest(url: URL, config: RequestConfig, inputs: [String]) async throws -> [[Double]] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !config.token.isEmpty {
            request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try Wire.encoder.encode(EmbeddingsRequest(model: config.embeddingModel, input: inputs))
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw ChatServiceError.badStatus(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        let decoded = try Wire.decoder.decode(EmbeddingsResponse.self, from: data)
        return decoded.data.sorted { $0.index < $1.index }.map(\.embedding)
    }

    /// The configured embeddings URL plus its alternate route (/v1/embeddings ↔ /embeddings).
    private static func embedCandidates(_ url: URL) -> [URL] {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return [url] }
        let path = comps.path
        let altPath: String?
        if path.hasSuffix("/v1/embeddings") {
            altPath = String(path.dropLast("/v1/embeddings".count)) + "/embeddings"
        } else if path.hasSuffix("/embeddings") {
            altPath = String(path.dropLast("/embeddings".count)) + "/v1/embeddings"
        } else {
            altPath = nil
        }
        guard let altPath else { return [url] }
        comps.path = altPath
        return comps.url.map { [url, $0] } ?? [url]
    }

    // MARK: Audio (OpenAI-compatible)

    static func transcribe(config: RequestConfig, audio: Data, fileName: String) async throws -> String {
        guard let url = config.transcriptionsURL else { throw ChatServiceError.invalidURL }
        let boundary = "konishi-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if !config.token.isEmpty {
            request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        }

        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        field("model", config.sttModel)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(audio)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw ChatServiceError.badStatus(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        struct Transcription: Decodable { let text: String }
        return (try? JSONDecoder().decode(Transcription.self, from: data))?.text
            ?? String(data: data, encoding: .utf8) ?? ""
    }

    static func speech(config: RequestConfig, text: String) async throws -> Data {
        guard let url = config.speechURL else { throw ChatServiceError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !config.token.isEmpty {
            request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        }
        let payload: [String: String] = [
            "model": config.ttsModel,
            "voice": config.ttsVoice,
            "input": text,
            "response_format": "wav"
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw ChatServiceError.badStatus(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    // MARK: Models & connectivity

    static func fetchModels(config: RequestConfig) async throws -> [ModelInfo] {
        if let apiURL = config.apiModelsURL,
           let list = try? await getModels(url: apiURL, token: config.token),
           !list.isEmpty {
            return list
        }
        guard let url = config.modelsURL else { throw ChatServiceError.invalidURL }
        return try await getModels(url: url, token: config.token)
    }

    private static func getModels(url: URL, token: String) async throws -> [ModelInfo] {
        var request = URLRequest(url: url)
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw ChatServiceError.badStatus(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return try Wire.decoder.decode(ModelsResponse.self, from: data).data
    }

    static func ping(config: RequestConfig) async -> Bool {
        (try? await fetchModels(config: config)) != nil
    }

    /// Fetch models from the audio endpoint (may be a different server than chat).
    static func fetchAudioModels(config: RequestConfig) async throws -> [ModelInfo] {
        guard let url = config.audioModelsURL else { throw ChatServiceError.invalidURL }
        return try await getModels(url: url, token: config.token)
    }

    /// Fetch the voices a TTS model ships (mlx-audio: GET /v1/audio/voices?model=…).
    static func fetchVoices(config: RequestConfig, model: String) async throws -> [String] {
        guard let base = config.audioVoicesURL,
              var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)
        else { throw ChatServiceError.invalidURL }
        comps.queryItems = [URLQueryItem(name: "model", value: model)]
        guard let url = comps.url else { throw ChatServiceError.invalidURL }
        var request = URLRequest(url: url)
        if !config.token.isEmpty {
            request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw ChatServiceError.badStatus(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return (try? Wire.decoder.decode(VoicesResponse.self, from: data))?.data.map(\.id) ?? []
    }

    // MARK: Helpers

    private static func makeRequest(
        config: RequestConfig,
        messages: [WireMessage],
        tools: [ToolDef]?,
        toolChoice: String?,
        stream: Bool
    ) -> ChatCompletionRequest {
        ChatCompletionRequest(
            model: config.model,
            messages: messages,
            temperature: config.temperature,
            topP: config.topP,
            maxTokens: config.maxTokens,
            stream: stream,
            streamOptions: stream ? StreamOptions(includeUsage: true) : nil,
            stop: config.stop,
            seed: config.seed,
            presencePenalty: config.presencePenalty,
            frequencyPenalty: config.frequencyPenalty,
            tools: tools,
            toolChoice: toolChoice,
            // Cover the common template flags: enable_thinking (Gemma 4, Qwen3) + thinking (other templates).
            chatTemplateKwargs: config.enableThinking.map { ["enable_thinking": $0, "thinking": $0] },
            reasoningEffort: config.enableThinking == false ? "none" : nil
        )
    }

    private static func makeURLRequest(url: URL, token: String, body: ChatCompletionRequest) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 180   // allow slow prompt-processing to first token (streaming resets it per packet)
        request.httpBody = try Wire.encoder.encode(body)
        return request
    }

    private static func checkStatus(
        _ response: URLResponse,
        bytes: URLSession.AsyncBytes
    ) async throws {
        guard let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) else { return }
        var body = ""
        for try await line in bytes.lines { body += line }
        throw ChatServiceError.badStatus(http.statusCode, body)
    }
}
