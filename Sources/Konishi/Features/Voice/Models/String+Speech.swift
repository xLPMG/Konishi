import Foundation

extension String {
    /// Strips Markdown syntax and emojis so text-to-speech reads clean prose.
    var strippedForSpeech: String {
        var s = self
        s = s.replacingOccurrences(of: "```[\\s\\S]*?```", with: " ", options: .regularExpression)   // code fences
        s = s.replacingOccurrences(of: "!\\[[^\\]]*\\]\\([^\\)]*\\)", with: " ", options: .regularExpression) // images
        s = s.replacingOccurrences(of: "\\[([^\\]]+)\\]\\([^\\)]*\\)", with: "$1", options: .regularExpression) // links -> text
        s = LaTeX.speech(s)                                                                             // LaTeX/math -> spoken words
        s = s.replacingOccurrences(of: "(?m)^\\s{0,3}#{1,6}\\s*", with: "", options: .regularExpression) // headings
        s = s.replacingOccurrences(of: "(?m)^\\s*[-*+]\\s+", with: "", options: .regularExpression)     // bullets
        s = s.replacingOccurrences(of: "(?m)^\\s*>\\s?", with: "", options: .regularExpression)         // quotes
        s = s.replacingOccurrences(of: "[*_`~]", with: "", options: .regularExpression)                 // emphasis / inline code
        s = String(s.unicodeScalars.filter { !$0.isEmojiLike })
        s = s.replacingOccurrences(
            of: "(?i)(?<![\\p{L}\\p{N}])(?:[:;=8x][\\-^]?[)(/\\\\|dp]|[)(/\\\\|][\\-^]?[:;=8x]|<3)(?=$|[\\s,.!?])",
            with: " ", options: .regularExpression
        ) // emoticons and hearts
        s = s.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\n{2,}", with: "\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension Unicode.Scalar {
    var isEmojiLike: Bool {
        if value == 0x200D || value == 0xFE0F || value == 0x20E3 { return true } // ZWJ, variation selector, keycap
        if properties.isEmojiPresentation { return true }
        switch value {
        case 0x1F000...0x1FAFF, 0x2600...0x27BF, 0x2B00...0x2BFF,
             0x1F1E6...0x1F1FF, 0x2300...0x23FF:
            return true
        default:
            return false
        }
    }
}
