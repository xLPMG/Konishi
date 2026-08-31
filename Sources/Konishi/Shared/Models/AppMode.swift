import Foundation

/// Top-level interaction mode. Each swaps the toolset + system prompt.
enum AppMode: String, CaseIterable, Identifiable, Sendable {
    case chat
    case conversational
    case language

    var id: String { rawValue }

    var label: String {
        switch self {
        case .chat: "Chat"
        case .conversational: "Voice"
        case .language: "Learn"
        }
    }

    var icon: String {
        switch self {
        case .chat: "bubble.left.and.bubble.right"
        case .conversational: "waveform"
        case .language: "character.book.closed"
        }
    }
}
