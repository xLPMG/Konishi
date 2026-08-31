import Foundation

enum Role: String, Codable, Sendable {
    case system
    case user
    case assistant
    case tool
}

/// Per-response performance metrics shown in the stats bar.
struct MessageStats: Codable, Equatable, Sendable {
    var timeToFirstToken: Double?   // seconds
    var tokensPerSecond: Double?
    var promptTokens: Int?
    var completionTokens: Int?
    var totalTokens: Int?
    var duration: Double?           // seconds
}

/// A text document (PDF, source, markdown, etc.) whose extracted text is sent with the message.
struct Attachment: Identifiable, Equatable, Codable, Sendable {
    var id = UUID()
    var name: String
    var text: String
}

/// A web source (search result or fetched page) used while producing an assistant reply.
struct Source: Identifiable, Equatable, Codable, Sendable {
    var title: String
    var url: String
    var id: String { url }
}

struct ChatMessage: Identifiable, Equatable, Codable, Sendable {
    var id = UUID()
    var role: Role
    var content: String
    var stats: MessageStats?
    /// The model's streamed chain-of-thought (reasoning), shown in a collapsible section. Never re-sent.
    var reasoning: String?
    /// Base64 data URLs for attached images (vision).
    var images: [String]
    /// Extracted-text document attachments (PDF, text files) injected into the prompt.
    var attachments: [Attachment]
    /// Web sources gathered via web_search/web_fetch while writing this reply.
    var sources: [Source]
    /// True when the user spoke over this assistant response before it finished playing.
    var interrupted: Bool
    /// Tool calls requested by the assistant on this turn.
    var toolCalls: [ToolCall]?
    /// For tool-result messages.
    var toolCallId: String?
    var toolName: String?
    /// Rendered in the UI but never sent to the model (e.g. auto-attached plot images for servers
    /// that reject image content).
    var localOnly: Bool = false

    init(
        id: UUID = UUID(),
        role: Role,
        content: String,
        stats: MessageStats? = nil,
        reasoning: String? = nil,
        images: [String] = [],
        attachments: [Attachment] = [],
        sources: [Source] = [],
        interrupted: Bool = false,
        toolCalls: [ToolCall]? = nil,
        toolCallId: String? = nil,
        toolName: String? = nil,
        localOnly: Bool = false
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.stats = stats
        self.reasoning = reasoning
        self.images = images
        self.attachments = attachments
        self.sources = sources
        self.interrupted = interrupted
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
        self.toolName = toolName
        self.localOnly = localOnly
    }

    /// Rough byte size of extracted attachment text, for token budgeting.
    var attachmentBytes: Int { attachments.reduce(0) { $0 + $1.text.utf8.count } }

    private enum CodingKeys: String, CodingKey {
        case id, role, content, stats, reasoning, images, attachments, sources, interrupted, toolCalls, toolCallId, toolName, localOnly
    }

    // Tolerant decode so conversations saved before `images`/`attachments` existed still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        role = try c.decode(Role.self, forKey: .role)
        content = try c.decodeIfPresent(String.self, forKey: .content) ?? ""
        stats = try c.decodeIfPresent(MessageStats.self, forKey: .stats)
        reasoning = try c.decodeIfPresent(String.self, forKey: .reasoning)
        images = try c.decodeIfPresent([String].self, forKey: .images) ?? []
        attachments = try c.decodeIfPresent([Attachment].self, forKey: .attachments) ?? []
        sources = try c.decodeIfPresent([Source].self, forKey: .sources) ?? []
        interrupted = try c.decodeIfPresent(Bool.self, forKey: .interrupted) ?? false
        toolCalls = try c.decodeIfPresent([ToolCall].self, forKey: .toolCalls)
        toolCallId = try c.decodeIfPresent(String.self, forKey: .toolCallId)
        toolName = try c.decodeIfPresent(String.self, forKey: .toolName)
        localOnly = try c.decodeIfPresent(Bool.self, forKey: .localOnly) ?? false
    }
}

extension ToolCall: Equatable {
    static func == (lhs: ToolCall, rhs: ToolCall) -> Bool {
        lhs.id == rhs.id
            && lhs.function.name == rhs.function.name
            && lhs.function.arguments == rhs.function.arguments
    }
}
