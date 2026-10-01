import SwiftUI

/// Renders a Markdown string as a stack of blocks: headings, lists, quotes,
/// paragraphs (with inline styling) and fenced code blocks with a copy button.
struct MarkdownView: View {
    let text: String
    var baseSize: Double = 14
    var sources: [Source] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case let .code(code, language):
                    CodeBlockView(code: code, language: language, baseSize: baseSize)
                case let .table(headers, rows, alignments):
                    MarkdownTableView(
                        headers: headers,
                        rows: rows,
                        alignments: alignments,
                        baseSize: baseSize,
                        sources: sources
                    )
                case let .lines(lines):
                    ForEach(Array(groupedLines(lines).enumerated()), id: \.offset) { _, line in
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
        case table([String], [[String]], [TableAlignment])
    }

    fileprivate enum TableAlignment {
        case leading, center, trailing
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
            guard !buffer.isEmpty else { return }
            var plain: [String] = []

            func flushPlain() {
                if !plain.isEmpty { result.append(.lines(plain)); plain = [] }
            }

            var index = 0
            while index < buffer.count {
                if index + 1 < buffer.count,
                   let headers = tableCells(buffer[index]),
                   let alignments = tableSeparator(buffer[index + 1]),
                   headers.count == alignments.count {
                    flushPlain()
                    var rows: [[String]] = []
                    index += 2
                    while index < buffer.count,
                          let cells = tableCells(buffer[index]),
                          cells.count == headers.count {
                        rows.append(cells)
                        index += 1
                    }
                    result.append(.table(headers, rows, alignments))
                } else {
                    plain.append(buffer[index])
                    index += 1
                }
            }
            flushPlain()
            buffer = []
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

    private static func tableCells(_ line: String) -> [String]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|") else { return nil }
        var content = trimmed
        if content.hasPrefix("|") { content.removeFirst() }
        if content.hasSuffix("|") { content.removeLast() }

        var cells: [String] = []
        var cell = ""
        var escaped = false
        for character in content {
            if escaped {
                cell.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "|" {
                cells.append(cell.trimmingCharacters(in: .whitespaces))
                cell = ""
            } else {
                cell.append(character)
            }
        }
        if escaped { cell.append("\\") }
        cells.append(cell.trimmingCharacters(in: .whitespaces))
        return cells.count >= 2 ? cells : nil
    }

    private static func tableSeparator(_ line: String) -> [TableAlignment]? {
        guard let cells = tableCells(line) else { return nil }
        var alignments: [TableAlignment] = []
        for cell in cells {
            let marker = cell.replacingOccurrences(of: " ", with: "")
            let leadingColon = marker.hasPrefix(":")
            let trailingColon = marker.hasSuffix(":")
            let dashes = marker.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            guard dashes.count >= 3, dashes.allSatisfy({ $0 == "-" }) else { return nil }
            alignments.append(leadingColon && trailingColon ? .center : trailingColon ? .trailing : .leading)
        }
        return alignments
    }

    // MARK: Line rendering

    private func groupedLines(_ lines: [String]) -> [String] {
        var result: [String] = []
        var paragraph: [String] = []

        func flushParagraph() {
            if !paragraph.isEmpty { result.append(paragraph.joined(separator: "\n")); paragraph = [] }
        }

        var index = 0
        while index < lines.count {
            let line = lines[index]
            if line.trimmingCharacters(in: .whitespaces).isEmpty || headingLevel(line) != nil
                || isBullet(line) || numberedItem(line) != nil
                || MarkdownSyntax.isHorizontalRule(line) {
                flushParagraph()
                result.append(line)
            } else if line.hasPrefix("> ") {
                flushParagraph()
                var quoteLines = [line]
                while index + 1 < lines.count, lines[index + 1].hasPrefix("> ") {
                    index += 1
                    quoteLines.append(lines[index])
                }
                result.append(quoteLines.joined(separator: "\n"))
            } else {
                paragraph.append(line)
            }
            index += 1
        }
        flushParagraph()
        return result
    }

    @ViewBuilder
    private func lineView(_ raw: String) -> some View {
        let line = raw
        if line.trimmingCharacters(in: .whitespaces).isEmpty {
            Spacer().frame(height: 2)
        } else if MarkdownSyntax.isHorizontalRule(line) {
            Divider().padding(.vertical, 4)
        } else if let callout = MarkdownSyntax.callout(from: line) {
            let color = calloutColor(callout.kind)
            VStack(alignment: .leading, spacing: 4) {
                Label(callout.kind.capitalized, systemImage: calloutIcon(callout.kind))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(color)
                if !callout.body.isEmpty { inline(callout.body) }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1).fill(color).frame(width: 3)
            }
        } else if let heading = headingLevel(line) {
            inline(String(line.drop(while: { $0 == "#" || $0 == " " })))
                .font(.system(size: baseSize + CGFloat(8 - heading * 2), weight: .bold))
                .padding(.top, 2)
        } else if let task = MarkdownSyntax.taskItem(from: line) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: task.isChecked ? "checkmark.square.fill" : "square")
                    .foregroundStyle(task.isChecked ? Color.accentColor : Color.secondary)
                    .font(.system(size: baseSize - 1))
                    .padding(.top, 1)
                inline(task.content)
            }
            .padding(.leading, CGFloat(task.indentationDepth * 14))
        } else if isBullet(line) {
            HStack(alignment: .top, spacing: 6) {
                Text("•").foregroundStyle(.secondary)
                inline(bulletContent(line))
            }
            .padding(.leading, CGFloat(MarkdownSyntax.indentationDepth(line) * 14))
        } else if let (number, rest) = numberedItem(line) {
            HStack(alignment: .top, spacing: 6) {
                Text("\(number).").foregroundStyle(.secondary).monospacedDigit()
                inline(rest)
            }
            .padding(.leading, CGFloat(MarkdownSyntax.indentationDepth(line) * 14))
        } else if line.hasPrefix("> ") {
            inline(line.components(separatedBy: "\n").map { String($0.dropFirst(2)) }.joined(separator: "\n"))
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
        Text(MarkdownInline.attributed(s, sources: sources))
            .font(.system(size: baseSize))
    }

    private func calloutIcon(_ kind: String) -> String {
        switch kind.uppercased() {
        case "TIP": return "lightbulb"
        case "IMPORTANT": return "star"
        case "WARNING": return "exclamationmark.triangle"
        case "CAUTION": return "hand.raised"
        default: return "info.circle"
        }
    }

    private func calloutColor(_ kind: String) -> Color {
        switch kind.uppercased() {
        case "TIP": return .green
        case "IMPORTANT": return .purple
        case "WARNING": return .orange
        case "CAUTION": return .red
        default: return .blue
        }
    }

    private func headingLevel(_ line: String) -> Int? {
        var count = 0
        for ch in line { if ch == "#" { count += 1 } else { break } }
        return (count > 0 && count <= 6 && line.dropFirst(count).first == " ") ? count : nil
    }

    private func isBullet(_ line: String) -> Bool {
        let t = line.drop(while: { $0 == " " })
        return t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("+ ")
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
        guard after.hasPrefix(". ") || after.hasPrefix(") ") else { return nil }
        return (n, String(after.dropFirst(2)))
    }
}

enum MarkdownSyntax {
    struct TaskItem: Equatable {
        let indentationDepth: Int
        let isChecked: Bool
        let content: String
    }

    struct Callout: Equatable {
        let kind: String
        let body: String
    }

    static func indentationDepth(_ line: String) -> Int {
        line.prefix(while: { $0 == " " }).count / 2
    }

    static func taskItem(from line: String) -> TaskItem? {
        let leadingSpaces = line.prefix(while: { $0 == " " }).count
        let trimmed = line.dropFirst(leadingSpaces)
        guard trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") else { return nil }
        let body = trimmed.dropFirst(2)
        guard body.count >= 4 else { return nil }
        let characters = Array(body.prefix(4))
        guard characters[0] == "[", characters[2] == "]", characters[3] == " ",
              characters[1] == " " || characters[1] == "x" || characters[1] == "X" else {
            return nil
        }
        return TaskItem(
            indentationDepth: leadingSpaces / 2,
            isChecked: characters[1] != " ",
            content: String(body.dropFirst(4))
        )
    }

    static func isHorizontalRule(_ line: String) -> Bool {
        let markers = line.filter { !$0.isWhitespace }
        guard markers.count >= 3, let first = markers.first,
              first == "-" || first == "*" || first == "_" else { return false }
        return markers.allSatisfy { $0 == first }
    }

    static func callout(from quotedBlock: String) -> Callout? {
        let lines = quotedBlock.components(separatedBy: "\n")
        guard let first = lines.first, first.hasPrefix("> ") else { return nil }
        let firstContent = String(first.dropFirst(2))
        guard firstContent.hasPrefix("[!"), let close = firstContent.firstIndex(of: "]") else { return nil }
        let kind = String(firstContent[firstContent.index(firstContent.startIndex, offsetBy: 2)..<close]).uppercased()
        let knownKinds: Set<String> = ["NOTE", "TIP", "IMPORTANT", "WARNING", "CAUTION"]
        guard knownKinds.contains(kind) else { return nil }

        var bodyLines: [String] = []
        let firstBody = firstContent[firstContent.index(after: close)...].trimmingCharacters(in: .whitespaces)
        if !firstBody.isEmpty { bodyLines.append(firstBody) }
        bodyLines.append(contentsOf: lines.dropFirst().map { line in
            line.hasPrefix("> ") ? String(line.dropFirst(2)) : line
        })
        return Callout(kind: kind, body: bodyLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

enum MarkdownInline {
    private static let citationRegex = try! NSRegularExpression(
        pattern: #"\[(\d+(?:\s*,\s*\d+)*)\]"#,
        options: []
    )
    private static let numberRegex = try! NSRegularExpression(pattern: #"\d+"#, options: [])

    static func attributed(_ text: String, sources: [Source]) -> AttributedString {
        let displayText = linkedCitations(in: LaTeX.render(text), sources: sources)
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        let attributed = (try? AttributedString(markdown: displayText, options: options))
            ?? AttributedString(displayText)
        return attributed
    }

    private static func linkedCitations(in text: String, sources: [Source]) -> String {
        guard !sources.isEmpty else { return text }
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let matches = citationRegex.matches(in: text, range: fullRange)
        let rewritten = NSMutableString(string: text)
        for match in matches.reversed() {
            if isInsideCodeSpan(in: nsText, before: match.range.location) { continue }
            let followingIndex = NSMaxRange(match.range)
            if followingIndex < nsText.length {
                let nextCharacter = nsText.substring(with: NSRange(location: followingIndex, length: 1))
                if nextCharacter == "(" || nextCharacter == "[" { continue }
            }
            let digitsRange = match.range(at: 1)
            let digits = nsText.substring(with: digitsRange) as NSString
            let digitMatches = numberRegex.matches(
                in: digits as String,
                range: NSRange(location: 0, length: digits.length)
            )
            var links: [String] = []
            var valid = !digitMatches.isEmpty
            for digitMatch in digitMatches {
                guard let sourceIndex = Int(digits.substring(with: digitMatch.range)),
                      sources.indices.contains(sourceIndex - 1),
                      let url = URL(string: sources[sourceIndex - 1].url),
                      ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { continue }
                let destination = url.absoluteString
                    .replacingOccurrences(of: "<", with: "%3C")
                    .replacingOccurrences(of: ">", with: "%3E")
                    .replacingOccurrences(of: " ", with: "%20")
                links.append("[\(sourceIndex)](<\(destination)>)")
            }
            if links.count != digitMatches.count { valid = false }
            if valid { rewritten.replaceCharacters(in: match.range, with: links.joined(separator: ", ")) }
        }
        return rewritten as String
    }

    private static func isInsideCodeSpan(in text: NSString, before location: Int) -> Bool {
        var index = 0
        var delimiterLength: Int?
        while index < location {
            guard text.character(at: index) == 0x60 else {
                index += 1
                continue
            }
            let start = index
            while index < location, text.character(at: index) == 0x60 { index += 1 }
            let runLength = index - start
            var backslashes = 0
            var preceding = start - 1
            while preceding >= 0, text.character(at: preceding) == 0x5C {
                backslashes += 1
                preceding -= 1
            }
            guard backslashes.isMultiple(of: 2) else { continue }
            if delimiterLength == nil {
                delimiterLength = runLength
            } else if delimiterLength == runLength {
                delimiterLength = nil
            }
        }

        guard let delimiterLength else { return false }
        index = location
        while index < text.length {
            guard text.character(at: index) == 0x60 else {
                index += 1
                continue
            }
            let start = index
            while index < text.length, text.character(at: index) == 0x60 { index += 1 }
            let runLength = index - start
            var backslashes = 0
            var preceding = start - 1
            while preceding >= 0, text.character(at: preceding) == 0x5C {
                backslashes += 1
                preceding -= 1
            }
            if runLength == delimiterLength, backslashes.isMultiple(of: 2) { return true }
        }
        return false
    }
}

private struct MarkdownTableView: View {
    let headers: [String]
    let rows: [[String]]
    let alignments: [MarkdownView.TableAlignment]
    let baseSize: Double
    let sources: [Source]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                tableRow(headers, header: true)
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    tableRow(row, header: false)
                        .background(index.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.035))
                }
            }
            .overlay(Rectangle().stroke(.separator, lineWidth: 1))
        }
    }

    private func tableRow(_ cells: [String], header: Bool) -> some View {
        GridRow {
            ForEach(Array(cells.enumerated()), id: \.offset) { index, cell in
                inline(cell)
                    .fontWeight(header ? .semibold : .regular)
                    .frame(minWidth: 90, maxWidth: 260, alignment: frameAlignment(index))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .overlay(alignment: .trailing) {
                        Rectangle().fill(.separator).frame(width: 1)
                    }
            }
        }
        .background(header ? Color.primary.opacity(0.08) : Color.clear)
        .overlay(alignment: .bottom) {
            Rectangle().fill(.separator).frame(height: 1)
        }
    }

    private func inline(_ text: String) -> Text {
        Text(MarkdownInline.attributed(text, sources: sources))
            .font(.system(size: baseSize))
    }

    private func frameAlignment(_ index: Int) -> Alignment {
        guard alignments.indices.contains(index) else { return .leading }
        switch alignments[index] {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
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
