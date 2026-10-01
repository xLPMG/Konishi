import Foundation

// MARK: - Message content (string or multimodal parts)

struct ImageURL: Codable, Sendable {
    let url: String
}

struct ContentPart: Codable, Sendable {
    let type: String            // "text" | "image_url"
    let text: String?
    let imageUrl: ImageURL?

    static func text(_ s: String) -> ContentPart { .init(type: "text", text: s, imageUrl: nil) }
    static func image(_ url: String) -> ContentPart { .init(type: "image_url", text: nil, imageUrl: ImageURL(url: url)) }
}

enum WireContent: Codable, Sendable {
    case text(String)
    case parts([ContentPart])

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case let .text(s): try c.encode(s)
        case let .parts(p): try c.encode(p)
        }
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { self = .text(s) }
        else { self = .parts(try c.decode([ContentPart].self)) }
    }
}

// MARK: - Tool calling

struct FunctionCall: Codable, Sendable {
    var name: String?
    var arguments: String
}

struct ToolCall: Codable, Sendable, Identifiable {
    let id: String
    let type: String
    let function: FunctionCall
}

struct FunctionDef: Codable, Sendable {
    let name: String
    let description: String
    let parameters: JSONValue
}

struct ToolDef: Codable, Sendable {
    let type: String
    let function: FunctionDef

    static func function(name: String, description: String, parameters: JSONValue) -> ToolDef {
        .init(type: "function", function: FunctionDef(name: name, description: description, parameters: parameters))
    }
}

// MARK: - Wire messages

struct WireMessage: Codable, Sendable {
    var role: String
    var content: WireContent?
    var toolCalls: [ToolCall]?
    var toolCallId: String?
    var name: String?

    init(role: String, text: String) {
        self.role = role
        self.content = .text(text)
    }
    init(role: String, parts: [ContentPart]) {
        self.role = role
        self.content = .parts(parts)
    }
    init(role: String, content: WireContent?, toolCalls: [ToolCall]? = nil, toolCallId: String? = nil, name: String? = nil) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
        self.name = name
    }
    static func toolResult(id: String, name: String, content: String) -> WireMessage {
        WireMessage(role: "tool", content: .text(content), toolCallId: id, name: name)
    }
}

struct StreamOptions: Codable, Sendable {
    let includeUsage: Bool
}

struct ChatCompletionRequest: Codable, Sendable {
    let model: String
    let messages: [WireMessage]
    let temperature: Double
    let topP: Double?
    let maxTokens: Int?
    let stream: Bool
    let streamOptions: StreamOptions?
    let stop: [String]?
    let seed: Int?
    let presencePenalty: Double?
    let frequencyPenalty: Double?
    let tools: [ToolDef]?
    let toolChoice: String?
    /// Extra kwargs forwarded to the server's chat template (e.g. enable_thinking for Gemma).
    var chatTemplateKwargs: [String: Bool]? = nil
    /// OpenAI-style switch some servers (e.g. Splash) honour instead of template kwargs; only "none" is sent.
    var reasoningEffort: String? = nil
}

// MARK: - Responses

struct Usage: Decodable, Sendable, Equatable {
    let promptTokens: Int?
    let completionTokens: Int?
    let totalTokens: Int?
}

struct ChatCompletionChunk: Decodable, Sendable {
    struct Choice: Decodable, Sendable {
        struct Delta: Decodable, Sendable {
            let role: String?
            let content: String?
            let reasoningContent: String?
            let reasoning: String?
            let toolCalls: [ToolCallDelta]?
        }
        let delta: Delta
        let finishReason: String?
    }
    let choices: [Choice]?
    let usage: Usage?
}

struct ToolCallDelta: Decodable, Sendable {
    let index: Int
    let id: String?
    let function: FunctionDelta?
}

struct FunctionDelta: Decodable, Sendable {
    let name: String?
    let arguments: String?
}

struct ChatCompletionResponse: Decodable, Sendable {
    struct Choice: Decodable, Sendable {
        struct Message: Decodable, Sendable {
            let content: String?
            let toolCalls: [ToolCall]?
        }
        let message: Message
    }
    let choices: [Choice]
    let usage: Usage?
}

/// Streaming event surfaced to the UI layer.
enum StreamEvent: Sendable {
    case delta(String)
    case reasoning(String)
    case usage(Usage)
    case toolCalls([ToolCall])
    case finish(String?)
}

// MARK: - Embeddings

struct EmbeddingsRequest: Codable, Sendable {
    let model: String
    let input: [String]
}

struct EmbeddingsResponse: Decodable, Sendable {
    struct Item: Decodable, Sendable {
        let embedding: [Double]
        let index: Int
    }
    let data: [Item]
}

// MARK: - Models listing

struct ModelInfo: Identifiable, Decodable, Sendable, Hashable {
    let id: String
    let state: String?
    let type: String?
    let maxContextLength: Int?
    let loadedContextLength: Int?

    /// nil when the server doesn't report load state (e.g. mlx_lm.server).
    var isLoaded: Bool? {
        guard let state else { return nil }
        return state == "loaded"
    }
}

struct ModelsResponse: Decodable, Sendable {
    let data: [ModelInfo]
}

struct VoicesResponse: Decodable, Sendable {
    struct Item: Decodable, Sendable { let id: String }
    let data: [Item]
}

// MARK: - Codec helpers

enum Wire {
    // Shared instances: configuring a snake_case coder is not free, and `decoder` is hit once
    // per streamed token in ChatService.runStream.
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()
}
