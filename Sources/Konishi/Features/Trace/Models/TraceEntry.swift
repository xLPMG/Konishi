import Foundation

/// One entry in a conversation's live request/response trace.
struct TraceEntry: Identifiable, Sendable, Codable {
    enum Kind: String, CaseIterable, Sendable, Codable {
        case request, token, reasoning, usage, tool, result, finish, error, info, compress, memory
    }

    let id: UUID
    let date: Date
    let kind: Kind
    let text: String
    /// Optional full payload shown only on demand (e.g. the entire request sent to the model).
    let detail: String?

    init(kind: Kind, text: String, detail: String? = nil, date: Date = .now) {
        self.id = UUID()
        self.kind = kind
        self.text = text
        self.detail = detail
        self.date = date
    }
}
