import Foundation

struct MessageSuggestion: Identifiable, Equatable, Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        case reply
        case webSearch = "web_search"
        // Kept for suggestions saved by versions that used a Google-specific action type.
        case googleSearch = "google_search"
    }

    var kind: Kind
    var label: String
    var value: String

    var id: String { "\(kind.rawValue):\(value)" }
}

/// Removes the optional action footer before reply text reaches the chat bubble or TTS.
struct ResponseSuggestionStripper {
    struct Output {
        var visible = ""
        var suggestions: [MessageSuggestion] = []
        var footerFound = false
    }

    private struct Payload: Decodable {
        struct Item: Decodable {
            let type: String
            let label: String
            let value: String
        }

        let suggestions: [Item]
    }

    private static let opener = "<konishi_actions>"
    private static let closer = "</konishi_actions>"
    private static let maximumFooterLength = 4096

    private enum State {
        case scanning
        case footer
        case passthrough
    }

    private var state = State.scanning
    private var buffer = ""
    private var footerTooLarge = false

    mutating func consume(_ delta: String) -> Output {
        buffer += delta
        var output = Output()

        while true {
            switch state {
            case .scanning:
                if let range = buffer.range(of: Self.opener) {
                    output.visible += buffer[..<range.lowerBound]
                    buffer = String(buffer[range.upperBound...])
                    state = .footer
                    continue
                }

                let keep = Self.partialTail(of: buffer, marker: Self.opener)
                if buffer.count > keep {
                    let end = buffer.index(buffer.endIndex, offsetBy: -keep)
                    output.visible += buffer[..<end]
                    buffer = String(buffer[end...])
                }
                return output

            case .footer:
                if let range = buffer.range(of: Self.closer) {
                    output.footerFound = true
                    if !footerTooLarge {
                        output.suggestions = Self.parse(String(buffer[..<range.lowerBound]))
                    }
                    buffer = String(buffer[range.upperBound...])
                    footerTooLarge = false
                    state = .passthrough
                    continue
                }

                if buffer.count > Self.maximumFooterLength + Self.closer.count {
                    footerTooLarge = true
                    buffer = String(buffer.suffix(Self.closer.count - 1))
                }
                return output

            case .passthrough:
                output.visible += buffer
                buffer = ""
                return output
            }
        }
    }

    mutating func finish() -> Output {
        var output = Output()
        if case .scanning = state {
            output.visible = buffer
        } else if case .passthrough = state {
            output.visible = buffer
        }
        buffer = ""
        state = .passthrough
        return output
    }

    private static func parse(_ json: String) -> [MessageSuggestion] {
        guard let data = json.data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: data)
        else { return [] }

        var suggestions: [MessageSuggestion] = []
        for item in payload.suggestions.prefix(3) {
            guard let kind = MessageSuggestion.Kind(rawValue: item.type) else { continue }
            let label = item.label.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = item.value.trimmingCharacters(in: .whitespacesAndNewlines)
            let maximumValueLength = kind == .reply ? 500 : 250
            guard !label.isEmpty, label.utf8.count <= 48,
                  !value.isEmpty, value.utf8.count <= maximumValueLength,
                  !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            else { continue }

            let suggestion = MessageSuggestion(kind: kind, label: label, value: value)
            if !suggestions.contains(where: { $0.id == suggestion.id }) {
                suggestions.append(suggestion)
            }
        }
        return suggestions
    }

    private static func partialTail(of text: String, marker: String) -> Int {
        let characters = Array(text)
        let markerCharacters = Array(marker)
        var count = min(characters.count, markerCharacters.count - 1)
        while count > 0 {
            if Array(characters.suffix(count)) == Array(markerCharacters.prefix(count)) {
                return count
            }
            count -= 1
        }
        return 0
    }
}