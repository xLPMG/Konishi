import Foundation

/// Some local models (e.g. Gemma 4's thinking mode) emit their chain-of-thought *inline in the
/// assistant `content` stream* — wrapped as `<think>…</think>` or a `thought … <channel|> …`
/// channel split — instead of using the OpenAI `reasoning_content` field the app already routes to
/// the trace. Left unfiltered, that thinking leaks straight into the chat bubble (and TTS).
/// `ThinkStripper` consumes streamed content deltas and separates hidden reasoning from the
/// visible answer. It is stateful: feed it one stream's deltas in order, then call `finish()`.
struct ThinkStripper {
    struct Output {
        var visible = ""
        var reasoning = ""
    }

    /// An inline-reasoning block. `open` is matched only at the very start of the message (leading
    /// whitespace ignored). `loose` blocks use a permissive opener (a bare word), so an unterminated
    /// one is revealed as visible on `finish()` rather than silently dropped.
    private struct Block {
        let open: String
        let close: String
        let loose: Bool
    }

    private static let blocks: [Block] = [
        Block(open: "<think>", close: "</think>", loose: false),
        Block(open: "<thinking>", close: "</thinking>", loose: false),
        Block(open: "<|channel|>analysis<|message|>", close: "<|channel|>final<|message|>", loose: false),
        Block(open: "<|channel|>thought", close: "<channel|>", loose: false),
        Block(open: "<|channel>thought", close: "<channel|>", loose: false),
        Block(open: "thought", close: "<channel|>", loose: true),
    ]

    private static let maxOpenLen = blocks.map(\.open.count).max() ?? 0

    private enum State {
        case detecting
        case reasoning(close: String, looseFallback: String?)
        case passthrough
    }

    private var state: State = .detecting
    private var buffer = ""

    /// Feed one streamed content delta; returns the text to show and any stripped reasoning.
    mutating func consume(_ delta: String) -> Output {
        buffer += delta
        var out = Output()
        while true {
            switch state {
            case .detecting:
                let leading = buffer.prefix(while: { $0.isWhitespace })
                let trimmed = String(buffer.dropFirst(leading.count))
                if trimmed.isEmpty { return out }   // only whitespace so far — wait for a real char
                if let block = Self.blocks.first(where: { trimmed.hasPrefix($0.open) }) {
                    buffer = String(trimmed.dropFirst(block.open.count))
                    let looseFallback = block.loose ? String(leading) + block.open : nil
                    state = .reasoning(close: block.close, looseFallback: looseFallback)
                    continue
                }
                // Could the head still grow into an opener? If so, hold until it disambiguates.
                if trimmed.count < Self.maxOpenLen,
                   Self.blocks.contains(where: { $0.open.hasPrefix(trimmed) }) {
                    return out
                }
                out.visible += buffer
                buffer = ""
                state = .passthrough
                return out

            case let .reasoning(close, looseFallback):
                if let r = buffer.range(of: close) {
                    out.reasoning += buffer[..<r.lowerBound]
                    buffer = String(buffer[r.upperBound...])
                    state = .passthrough
                    continue
                }
                if looseFallback != nil { return out }
                // The close marker may be split across deltas: hold back a possible partial tail.
                let keep = Self.partialTail(of: buffer, marker: close)
                if buffer.count > keep {
                    let idx = buffer.index(buffer.endIndex, offsetBy: -keep)
                    out.reasoning += buffer[..<idx]
                    buffer = String(buffer[idx...])
                }
                return out

            case .passthrough:
                out.visible += buffer
                buffer = ""
                return out
            }
        }
    }

    /// Flush anything still buffered when the stream ends.
    mutating func finish() -> Output {
        var out = Output()
        switch state {
        case let .reasoning(_, looseFallback):
            // A well-delimited block that never closed is still reasoning (truncated); a loose one
            // is ambiguous, so surface it rather than lose the message.
            if let looseFallback {
                out.visible += looseFallback + buffer
            } else {
                out.reasoning += buffer
            }
        default:
            out.visible += buffer
        }
        buffer = ""
        state = .passthrough
        return out
    }

    /// Largest k (< marker length) where the last k chars of `text` equal the first k chars of
    /// `marker` — a possible split close marker to hold back for the next delta.
    private static func partialTail(of text: String, marker: String) -> Int {
        let t = Array(text), m = Array(marker)
        var k = min(t.count, m.count - 1)
        while k > 0 {
            if Array(t.suffix(k)) == Array(m.prefix(k)) { return k }
            k -= 1
        }
        return 0
    }
}
