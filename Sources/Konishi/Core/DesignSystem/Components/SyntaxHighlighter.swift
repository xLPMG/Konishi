import SwiftUI

/// Lightweight, language-agnostic highlighter: strings, comments, numbers, and common keywords.
enum SyntaxHighlighter {
    private static let keywords: Set<String> = [
        "func", "let", "var", "if", "else", "for", "while", "return", "struct", "class",
        "enum", "protocol", "extension", "import", "guard", "switch", "case", "default",
        "public", "private", "static", "final", "async", "await", "throws", "try", "in",
        "def", "lambda", "print", "self", "None", "True", "False", "true", "false", "null",
        "const", "function", "new", "typeof", "interface", "type", "export", "from",
        "int", "double", "float", "string", "bool", "void", "nil", "do", "then", "end",
        "and", "or", "not", "with", "as", "yield", "match", "where"
    ]

    /// (pattern, color) rules, compiled once. Order matters: keywords/numbers first,
    /// then strings and comments override.
    private static let rules: [(regex: NSRegularExpression, color: Color)] = {
        let specs: [(String, String, NSRegularExpression.Options)] = [
            ("\\b(\(keywords.joined(separator: "|")))\\b", "#C792EA", []),
            ("\\b\\d+(?:\\.\\d+)?\\b", "#F78C6C", []),
            ("\"[^\"]*\"|'[^']*'", "#C3E88D", []),
            ("//[^\\n]*|#[^\\n]*", "#8792A2", []),
            ("/\\*.*?\\*/", "#8792A2", [.dotMatchesLineSeparators])
        ]
        return specs.compactMap { pattern, hex, options in
            (try? NSRegularExpression(pattern: pattern, options: options)).map { ($0, Color(hex: hex)) }
        }
    }()

    /// Small LRU-ish cache so a streaming code block isn't re-highlighted from scratch every token.
    @MainActor private static var cache: [String: AttributedString] = [:]
    @MainActor private static var cacheOrder: [String] = []
    private static let cacheLimit = 64

    @MainActor
    static func highlight(_ code: String, baseSize: Double) -> AttributedString {
        let key = "\(baseSize)\u{0}\(code)"
        if let cached = cache[key] { return cached }

        var out = AttributedString(code)
        out.font = Font.system(size: baseSize, weight: .regular, design: .monospaced)
        out.foregroundColor = .primary

        let range = NSRange(location: 0, length: (code as NSString).length)
        for (regex, color) in rules {
            for match in regex.matches(in: code, range: range) {
                guard let r = Range(match.range, in: out) else { continue }
                out[r].foregroundColor = color
            }
        }

        cache[key] = out
        cacheOrder.append(key)
        if cacheOrder.count > cacheLimit {
            let evict = cacheOrder.removeFirst()
            cache[evict] = nil
        }
        return out
    }
}
