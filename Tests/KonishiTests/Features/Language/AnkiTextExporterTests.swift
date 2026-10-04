import Foundation
import Testing

@testable import Konishi

@Suite("AnkiTextExporter")
struct AnkiTextExporterTests {
    @Test("renders UTF-8 vocabulary with Anki headers and omits empty sections")
    func headersAndFieldMapping() {
        let card = LearnItem(
            profileID: UUID(), kind: .vocab, term: "言葉", reading: "ことば", translation: "word",
            partOfSpeech: "noun", register: "neutral", examples: ["新しい言葉"],
            tags: ["reading", "daily"])
        let grammar = LearnItem(profileID: card.profileID, kind: .grammar, term: "～ている", translation: "ongoing")

        let rendered = AnkiTextExporter.render([grammar, card])
        #expect(rendered.hasPrefix("#separator:tab\n#html:true\n#notetype:Basic\n#columns:Front\tBack\tTags\n#tags column:3\n"))
        #expect(rendered.contains("言葉\t<b>Reading:</b> ことば<br><b>Translation:</b> word<br><b>Part of speech:</b> noun<br><b>Register:</b> neutral<br><b>Examples:</b> 新しい言葉\treading daily"))
        #expect(!rendered.contains("ongoing"))
        #expect(!rendered.contains("Notes:"))
    }

    @Test("escapes HTML and keeps tab/newline/quote records in three fields")
    func escapingAndTSVRecords() {
        let card = LearnItem(
            profileID: UUID(), kind: .vocab, term: "front\t\"quoted\"\nline", reading: "",
            translation: "Tom & Jerry <tag> \"word\"\tline\nnext", notes: "note\twith tab",
            tags: ["animals and pets", "日常", "animals   and pets"])
        let rendered = AnkiTextExporter.render([card])
        let body = String(rendered.split(separator: "\n", omittingEmptySubsequences: false).dropFirst(5).joined(separator: "\n"))
        let rows = parseTSV(body)

        #expect(rows.count == 1)
        #expect(rows[0].count == 3)
        #expect(rows[0][0] == "front\t&quot;quoted&quot;<br>line")
        #expect(rows[0][1].contains("Tom &amp; Jerry &lt;tag&gt; &quot;word&quot;\tline<br>next"))
        #expect(rows[0][1].contains("note\twith tab"))
        #expect(rows[0][2] == "animals_and_pets 日常")
    }

    @Test("creates a path-safe localized filename")
    func safeFilename() {
        #expect(AnkiTextExporter.defaultFilename(language: "Japanese") == "Konishi-Japanese-vocabulary.txt")
        #expect(AnkiTextExporter.defaultFilename(language: "A/B:C") == "Konishi-A-B-C-vocabulary.txt")
        #expect(AnkiTextExporter.defaultFilename(language: "///") == "Konishi-Language-vocabulary.txt")
    }

    private func parseTSV(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]
            if quoted {
                if character == "\"" {
                    let next = text.index(after: index)
                    if next < text.endIndex, text[next] == "\"" {
                        field.append("\"")
                        index = next
                    } else {
                        quoted = false
                    }
                } else {
                    field.append(character)
                }
            } else if character == "\"" && field.isEmpty {
                quoted = true
            } else if character == "\t" {
                row.append(field)
                field = ""
            } else if character == "\n" {
                row.append(field)
                rows.append(row)
                row = []
                field = ""
            } else {
                field.append(character)
            }
            index = text.index(after: index)
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }
}