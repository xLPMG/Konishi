import Foundation
import Testing

@testable import Konishi

@Suite("Markdown rendering")
struct MarkdownRenderingTests {
    @Test("task list markers and indentation are parsed")
    func taskLists() {
        #expect(MarkdownSyntax.taskItem(from: "- [ ] open") == .init(
            indentationDepth: 0, isChecked: false, content: "open"))
        #expect(MarkdownSyntax.taskItem(from: "  * [X] nested") == .init(
            indentationDepth: 1, isChecked: true, content: "nested"))
        #expect(MarkdownSyntax.taskItem(from: "+ [ ] plus marker") == .init(
            indentationDepth: 0, isChecked: false, content: "plus marker"))
        #expect(MarkdownSyntax.taskItem(from: "- [x]missing") == nil)
    }

    @Test("horizontal rules require three matching markers")
    func horizontalRules() {
        #expect(MarkdownSyntax.isHorizontalRule("---"))
        #expect(MarkdownSyntax.isHorizontalRule("* * *"))
        #expect(!MarkdownSyntax.isHorizontalRule("--"))
        #expect(!MarkdownSyntax.isHorizontalRule("-*-"))
    }

    @Test("callouts collect quoted continuation lines")
    func callouts() {
        #expect(MarkdownSyntax.callout(from: "> [!WARNING]\n> Check the source.") == .init(
            kind: "WARNING", body: "Check the source."))
        #expect(MarkdownSyntax.callout(from: "> [!NOTE] Inline note") == .init(
            kind: "NOTE", body: "Inline note"))
        #expect(MarkdownSyntax.callout(from: "> [!UNKNOWN]\n> body") == nil)
    }

    @Test("citation indices link to the matching sources")
    func citations() {
        let first = Source(title: "One", url: "https://example.com/one")
        let second = Source(title: "Two", url: "https://example.com/two")
        let rendered = MarkdownInline.attributed("See [1, 2] for details.", sources: [first, second])
        let linkedURLs = Set(rendered.runs.compactMap(\.link))

        #expect(linkedURLs == [URL(string: first.url)!, URL(string: second.url)!])
    }

    @Test("explicit Markdown links are not treated as citations")
    func explicitLinks() {
        let source = Source(title: "Citation", url: "https://example.com/source")
        let markdown = MarkdownInline.attributed(
            "See [1](https://example.com/explicit), `[1]`, and [1].",
            sources: [source]
        )
        let linkedURLs = Set(markdown.runs.compactMap(\.link))
        let visibleText = String(markdown.characters)

        #expect(linkedURLs == [
            URL(string: source.url)!,
            URL(string: "https://example.com/explicit")!
        ])
        #expect(!visibleText.contains(source.url))
    }
}

@Suite("Science cards")
struct ScienceCardTests {
    @Test("bundled neutral atom shell counts match atomic numbers")
    func elementShells() {
        #expect(ChemicalElement.all.count == 118)
        for element in ChemicalElement.all {
            #expect(element.shells.reduce(0, +) == element.atomicNumber)
        }
        #expect(ChemicalElement.lookup("Fe")?.name == "Iron")
        #expect(ChemicalElement.lookup("8")?.symbol == "O")
    }

    @Test("explicit element and particle directives resolve locally")
    func directives() {
        let iron = ChemicalElement.lookup("iron")!
        let electron = PhysicsParticle.lookup("electron")!
        #expect(ScienceCard.parseDirective(":::element Fe") == .element(iron))
        #expect(ScienceCard.parseDirective(":::particle electron") == .particle(electron))
        #expect(ScienceCard.parseDirective(":::element Unknownium") == nil)
        #expect(ScienceCard.parseDirective(":::particle unknown") == nil)
        #expect(ScienceCard.parseDirective(":::element Fe extra") == nil)
    }
}

@Suite("Tool artifacts")
struct ToolArtifactTests {
    @Test("calculator output becomes a result artifact")
    func calculation() {
        #expect(ToolArtifact.make(
            toolName: "calculate",
            arguments: #"{"expression":"2 + 2"}"#,
            result: "2 + 2 = 4",
            sources: []
        ) == .calculation(expression: "2 + 2", value: "4", isError: false))
    }

    @Test("process status and output are separated")
    func processOutput() {
        #expect(ToolArtifact.make(
            toolName: "python_exec",
            arguments: "{}",
            result: "exit 1\nfailed",
            sources: []
        ) == .process(exitCode: 1, output: "failed"))
    }

    @Test("web tools require sources and unrelated tools keep plain output")
    func webAndFallback() {
        let source = Source(title: "Example", url: "https://example.com")
        #expect(ToolArtifact.make(
            toolName: "web_search", arguments: "{}", result: "result", sources: [source]
        ) == .sources([source]))
        #expect(ToolArtifact.make(
            toolName: "memory_read", arguments: "{}", result: "notes", sources: []
        ) == nil)
    }
}