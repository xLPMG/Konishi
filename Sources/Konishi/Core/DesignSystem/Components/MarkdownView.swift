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
                case let .table(headers, rows, alignments):
                    MarkdownTableView(
                        headers: headers,
                        rows: rows,
                        alignments: alignments,
                        baseSize: baseSize
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

        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).isEmpty || headingLevel(line) != nil
                || isBullet(line) || numberedItem(line) != nil || line.hasPrefix("> ") {
                flushParagraph()
                result.append(line)
            } else {
                paragraph.append(line)
            }
        }
        flushParagraph()
        return result
    }

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
        let displayText = LaTeX.render(s)
        if let attr = try? AttributedString(markdown: displayText, options: options) {
            return Text(attr).font(.system(size: baseSize))
        }
        return Text(displayText).font(.system(size: baseSize))
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

private struct MarkdownTableView: View {
    let headers: [String]
    let rows: [[String]]
    let alignments: [MarkdownView.TableAlignment]
    let baseSize: Double

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
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        let displayText = LaTeX.render(text)
        if let attributed = try? AttributedString(markdown: displayText, options: options) {
            return Text(attributed).font(.system(size: baseSize))
        }
        return Text(displayText).font(.system(size: baseSize))
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
