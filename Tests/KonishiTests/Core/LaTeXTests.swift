import Testing

@testable import Konishi

@Suite("LaTeX")
struct LaTeXTests {

    @Test("strips inline math delimiters and decodes commands")
    func inlineMath() {
        #expect(LaTeX.render("value is $\\Delta x$ today") == "value is `Δx` today")
        #expect(LaTeX.render("$5 \\cdot 10^{-3}$") == "`5·10⁻³`")
        #expect(LaTeX.render("$a \\approx b$") == "`a ≈ b`")
    }

    @Test("decodes stray escapes and commands outside math")
    func bareCommands() {
        #expect(LaTeX.render("about 50\\% done") == "about 50% done")
        #expect(LaTeX.render("the \\Delta value") == "the Δ value")
        #expect(LaTeX.render("\\text{hello} world") == "hello world")
        #expect(LaTeX.render("speed \\cdot time") == "speed · time")
    }

    @Test("frac and sqrt")
    func fracAndSqrt() {
        #expect(LaTeX.decodeMath("\\frac{1}{2}") == "1/2")
        #expect(LaTeX.decodeMath("\\frac{a+b}{c}") == "(a + b)/c")
        #expect(LaTeX.decodeMath("\\sqrt{2}") == "√2")
        #expect(LaTeX.decodeMath("\\sqrt{x+y}") == "√(x + y)")
    }

    @Test("superscripts and subscripts")
    func scripts() {
        #expect(LaTeX.decodeMath("x^2") == "x²")
        #expect(LaTeX.decodeMath("x_i") == "xᵢ")
        #expect(LaTeX.decodeMath("10^{-3}") == "10⁻³")
        #expect(LaTeX.decodeMath("a^{n+1}") == "aⁿ⁺¹")
    }

    @Test("display math and bracket delimiters")
    func displayMath() {
        #expect(LaTeX.render("$$E = mc^2$$") == "`E = mc²`")
        #expect(LaTeX.render("\\(a + b\\)") == "`a + b`")
        #expect(LaTeX.render("\\[x^2\\]") == "`x²`")
    }

    @Test("currency is not treated as math")
    func currency() {
        #expect(LaTeX.render("$5 and $10 total") == "$5 and $10 total")
    }

    @Test("prose is left untouched, snake_case survives")
    func prose() {
        #expect(LaTeX.render("call some_function() now") == "call some_function() now")
        #expect(LaTeX.render("use **bold** and _italic_") == "use **bold** and _italic_")
    }

    @Test("speech decodes math and commands to spoken words")
    func speech() {
        #expect(LaTeX.speech("about 50\\% done").contains("50 percent"))
        #expect(LaTeX.speech("$x^2$").contains("squared"))
        #expect(LaTeX.speech("$a \\approx b$").contains("approximately"))
        #expect(LaTeX.speech("$\\frac{a}{b}$").contains("a over b"))
        #expect(LaTeX.speech("$\\sqrt{2}$").contains("square root of 2"))
        #expect(LaTeX.speech("value is $\\Delta x$").contains("delta"))
        // no leftover math delimiters or backslashes
        #expect(!LaTeX.speech("$\\Delta x \\approx 5 \\cdot 10^{-3}\\%$").contains("\\"))
        #expect(!LaTeX.speech("$x^2$").contains("$"))
    }

    @Test("Greek letters stay separate words in speech")
    func speechGreek() {
        // e^{i\pi} must not glue into "ipi"
        let s = LaTeX.speech("$e^{i\\pi} + 1 = 0$")
        #expect(s.contains("i pie"))
        #expect(!s.contains("ipi"))
        let ab = LaTeX.speech("$\\alpha\\beta$")
        #expect(!ab.contains("alphabeta"))
    }
}
