import Testing

@testable import Konishi

@Suite("Inline reasoning stripping")
struct ThinkStripperTests {
    @Test("ordinary answers pass through unchanged")
    func ordinaryAnswerPassesThrough() {
        var stripper = ThinkStripper()
        let output = stripper.consume("A clear answer.")
        let final = stripper.finish()

        #expect(output.visible + final.visible == "A clear answer.")
        #expect(output.reasoning + final.reasoning == "")
    }

    @Test("strict think markers keep reasoning out of visible output")
    func thinkMarkers() {
        assertStripped(
            deltas: ["<think>private thoughts</think>Visible"],
            visible: "Visible",
            reasoning: "private thoughts")
    }

    @Test("longer thinking marker is not mistaken for think marker")
    func thinkingMarkerDoesNotCollideWithThink() {
        assertStripped(
            deltas: ["<thinking>private thoughts</thinking>Visible"],
            visible: "Visible",
            reasoning: "private thoughts")
    }

    @Test("channel markers and legacy thought markers are stripped")
    func channelMarkers() {
        assertStripped(
            deltas: ["<|channel|>analysis<|message|>private<|channel|>final<|message|>Answer"],
            visible: "Answer",
            reasoning: "private")
        assertStripped(
            deltas: ["<|channel|>thoughtprivate<channel|>Answer"],
            visible: "Answer",
            reasoning: "private")
        assertStripped(
            deltas: ["<|channel>thoughtprivate<channel|>Answer"],
            visible: "Answer",
            reasoning: "private")
    }

    @Test("opener, body, and closer may be split across deltas")
    func splitMarkers() {
        assertStripped(
            deltas: ["  <thi", "nk>hidden</thi", "nk>answer"],
            visible: "answer",
            reasoning: "hidden")
    }

    @Test("only a leading reasoning block is stripped")
    func onlyLeadingBlockIsStripped() {
        assertStripped(
            deltas: ["<think>hidden</think>Answer <think>literal"],
            visible: "Answer <think>literal",
            reasoning: "hidden")
    }

    @Test("unterminated strict blocks remain reasoning")
    func unterminatedStrictBlock() {
        assertStripped(
            deltas: ["<think>truncated thought"],
            visible: "",
            reasoning: "truncated thought")
    }

    @Test("unterminated loose thought is surfaced rather than discarded")
    func unterminatedLooseBlockIsVisible() {
        assertStripped(
            deltas: ["thought that might be an answer"],
            visible: "thought that might be an answer",
            reasoning: "")
    }

    @Test("leading whitespace is preserved with ordinary text")
    func leadingWhitespaceIsPreserved() {
        assertStripped(deltas: ["  Hello"], visible: "  Hello", reasoning: "")
    }

    private func assertStripped(deltas: [String], visible: String, reasoning: String) {
        var stripper = ThinkStripper()
        let outputs = deltas.map { stripper.consume($0) }
        let final = stripper.finish()
        let actualVisible = outputs.map(\.visible).joined() + final.visible
        let actualReasoning = outputs.map(\.reasoning).joined() + final.reasoning

        #expect(actualVisible == visible)
        #expect(actualReasoning == reasoning)
    }
}