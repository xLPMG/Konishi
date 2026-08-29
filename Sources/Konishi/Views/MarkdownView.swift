import SwiftUI

/// Renders a Markdown string as a stack of blocks: headings, lists, quotes,
/// paragraphs (with inline styling) and fenced code blocks with a copy button.
struct MarkdownView: View {
    let text: String
    var baseSize: Double = 14

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case let .code(code, language):
                    CodeBlockView(code: code, language: language, baseSize: baseSize)
                case let .lines(lines):
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        lineView(line)
                    }
                }
            }
        }
    }

    // MARK: Block parsing

    private enum Block {
        case lines([String])
        case code(String, String?)
    }

    private var blocks: [Block] { Self.parse(text) }

    /// Bounded cache so stable messages aren't re-parsed on every render (hover, scroll, font change).
    @MainActor private static var cache: [String: [Block]] = [:]
    @MainActor private static var cacheOrder: [String] = []
    private static let cacheLimit = 128

    @MainActor
    private static func parse(_ text: String) -> [Block] {
        if let cached = cache[text] { return cached }
        let result = parseUncached(text)
        cache[text] = result
        cacheOrder.append(text)
        if cacheOrder.count > cacheLimit { cache[cacheOrder.removeFirst()] = nil }
        return result
    }

    private static func parseUncached(_ text: String) -> [Block] {
        var result: [Block] = []
        var buffer: [String] = []
        var inCode = false
        var codeLines: [String] = []
        var language: String?

        func flushLines() {
            if !buffer.isEmpty { result.append(.lines(buffer)); buffer = [] }
        }

        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if inCode {
                    result.append(.code(codeLines.joined(separator: "\n"), language))
                    codeLines = []; language = nil; inCode = false
                } else {
                    flushLines()
                    inCode = true
                    let tag = line.trimmingCharacters(in: .whitespaces).dropFirst(3)
                        .trimmingCharacters(in: .whitespaces)
                    language = tag.isEmpty ? nil : String(tag)
                }
                continue
            }
            if inCode { codeLines.append(line) } else { buffer.append(line) }
        }
        if inCode { result.append(.code(codeLines.joined(separator: "\n"), language)) }
        flushLines()
        return result
    }

    // MARK: Line rendering

    @ViewBuilder
    private func lineView(_ raw: String) -> some View {
        let line = raw
        if line.trimmingCharacters(in: .whitespaces).isEmpty {
            Spacer().frame(height: 2)
        } else if let heading = headingLevel(line) {
            inline(String(line.drop(while: { $0 == "#" || $0 == " " })))
                .font(.system(size: baseSize + CGFloat(8 - heading * 2), weight: .bold))
                .padding(.top, 2)
        } else if isBullet(line) {
            HStack(alignment: .top, spacing: 6) {
                Text("•").foregroundStyle(.secondary)
                inline(bulletContent(line))
            }
        } else if let (number, rest) = numberedItem(line) {
            HStack(alignment: .top, spacing: 6) {
                Text("\(number).").foregroundStyle(.secondary).monospacedDigit()
                inline(rest)
            }
        } else if line.hasPrefix("> ") {
            inline(String(line.dropFirst(2)))
                .padding(.leading, 8)
                .overlay(alignment: .leading) {
                    Rectangle().fill(.secondary).frame(width: 2)
                }
                .foregroundStyle(.secondary)
        } else {
            inline(line)
        }
    }

    private func inline(_ s: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        if let attr = try? AttributedString(markdown: s, options: options) {
            return Text(attr).font(.system(size: baseSize))
        }
        return Text(s).font(.system(size: baseSize))
    }

    private func headingLevel(_ line: String) -> Int? {
        var count = 0
        for ch in line { if ch == "#" { count += 1 } else { break } }
        return (count > 0 && count <= 6 && line.dropFirst(count).first == " ") ? count : nil
    }

    private func isBullet(_ line: String) -> Bool {
        let t = line.drop(while: { $0 == " " })
        return t.hasPrefix("- ") || t.hasPrefix("* ")
    }

    private func bulletContent(_ line: String) -> String {
        let t = line.drop(while: { $0 == " " })
        return String(t.dropFirst(2))
    }

    private func numberedItem(_ line: String) -> (Int, String)? {
        let t = line.drop(while: { $0 == " " })
        let digits = t.prefix(while: { $0.isNumber })
        guard !digits.isEmpty, let n = Int(digits) else { return nil }
        let after = t.dropFirst(digits.count)
        guard after.hasPrefix(". ") else { return nil }
        return (n, String(after.dropFirst(2)))
    }
}

private struct CodeBlockView: View {
    let code: String
    let language: String?
    let baseSize: Double
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language?.uppercased() ?? "CODE")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.black.opacity(0.25))

            ScrollView(.horizontal, showsIndicators: false) {
                Text(SyntaxHighlighter.highlight(code, baseSize: baseSize))
                    .textSelection(.enabled)
                    .padding(10)
            }
        }
        .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.08)))
    }
}
