import Foundation

enum AnkiTextExporter {
    static func vocabulary(from items: [LearnItem]) -> [LearnItem] {
        items.filter { $0.kind == .vocab }
            .sorted { lhs, rhs in
                let order = lhs.term.localizedStandardCompare(rhs.term)
                return order == .orderedSame ? lhs.id.uuidString < rhs.id.uuidString : order == .orderedAscending
            }
    }

    static func render(_ items: [LearnItem]) -> String {
        let cards = vocabulary(from: items)
        let header = [
            "#separator:tab",
            "#html:true",
            "#notetype:Basic",
            "#columns:Front\tBack\tTags",
            "#tags column:3",
        ].joined(separator: "\n")
        let notes = cards.map { item in
            let front = cleanHTMLText(item.term)
            let sections = backSections(for: item)
            let back = sections.joined(separator: "<br>")
            let tags = ankiTags(item.tags)
            return [front, back, tags].map(escapeTSVField).joined(separator: "\t")
        }
        return (notes.isEmpty ? header : header + "\n" + notes.joined(separator: "\n")) + "\n"
    }

    static func defaultFilename(language: String) -> String {
        let invalidCharacters: Set<Character> = ["/", "\\", ":", "*", "?", "\"", "<", ">", "|"]
        let safe = String(language.map { character -> Character in
            character.isNewline || character.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
                || invalidCharacters.contains(character) ? "-" : character
        })
        .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        let filenameLanguage = safe.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return "Konishi-\(filenameLanguage.isEmpty ? "Language" : filenameLanguage)-vocabulary.txt"
    }

    private static func backSections(for item: LearnItem) -> [String] {
        var sections: [String] = []
        append("Reading", item.reading, to: &sections)
        append("Translation", item.translation, to: &sections)
        append("Part of speech", item.partOfSpeech, to: &sections)
        append("Register", item.register, to: &sections)
        let examples = item.examples.map(cleanHTMLText).filter { !$0.isEmpty }
        if !examples.isEmpty {
            sections.append("<b>Examples:</b> " + examples.joined(separator: "<br>"))
        }
        append("Notes", item.notes, to: &sections)
        return sections
    }

    private static func append(_ label: String, _ value: String, to sections: inout [String]) {
        let content = cleanHTMLText(value)
        guard !content.isEmpty else { return }
        sections.append("<b>\(label):</b> \(content)")
    }

    private static func cleanHTMLText(_ value: String) -> String {
        escapeHTML(value.trimmingCharacters(in: .whitespacesAndNewlines))
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n", with: "<br>")
    }

    private static func escapeHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private static func ankiTags(_ tags: [String]) -> String {
        var seen = Set<String>()
        return tags.compactMap { tag -> String? in
            let token = tag.split(whereSeparator: \.isWhitespace).joined(separator: "_")
            guard !token.isEmpty,
                  !token.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  seen.insert(token.lowercased()).inserted
            else { return nil }
            return token
        }
        .joined(separator: " ")
    }

    private static func escapeTSVField(_ value: String) -> String {
        guard value.contains("\t") || value.contains("\n") || value.contains("\r") || value.contains("\"") else {
            return value
        }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}